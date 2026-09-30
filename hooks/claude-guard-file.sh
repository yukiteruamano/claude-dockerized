#!/bin/bash
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
# CLAUDE_DOCKERIZED_GUARD_VERSION=2

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Trusted tool path (T-04): never the inherited PATH (see claude-guard-bash.sh).
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

# Parse the payload into "key<TAB>value" lines:
#   tool   <tool_name>
#   write  1                       (the call writes: content/edits/new_source)
#   read   <path-like field>       (checked against the secret deny list)
#   target <path being written>    (checked against the write roots)
# Grep's `pattern` is a content regex, not a path, so only Glob's is a target.
# Values with control characters are refused by the parsers (exit 3).
# shellcheck disable=SC2016 # jq program, not a shell expansion
JQ_PROG='
def s: if type == "string" then . else empty end;
def clean: if test("[\u0000-\u001f]") then error("control character") else . end;
if type != "object" then error("not an object") else . end
| (.tool_name // "" | s) as $tool
| (.tool_input // {}) as $ti
| if ($ti | type) != "object" then error("tool_input") else . end
| "tool\t\($tool | clean)",
  (if ($ti.content | type) == "string" or ($ti.edits | type) == "array" or ($ti.new_source | type) == "string" then "write\t1" else empty end),
  ([$ti.file_path, $ti.notebook_path, $ti.path, $ti.glob, (if $tool == "Glob" then $ti.pattern else empty end)][] | s | clean | "read\t\(.)"),
  ([$ti.file_path, $ti.notebook_path][] | s | clean | "target\t\(.)")
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

TOOL="" WRITES=false
READS=() TARGETS=()
while IFS=$'\t' read -r key value; do
    case "$key" in
    tool) TOOL="$value" ;;
    write) WRITES=true ;;
    read) [ -n "$value" ] && READS+=("$value") ;;
    target) [ -n "$value" ] && TARGETS+=("$value") ;;
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

# --- Secret reads (literal path + symlink-resolved target) ---
# Credential stores (T-10): OAuth store, git/pypi creds, netrc, docker/gh/kube/gcloud.
# Case-insensitive: SERVER.KEY or .PEM exports are the same secrets.
DENY_RE='(^|/)\.env(\.([^e]|$)|$)|(^|/)\.env\..*|\.pem$|\.key$|(^|/)auth\.json$|(^|/)id_(rsa|dsa|ecdsa|ed25519|ed25519_sk|ecdsa_sk|eddsa)$|(^|/)\.ssh(/|$)''|(^|/)\.npmrc$|(^|/)\.mcp-auth(/|$)|(^|/)\.?credentials(\.|$)|(^|/)private-keys-v1\.d(/|$)|(^|/)\.gitconfig$|(^|/)\.composio(/|$)|(^|/)\.(netrc|git-credentials|pypirc)$|(^|/)\.docker/config\.json$|(^|/)gh/hosts\.yml$|(^|/)\.kube/config$|(^|/)\.config/gcloud(/|$)'

check_deny_read() {
    local p="$1"
    # .env.example templates stay readable
    case "$p" in
    *.env.example*) return 1 ;;
    esac
    # public keys stay readable
    case "$p" in
    *.pub) return 1 ;;
    *public-keys.d*|*authorized_keys*) return 1 ;;
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

for target in "${READS[@]}"; do
    check_deny_read "$target" && deny_read "$target"
    if command -v realpath >/dev/null 2>&1; then
        REAL="$(realpath -m "$target" 2>/dev/null || true)"
        # resolve symlink when it exists
        if [ -e "$target" ]; then
            REAL2="$(realpath "$target" 2>/dev/null || true)"
            [ -n "$REAL2" ] && REAL="$REAL2"
        fi
        if [ -n "${REAL:-}" ] && [ "$REAL" != "$target" ] && check_deny_read "$REAL"; then deny_read "$target"; fi
    fi
done

# --- Write confinement (every tool that writes) ---
[ "$WRITES" = true ] || exit 0
[ "${#TARGETS[@]}" -gt 0 ] || deny_reason "write without a target path"

# Roots: the project dir + approved scratch. Never "/". The hook's cwd is only
# a fallback when Claude Code does not export CLAUDE_PROJECT_DIR.
ROOTS=""
add_root() {
    case "$1" in
    ""|/) return 0 ;;
    /*) ROOTS="$ROOTS|$1" ;;
    esac
}
add_root "${CLAUDE_PROJECT_DIR:-}"
add_root "${CLAUDE_DOCKERIZED_PROJECT_DIR:-}"
[ -z "${CLAUDE_PROJECT_DIR:-}${CLAUDE_DOCKERIZED_PROJECT_DIR:-}" ] && add_root "$PWD"
add_root "/tmp/claude"

lexical() {
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

is_inside() {
    local c="$1" r
    local OLDIFS="$IFS"; IFS='|'
    for r in $ROOTS; do
        [ -z "$r" ] && continue
        if [ "$c" = "$r" ] || [[ "$c" == "$r/"* ]]; then
            IFS="$OLDIFS"
            return 0
        fi
    done
    IFS="$OLDIFS"
    return 1
}

# Strict mode also protects files the host executes or that relax the policy
# (T-01, T-03): git hooks/config and project Claude settings. In balanced mode
# the wrapper's session integrity check reports changes to them instead.
is_protected() {
    case "$1" in
    */.git/hooks/* | */.git/config | */.claude/settings.json | */.claude/settings.local.json) return 0 ;;
    esac
    return 1
}

BASE="${CLAUDE_PROJECT_DIR:-${CLAUDE_DOCKERIZED_PROJECT_DIR:-$PWD}}"
for target in "${TARGETS[@]}"; do
    if [[ "$target" == /* ]]; then
        ABS="$(lexical "$target")"
    else
        ABS="$(lexical "$BASE/$target")"
    fi

    CANDIDATES=("$ABS")
    if [ -e "$ABS" ] && command -v realpath >/dev/null 2>&1; then
        R="$(realpath "$ABS" 2>/dev/null || true)"
        [ -n "$R" ] && CANDIDATES+=("$R")
    fi
    PARENT="${ABS%/*}"
    [ -z "$PARENT" ] && PARENT="/"
    if [ -e "$PARENT" ] && command -v realpath >/dev/null 2>&1; then
        RP="$(realpath "$PARENT" 2>/dev/null || true)"
        [ -n "$RP" ] && CANDIDATES+=("$RP/${ABS##*/}")
    fi

    for c in "${CANDIDATES[@]}"; do
        is_inside "$c" || deny_write "$target"
        if [ "$POLICY_MODE" = strict ] && is_protected "$c"; then
            deny_reason "strict policy protects $target (git hooks/config, project Claude settings)"
        fi
    done
done

exit 0
