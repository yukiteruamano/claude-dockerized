#!/bin/bash
# CLI output and diagnostics contract (lib/ui-lib.sh, lib/diag-lib.sh,
# wizard prompts): diagnostics on stderr, color only for terminals, plain
# symbols outside UTF-8 locales, actionable Docker errors, machine-readable
# version/doctor, read-only commands usable from $HOME, and wizard prompts
# that keep the current value on Enter.
#
# Usage: bash tests/ui.test.sh
# shellcheck disable=SC2034,SC2317  # globals feed config-lib.sh; helpers run via check

# No `set -u`: config-lib.sh is sourced by callers that do not use it.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="ui"
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
unset NO_COLOR CLICOLOR_FORCE
mkdir -p "$HOME"
BIN="$REPO_DIR/bin/claude-dockerized"
ESC=$'\033'

# --- streams, color, symbols (ui-lib) -------------------------------------------------------
ui() { bash -c 'source "$1/lib/ui-lib.sh"; print_info info; print_error boom' _ "$REPO_DIR"; }
out_only="$(ui 2>/dev/null)"
err_only="$(ui 2>&1 >/dev/null)"
check "info goes to stdout" has_text "info" "$out_only"
check_not "errors never go to stdout" has_text "boom" "$out_only"
check "errors go to stderr" has_text "boom" "$err_only"
check_not "no color when not a terminal" has_text "${ESC}[" "$(ui 2>&1)"
check "CLICOLOR_FORCE forces color" has_text "${ESC}[" "$(CLICOLOR_FORCE=1 ui 2>&1)"
check_not "NO_COLOR wins over CLICOLOR_FORCE" has_text "${ESC}[" "$(NO_COLOR=1 CLICOLOR_FORCE=1 ui 2>&1)"
check_not "no literal quote artifacts around colors" has_text "'$ESC" "$(CLICOLOR_FORCE=1 ui 2>&1)"
check "ASCII symbols outside UTF-8 locales" has_line "x boom" "$(LC_ALL=C LANG=C ui 2>&1)"
check "UTF-8 symbols in UTF-8 locales" has_line "✗ boom" "$(LC_ALL=C.UTF-8 ui 2>&1)"
check_not "--no-color strips color" has_text "${ESC}[" "$(CLICOLOR_FORCE=1 bash "$BIN" --no-color help 2>&1)"

# --- version without Docker ---------------------------------------------------------------
STUB="$TMP/stub"
mkdir -p "$STUB"
# A PATH with every tool of the current one except docker.
NODOCKER="$TMP/nodocker"
mkdir -p "$NODOCKER"
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        name="${f##*/}"
        [ "$name" = docker ] && continue
        [ -x "$f" ] && [ ! -e "$NODOCKER/$name" ] && ln -s "$f" "$NODOCKER/$name"
    done
done
nodocker_path="$NODOCKER"
ver_out="$(PATH="$nodocker_path" bash "$BIN" version 2>&1)"
ver_rc=$?
assert_eq "$ver_rc" 0 "version works without Docker"
check "version names the wrapper" has_text "claude-dockerized " "$ver_out"
check "version shows the guard" has_text "guard v" "$ver_out"
ver_json="$(PATH="$nodocker_path" bash "$BIN" --version --json 2>/dev/null)"
valid_json() { node -e 'JSON.parse(process.argv[1])' "$1" 2>/dev/null; }
check "version --json is valid JSON" valid_json "$ver_json"
check "-V is an alias of version" has_text '"wrapper"' "$ver_json"

# --- actionable Docker errors ------------------------------------------------------------------
fake_docker() {
    printf '#!/bin/bash\n[ "$1" = info ] && { echo "%s" >&2; exit 1; }\nexit 0\n' "$1" >"$STUB/docker"
    chmod +x "$STUB/docker"
}
fake_docker "permission denied while trying to connect to the Docker daemon socket"
perm_out="$(PATH="$STUB:$PATH" bash "$BIN" build 2>&1)"
check "permission problem explained" has_text "No permission" "$perm_out"
check "permission fix suggested" has_text "docker' group" "$perm_out"
fake_docker "Cannot connect to the Docker daemon. Is the docker daemon running?"
down_out="$(PATH="$STUB:$PATH" bash "$BIN" build 2>&1)"
check "stopped daemon explained" has_text "not running" "$down_out"
no_cli_out="$(PATH="$nodocker_path" bash "$BIN" build 2>&1)"
rm -f "$STUB/docker"
no_cli_out="$(PATH="$nodocker_path" bash "$BIN" build 2>&1)"
check "missing CLI explained" has_text "Docker CLI not found" "$no_cli_out"

# --- doctor --json and exit status (host checks) -------------------------------------------------
doc_json="$(PATH="$nodocker_path" bash "$BIN" doctor --json 2>/dev/null)"
doc_rc=$?
check "doctor --json is valid JSON" valid_json "$doc_json"
assert_eq "$doc_rc" 1 "doctor fails when Docker is unavailable"
check "doctor reports the docker check" has_text '"check":"docker"' "$doc_json"
check "doctor reports the release-key check" has_text '"check":"release-key"' "$doc_json"

# --- read-only commands from $HOME (no project mount, no refusal) --------------------------------
cat >"$STUB/docker" <<EOF
#!/bin/bash
[ "\$1" = run ] && printf '%s\n' "\$@" >"$TMP/mcp.argv"
exit 0
EOF
chmod +x "$STUB/docker"
mcp_out="$(cd "$HOME" && PATH="$STUB:$PATH" bash "$BIN" mcp list 2>&1)"
mcp_rc=$?
assert_eq "$mcp_rc" 0 "mcp list works from \$HOME"
check_not "mcp list from \$HOME mounts no project" grep -qF -- "$HOME:" "$TMP/mcp.argv"
check_not "no home-directory refusal" has_text "Refusing to run" "$mcp_out"

# --- wizard prompts keep the current value on Enter ------------------------------------------------
# shellcheck source=/dev/null
source "$REPO_DIR/lib/config-lib.sh"
MEMORY=4g
prompt_memory <<<"" >/dev/null 2>&1
assert_eq "$MEMORY" 4g "Enter keeps the memory limit"
prompt_memory <<<"none" >/dev/null 2>&1
assert_eq "$MEMORY" "" "'none' clears the memory limit"
CPUS=2
prompt_cpus <<<"" >/dev/null 2>&1
assert_eq "$CPUS" 2 "Enter keeps the CPU limit"
CLEANUP_DAYS=30
prompt_cleanup_days <<<"" >/dev/null 2>&1
assert_eq "$CLEANUP_DAYS" 30 "Enter keeps the retention"
LSP_ENABLED=true
LSP_SERVERS=go
printf '\n\n' | prompt_lsp >/dev/null 2>&1
assert_eq "$LSP_ENABLED" true "Enter keeps LSP enabled"
FORMATTERS_ENABLED=true
prompt_formatters <<<"" >/dev/null 2>&1
assert_eq "$FORMATTERS_ENABLED" true "Enter keeps formatters enabled"
HARDENING=standard
prompt_hardening <<<"" >/dev/null 2>&1
assert_eq "$HARDENING" standard "Enter keeps the hardening profile"
CUSTOM_MOUNTS=()
CUSTOM_MOUNT_KEYS=()
mount_out="$(printf 'y\n%s\n\nn\nn\n' "$HOME/.ssh" | prompt_custom_mounts 2>&1)"
check_not "a refused mount is never reported as added" has_text "Added mount" "$mount_out"

t_summary
