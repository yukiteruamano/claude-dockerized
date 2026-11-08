#!/bin/bash -p
# claude-guard-file.sh - Claude Code PreToolUse hook
# (matcher: Read|Edit|MultiEdit|Write|NotebookEdit|Glob|Grep).
#
# Native security enforcement for claude-dockerized. Mounted read-only into the
# container at /home/coder/.claude/hooks-guard/. Edit the repo copy (hooks/)
# and run `claude-dockerized config sync`: the installed copy under
# ~/.config/claude-dockerized/hooks/ is verified byte for byte, and local
# edits there are reported as drift and restored (with a .bak).
#
# Protocol: JSON via stdin, exit 2 + stderr blocks, exit 0 means no objection.
# Any other exit is a non-blocking error for Claude Code (the tool still
# runs), so every failure path here exits 2.
#
# The shebang is `bash -p`: privileged mode never sources $BASH_ENV/$ENV, which
# a project's settings `env` could otherwise point at a script that exits 0
# before this file runs. The managed policy also pins those variables empty.
#
# CLAUDE_DOCKERIZED_GUARD_VERSION=5

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Trusted tool path (T-04): never the inherited PATH (see claude-guard-bash.sh).
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

# Parse the payload into "key<TAB>value" lines:
#   tool   <tool_name>
#   write  1                       (the call writes: content/edits/new_source)
#   read   <path-like field>       (checked against the secret deny list)
#   target <path being written>    (checked against the write roots)
#   search <Grep/Glob root dir>    (refused when it would sweep secret stores)
# Grep's `pattern` is a content regex, not a path, so only Glob's is a target.
# Values with control characters are refused by the parsers (exit 3).
# shellcheck disable=SC2016 # jq program, not a shell expansion
JQ_PROG='
def s: if type == "string" then . else empty end;
def clean: if test("[\u0000-\u001f]") then error("control character") else . end;
if type != "object" then error("not an object") else . end
| (.tool_name | if type == "string" then . else "" end) as $tool
| (.tool_input // {}) as $ti
| if ($ti | type) != "object" then error("tool_input") else . end
| "tool\t\($tool | clean)",
  (if ($ti.content | type) == "string" or ($ti.edits | type) == "array" or ($ti.new_source | type) == "string" then "write\t1" else empty end),
  ([$ti.file_path, $ti.notebook_path, $ti.path, $ti.glob, (if $tool == "Glob" then $ti.pattern else empty end)][] | s | clean | "read\t\(.)"),
  ([$ti.file_path, $ti.notebook_path][] | s | clean | "target\t\(.)"),
  (if $tool == "Grep" or $tool == "Glob" then ($ti.path | s | clean | "search\t\(.)") else empty end)
'
PY_PROG='import json,sys
def bad(): sys.exit(3)
try:
    d=json.load(sys.stdin)
except Exception:
    bad()
if not isinstance(d,dict): bad()
ti=d.get("tool_input") or {}
if not isinstance(ti,dict): bad()
tool=d.get("tool_name") if isinstance(d.get("tool_name"),str) else ""
def clean(v):
    if any(ord(c)<32 for c in v): bad()
    return v
out=["tool\t"+clean(tool)]
if isinstance(ti.get("content"),str) or isinstance(ti.get("edits"),list) or isinstance(ti.get("new_source"),str):
    out.append("write\t1")
fields=["file_path","notebook_path","path","glob"]+(["pattern"] if tool=="Glob" else [])
for f in fields:
    if isinstance(ti.get(f),str): out.append("read\t"+clean(ti[f]))
for f in ["file_path","notebook_path"]:
    if isinstance(ti.get(f),str): out.append("target\t"+clean(ti[f]))
if tool in ("Grep","Glob") and isinstance(ti.get("path"),str): out.append("search\t"+clean(ti["path"]))
print("\n".join(out))'
NODE_PROG='let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
const bad=()=>process.exit(3);let d;try{d=JSON.parse(s)}catch{bad()}
if(!d||typeof d!=="object"||Array.isArray(d))bad();
const ti=d.tool_input??{};if(typeof ti!=="object"||Array.isArray(ti))bad();
const tool=typeof d.tool_name==="string"?d.tool_name:"";
const clean=v=>{if(/[\u0000-\u001f]/.test(v))bad();return v};
const out=["tool\t"+clean(tool)];
if(typeof ti.content==="string"||Array.isArray(ti.edits)||typeof ti.new_source==="string")out.push("write\t1");
for(const f of ["file_path","notebook_path","path","glob",...(tool==="Glob"?["pattern"]:[])])if(typeof ti[f]==="string")out.push("read\t"+clean(ti[f]));
for(const f of ["file_path","notebook_path"])if(typeof ti[f]==="string")out.push("target\t"+clean(ti[f]));
if((tool==="Grep"||tool==="Glob")&&typeof ti.path==="string")out.push("search\t"+clean(ti.path));
console.log(out.join("\n"))})'

parse_payload() {
    if command -v jq >/dev/null 2>&1; then
        jq -r "$JQ_PROG" 2>/dev/null <<<"$INPUT" || return 3
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "$PY_PROG" 2>/dev/null <<<"$INPUT" || return 3
        return 0
    fi
    if command -v node >/dev/null 2>&1; then
        node -e "$NODE_PROG" 2>/dev/null <<<"$INPUT" || return 3
        return 0
    fi
    return 4
}

PARSED="$(parse_payload)"
case $? in
0) ;;
4) deny_reason "no JSON parser (jq, python3 or node) on the trusted path" ;;
*) deny_reason "unparseable hook payload" ;;
esac

# Every parser prints a "tool" line first; anything else means the payload was
# not understood (e.g. a jq filter that produced nothing), so refuse it.
case "$PARSED" in
tool$'\t'*) ;;
*) deny_reason "unparseable hook payload" ;;
esac

TOOL="" WRITES=false
READS=() TARGETS=() SEARCHES=()
while IFS=$'\t' read -r key value; do
    case "$key" in
    tool) TOOL="$value" ;;
    write) WRITES=true ;;
    read) [ -n "$value" ] && READS+=("$value") ;;
    target) [ -n "$value" ] && TARGETS+=("$value") ;;
    search) [ -n "$value" ] && SEARCHES+=("$value") ;;
    esac
done <<<"$PARSED"

case "$TOOL" in
Edit | MultiEdit | Write | NotebookEdit) WRITES=true ;;
esac

deny_read() {
    printf 'Blocked by claude-dockerized security policy: refusing to read %s\n' "$1" >&2
    exit 2
}

deny_write() {
    printf 'Blocked by claude-dockerized security policy: write outside project directory: %s\n' "$1" >&2
    exit 2
}

# Collapse ".", ".." and duplicate slashes without touching the filesystem.
lexical_path() {
    local p="$1" abs="" out="" part
    case "$p" in /*) abs=1 ;; esac
    # collapse duplicate slashes
    p="$(printf '%s' "$p" | tr -s '/')"
    local IFS='/'
    # shellcheck disable=SC2162
    for part in $p; do
        case "$part" in
        ""|.) continue ;;
        ..) out="${out%/*}" ;;
        *) out="$out/$part" ;;
        esac
    done
    [ -z "$out" ] && out="/"
    [ -z "$abs" ] && out="${out#/}"
    printf '%s' "$out"
}

# --- Secret reads (literal path + symlink-resolved target) ---
# Credential stores (T-10): OAuth store, git/pypi creds, netrc, docker/gh/kube/gcloud.
# Case-insensitive (grep -i below): SERVER.KEY or .PEM exports are the same secrets.
DENY_RE='(^|/)\.env(\.([^e]|$)|$)|(^|/)\.env\..*|\.pem$|\.key$|(^|/)auth\.json$|(^|/)id_(rsa|dsa|ecdsa|ed25519|ed25519_sk|ecdsa_sk|eddsa)$|(^|/)\.ssh(/|$)''|(^|/)\.npmrc$|(^|/)\.mcp-auth(/|$)|(^|/)\.?credentials(\.|$)|(^|/)private-keys-v1\.d(/|$)|(^|/)\.gitconfig$|(^|/)\.(netrc|git-credentials|pypirc)$|(^|/)\.docker/config\.json$|(^|/)gh/hosts\.yml$|(^|/)\.kube/config$|(^|/)\.config/gcloud(/|$)|(^|/)\.envrc$|(^|/)\.pgpass$|(^|/)\.aws(/|$)|\.(p12|pfx|jks)$|(^|/)\.(bash|zsh)_history$|(^|/)\.claude\.json$|^/proc/.*/environ$'

check_deny_read() {
    local p="$1" base="${1##*/}"
    # Exemptions look at the final path component only (T-08): a directory that
    # merely contains one of these names must not whitelist what is inside it.
    case "$base" in
    *.env.example* | *.pub | authorized_keys) return 1 ;;
    esac
    # public-keys.d/ holds public material, unless the file itself is a secret
    case "$p" in
    */public-keys.d/*) printf '%s' "$base" | grep -Eiq "$DENY_RE" || return 1 ;;
    esac
    printf '%s' "$p" | grep -Eiq "$DENY_RE" && return 0
    # bare *key heuristic (mykey, deploy_key) — allow monkey-style words only
    # when they do not look like key files
    if printf '%s' "$p" | grep -Eq '(^|/)[[:alnum:]._-]*key$'; then
        case "$p" in
        *monkey*|*keyboard*|*turkey*) return 1 ;;
        *) return 0 ;;
        esac
    fi
    if printf '%s' "$p" | grep -Eq '(^|/)[[:alnum:]._-]*(_key|-key|_priv)$'; then
        return 0
    fi
    return 1
}


# --- Path forms ---
# Claude Code expands a leading `~` itself, so `~/.bashrc` is the home's
# .bashrc, never "<project>/~/.bashrc". The home is the hook's $HOME and the
# container's /home/coder (settings `env` could move $HOME); both are checked.
HOMES=(/home/coder)
case "${HOME:-}" in
/home/coder | "") ;;
/*) HOMES=("$HOME" /home/coder) ;;
esac

# Print every absolute spelling of a path, one per line: "~", "~/x", "~user/x"
# and a leading $HOME/${HOME} are expanded, other relative paths are joined to
# the project directory (relative means "inside the project", whatever the
# hook's cwd is).
absolute_forms() {
    local p="$1" rest home
    case "$p" in
    "~" | "~/"* | '$HOME' | '$HOME/'* | '${HOME}' | '${HOME}/'*)
        rest="${p#\~}"
        rest="${rest#\$HOME}"
        rest="${rest#\$\{HOME\}}"
        for home in "${HOMES[@]}"; do printf '%s%s\n' "$home" "$rest"; done
        ;;
    "~"*)
        rest="${p#\~}"
        printf '/home/%s\n' "$rest"
        ;;
    /*) printf '%s\n' "$p" ;;
    *) printf '%s/%s\n' "$BASE" "$p" ;;
    esac
}

# The project directory must be a real, absolute project path: unset, relative,
# "/", the home (or an ancestor of it), a credential or tool dir in the home and
# system directories are refused, so a forged CLAUDE_PROJECT_DIR cannot widen
# the write roots. Prints the problem, nothing when the path is usable.
project_dir_problem() {
    local p="$1" home d
    case "$p" in
    /*) ;;
    *) printf 'CLAUDE_PROJECT_DIR is not set or not absolute'; return 0 ;;
    esac
    p="$(lexical_path "$p")"
    if [ "$p" = "/" ]; then printf 'the project directory is /'; return 0; fi
    for home in "${HOMES[@]}"; do
        if [ "$p" = "$home" ] || [[ "$home" == "$p/"* ]]; then
            printf 'the project directory %s is the home or contains it' "$p"
            return 0
        fi
        for d in .claude .config .local .cache .ssh .gnupg .mcp-auth .aws .kube .docker; do
            if [ "$p" = "$home/$d" ] || [[ "$p" == "$home/$d/"* ]]; then
                printf 'the project directory %s is inside %s' "$p" "$home/$d"
                return 0
            fi
        done
    done
    case "$p" in
    /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /etc | /etc/* | /usr | /usr/* | /bin | /bin/* | /sbin | /sbin/* | /lib | /lib/* | /lib64 | /lib64/* | /boot | /boot/* | /root | /root/* | /run | /run/*)
        printf 'the project directory %s is a system directory' "$p"
        ;;
    esac
    return 0
}

PROJECT_PROBLEM="$(project_dir_problem "${CLAUDE_PROJECT_DIR:-}")"
if [ -z "$PROJECT_PROBLEM" ] && command -v realpath >/dev/null 2>&1; then
    PROJECT_REAL="$(realpath -m "$CLAUDE_PROJECT_DIR" 2>/dev/null || true)"
    PROJECT_PROBLEM="$(project_dir_problem "$PROJECT_REAL")"
fi
# Relative read paths still need a base when the project dir is unusable; the
# read checks only ever deny, so the cwd is a safe fallback there.
if [ -z "$PROJECT_PROBLEM" ]; then BASE="$CLAUDE_PROJECT_DIR"; else BASE="$PWD"; fi

for target in "${READS[@]}"; do
    check_deny_read "$target" && deny_read "$target"
    while IFS= read -r abs_target; do
        check_deny_read "$abs_target" && deny_read "$target"
        check_deny_read "$(lexical_path "$abs_target")" && deny_read "$target"
        if command -v realpath >/dev/null 2>&1; then
            REAL="$(realpath -m "$abs_target" 2>/dev/null || true)"
            if [ -n "$REAL" ] && check_deny_read "$REAL"; then deny_read "$target"; fi
        fi
    done < <(absolute_forms "$target")
done

# --- Recursive search roots (Grep/Glob) ---
# Read-deny only sees the path a tool names, but a recursive search over a
# directory reads every file below it. Refuse roots that are, or contain, the
# credential stores, and the kernel trees (/proc/<pid>/environ holds the
# session's credentials); searching a project directory stays allowed.
search_root_too_broad() {
    local p="$1" home d
    [ "$p" = "/" ] && return 0
    case "$p" in
    /proc | /proc/* | /sys | /sys/* | /dev | /dev/*) return 0 ;;
    esac
    for home in "${HOMES[@]}"; do
        # the home itself and every ancestor of it
        if [ "$p" = "$home" ] || [[ "$home" == "${p%/}/"* ]]; then return 0; fi
        for d in .claude .config .aws .kube .docker .gnupg .mcp-auth .ssh; do
            [ "$p" = "$home/$d" ] && return 0
        done
    done
    return 1
}

for target in "${SEARCHES[@]}"; do
    while IFS= read -r abs_target; do
        ROOT="$(lexical_path "$abs_target")"
        search_root_too_broad "$ROOT" && deny_read "$target (recursive search over secret stores)"
        if command -v realpath >/dev/null 2>&1; then
            REAL="$(realpath -m "$abs_target" 2>/dev/null || true)"
            [ -n "$REAL" ] && search_root_too_broad "$REAL" && deny_read "$target (recursive search over secret stores)"
        fi
    done < <(absolute_forms "$target")
done

# --- Write confinement (every tool that writes) ---
[ "$WRITES" = true ] || exit 0
[ "${#TARGETS[@]}" -gt 0 ] || deny_reason "write without a target path"

# Roots: the project dir + approved scratch. Never "/", never the home, never
# the hook's cwd: without a usable CLAUDE_PROJECT_DIR only the scratch dir is
# writable (fail closed).
ROOTS=(/tmp/claude)
if [ -z "$PROJECT_PROBLEM" ]; then
    ROOTS+=("$(lexical_path "$CLAUDE_PROJECT_DIR")")
    [ -n "${PROJECT_REAL:-}" ] && ROOTS+=("$PROJECT_REAL")
fi

is_inside() {
    local c="$1" r
    for r in "${ROOTS[@]}"; do
        if [ "$c" = "$r" ] || [[ "$c" == "$r/"* ]]; then return 0; fi
    done
    return 1
}

deny_outside() {
    [ -n "$PROJECT_PROBLEM" ] && deny_reason "write outside /tmp/claude refused: $PROJECT_PROBLEM: $1"
    deny_write "$1"
}

# Strict mode also protects files the host executes or that relax the policy
# (T-01, T-03): git hooks/config, submodules, MCP servers, project Claude
# settings, commands and agents. In balanced mode
# the wrapper's session integrity check reports changes to them instead.
is_protected() {
    case "$1" in
    */.git/hooks/* | */.git/config | */.gitmodules | */.mcp.json | */.claude/settings.json | */.claude/settings.local.json | */.claude/commands/* | */.claude/agents/*) return 0 ;;
    esac
    return 1
}

for target in "${TARGETS[@]}"; do
    while IFS= read -r abs_target; do
        ABS="$(lexical_path "$abs_target")"

        # realpath -m resolves every symlink on the way (also below directories
        # that do not exist yet, and dangling links); an unresolvable path is refused.
        CANDIDATES=("$ABS")
        if command -v realpath >/dev/null 2>&1; then
            R="$(realpath -m "$ABS" 2>/dev/null)" && [ -n "$R" ] || deny_write "$target"
            CANDIDATES+=("$R")
        fi

        for c in "${CANDIDATES[@]}"; do
            is_inside "$c" || deny_outside "$target"
            if [ "$POLICY_MODE" = strict ] && is_protected "$c"; then
                deny_reason "strict policy protects $target (git hooks/config, MCP servers, project Claude settings)"
            fi
        done
    done < <(absolute_forms "$target")
done

exit 0
