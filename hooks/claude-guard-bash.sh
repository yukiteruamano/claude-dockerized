#!/bin/bash -p
# claude-guard-bash.sh - Claude Code PreToolUse hook (matcher: Bash).
#
# Native security enforcement for claude-dockerized. Mounted read-only into the
# container at /home/coder/.claude/hooks-guard/. Edit the repo copy (hooks/)
# and run `claude-dockerized config sync`: the installed copy under
# ~/.config/claude-dockerized/hooks/ is verified byte for byte, and local
# edits there are reported as drift and restored (with a .bak).
#
# Protocol: Claude Code passes tool input as JSON via stdin. Exit 2 + stderr
# blocks the action (feedback to Claude); exit 0 means no objection and the
# normal permissions flow applies. Any other exit is a non-blocking error for
# Claude Code (the tool still runs), so every failure path here exits 2.
#
# The shebang is `bash -p`: privileged mode never sources $BASH_ENV/$ENV, which
# a project's settings `env` could otherwise point at a script that exits 0
# before this file runs. The managed policy also pins those variables empty.
#
# CLAUDE_DOCKERIZED_GUARD_VERSION=8
#
# Policy modes (./policy-mode, written by the wrapper next to this hook on the
# read-only mount; CLAUDE_DOCKERIZED_POLICY is only a fallback because project
# settings can inject env vars; default "balanced"; unknown values → strict):
#   strict   — every vendored policy pattern is enforced as-is.
#   balanced — cloud-tenant rules, admin_bypass rules and patterns that fire on
#              ordinary local development are dropped (recommended).
#   none     — vendored patterns disabled entirely ("off" accepted as alias);
#              the built-in backstops below and settings.json permissions remain.
#
# Remote handling is allowed by default in ALL modes: git over SSH, remote MCP
# (http/sse), registries and APIs are legitimate flows. Only destruction,
# exfiltration, secrets and Docker escapes are blocked — never the fact of
# operating against a remote.

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="$HOOK_DIR/policies"

# Trusted tool path (T-04): never the inherited PATH, whose first entry is the
# session-writable ~/.local/bin. ./hook-path (read-only mount; tests stage their
# own) may pin it; the default holds the image's root-owned binaries.
TRUSTED_PATH="/usr/local/lib/claude-dockerized/bin:/usr/bin:/bin"
if [ -r "$HOOK_DIR/hook-path" ]; then
    IFS= read -r TRUSTED_PATH <"$HOOK_DIR/hook-path" || true
fi
export PATH="$TRUSTED_PATH"
# Nothing injected through settings `env` may reach the tools this hook spawns.
unset BASH_ENV ENV NODE_OPTIONS NODE_PATH LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT

deny_reason() {
    printf 'Blocked by claude-dockerized security policy: %s\n' "$1" >&2
    exit 2
}

# Policy mode: ./policy-mode wins over the env fallback; unknown → strict.
POLICY_MODE="${CLAUDE_DOCKERIZED_POLICY:-balanced}"
if [ -r "$HOOK_DIR/policy-mode" ]; then
    IFS= read -r POLICY_MODE <"$HOOK_DIR/policy-mode" || true
fi
POLICY_MODE="$(printf '%s' "$POLICY_MODE" | tr '[:upper:]' '[:lower:]')"
case "$POLICY_MODE" in
strict | balanced | none) ;;
off) POLICY_MODE="none" ;;
*) POLICY_MODE="strict" ;;
esac

INPUT="$(cat)"
[ -n "$INPUT" ] || deny_reason "empty hook payload"

# Extract .tool_input.command with jq, python3 or node. A payload that does
# not parse is refused (exit 3 from the parser); a missing command prints "".
extract_command() {
    if command -v jq >/dev/null 2>&1; then
        jq -er 'if type == "object" then (.tool_input.command // "") else error("not an object") end' 2>/dev/null <<<"$INPUT" || return 3
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    assert isinstance(d,dict)
except Exception:
    sys.exit(3)
ti=d.get("tool_input") or {}
print(ti.get("command","") if isinstance(ti,dict) else "")' 2>/dev/null <<<"$INPUT" || return 3
        return 0
    fi
    if command -v node >/dev/null 2>&1; then
        node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let d;try{d=JSON.parse(s)}catch{process.exit(3)}if(!d||typeof d!=="object")process.exit(3);console.log(d.tool_input?.command??"")})' 2>/dev/null <<<"$INPUT" || return 3
        return 0
    fi
    # No parser at all: match the raw payload (over-blocks, never under-blocks).
    printf '%s' "$INPUT"
}
CMD="$(extract_command)" || deny_reason "unparseable hook payload"
[ -z "$CMD" ] && exit 0
# A huge command could keep the regex engines busy past the hook timeout, and
# Claude Code runs the tool when a hook times out (T-11). Real commands are far
# below this; file content belongs in the Write tool.
MAX_COMMAND_CHARS=65536
[ "${#CMD}" -le "$MAX_COMMAND_CHARS" ] ||
    deny_reason "command longer than 64 KiB (${#CMD} characters); split it or write large content with the Write tool"

# Normalize shell word-separator obfuscation back to spaces before matching
# (port of guard normalizeShell): ${IFS...}, $IFS, $IFS$9, $'\t', $'\n'.
# shellcheck disable=SC2016 # the $'…' shapes are intentional sed literals, not expansions
NORM="$(printf '%s' "$CMD" | sed -e 's/\${IFS[^}]*}/ /gI' -e 's/\$IFS\(\$[0-9@*]\)\{0,1\}/ /gI' -e "s/\\$'\\\\t'/ /g" -e "s/\\$'\\\\n'/ /g")"

deny() {
    printf 'Blocked by claude-dockerized security policy: %s\n' "$CMD" >&2
    exit 2
}

deny_policy() {
    printf 'Blocked by workspace policy (policy/%s): %s\n' "$1" "$2" >&2
    exit 2
}

# Remote-operation safeguard (balanced/none): the vendored set must never block
# a plain remote flow (git over SSH, a registry download, an MCP endpoint). The
# override trusts the shape of one plain command, so anything chained,
# expanded, redirected, escaped, uploading or reconfiguring is judged by the
# vendored rules like in strict.
REMOTE_OPTS='([[:space:]]+-[^[:space:]]+)*'
REMOTE_REGISTRY="^curl${REMOTE_OPTS}[[:space:]]+https://(registry\\.npmjs\\.org|pypi\\.org|files\\.pythonhosted\\.org)(/[^[:space:]]*)?${REMOTE_OPTS}\$"
REMOTE_MCP="^(curl|wget)${REMOTE_OPTS}[[:space:]]+https://[^/[:space:]@]+(/[^[:space:]]*)?/mcp([/?#][^[:space:]]*)?${REMOTE_OPTS}\$"
remote_flow_ok() {
    local word lc
    local -a words=()
    case "$CMD" in
    *\;* | *\&* | *\|* | *\`* | *\$* | *\<* | *\>* | *\(* | *\)* | *\\* | *$'\n'* | *$'\r'*) return 1 ;;
    esac
    # Uploads: -d/-F/-T/-K alone or inside a short-option cluster (-sT/x).
    read -r -a words <<<"$CMD"
    for word in "${words[@]}"; do
        case "$word" in
        --data* | --form* | --upload-file* | --post* | --json* | --body* | --config* | --method*) return 1 ;;
        --*) ;;
        -*[dFTK]*) return 1 ;;
        esac
    done
    case "$CMD" in
    "git clone git@"* | "git ls-remote git@"* | "git fetch git@"* | "git pull git@"* | "git push git@"*)
        lc="$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')"
        case "$lc" in *sshcommand* | *ext::* | *fd::*) return 1 ;; esac
        # Options that run a program or rewrite the config: -c/--config,
        # --upload-pack/-u (not push's -u), --receive-pack/--exec, --template.
        read -r -a words <<<"$lc"
        for word in "${words[@]}"; do
            case "$word" in
            -c* | --config* | --upload-pack* | --receive-pack* | --exec* | --template*) return 1 ;;
            -u*) case "$lc" in "git push "*) ;; *) return 1 ;; esac ;;
            esac
        done
        return 0
        ;;
    esac
    [[ "$CMD" =~ $REMOTE_REGISTRY ]] && return 0
    [[ "$CMD" =~ $REMOTE_MCP ]] && return 0
    return 1
}

# --- Vendored policy patterns (exact JS RegExp semantics via node) ---
# An allow match (templates, public keys) only removes the matched tokens; the
# vendored deny rules still judge the rest and the built-in backstops below
# always run (T-08). The engine runs under a hard deadline below the hook
# timeout: a pathological input is refused, never waved through (T-11).
POLICY_ENGINE_SECONDS=15
# ./engine-seconds (read-only mount like ./hook-path; tests stage a short one)
# may only shorten the deadline.
if [ -r "$HOOK_DIR/engine-seconds" ]; then
    IFS= read -r _secs <"$HOOK_DIR/engine-seconds" || true
    case "${_secs:-}" in
    [1-9] | 1[0-5]) POLICY_ENGINE_SECONDS="$_secs" ;;
    esac
fi
if [ "$POLICY_MODE" != "none" ]; then
    command -v node >/dev/null 2>&1 || deny_reason "policy engine unavailable (node not found on the trusted path)"
    command -v timeout >/dev/null 2>&1 || deny_reason "policy engine deadline unavailable (timeout not found on the trusted path)"
    export CGB_CMD="$CMD"
    export CGB_POLICY_MODE="$POLICY_MODE"
    export CGB_POLICIES_DIR="$POLICIES_DIR"
    _rc=0
    VENDORED_RESULT="$(timeout -s KILL "$POLICY_ENGINE_SECONDS" node "$HOOK_DIR/guard-eval.js" 2>/dev/null)" || _rc=$?
    case "$_rc" in
    0) ;;
    124 | 137) VENDORED_RESULT="error|policy engine timed out (command too complex to evaluate)" ;;
    *) VENDORED_RESULT="error|policy engine crashed" ;;
    esac
    case "$VENDORED_RESULT" in
    allow | pass) ;;
    deny\|*)
        _rid="${VENDORED_RESULT#deny|}"
        _rid="${_rid%%|*}"
        _reason="${VENDORED_RESULT#deny|*|}"
        if [ "$POLICY_MODE" = "strict" ] || ! remote_flow_ok; then
            deny_policy "$_rid" "$_reason"
        fi
        ;;
    error\|*) deny_reason "${VENDORED_RESULT#error|}" ;;
    *) deny_reason "unexpected policy engine output" ;;
    esac
fi

# --- Built-in backstops (mode-independent) ---
# Quotes and backslashes do not end a word in the shell: `.e""nv`,
# `id_ed"25519"` and `.e\nv` run as `.env` and `id_ed25519`, so the backstops
# also see the form without them (T-26).
UNQUOTED="$(printf '%s' "$NORM" | tr -d '"'"'"'\\')"
T="$CMD
$NORM
$UNQUOTED"
match() { printf '%s' "$T" | grep -Eq "$1"; }

# sudo anywhere (including prose/commit messages/grep patterns by design)
match '(^|[^[:alnum:]_])sudo([^[:alnum:]_]|$)' && deny
# rm -rf / variants, /* globs and /.. traversals
match 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+/' && deny
match 'rm[[:space:]]+.*[[:space:]]+/[[:space:]]*$' && deny
match 'rm[[:space:]]+[^|;&]*[[:space:]]/\*([[:space:];|&]|$)' && deny
match 'rm[[:space:]]+[^|;&]*/\.\.(/|$)' && deny
# recursive rm of the home or the working tree itself (~, $HOME, ., ..)
match 'rm[[:space:]]+[^|;&]*-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+([^|;&]*[[:space:]])?["'"'"']?(~|\$HOME|\$\{HOME\}|\.\.?)["'"'"']?/?["'"'"']?([[:space:];|&]|$)' && deny
# ... and of everything in the home (rm -rf ~/*), or a find that deletes from
# the home or the root (find ~ -delete, find / -exec rm)
HOMEWORD='["'"'"']?(~|\$HOME|\$\{HOME\}|/home/[^/[:space:];|&]+)["'"'"']?/?\*?["'"'"']?([[:space:];|&]|$)'
match "rm[[:space:]]+[^|;&]*-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+([^|;&]*[[:space:]])?${HOMEWORD}" && deny
match '(^|[^[:alnum:]_])find[[:space:]]+([^|;&]*[[:space:]])?["'"'"']?(~|\$HOME|\$\{HOME\}|/home/[^/[:space:];|&]+|/)["'"'"']?/?["'"'"']?[[:space:]][^|&]*(-delete|-exec(dir)?[[:space:]]+([^[:space:]]*/)?(rm|shred|unlink))([^[:alnum:]_]|$)' && deny
match '(^|[^[:alnum:]_])mkfs(\.[[:alnum:]_]+)?([^[:alnum:]_]|$)' && deny
match '(^|[^[:alnum:]_])dd([^[:alnum:]_]|$)[^|;&]*of=/(dev/)?[a-z]' && deny
match '(^|[^[:alnum:]_])(shutdown|reboot|halt|poweroff)([^[:alnum:]_]|$)' && deny
match 'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*0?777[[:space:]]+/' && deny
match 'chmod[[:space:]]+[^|;&]*[[:space:]]/\*([[:space:];|&]|$)' && deny
match 'chmod[[:space:]]+[^|;&]*/\.\.(/|$)' && deny
match 'chown[[:space:]]+[^|;&]*[[:space:]]/([[:space:];|&*]|$)' && deny
match 'chown[[:space:]]+[^|;&]*/\.\.(/|$)' && deny
match '>[[:space:]]*/dev/(sd|nvme|hd)' && deny
# proc environ + cloud metadata (literal + decimal/hex/octal forms)
match '/proc/[^[:space:]]*/environ' && deny
match '169\.254\.169\.254' && deny
match '(^|[^[:alnum:]])2852039166([^[:alnum:]]|$)' && deny
match '0x[aA]9[fF][eE][aA]9[fF][eE]' && deny
match '0x[aA]9[[:space:]]*\.[[:space:]]*0x[fF][eE][[:space:]]*\.[[:space:]]*0x[aA]9[[:space:]]*\.[[:space:]]*0x[fF][eE]' && deny
match '0251\.0376\.0251\.0376' && deny
match '::ffff:(a9fe:a9fe|169\.254\.169\.254)' && deny
# 169.254.43518 (a.b.16-bit), 169.16689662 (a.24-bit), AWS IPv6 IMDS
match '169\.254\.43518|(^|[^[:alnum:].])169\.16689662([^[:alnum:]]|$)|[fF][dD]00:[eE][cC]2::254' && deny
# docker escapes (opt-in socket): the host root as a volume (-v /:/x, -v=/:/x,
# --volume=/:/x, --mount source=/), privileged mode, extra capabilities, host
# namespaces and disabled confinement
DOCKER='(^|[^[:alnum:]_])(docker|podman)([^[:alnum:]_]|$)[^|;&]*'
match "${DOCKER}"'(^|[[:space:]])(-v|--volume)[=[:space:]]*["'"'"']?/[/.]*:' && deny
match "${DOCKER}--privileged" && deny
match "${DOCKER}"'--mount[^|;&]*(source|src)[[:space:]]*=[[:space:]]*/[/.]*([[:space:],"'"'"']|$)' && deny
match "${DOCKER}"'--cap-add([=[:space:]]|$)' && deny
match "${DOCKER}"'--(pid|userns|ipc|uts|cgroupns)[=[:space:]]+["'"'"']?host' && deny
match "${DOCKER}"'--security-opt[=[:space:]]+["'"'"']?[^[:space:]]*(unconfined|label[=:]disable)' && deny
# secret path references (any program)
match '(^|[/[:space:]"'"'"'=:(])auth\.json([[:space:]"'"'"'/):;,]|$)' && deny
match '(^|[/[:space:]"'"'"'=:(.-])credentials([[:space:]"'"'"'/.=:;,]|$)' && deny
# other credential stores (T-10): netrc, git/pypi creds, docker/gh/kube/gcloud
match '(^|[/[:space:]"'"'"'=:(])\.(netrc|git-credentials|pypirc|pgpass)([[:space:]"'"'"'/):;,]|$)' && deny
match '\.docker/config\.json|(^|[/[:space:]"'"'"'=:(])gh/hosts\.yml|\.kube/config([^[:alnum:]_.-]|$)|\.aws/(credentials|config)([^[:alnum:]_.-]|$)|\.config/gcloud([/[:space:]"'"'"'):;,]|$)' && deny
match '(^|[/[:space:]"'"'"'=:(])\.npmrc([[:space:]"'"'"'/):;,]|$)' && deny
match '(^|[/[:space:]"'"'"'=:(])\.mcp-auth([/[:space:]"'"'"'=:,;]|$)' && deny
match '(^|[/[:space:]"'"'"'=:(])\.gitconfig([[:space:]"'"'"'/):;,]|$)' && deny
match '(^|[/[:space:]"'"'"'=:(])id_(rsa|dsa|ecdsa|ed25519|ed25519_sk|ecdsa_sk|eddsa)([[:space:]"'"'"'/):;,:\-]|$)' && deny
# leak verb + secret token (.pem/.key/key-like/bare *key)
LEAK='cat|tac|less|more|head|tail|grep|egrep|fgrep|rg|sed|awk|cut|strings|xxd|od|hexdump|base64|base32|cp|mv|install|scp|rsync|tar|zip|gzip|bzip2|xz|curl|wget|nc|ncat|socat|telnet|python[0-9.]*|node|deno|bun|perl|ruby|php|sort|nl|rev|tr|split|comm|join|paste|pr|fmt|expand|unexpand|fold|csplit|diff|cmp|xargs|dd'
READV='cat|tac|less|more|head|tail|cp|mv|install|scp|rsync|tar|zip|gzip|bzip2|xz|base64|base32|xxd|od|hexdump|strings|dd|python[0-9.]*|node|deno|bun|perl|ruby|php'
# Public-key tokens (*.pub, public-keys.d/…, authorized_keys) are stripped per
# token instead of exempting the whole command (T-08): `cp server.key x.pub`
# still denies on server.key.
P="$(printf '%s' "$T" | sed -E 's#[^[:space:]"'"'"'|;&<>]*(\.pub|public-keys\.d[^[:space:]"'"'"'|;&<>]*|authorized_keys)([[:space:]"'"'"'|;&<>]|$)#\2#g')"
pmatch() { printf '%s' "$P" | grep -Eq "$1"; }
pmatchi() { printf '%s' "$P" | grep -Eiq "$1"; }
pmatchi "($LEAK)[^|;&]*\.pem([^[:alnum:]_.]|$)" && deny
pmatchi "($LEAK)[^|;&]*\.key([^[:alnum:]_.]|$)" && deny
pmatchi "($LEAK)[^|;&]*\.(p12|pfx|jks)([^[:alnum:]_.]|$)" && deny
pmatch "($LEAK)[^|;&]*(\.envrc|\.(bash|zsh)_history|\.claude\.json)([^[:alnum:]_.]|$)" && deny
# Bare code identifiers such as profile_overlay_key_ok are dropped for this
# rule only (grepping a function name is not a key read); a path, an
# extension, or a name that ends in _key/-key still matches, and the READV
# rule below still covers reading such a file.
PI="$(printf '%s' "$P" | sed -E 's#(^|[[:space:]])[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)*_key_[A-Za-z0-9_]*[A-Za-z0-9]([[:space:]]|$)#\1\3#g')"
printf '%s' "$PI" | grep -Eq "($LEAK)[^|;&]*(_key|-key|_priv)([^[:alnum:]]|$)" && deny
pmatch "($READV)[^|;&]*[[:alnum:]._-]*key([^[:alnum:]]|$)" && deny
pmatch '(^|[;&|][[:space:]]*)(source|\.)[[:space:]]+[^[:space:]"'"'"'|;&<>]*\.(pem|key)([^[:alnum:]_.]|$)' && deny
pmatch '<[[:space:]]*[^[:space:]"'"'"'|;&]*\.(pem|key)([^[:alnum:]_.]|$)' && deny
# Shell globs that spell a secret name (T-26): `.en?`, `id_e*`, `.cred*`,
# `server.p?m`. Each globbed word is matched, as a shell pattern, against the
# secret names and extensions; a word needs two literal characters, so `*`
# and `*.*` stay allowed. Extglob is on inside [[ ]], so long words and words
# with parentheses (split off below) are skipped to keep matching cheap.
GLOB_SECRET_NAMES=(.env .envrc id_rsa id_dsa id_ecdsa id_ed25519 id_ecdsa_sk id_ed25519_sk
    .credentials.json credentials auth.json .netrc .git-credentials .npmrc .pgpass .pypirc)
GLOB_SECRET_EXTS=(pem key p12 pfx jks)
glob_spells_secret() {
    local word base ext literal name
    local -a words=()
    IFS=$' \t' read -r -a words <<<"$(printf '%s' "$UNQUOTED" | tr ';|&<>()`\n\r' '          ')"
    for word in "${words[@]}"; do
        case "$word" in *[][?*]*) ;; *) continue ;; esac
        [ "${#word}" -le 128 ] || continue
        # A process environment through a glob: /proc/self/env*, /proc/*/enviro?
        for name in /proc/self/environ /proc/1/environ /proc/thread-self/environ /proc/self/task/1/environ; do
            # shellcheck disable=SC2053 # the word is matched as a glob on purpose
            [[ "$name" == $word ]] && return 0
        done
        base="${word##*/}"
        literal="${base//[][?*]/}"
        [ "${#literal}" -ge 2 ] || continue
        for name in "${GLOB_SECRET_NAMES[@]}"; do
            # shellcheck disable=SC2053 # the word is matched as a glob on purpose
            [[ "$name" == $base ]] && return 0
        done
        case "$base" in *.*) ext="${base##*.}" ;; *) continue ;; esac
        literal="${ext//[][?*]/}"
        case "$ext" in *[][?*]*) ;; *) continue ;; esac
        [ "${#literal}" -ge 2 ] || continue
        for name in "${GLOB_SECRET_EXTS[@]}"; do
            # shellcheck disable=SC2053 # the extension is matched as a glob on purpose
            [[ "$name" == $ext ]] && return 0
        done
    done
    return 1
}
if printf '%s' "$UNQUOTED" | grep -Eq "(^|[^[:alnum:]_])($LEAK)([^[:alnum:]_]|$)" && glob_spells_secret; then
    deny
fi
# Writes into files the host executes or that relax the policy (T-01, T-03, T-04):
# git hooks/config, project and user Claude settings, ~/.local/bin, skills. The
# Edit deny rules do not cover Bash, so redirects and write verbs are matched here.
WRITEV='(>>?|(^|[^[:alnum:]_.-])(tee|cp|mv|ln|install|truncate|touch|chmod|chown|rm|dd|rsync|sed[[:space:]]+-[a-zA-Z]*i[^|;&]*)[[:space:]])'
PROTECTED='(\.git/hooks([/[:space:]'"'"';|&]|$)|\.git/config([^[:alnum:]_.-]|$)|\.claude/settings(\.local)?\.json|\.local/bin([/[:space:]'"'"']|$)|\.claude/skills([/[:space:]'"'"']|$))'
match "${WRITEV}[^|;&]*${PROTECTED}" && deny
# Downloads written straight into them (curl -o/-O/--output, wget -O/-P).
match "(^|[^[:alnum:]_.-])(curl|wget)([[:space:]][^|;&]*)?[[:space:]](-[a-zA-Z]*[oOP]|--output(-document|-dir)?|--directory-prefix)[^|;&]*${PROTECTED}" && deny
# Interpreters writing them: open(…, 'w'/'a'/'x'/'+'), write_text, fs.writeFile*.
if match "$PROTECTED"; then
    match '(write_text|write_bytes|writeFileSync|writeFile|appendFileSync|appendFile|createWriteStream|copyFileSync|copyfile|copy2|renameSync|symlinkSync|os\.(rename|replace|symlink)|shutil\.(copy|move))[[:space:]]*\(' && deny
    match 'open[[:space:]]*\([^)]*,[[:space:]]*(mode[[:space:]]*=[[:space:]]*)?["'"'"'][rbt]*[wax+]' && deny
fi
# git settings that run a program or load other config (core.hooksPath,
# core.pager, core.sshCommand, core.fsmonitor, core.editor, *.helper,
# include.path, `!` aliases) persist in .git/config or ~/.gitconfig (T-01).
GITKEYS='(core\.(hookspath|pager|sshcommand|fsmonitor|editor|askpass|gitproxy)|[^[:space:]=]*\.(helper|textconv|command|process|clean|smudge)|include(if\.[^[:space:]=]*)?\.path|sequence\.editor|diff\.external)'
if printf '%s' "$T" | grep -Eiq "(^|[^[:alnum:]_.-])git[[:space:]][^|;&]*config[[:space:]][^|;&]*${GITKEYS}[\"']?([[:space:]]+|=)[^[:space:]]"; then deny; fi
if printf '%s' "$T" | grep -Eiq "(^|[^[:alnum:]_.-])git[[:space:]][^|;&]*config[[:space:]][^|;&]*alias\.[^[:space:]=]+[\"']?([[:space:]]+|=)[\"']?!"; then deny; fi
# ... and the same programs passed for one command: git -c core.sshCommand=…,
# --upload-pack/--receive-pack, ext:: transports (they also defeat the
# remote-flow override above).
if printf '%s' "$T" | grep -Eiq "(^|[^[:alnum:]_.-])git[[:space:]][^|;&]*(-c[[:space:]]*|--config(-env)?[=[:space:]]+)[\"']?(${GITKEYS}|alias\.[^[:space:]=]+=[\"']?!)"; then deny; fi
if printf '%s' "$T" | grep -Eq "(^|[^[:alnum:]_.-])git[[:space:]][^|;&]*(--upload-pack|--receive-pack|[[:space:]]ext::)"; then deny; fi
# openssl reading a private key (generation stays allowed)
match '(^|[^[:alnum:]_])openssl[[:space:]]+(rsa|pkey|ec|dsa|pkcs8|pkcs12|asn1parse)[^|;&]*(-inkey|-in|-text)([^[:alnum:]_]|$)' && deny
# ssh-keygen -y -f (case-sensitive; -Y sign stays allowed)
if printf '%s' "$T" | grep -qE 'ssh-keygen[^|;&]*-y[^|;&]*-f'; then deny; fi
# git plumbing over key material
KEYTOK='\.pem|\.key|_key|-key|_priv|id_(rsa|dsa|ecdsa|ed25519|eddsa)'
match "(^|[^[:alnum:]_])git[[:space:]]+(show|cat-file)[^|;&]*:[^[:space:];|&]*($KEYTOK)" && deny
match "(^|[^[:alnum:]_])git[[:space:]]+grep[^|;&]*($KEYTOK)" && deny
match "(^|[^[:alnum:]_])git[[:space:]]+archive[^|;&]*($KEYTOK)" && deny
match "(^|[^[:alnum:]_])git[[:space:]]+log[^|;&]*(-p|--patch)[^|;&]*($KEYTOK)" && deny
if printf '%s' "$T" | grep -qE "(^|[^[:alnum:]_])git[[:space:]]+diff[^|;&]*($KEYTOK)"; then
    case "$T" in *--stat*) ;; *) deny ;; esac
fi
# renamed extractor binaries (token-gated on key-like target)
match "(^|[;|&[:space:]])(ssh-keygen|[^[:space:];|&]+/[[:alnum:]._-]+)[^|;&]*-y[^|;&]*-f[^|;&]*($KEYTOK)" && deny
match "(^|[;|&[:space:]])(openssl|[^[:space:];|&]+/[[:alnum:]._-]+)[[:space:]]+(rsa|pkey|ec|dsa|pkcs8|pkcs12|asn1parse)[^|;&]*(-inkey|-in|-text)[^|;&]*($KEYTOK)" && deny
# GPG private material / secret export
match 'private-keys-v1\.d' && deny
match '(^|[^[:alnum:]_])gpg[^|;&]*--export-secret(-keys|-subkeys)?([^[:alnum:]-]|$)' && deny
# bare environment dumps
match '(^|[;|&(`\n])[[:space:]]*(env|printenv|set|export|declare|typeset)[[:space:]]*([;|&\n]|$)' && deny
match '(^|[^[:alnum:]_])export[[:space:]]+-p([^[:alnum:]]|$)' && deny
match '(^|[^[:alnum:]_])declare[[:space:]]+-p([^[:alnum:]]|$)' && deny
match '(^|[^[:alnum:]_])typeset[[:space:]]+-p([^[:alnum:]]|$)' && deny
match '(^|[^[:alnum:]_])compgen[[:space:]]+-e([^[:alnum:]]|$)' && deny
match '(^|[^[:alnum:]_])compgen[[:space:]]+-v([^[:alnum:]]|$)' && deny
match '(^|[^[:alnum:]_])declare[[:space:]]+-x([^[:alnum:]]|$)' && deny
match '(^|[^[:alnum:]_])typeset[[:space:]]+-x([^[:alnum:]]|$)' && deny
match '(^|[^[:alnum:]_])printenv[[:space:]]+[^|;&]*(KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|AUTH|API[_-]?KEY)([^[:alnum:]]|$)' && deny
# env/printenv in command position (also /usr/bin/env, $(env), `command env`)
# with only options or assignments and no command to run: `env -0`, `env > f`.
# `env FOO=1 make` runs make and stays allowed. A deny list of dump spellings
# can never be complete; it only removes the obvious ones (see YELLOW.md).
ENVARG='[^[:space:];&|()`<>]'
CMDPOS='(^|[;&|(`{!]|\$\()[[:space:]]*((command|exec|builtin|nohup|time|nice|setsid|stdbuf|xargs)[[:space:]]+(-[^[:space:]]*[[:space:]]+)*)*'
match "${CMDPOS}(${ENVARG}*/)?(env|printenv)([[:space:]]+(-[uC][[:space:]]+${ENVARG}+|--(unset|chdir)[[:space:]]+${ENVARG}+|-${ENVARG}*|[A-Za-z_][A-Za-z0-9_]*=${ENVARG}*))*[[:space:]]*([;&|)\`<>]|[0-9]+>|\$)" && deny
# ps with the BSD `e` flag prints every process's environment (ps eww, ps auxe)
# (first argument in BSD syntax, or a lone e/eww anywhere: ps -p 1 e)
match '(^|[^[:alnum:]_.-])ps[[:space:]]+[acfhjlmrsuvwxST]*e[acefhjlmrsuvwxST]*([[:space:];&|)]|$)' && deny
match '(^|[^[:alnum:]_.-])ps[[:space:]][^|;&]*[[:space:]]e+w*([[:space:];&|)]|$)' && deny
# whole-environment objects: dict(os.environ), for k in os.environ, awk ENVIRON
match '(dict|str|repr|list|sorted|vars|dumps?|pformat|pprint|print)[[:space:]]*\([[:space:]]*(\*\*)?(os[[:space:]]*\.[[:space:]]*)?environ([[:space:]]*\.[[:space:]]*(copy|items|keys|values)[[:space:]]*\([[:space:]]*\))?[[:space:]]*[),]' && deny
match '(^|[^[:alnum:]_])for[[:space:]][^:]*[[:space:]]in[[:space:]]+(os[[:space:]]*\.[[:space:]]*)?environ([^[:alnum:]_[]|$)' && deny
match '(^|[^[:alnum:]_])ENVIRON([^[:alnum:]_[]|$)' && deny
# interpreter bulk env dumps (scoped member access stays allowed)
match 'console[[:space:]]*\.[[:space:]]*(log|dir|debug|info)[[:space:]]*\([[:space:]]*process[[:space:]]*\.[[:space:]]*env[[:space:]]*\)' && deny
match 'print[[:space:]]*\([[:space:]]*os[[:space:]]*\.[[:space:]]*environ([[:space:]]*\.[[:space:]]*(copy|items|keys|values)[[:space:]]*\([[:space:]]*\))?[[:space:]]*\)' && deny
match 'pprint[[:space:]]*\([[:space:]]*os[[:space:]]*\.[[:space:]]*environ[[:space:]]*\)' && deny
# puts/p ENV: bare dumps denied, scoped access (ENV["X"], ENV.fetch(..)) allowed
if printf '%s' "$T" | grep -Eq '(^|[^[:alnum:]_])(puts|p)[[:space:]]+ENV'; then
    if printf '%s' "$T" | grep -Eq '(puts|p)[[:space:]]+ENV([[:space:]]*\[|[[:space:]]*\.[[:space:]]*(fetch|key\?|slice|dig|values_at)[[:space:]]*\()'; then
        :
    else
        deny
    fi
fi
match '(^|[^[:alnum:]_])(print|say|warn|printf)[^;&]*%ENV' && deny
# shellcheck disable=SC2016 # $_ENV/$_SERVER are intentional grep literals, not expansions
match '(print_r|var_dump|var_export)[[:space:]]*\([[:space:]]*(getenv\([[:space:]]*\)|\$_ENV([^[]|$)|\$_SERVER([^[]|$))' && deny
match 'console[[:space:]]*\.[[:space:]]*(log|dir)[[:space:]]*\([[:space:]]*Deno[[:space:]]*\.[[:space:]]*env[[:space:]]*\.[[:space:]]*toObject' && deny
# node -p process.env (bare dump denied; process.env.X / process.env["X"] allowed)
if printf '%s' "$T" | grep -qE '(^|[^[:alnum:]_])node[^|;&]*-(p|print)([^[:alnum:]]|$)'; then
    if printf '%s' "$T" | grep -qE 'process[[:space:]]*\.[[:space:]]*env[[:space:]]*(\.[[:space:]]*[A-Za-z_$][A-Za-z0-9_$]*|\[)'; then
        :
    elif printf '%s' "$T" | grep -qE '(^|[^[:alnum:]_])node[^|;&]*-(p|print)([^[:alnum:]]|$)[^|;&]*process[[:space:]]*\.[[:space:]]*env([^[:alnum:]_]|$)'; then
        deny
    fi
fi
# forwarded agents are signing oracles: forbid host-agent control
match '(^|[^[:alnum:]_])ssh-add[^|;&]*-[DdxXe]([^[:alnum:]]|$)' && deny
match '(^|[^[:alnum:]_])gpgconf[^|;&]*--(kill|reload)([^[:alnum:]]|$)' && deny
# .env references (any program). Templates (*.env.example) are stripped first
# so `cat .env.example && cat .env` still denies on the real one; process.env
# member access in code has no path boundary and stays allowed.
_STRIPPED="$(printf '%s' "$T" | sed 's/\.env\.example//g')"
if printf '%s' "$_STRIPPED" | grep -qE '(^|[^[:alnum:]_.])\.env([^[:alnum:]_]|$)'; then deny; fi

# git push asks for confirmation in every spelling. The managed `Bash(git push *)`
# ask rule is prefix-based, so `git -C . push`, `command git push` or
# `/usr/bin/git push` would slip past it. Nothing above denied the command, so
# answer "ask" through the PreToolUse JSON protocol (exit 0 + permissionDecision).
GITOPTS='([[:space:]]+(-[Cc][[:space:]]+[^[:space:];&|]+|--(git-dir|work-tree|namespace|exec-path|config-env|super-prefix)[[:space:]]+[^-[:space:];&|][^[:space:];&|]*|-[^[:space:];&|]*))*'
if printf '%s\n%s' "$CMD" "$UNQUOTED" | grep -Eq "(^|[^[:alnum:]_.-])git${GITOPTS}[[:space:]]+push([[:space:];&|)]|\$)"; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"claude-dockerized: git push needs your confirmation"}}'
fi

exit 0
