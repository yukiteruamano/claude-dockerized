#!/bin/bash
# claude-guard-file.sh - Claude Code PreToolUse hook (matcher: Read|Edit|Write|Glob|Grep).
#
# Native security enforcement for claude-dockerized. Mounted read-only into the
# container at /home/coder/.claude/hooks-guard/. Edit from the host at
# ~/.config/claude-dockerized/hooks/ instead.
#
# Protocol: JSON via stdin, exit 2 + stderr blocks, exit 0 means no objection.
#
# CLAUDE_DOCKERIZED_GUARD_VERSION=1

set -u

INPUT="$(cat)"

extract_field() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.tool_input.file_path // .tool_input.path // .tool_input.pattern // empty' 2>/dev/null <<<"$INPUT" && return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys
try:
    ti=json.load(sys.stdin).get("tool_input",{})
    print(ti.get("file_path",ti.get("path",ti.get("pattern",""))))
except Exception:
    print("")' 2>/dev/null <<<"$INPUT" && return 0
    fi
    if command -v node >/dev/null 2>&1; then
        node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const ti=JSON.parse(s).tool_input||{};console.log(ti.file_path??ti.path??ti.pattern??"")}catch{console.log("")}})' 2>/dev/null <<<"$INPUT" && return 0
    fi
    printf ''
}

extract_tool() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.tool_name // empty' 2>/dev/null <<<"$INPUT" && return 0
    fi
    printf ''
}

TARGET="$(extract_field)"
[ -z "$TARGET" ] && exit 0
TOOL="$(extract_tool)"

deny_read() {
    printf 'Blocked by claude-dockerized security policy: refusing to read %s\n' "$TARGET" >&2
    exit 2
}

deny_write() {
    printf 'Blocked by claude-dockerized security policy: write outside project directory: %s\n' "$TARGET" >&2
    exit 2
}

# --- Secret reads (literal path + symlink-resolved target) ---
DENY_RE='(^|/)\.env(\.([^e]|$)|$)|(^|/)\.env\..*|\.pem$|\.key$|(^|/)auth\.json$|(^|/)id_(rsa|dsa|ecdsa|ed25519|ed25519_sk|ecdsa_sk|eddsa)$|(^|/)\.ssh(/|$)''|(^|/)\.npmrc$|(^|/)\.mcp-auth(/|$)|(^|/)credentials(\.|$)|(^|/)private-keys-v1\.d(/|$)|(^|/)\.gitconfig$|(^|/)\.composio(/|$)'

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
    printf '%s' "$p" | grep -Eq "$DENY_RE" && return 0
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

if check_deny_read "$TARGET"; then deny_read; fi
if command -v realpath >/dev/null 2>&1; then
    REAL="$(realpath -m "$TARGET" 2>/dev/null || true)"
    # resolve symlink when it exists
    if [ -e "$TARGET" ]; then
        REAL2="$(realpath "$TARGET" 2>/dev/null || true)"
        [ -n "$REAL2" ] && REAL="$REAL2"
    fi
    if [ -n "${REAL:-}" ] && [ "$REAL" != "$TARGET" ] && check_deny_read "$REAL"; then deny_read; fi
fi

# --- Write confinement (Edit|Write only) ---
case "$TOOL" in
Edit|Write|edit|write) ;;
*)
    # When tool name is absent (older hook payloads), apply confinement to any
    # target that looks like a write. The Bash hook handles commands; here we
    # only confine when the payload carries file content or is explicitly a
    # write-like tool. Fall back to confining absolute/relative paths that are
    # not plain reads: check for tool_input.content presence.
    HAS_CONTENT=false
    if command -v jq >/dev/null 2>&1; then
        jq -e '.tool_input.content // empty | type == "string"' >/dev/null 2>&1 <<<"$INPUT" && HAS_CONTENT=true
    fi
    # Heuristic from the test harness: the harness under tests/ passes the
    # action via CLAUDE_DOCKERIZED_TEST_ACTION env.
    if [ "${CLAUDE_DOCKERIZED_TEST_ACTION:-}" = "edit" ] || [ "${CLAUDE_DOCKERIZED_TEST_ACTION:-}" = "write" ]; then
        HAS_CONTENT=true
    fi
    [ "$HAS_CONTENT" = true ] || exit 0
    ;;
esac

# Roots: project dir(s) + approved scratch. Never "/" .
ROOTS=""
add_root() {
    case "$1" in
    ""|/) return 0 ;;
    /*) ROOTS="$ROOTS|$1" ;;
    esac
}
add_root "${CLAUDE_PROJECT_DIR:-}"
add_root "${CLAUDE_DOCKERIZED_PROJECT_DIR:-}"
add_root "$PWD"
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

if [[ "$TARGET" == /* ]]; then
    ABS="$(lexical "$TARGET")"
else
    BASE="${CLAUDE_PROJECT_DIR:-${CLAUDE_DOCKERIZED_PROJECT_DIR:-$PWD}}"
    ABS="$(lexical "$BASE/$TARGET")"
fi

CANDIDATES="$ABS"
if [ -e "$ABS" ] && command -v realpath >/dev/null 2>&1; then
    R="$(realpath "$ABS" 2>/dev/null || true)"
    [ -n "$R" ] && CANDIDATES="$CANDIDATES|$R"
fi
PARENT="${ABS%/*}"
[ -z "$PARENT" ] && PARENT="/"
if [ -e "$PARENT" ] && command -v realpath >/dev/null 2>&1; then
    RP="$(realpath "$PARENT" 2>/dev/null || true)"
    if [ -n "$RP" ]; then
        CANDIDATES="$CANDIDATES|$RP/${ABS##*/}"
    fi
fi

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

OLDIFS="$IFS"; IFS='|'
for c in $CANDIDATES; do
    if ! is_inside "$c"; then
        IFS="$OLDIFS"
        deny_write
    fi
done
IFS="$OLDIFS"

exit 0
