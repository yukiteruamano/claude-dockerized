#!/bin/bash
# LSP/formatter installs (T-14): pinned versions, inside a throwaway image
# container with no capabilities and npm --ignore-scripts, never npm/uv on
# the host, only when something is missing, and formatters alone work.
# docker, npm and uv are stubbed (they record their calls).
#
# Usage: bash tests/lsp-install.test.sh
# shellcheck disable=SC2034,SC2317  # globals feed config-lib.sh; helpers run via check

# No `set -u`: config-lib.sh is sourced by callers that do not use it.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="lsp-install"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

export TMPDIR="${TMPDIR:-/tmp/claude}"
TMP="$(t_tmpdir)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

export HOME="$TMP/home"
export CONFIG_DIR="$HOME/.config/claude-dockerized"
export CCODE_HOME="$CONFIG_DIR/home"
export NO_COLOR=1
unset CLAUDE_DOCKERIZED_SKIP_LSP_INSTALL
mkdir -p "$CCODE_HOME/.local/bin"

STUB="$TMP/stub"
CALLS="$TMP/calls"
mkdir -p "$STUB" "$CALLS"
for tool in docker npm uv; do
    cat >"$STUB/$tool" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >"$CALLS/$tool.\$(date +%s%N)"
exit 0
EOF
    chmod +x "$STUB/$tool"
done
export PATH="$STUB:$PATH"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config-lib.sh"

calls_of() { cat "$CALLS"/"$1".* 2>/dev/null; }
reset_calls() { rm -f "$CALLS"/*; unset _LSP_FORMATTERS_DONE; }
install_run() { calls_of docker | grep -qx run; }
run_has() { calls_of docker | grep -qxF -- "$1"; }
run_has_text() { calls_of docker | grep -qF -- "$1"; }

LSP_ENABLED=true
LSP_SERVERS="ts,python"
FORMATTERS_ENABLED=false
reset_calls
ensure_lsp_formatters >/dev/null 2>&1
check "install runs in a container" install_run
check "container drops every capability" run_has --cap-drop=ALL
check "container sets no-new-privileges" run_has no-new-privileges:true
check "container runs as the host user" run_has "$(id -u):$(id -g)"
check "npm scripts are disabled" run_has_text "--ignore-scripts"
check "typescript-language-server is pinned" run_has_text "typescript-language-server@6.0.1"
check "pyright is pinned" run_has_text "pyright@1.1.414"
check "ruff is pinned" run_has "RUFF_VERSION=$FMT_RUFF_VERSION"
check "only the generated-home bin dir is writable" run_has "$CCODE_HOME/.local/bin:/opt/lsp-bin:rw"
check_not "host npm is never called" [ -n "$(calls_of npm)" ]
check_not "host uv is never called" [ -n "$(calls_of uv)" ]

# Already installed: nothing to do, no container. Binaries must be executable
# (a dangling symlink or a non-executable placeholder counts as missing).
for b in typescript-language-server pyright-langserver ruff; do : >"$CCODE_HOME/.local/bin/$b"; chmod +x "$CCODE_HOME/.local/bin/$b"; done
reset_calls
ensure_lsp_formatters >/dev/null 2>&1
check_not "nothing reinstalled when present" install_run

# A dangling symlink is missing: it must reinstall (regression: `-e` treated
# the stale link as present and looped installs every run).
rm -f "$CCODE_HOME/.local/bin/ruff"
ln -s .lsp/uv-bin/ruff "$CCODE_HOME/.local/bin/ruff"
reset_calls
ensure_lsp_formatters >/dev/null 2>&1
check "dangling symlink triggers reinstall" install_run

# A non-executable placeholder is missing too.
rm -f "$CCODE_HOME/.local/bin/ruff"
: >"$CCODE_HOME/.local/bin/ruff"
reset_calls
ensure_lsp_formatters >/dev/null 2>&1
check "non-executable file triggers reinstall" install_run
for b in typescript-language-server pyright-langserver ruff; do : >"$CCODE_HOME/.local/bin/$b"; chmod +x "$CCODE_HOME/.local/bin/$b"; done

# A container-absolute uv link is healed on the host without docker: uv leaves
# .lsp/uv-bin/ruff -> /opt/lsp-bin/.lsp/uv-tools/ruff/bin/ruff, which dangles
# on the host even though the real binary persisted in the shared home.
rm -rf "$CCODE_HOME/.local/bin/.lsp"
mkdir -p "$CCODE_HOME/.local/bin/.lsp/uv-tools/ruff/bin" "$CCODE_HOME/.local/bin/.lsp/uv-bin"
: >"$CCODE_HOME/.local/bin/.lsp/uv-tools/ruff/bin/ruff"
chmod +x "$CCODE_HOME/.local/bin/.lsp/uv-tools/ruff/bin/ruff"
ln -sfn /opt/lsp-bin/.lsp/uv-tools/ruff/bin/ruff "$CCODE_HOME/.local/bin/.lsp/uv-bin/ruff"
ln -sfn .lsp/uv-bin/ruff "$CCODE_HOME/.local/bin/ruff"
reset_calls
ensure_lsp_formatters >/dev/null 2>&1
check_not "container-absolute uv link heals without a container" install_run
check "healed ruff resolves on the host" lsp_bin_ok "$CCODE_HOME/.local/bin/ruff"

# Same absolute link but the real binary never persisted: still reinstalls.
rm -f "$CCODE_HOME/.local/bin/.lsp/uv-tools/ruff/bin/ruff"
reset_calls
ensure_lsp_formatters >/dev/null 2>&1
check "unhealable uv link triggers reinstall" install_run
for b in typescript-language-server pyright-langserver ruff; do : >"$CCODE_HOME/.local/bin/$b"; chmod +x "$CCODE_HOME/.local/bin/$b"; done

# Second call in the same process is a no-op (check_config + run_claude used
# to spawn two throwaway containers per `run`).
reset_calls
ensure_lsp_formatters >/dev/null 2>&1
ensure_lsp_formatters >/dev/null 2>&1
check_not "second call in the same process spawns no container" install_run
reset_calls
ensure_lsp_formatters >/dev/null 2>&1
check "stamp written when up to date" [ -f "$CCODE_HOME/.local/bin/.lsp-versions" ]

# Formatters alone install their binaries (was: nothing without lsp=true).
LSP_ENABLED=false
FORMATTERS_ENABLED=true
reset_calls
ensure_lsp_formatters >/dev/null 2>&1
check "formatters alone trigger an install" install_run
check "prettier is pinned" run_has_text "prettier@3.9.9"

# Disabled / skipped: nothing at all.
FORMATTERS_ENABLED=false
reset_calls
ensure_lsp_formatters >/dev/null 2>&1
check_not "disabled: no install" install_run
LSP_ENABLED=true
LSP_SERVERS=go
reset_calls
CLAUDE_DOCKERIZED_SKIP_LSP_INSTALL=1 ensure_lsp_formatters >/dev/null 2>&1
check_not "skip flag: no install" install_run

t_summary
