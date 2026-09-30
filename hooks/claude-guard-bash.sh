#!/bin/bash
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
# CLAUDE_DOCKERIZED_GUARD_VERSION=3
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

# Normalize shell word-separator obfuscation back to spaces before matching
# (port of guard normalizeShell): ${IFS...}, $'\t', $'\n'.
# shellcheck disable=SC2016 # the $'…' shapes are intentional sed literals, not expansions
NORM="$(printf '%s' "$CMD" | sed -e 's/\${IFS[^}]*}/ /gI' -e "s/\\$'\\\\t'/ /g" -e "s/\\$'\\\\n'/ /g")"

deny() {
    printf 'Blocked by claude-dockerized security policy: %s\n' "$CMD" >&2
    exit 2
}

deny_policy() {
    printf 'Blocked by workspace policy (policy/%s): %s\n' "$1" "$2" >&2
    exit 2
}

# --- Vendored policy patterns (exact JS RegExp semantics via node) ---
# An allow match (templates, public keys) only skips the vendored deny rules;
# the built-in backstops below always run (T-08).
if [ "$POLICY_MODE" != "none" ]; then
    command -v node >/dev/null 2>&1 || deny_reason "policy engine unavailable (node not found on the trusted path)"
    export CGB_CMD="$CMD"
    export CGB_POLICY_MODE="$POLICY_MODE"
    export CGB_POLICIES_DIR="$POLICIES_DIR"
    VENDORED_RESULT="$(node "$HOOK_DIR/guard-eval.js" 2>/dev/null)" || VENDORED_RESULT="error|policy engine crashed"
    case "$VENDORED_RESULT" in
    allow | pass) ;;
    deny\|*)
        _rid="${VENDORED_RESULT#deny|}"
        _rid="${_rid%%|*}"
        _reason="${VENDORED_RESULT#deny|*|}"
        # Remote-operation safeguard: in balanced mode the vendored set must
        # never block plain remote flows (see remote-allow tests). The
        # excluded-ID list in guard-eval.js already drops the noisy rules; if a
        # rule still fires on a plain `git clone ssh:` / registry curl / MCP
        # https URL, let the built-in backstops decide instead.
        if [ "$POLICY_MODE" != "strict" ]; then
            case "$CMD" in
            git\ clone\ git@*|git\ ls-remote\ git@*|git\ fetch\ git@*|git\ pull\ git@*|git\ push\ git@*)
                ;;
            curl\ https://registry.npmjs.org*|curl\ -*https://registry.npmjs.org*|curl\ https://pypi.org*|curl\ https://files.pythonhosted.org*)
                ;;
            curl\ https://*/mcp*|curl\ https://*mcp*|wget\ https://*/mcp*)
                ;;
            *) deny_policy "$_rid" "$_reason" ;;
            esac
        else
            deny_policy "$_rid" "$_reason"
        fi
        ;;
    error\|*) deny_reason "${VENDORED_RESULT#error|}" ;;
    *) deny_reason "unexpected policy engine output" ;;
    esac
fi

# --- Built-in backstops (mode-independent) ---
T="$CMD
$NORM"
match() { printf '%s' "$T" | grep -Eq "$1"; }

# sudo anywhere (including prose/commit messages/grep patterns by design)
match '(^|[^[:alnum:]_])sudo([^[:alnum:]_]|$)' && deny
# rm -rf / variants, /* globs and /.. traversals
match 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+/' && deny
match 'rm[[:space:]]+.*[[:space:]]+/[[:space:]]*$' && deny
match 'rm[[:space:]]+[^|;&]*[[:space:]]/\*([[:space:];|&]|$)' && deny
match 'rm[[:space:]]+[^|;&]*/\.\.(/|$)' && deny
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
match '/proc/[^/[:space:]]*/environ' && deny
match '169\.254\.169\.254' && deny
match '(^|[^[:alnum:]])2852039166([^[:alnum:]]|$)' && deny
match '0x[aA]9[fF][eE][aA]9[fF][eE]' && deny
match '0x[aA]9[[:space:]]*\.[[:space:]]*0x[fF][eE][[:space:]]*\.[[:space:]]*0x[aA]9[[:space:]]*\.[[:space:]]*0x[fF][eE]' && deny
match '0251\.0376\.0251\.0376' && deny
match '::ffff:(a9fe:a9fe|169\.254\.169\.254)' && deny
# docker escapes (short + long forms, privileged)
match '(^|[^[:alnum:]_])docker([^[:alnum:]_]|$)[^|;&]*-v[[:space:]]+/:/' && deny
match '(^|[^[:alnum:]_])docker([^[:alnum:]_]|$)[^|;&]*--privileged' && deny
match '(^|[^[:alnum:]_])docker([^[:alnum:]_]|$)[^|;&]*--volume[[:space:]]+/:/' && deny
match '(^|[^[:alnum:]_])docker([^[:alnum:]_]|$)[^|;&]*--mount[^|;&]*source[[:space:]]*=[[:space:]]*/([[:space:],]|$)' && deny
# secret path references (any program)
match '(^|[/[:space:]"'"'"'=:(])auth\.json([[:space:]"'"'"'/):;,]|$)' && deny
match '(^|[/[:space:]"'"'"'=:(.-])credentials([[:space:]"'"'"'/.=:;,]|$)' && deny
# other credential stores (T-10): netrc, git/pypi creds, docker/gh/kube/gcloud
match '(^|[/[:space:]"'"'"'=:(])\.(netrc|git-credentials|pypirc)([[:space:]"'"'"'/):;,]|$)' && deny
match '\.docker/config\.json|(^|[/[:space:]"'"'"'=:(])gh/hosts\.yml|\.kube/config([^[:alnum:]_.-]|$)|\.config/gcloud([/[:space:]"'"'"'):;,]|$)' && deny
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
pmatch "($LEAK)[^|;&]*\.pem([^[:alnum:]_.]|$)" && deny
pmatch "($LEAK)[^|;&]*\.key([^[:alnum:]_.]|$)" && deny
pmatch "($LEAK)[^|;&]*(_key|-key|_priv)([^[:alnum:]]|$)" && deny
pmatch "($READV)[^|;&]*[[:alnum:]._-]*key([^[:alnum:]]|$)" && deny
pmatch '(^|[;&|][[:space:]]*)(source|\.)[[:space:]]+[^[:space:]"'"'"'|;&<>]*\.(pem|key)([^[:alnum:]_.]|$)' && deny
pmatch '<[[:space:]]*[^[:space:]"'"'"'|;&]*\.(pem|key)([^[:alnum:]_.]|$)' && deny
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

exit 0
