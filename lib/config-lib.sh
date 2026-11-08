#!/bin/bash

# config-lib.sh - Shared configuration module for claude-dockerized
# This file is sourced by other scripts (not executed directly)
# Provides: config parsing, docker arg building, shared volume logic, and interactive prompts

# NOTE: Do not use "set -e" here — this is a library file sourced by callers.
# Let calling scripts control their own error handling.

# ============================================
# CONSTANTS
# ============================================

CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/claude-dockerized}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config}"

# Self-contained Claude Code state tree. The wrapper owns all of Claude Code's
# runtime state (config, data, state, cache) under this single host directory
# instead of spreading it across the host XDG dirs, so the setup is portable
# and replaces native host usage. It mirrors the container home layout and is
# mounted piece by piece (fine-grained mounts, never ~/.claude as a whole).
#
# Accounts are profiles: each one owns a CCODE_HOME of its own under
# $PROFILES_DIR/<name>/home (plus its config overlay and secrets file), see
# lib/profile-lib.sh. activate_profile derives CCODE_HOME from the selected
# profile; a CCODE_HOME already present in the environment pins the state
# root instead (test seam / advanced use) and disables the profile layout.
PROFILES_DIR="${PROFILES_DIR:-$CONFIG_DIR/profiles}"
if [ -n "${CCODE_HOME:-}" ]; then
    CCODE_HOME_PINNED=true
else
    CCODE_HOME_PINNED=false
fi
CCODE_HOME="${CCODE_HOME:-$PROFILES_DIR/default/home}"

# Directory holding the active agent relay sockets, one subdir per session and
# kind (GnuPG, SSH). The relay lives on a normal filesystem so Docker can bind
# it (it cannot bind sockets under the per-user /run/user tmpfs). GPG_RELAY_DIR
# is the historical name of the override and still honored.
SOCKET_RELAY_DIR="${SOCKET_RELAY_DIR:-${GPG_RELAY_DIR:-$CONFIG_DIR/agent-relay}}"

# Self-contained install location (Doom-style). The git checkout lives here;
# the binary is always <install>/bin/claude-dockerized, reached via PATH.
# Nothing is ever installed into ~/.local/bin (no symlink, no stub, no copy).
CCODE_INSTALL_DIR="${CCODE_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-dockerized}"
CCODE_BIN_DIR="$CCODE_INSTALL_DIR/bin"
# The rc line that puts the install on PATH, written by `claude-dockerized
# install` (and printed for shells without an rc file). $HOME/$PATH stay
# unexpanded in it; it follows CCODE_INSTALL_DIR when that is customised.
# shellcheck disable=SC2034 # consumed by lib/install-lib.sh
case "$CCODE_INSTALL_DIR" in
"$HOME"/*) CCODE_BIN_PATH_LINE="export PATH=\"\$HOME/${CCODE_INSTALL_DIR#"$HOME"/}/bin:\$PATH\"" ;;
*) CCODE_BIN_PATH_LINE="export PATH=\"$CCODE_INSTALL_DIR/bin:\$PATH\"" ;;
esac

# ============================================
# OUTPUT (colors, symbols, stdout/stderr levels: see lib/ui-lib.sh)
# ============================================

# shellcheck source=lib/ui-lib.sh
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/ui-lib.sh"

# Library-level names for the shared output helpers.
config_info() { print_info "$1"; }
config_success() { print_success "$1"; }
config_warning() { print_warning "$1"; }
config_error() { print_error "$1"; }

# Point TMPDIR at a private, user-owned 0700 dir unless the caller already set
# one (T-17). The former default, a fixed /tmp/claude, is predictable and
# shared: another local user could pre-create it and race the merge temps
# that become the managed settings. Prefers $XDG_RUNTIME_DIR (per-user tmpfs),
# then $CONFIG_DIR/tmp. Usage: ensure_private_tmpdir
ensure_private_tmpdir() {
    [ -n "${TMPDIR:-}" ] && return 0
    local dir
    for dir in "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/claude-dockerized}" "$CONFIG_DIR/tmp"; do
        [ -n "$dir" ] || continue
        mkdir -p "$dir" 2>/dev/null || continue
        # Refuse a dir someone else owns or that is a symlink.
        [ -O "$dir" ] && [ ! -L "$dir" ] || continue
        chmod 700 "$dir" 2>/dev/null || continue
        export TMPDIR="$dir"
        return 0
    done
    # mktemp in /tmp still creates unique 0600 files.
    export TMPDIR=/tmp
}

# Session integrity check (fingerprint + report of persistent paths).
# shellcheck source=lib/integrity-lib.sh
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/integrity-lib.sh"

# The rest of the library, one responsibility per module. They only define
# functions (and the pinned LSP versions): load order does not matter.
_CONFIG_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/config-file-lib.sh
source "$_CONFIG_LIB_DIR/config-file-lib.sh"
# shellcheck source=lib/mount-validate-lib.sh
source "$_CONFIG_LIB_DIR/mount-validate-lib.sh"
# shellcheck source=lib/mounts-lib.sh
source "$_CONFIG_LIB_DIR/mounts-lib.sh"
# shellcheck source=lib/layer-lib.sh
source "$_CONFIG_LIB_DIR/layer-lib.sh"
# shellcheck source=lib/agent-lib.sh
source "$_CONFIG_LIB_DIR/agent-lib.sh"
# shellcheck source=lib/lsp-lib.sh
source "$_CONFIG_LIB_DIR/lsp-lib.sh"
# shellcheck source=lib/wizard-lib.sh
source "$_CONFIG_LIB_DIR/wizard-lib.sh"
# shellcheck source=lib/profile-lib.sh
source "$_CONFIG_LIB_DIR/profile-lib.sh"
# shellcheck source=lib/profile-overlay-lib.sh
source "$_CONFIG_LIB_DIR/profile-overlay-lib.sh"
# shellcheck source=lib/profile-migrate-lib.sh
source "$_CONFIG_LIB_DIR/profile-migrate-lib.sh"
# shellcheck source=lib/profile-cmd-lib.sh
source "$_CONFIG_LIB_DIR/profile-cmd-lib.sh"
# shellcheck source=lib/profile-edit-lib.sh
source "$_CONFIG_LIB_DIR/profile-edit-lib.sh"
unset _CONFIG_LIB_DIR

# Resolve an editor: $EDITOR first, then common fallbacks.
# Prints the editor command name, or nothing when none is available.
# Usage: editor=$(resolve_editor)
resolve_editor() {
    if [ -n "${EDITOR:-}" ]; then
        echo "$EDITOR"
        return 0
    fi
    local candidate
    for candidate in sensible-editor vi nano; do
        if command -v "$candidate" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# ============================================
# CONFIG STATE (global arrays, populated by parse_config)
# ============================================

declare -a CUSTOM_MOUNTS=()     # Array of "host_path:container_path[:rw]" values
declare -a CUSTOM_MOUNT_KEYS=() # Parallel array of config key suffixes (after "mount.")
declare -a DOCKER_MOUNT_ARGS=() # Array of docker -v arguments (populated by build_mount_args)
declare -a DOCKER_ENV_ARGS=()   # Array of docker -e arguments (populated by build_env_args)
# shellcheck disable=SC2034 # populated here, consumed by callers (bin/claude-dockerized, tests)
declare -a DOCKER_ENV_FILE_ARGS=() # Array of docker --env-file arguments (populated by build_env_file_args)
declare -a VOLUME_ARGS=()          # Array of standard volume mount arguments (populated by build_standard_volume_args)
declare -a GIT_WORKTREE_ARGS=()    # Array of docker args for git worktree support (populated by build_git_worktree_args)
# Every setting.* default, in one place: sourced once and re-applied by
# load_config before it reads the file.
config_reset_settings() {
    SSH_AGENT_SUPPORT=false     # Boolean flag for SSH agent forwarding support
    GPG_AGENT_SUPPORT=false     # Boolean flag for GnuPG agent forwarding (git signing)
    GPG_ALLOW_MAIN_SOCKET=false # Allow fallback to the full-control agent socket
    GPG_AUTOSTART_AGENT=true    # Launch the host gpg-agent when its socket is missing
    GPG_RELAY=true              # Relay the agent socket through a normal-fs socket
    DOCKER_SOCKET=false         # Boolean flag: mount the host Docker socket (opt-in, root-equivalent)
    NETWORK="bridge"            # Container network: bridge (default, isolated from host loopback) | host (opt-in)
    SECURITY_POLICY="balanced"  # Security policy mode: strict | balanced | none ("off" accepted as alias for none)
    HARDENING="off"             # Runtime hardening profile: off (default, unchanged) | standard | strict (opt-in)
    INTEGRITY_CHECK=true        # Fingerprint persistent paths before/after each session and report changes
    IMAGE_STRIP_SETUID=false    # Build the image without setuid/setgid bits (opt-in)
    IMAGE_DOCKER_CLI=true       # Build the image with the Docker CLI (needed only with docker_socket)
    REQUIRE_CLAUDE_SHA=false    # Refuse to build a Claude Code version with no recorded sha256 (opt-in)
    NETWORK_EXPLICIT=false      # setting.network was set in the config (no default-change notice then)
    MEMORY=""                   # Optional container memory limit (docker --memory), e.g. 4g
    CPUS=""                     # Optional container CPU limit (docker --cpus), e.g. 2
    DEFAULT_PROFILE=""          # setting.profile: profile used when nothing selects one (empty = default)
    ENV_FILE=""                 # Per-profile dotenv secrets file (docker --env-file); load_config sets it to <profile>/env when present
    SHARE_SKILLS=false          # Mount the default profile's skills read-only instead of this profile's own
    LSP_FROM=""                 # "default": mount the default profile's .local/bin read-only (no per-profile LSP installs)
    CLAUDE_MODEL=""             # Optional default model (passed as --model); empty = Claude default / last /model choice
    CLAUDE_VERSION=""           # Claude Code release of this profile's own image (<repo>:claude-<version>); empty = shared image
    CLEANUP_DAYS="7"            # Local session-data retention (managed cleanupPeriodDays); empty = Claude default
    LSP_ENABLED=false           # Enable native LSP support (binaries + .lsp.json live in CCODE_HOME)
    LSP_SERVERS="ts,python"     # CSV of language servers to configure when setting.lsp=true
    FORMATTERS_ENABLED=false    # Enable native formatters (binaries + enabledPlugins in CCODE_HOME)
}
config_reset_settings
GPG_RELAY_SOCKET=""   # Active GnuPG relay socket for the current session
SSH_RELAY_SOCKET=""   # Active SSH relay socket for the current session
SSH_CONTAINER_SOCK="" # SSH_AUTH_SOCK path inside the container (set by build_mount_args)
GPG_SOCKET=""         # Resolved host agent socket (set by build_mount_args)
GPG_MIRROR_DIR=""     # Per-session GnuPG mirror (set by ensure_gpg_mirror)

# ============================================
# SHARED HELPERS
# ============================================

# Print the canonical install binary path (Doom-style: <install>/bin/claude-dockerized).
# Usage: repo_script_path
repo_script_path() {
    local repo_dir
    repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    readlink -f "$repo_dir/bin/claude-dockerized" 2>/dev/null || true
}

# Canonical install root for this checkout (lib/ -> repo root).
# Usage: install_root
install_root() {
    cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd
}

# Remove a legacy ~/.local/bin/claude-dockerized symlink left by older
# versions. A real (non-symlink) file is never touched. Returns 0 when
# nothing remains to clean.
# Usage: cleanup_legacy_symlink
cleanup_legacy_symlink() {
    local link="$HOME/.local/bin/claude-dockerized"
    if [ -L "$link" ]; then
        rm -f "$link" 2>/dev/null || true
        config_success "Removed legacy symlink $link (now reached via PATH)"
    fi
    return 0
}

# Verify the global host integration: <install>/bin on PATH plus the managed
# rc lines (aliases, completions, PATH). Report-only; sync never edits rc
# files (re-run `claude-dockerized install` to repair them).
# Usage: check_global_install
check_global_install() {
    local stale=false
    local expected bin_file
    expected=$(repo_script_path)
    bin_file="$CCODE_BIN_DIR/claude-dockerized"
    # The running checkout counts too: dev checkouts outside the canonical
    # path are fine as long as their bin/ is on PATH.
    local this_bin=""
    this_bin="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin" && pwd)/claude-dockerized"
    if command -v claude-dockerized >/dev/null 2>&1; then
        config_success "claude-dockerized on PATH ($(command -v claude-dockerized))"
    elif [ -n "$expected" ] && [ -x "$expected" ] && [[ ":$PATH:" == *":$(dirname "$expected"):"* ]]; then
        config_success "install bin/ on PATH ($(dirname "$expected"))"
    else
        config_warning "claude-dockerized not on PATH; run 'claude-dockerized install' to add $CCODE_BIN_DIR (or this checkout's bin/) to PATH"
        stale=true
    fi
    if [ -e "$HOME/.local/bin/claude-dockerized" ] && [ -L "$HOME/.local/bin/claude-dockerized" ]; then
        config_warning "legacy symlink present at $HOME/.local/bin/claude-dockerized; sync removes it"
        stale=true
    fi
    # Obsolete second binary: bin/ must hold only claude-dockerized.
    local stale_bin
    for stale_bin in "$CCODE_BIN_DIR/install" "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin" 2>/dev/null && pwd)/install"; do
        if [ -n "$stale_bin" ] && [ -e "$stale_bin" ]; then
            config_warning "obsolete install binary present at $stale_bin; sync removes it (use 'claude-dockerized install')"
            stale=true
        fi
    done
    local cand
    for cand in "$expected" "$this_bin" "$bin_file"; do
        if [ -n "$cand" ] && [ -e "$cand" ] && [ ! -x "$cand" ]; then
            config_warning "binary is not executable ($cand); sync restores +x"
            stale=true
        fi
    done

    local rc kind missing
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] || continue
        case "$rc" in
        *.bashrc) kind=bash ;;
        *) kind=zsh ;;
        esac
        missing=""
        if ! grep -qxF -- "alias ccd='claude-dockerized'" "$rc" 2>/dev/null ||
            ! grep -qxF -- "alias ccd-run='claude-dockerized run'" "$rc" 2>/dev/null ||
            ! grep -qxF -- "alias ccd-auth='claude-dockerized auth'" "$rc" 2>/dev/null; then
            missing="$missing aliases"
        fi
        grep -qF -- "completions/$kind.sh" "$rc" 2>/dev/null || missing="$missing completion"
        if ! grep -qF -- 'claude-dockerized/bin' "$rc" 2>/dev/null; then
            missing="$missing PATH"
        fi
        if [ -n "$missing" ]; then
            config_warning "$(basename "$rc"): stale host integration ($missing ); re-run 'claude-dockerized install' to repair"
            stale=true
        else
            config_success "$(basename "$rc") host integration (in sync)"
        fi
    done

    if [ "$stale" = true ]; then
        return 1
    fi
    return 0
}

# Check if Docker image exists locally
# Usage: check_image "$IMAGE_NAME"
check_image() {
    local image_name="$1"
    if ! docker image inspect "$image_name" >/dev/null 2>&1; then
        config_error "Docker image '$image_name' not found. Run 'claude-dockerized build${PROFILE_FLAG:+ --profile $PROFILE_FLAG}' first."
        return 1
    fi
}

# Image the active profile's sessions run: the shared image, or with
# setting.claude_version its own tag <repo>:claude-<version>, built by
# `build --profile NAME`. Usage: session_image_name
session_image_name() {
    if [ -n "${CLAUDE_VERSION:-}" ]; then
        printf '%s:claude-%s' "${IMAGE_NAME%%:*}" "$CLAUDE_VERSION"
    else
        printf '%s' "$IMAGE_NAME"
    fi
}

# Sanitize a string for use as part of a Docker container name
# Docker container names must match [a-zA-Z0-9][a-zA-Z0-9_.-]
# Usage: sanitize_container_name "my project dir"
sanitize_container_name() {
    local name="$1"
    name=$(echo "$name" | tr -cd '[:alnum:]._-')
    # Ensure it starts with alphanumeric
    while [[ "$name" =~ ^[^[:alnum:]] ]]; do name="${name#?}"; done
    [ -z "$name" ] && name="project"
    echo "$name"
}

# Generate a random hex suffix for container names
generate_random_suffix() {
    # 8 hex chars of OS entropy (avoids the collision-prone $RANDOM)
    head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# ============================================
# CONFIG PARSING (used at runtime by all scripts)
# ============================================

# Parse config file into global arrays
parse_config() {
    if ! load_config; then # Continue even if load fails: defaults are valid
        CUSTOM_MOUNTS=()
        CUSTOM_MOUNT_KEYS=()
        config_reset_settings
        profile_resolve_env_file
    fi
    # The overlay is parsed outside any `if`, so under the wrapper's `set -e`
    # a failing statement there would end the process silently: keep going.
    profile_apply_overlay || true
    return 0
}

# Print current configuration (for debugging/info)
print_config() {
    echo ""
    echo "Current configuration:"
    echo "  Config file: $CONFIG_FILE"
    echo "  Profile: ${PROFILE_NAME:-default} (${PROFILE_SOURCE:-default})"
    if [ ${#PROFILE_SET_KEYS[@]} -gt 0 ] || [ ${#PROFILE_UNAPPROVED[@]} -gt 0 ]; then
        echo "  Sources: [profile] = $PROFILE_CONFIG_FILE, [global; profile value dropped] = unapproved loosening, unmarked = global config or default"
    fi
    echo "  SSH agent forwarding: $SSH_AGENT_SUPPORT$(_config_source ssh_agent_support)"
    echo "  GnuPG agent forwarding: $GPG_AGENT_SUPPORT$(_config_source gpg_agent_support)"
    echo "  GPG main-socket fallback: $GPG_ALLOW_MAIN_SOCKET$(_config_source gpg_allow_main_socket)"
    echo "  GPG agent autostart: $GPG_AUTOSTART_AGENT$(_config_source gpg_autostart_agent)"
    echo "  GPG socket relay: $GPG_RELAY$(_config_source gpg_relay)"
    echo "  Docker socket: $DOCKER_SOCKET$(_config_source docker_socket)"
    if [ "$DOCKER_SOCKET" = true ]; then
        echo "  Docker socket WARNING: root-equivalent on the host (Docker-in-Docker only)"
    fi
    echo "  Container network: $NETWORK$(_config_source network)"
    echo "  Security policy: $SECURITY_POLICY$(_config_source security_policy)"
    echo "  Hardening profile: $HARDENING$(_config_source hardening)"
    echo "  Session integrity check: $INTEGRITY_CHECK$(_config_source integrity_check)"
    echo "  Image: strip setuid=$IMAGE_STRIP_SETUID, Docker CLI=$IMAGE_DOCKER_CLI, require Claude sha256=$REQUIRE_CLAUDE_SHA"
    echo "  Memory limit: ${MEMORY:-(none)}$(_config_source memory)"
    echo "  CPU limit: ${CPUS:-(none)}$(_config_source cpus)"
    if [ -n "$ENV_FILE" ]; then
        local env_key_count="?" env_file_path
        env_file_path=$(canonical_host_path "$ENV_FILE")
        if [ -f "$env_file_path" ]; then
            env_key_count=$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file_path" 2>/dev/null || true)
        fi
        echo "  Env file: $ENV_FILE ($env_key_count keys)"
    else
        echo "  Env file: (none)"
    fi
    echo "  Model: ${CLAUDE_MODEL:-(default)}$(_config_source model)"
    echo "  Claude Code image: $(session_image_name)$(_config_source claude_version)"
    echo "  Session retention: ${CLEANUP_DAYS:-(default)} days$(_config_source cleanup_days)"
    if [ "$LSP_ENABLED" = true ]; then echo "  LSP: true ($LSP_SERVERS)$(_config_source lsp lsp_servers)"; else echo "  LSP: false$(_config_source lsp)"; fi
    echo "  Formatters: $FORMATTERS_ENABLED$(_config_source formatters)"
    echo "  Shared skills (from default): $SHARE_SKILLS$(_config_source share_skills)"
    echo "  LSP binaries from: ${LSP_FROM:-(own)}$(_config_source lsp_from)"
    local loosened
    for loosened in "${PROFILE_LOOSENED[@]}"; do
        echo "  $UI_SYM_WARN loosened by this profile: $loosened"
    done

    if [ ${#CUSTOM_MOUNTS[@]} -gt 0 ]; then
        echo ""
        echo "  Custom mounts:"
        local i
        for i in "${!CUSTOM_MOUNTS[@]}"; do
            echo "    [$i] mount.${CUSTOM_MOUNT_KEYS[$i]}=${CUSTOM_MOUNTS[$i]}$(_config_source "mount.${CUSTOM_MOUNT_KEYS[$i]}")"
        done
    else
        echo ""
        echo "  Custom mounts: (none)"
    fi
    local dropped
    for dropped in "${PROFILE_DROPPED_MOUNTS[@]}"; do
        echo "    mount.$dropped dropped by this profile"
    done
    echo ""
}

# Where the active value of a setting comes from, as a suffix for
# print_config: " [profile]", " [profile, approved loosening]",
# " [global; profile value dropped]" or nothing (global config / default).
# Several keys share one line (lsp + lsp_servers): the first match wins.
# Usage: _config_source <key>...
_config_source() {
    local key item
    for key in "$@"; do
        for item in "${PROFILE_UNAPPROVED[@]}"; do
            [ "$item" = "$key" ] && { printf ' [global; profile value dropped]'; return 0; }
        done
        for item in "${PROFILE_LOOSENED[@]}"; do
            [ "${item%%=*}" = "$key" ] && { printf ' [profile, approved loosening]'; return 0; }
        done
        for item in "${PROFILE_SET_KEYS[@]}"; do
            [ "$item" = "$key" ] && { printf ' [profile]'; return 0; }
        done
    done
    return 0
}

# Print a docker command for DRY_RUN with secret-bearing values redacted:
# Secrets travel via --env-file (path only, safe to show); all other -e values
# (TERM, policy mode, …) stay visible for debugging. Any -e NAME=... whose name
# ends in _CONTENT is redacted (defense in depth). One flag per line.
# Usage: dry_run_print <docker args...>
dry_run_print() {
    [ $# -ge 2 ] || {
        printf '%s\n' "$@"
        return 0
    }
    local arg name mask_next=false
    printf '%s %s\n' "$1" "$2"
    shift 2
    for arg in "$@"; do
        if [ "$mask_next" = true ]; then
            name="${arg%%=*}"
            case "$name" in
            *_CONTENT) printf '  %s\n' "<redacted>" ;;
            *) printf '  %s\n' "$arg" ;;
            esac
            mask_next=false
            continue
        fi
        if [ "$arg" = "-e" ] || [ "$arg" = "--env" ]; then
            printf '  %s\n' "$arg"
            mask_next=true
            continue
        fi
        printf '  %s\n' "$arg"
    done
}
