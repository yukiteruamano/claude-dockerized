#!/bin/bash
# Opt-in runtime hardening profiles (setting.hardening). The default (off)
# must leave the historic runtime byte-for-byte unchanged; standard and strict
# add the documented flags and read-only mounts (T-01, T-05, T-06, T-22, T-23).
# No Docker needed: sources config-lib.sh with an isolated HOME/CONFIG_DIR.
#
# Usage: bash tests/hardening.test.sh
# shellcheck disable=SC2034,SC2317  # globals feed config-lib.sh; helpers run via check

# No `set -u`: config-lib.sh is sourced by callers that do not use it.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="hardening"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

export TMPDIR="${TMPDIR:-/tmp/claude}"
TMP="$(t_tmpdir)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

export HOME="$TMP/home"
export CONFIG_DIR="$HOME/.config/claude-dockerized"
export CCODE_HOME="$CONFIG_DIR/home"
export CLAUDE_DOCKERIZED_ALLOW_CONTAINER_SYNC=1
export CLAUDE_DOCKERIZED_SKIP_LSP_INSTALL=1
export NO_COLOR=1
PROJECT="$HOME/work/proj"
# A host ~/.mcp-auth exists on purpose: it must never be picked up.
mkdir -p "$PROJECT/.git/hooks" "$HOME/.mcp-auth"
: >"$PROJECT/.git/config"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config-lib.sh"
ensure_claude_dirs >/dev/null 2>&1

# argv_for <config-lines> — docker args (common + volumes) for that config.
argv_for() {
    printf '%b' "$1" >"$CONFIG_FILE"
    load_config >/dev/null 2>&1
    build_common_docker_args >/dev/null 2>&1
    build_standard_volume_args "$PROJECT" false >/dev/null 2>&1
    printf '%s\n' "${DOCKER_COMMON_ARGS[@]}" "${VOLUME_ARGS[@]}"
}
line() { has_line "$1" "$ARGV"; }
text() { has_text "$1" "$ARGV"; }
# Every read-write bind comes from the generated home or the project: no host
# directory holding a CLI or tokens is shared read-write (T-02).
rw_sources_contained() {
    local l src
    while IFS= read -r l; do
        case "$l" in
        /*:/*:rw)
            src="${l%%:*}"
            case "$src" in
            "$CCODE_HOME" | "$CCODE_HOME"/* | "$PROJECT" | "$PROJECT"/*) ;;
            *) return 1 ;;
            esac
            ;;
        esac
    done <<<"$ARGV"
}

# --- off (default): nothing added -------------------------------------------------------
ARGV="$(argv_for '')"
DEFAULT_ARGV="$ARGV"
for flag in --init --read-only --pids-limit --ipc --tmpfs --add-host; do
    check_not "off adds no $flag" line "$flag"
done
check "off keeps host networking" line host
check "off keeps plugins read-write" text "/home/coder/.claude/plugins:rw"
check "off keeps ~/.local/bin read-write" text "/home/coder/.local/bin:rw"
check_not "off adds no .git overlay" text "/.git/hooks:ro"
check "off: rw mounts only from the generated home or the project (T-02)" rw_sources_contained
check "off: MCP OAuth store from the generated home" text "$CCODE_HOME/.mcp-auth:/home/coder/.mcp-auth:rw"
check_not "off: the host ~/.mcp-auth is never mounted" text "$HOME/.mcp-auth:"
ARGV="$(argv_for 'setting.hardening=off\n')"
assert_eq "$ARGV" "$DEFAULT_ARGV" "explicit off is identical to the default"
ARGV="$(argv_for 'setting.hardening=paranoid\n')"
assert_eq "$ARGV" "$DEFAULT_ARGV" "an invalid profile falls back to off"

# --- standard ------------------------------------------------------------------------------
ARGV="$(argv_for 'setting.hardening=standard\n')"
check "standard: --init" line --init
check "standard: pids limit" line --pids-limit
check "standard: private IPC" line private
check_not "standard keeps a writable rootfs" line --read-only
check "standard keeps host networking" line host
check "standard keeps plugins read-write" text "/home/coder/.claude/plugins:rw"
check "standard reports its profile" line CLAUDE_DOCKERIZED_HARDENING=standard

# --- strict ----------------------------------------------------------------------------------
ARGV="$(argv_for 'setting.hardening=strict\n')"
check "strict: read-only rootfs" line --read-only
check "strict: /tmp is a tmpfs" text "/tmp:rw,nosuid,nodev,mode=1777"
check "strict: per-user tmpfs for caches" text "/home/coder/.cache:rw,nosuid,nodev,uid=$(id -u),gid=$(id -g),mode=0700"
check "strict: bridge network by default" line bridge
check_not "strict: host network dropped" line host
check "strict: host gateway alias" line "host.docker.internal:host-gateway"
for d in plugins skills agents commands; do
    check "strict: $d read-only" text "/home/coder/.claude/$d:ro"
done
check "strict: ~/.local/bin read-only" text "/home/coder/.local/bin:ro"
check "strict: rw mounts only from the generated home or the project (T-02)" rw_sources_contained
check "strict: MCP OAuth store stays writable (tokens, not code)" text "$CCODE_HOME/.mcp-auth:/home/coder/.mcp-auth:rw"
check "strict: project .git/config read-only overlay" text "$PROJECT/.git/config:/work/proj/.git/config:ro"
check "strict: project .git/hooks read-only overlay" text "$PROJECT/.git/hooks:/work/proj/.git/hooks:ro"
check "strict: credentials stay writable (auth)" text "/home/coder/.claude/.credentials.json:rw"
check "strict: .claude.json stays writable (Claude state)" text "/home/coder/.claude.json:rw"
check "strict keeps the rootless flags" line --cap-drop=ALL

ARGV="$(argv_for 'setting.hardening=strict\nsetting.network=host\n')"
check "strict honors an explicit network=host" line host
check_not "strict with explicit host adds no bridge" line bridge

t_summary
