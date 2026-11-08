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
# shellcheck source=lib/profile-cmd-lib.sh
source "$_CONFIG_LIB_DIR/profile-cmd-lib.sh"
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
        config_error "Docker image '$image_name' not found. Run 'claude-dockerized build' first."
        return 1
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
# CONFIG FILE OPERATIONS
# ============================================

# Check if config file exists
config_exists() {
    [ -f "$CONFIG_FILE" ]
}

# Initialize config file with header
init_config_file() {
    mkdir -p "$CONFIG_DIR"
    cat >"$CONFIG_FILE" <<'EOF'
# Claude Dockerized User Configuration
# Generated by 'claude-dockerized install' - edit manually or re-run 'claude-dockerized install' to modify

# Settings
# SSH Agent Forwarding (enables git over SSH in container)
# Automatically mounts SSH_AUTH_SOCK socket and passes the environment variable
# setting.ssh_agent_support=false

# GnuPG Agent Forwarding (enables git commit signing with your host keys)
# Shares only the public keyring and the gpg-agent socket; private keys never
# enter the container. Requires a running gpg-agent on the host.
# setting.gpg_agent_support=false

# Allow falling back to the full-control gpg-agent socket when the restricted
# S.gpg-agent.extra socket is unavailable. NOT recommended: the main socket can
# reconfigure the host agent. Default: false (warn and skip instead).
# setting.gpg_allow_main_socket=false

# Launch the host gpg-agent automatically at run time when its socket is
# missing. Default: true. Set to false to only warn and never start it.
# setting.gpg_autostart_agent=true

# Relay the agent socket through a socket on a normal filesystem. Needed when
# socketdir is on tmpfs (/run/user/<uid>/gnupg), which Docker cannot bind.
# Requires `socat` on the host. Default: true.
# setting.gpg_relay=true

# Docker socket (opt-in). Mounting it grants the container full control of the
# host Docker daemon, which is effectively root on the host. Enable only when
# you need Docker-in-Docker / Testcontainers.
# setting.docker_socket=false

# Container network: bridge (default; the host's localhost is out of reach,
# services it publishes on the Docker bridge via host.docker.internal) or host
# (shares the host network namespace).
# setting.network=bridge

# Security policy mode enforced by the mounted native hooks.
# strict = every vendored policy pattern; balanced = drop the noisy
# cloud/dev false positives (default); none = vendored patterns disabled
# (built-in backstops still apply). Remote flows stay allowed in all modes.
# setting.security_policy=balanced

# Runtime hardening profile (opt-in; default off keeps today's behavior).
# standard = init + pids limit + private IPC; strict = standard + read-only
# root filesystem, read-only persistent mounts (plugins, skills, ~/.local/bin,
# project .git hooks/config).
# setting.hardening=off

# Report changes to persistent paths (git hooks/config, ~/.local/bin, plugins,
# MCP servers, ...) after each session; audit log in audit/sessions.jsonl.
# setting.integrity_check=true

# Image build options (applied by `build` / `update`): strip setuid bits,
# leave out the Docker CLI (only needed with docker_socket).
# setting.image_strip_setuid=false
# setting.image_docker_cli=true
# Refuse to build a Claude Code version whose binary sha256 was never recorded
# (accept one explicitly with `build --trust-first-use`).
# setting.require_claude_sha=false

# Optional container resource limits (docker --memory / --cpus). Empty = no limit.
# setting.memory=4g
# setting.cpus=2

# Secrets are per profile (never global): the dotenv file
# ~/.config/claude-dockerized/profiles/<name>/env (mode 600) is loaded with
# docker --env-file. Edit it with: claude-dockerized profile edit <name> env

# Profile used when --profile, CLAUDE_DOCKERIZED_PROFILE and a project bind
# do not select one (empty = default). Change it with: claude-dockerized profile use <name>
# setting.profile=default

# Default model (passed as --model; empty = Claude default, /model still works).
# setting.model=

# Local session-data retention in days (cleanupPeriodDays; empty = Claude default).
# setting.cleanup_days=7

# Native LSP support (binaries + .lsp.json live in the generated home).
# setting.lsp=false

# Language servers for setting.lsp=true (csv: go,ts,python,rust).
# setting.lsp_servers=ts,python

# Native formatters (binaries + enabledPlugins in the generated home).
# setting.formatters=false

# Custom volume mounts (read-only by default)
# Format: mount.<name>=<host_path>:<container_path>[:rw]
# Examples:
#   mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
#   mount.gitignore_global=~/.config/git/gitignore_global:/home/coder/.config/git/gitignore_global
# NOTE: do NOT mount ~/.ssh (it exposes private keys and is refused). Use
# setting.ssh_agent_support=true: the agent socket plus ~/.ssh/config and
# known_hosts are mounted read-only automatically.

# Secrets live in the profile's env file (dotenv KEY=VALUE, never mounted):
# claude-dockerized profile edit <name> env. Install can add keys without
# ever printing them.
EOF
    config_success "Created config file at $CONFIG_FILE"
}

# Set the boolean global <var> from "true"/"false"; any other value leaves it
# unchanged (so an overlay can tighten as well as loosen a setting).
# Usage: _config_apply_bool <VAR> <value>
_config_apply_bool() {
    case "$2" in
    true) printf -v "$1" '%s' true ;;
    false) printf -v "$1" '%s' false ;;
    esac
}

# Apply one validated setting.<key>=<value> to the global settings.
# Usage: _config_apply_setting <key> <value>
_config_apply_setting() {
    local key="$1" value="$2"
    case "$key" in
    ssh_agent_support) _config_apply_bool SSH_AGENT_SUPPORT "$value" ;;
    gpg_agent_support) _config_apply_bool GPG_AGENT_SUPPORT "$value" ;;
    gpg_allow_main_socket) _config_apply_bool GPG_ALLOW_MAIN_SOCKET "$value" ;;
    gpg_autostart_agent) _config_apply_bool GPG_AUTOSTART_AGENT "$value" ;;
    gpg_relay) _config_apply_bool GPG_RELAY "$value" ;;
    docker_socket) _config_apply_bool DOCKER_SOCKET "$value" ;;
    share_skills) _config_apply_bool SHARE_SKILLS "$value" ;;
    lsp_from)
        case "$value" in
        "" | default) LSP_FROM="$value" ;;
        *) config_warning "Invalid lsp_from '$value' (use default or leave it empty); ignoring" ;;
        esac
        ;;
    network)
        case "$value" in
        "" | host | bridge)
            NETWORK="${value:-bridge}"
            if [ -n "$value" ]; then
                NETWORK_EXPLICIT=true
            fi
            ;;
        *) config_warning "Invalid network '$value' (use host|bridge); keeping $NETWORK" ;;
        esac
        ;;
    env_file) # secrets are per profile now (migrated by lib/profile-lib.sh)
        [ -z "$value" ] || config_warning "Ignoring setting.env_file: secrets are per profile (edit them with: claude-dockerized profile edit <name> env)"
        ;;
    profile) # default profile name (global config only); empty = default
        if [ -z "$value" ]; then
            DEFAULT_PROFILE=""
        elif profile_name_valid "$value"; then
            DEFAULT_PROFILE="$value"
        else
            config_warning "Invalid profile '$value' in setting.profile; using default"
        fi
        ;;
    model)
        case "$value" in
        "") CLAUDE_MODEL="" ;;
        *[!A-Za-z0-9._-]*) config_warning "Invalid model '$value' (use letters, numbers, . - or _); ignoring" ;;
        *) CLAUDE_MODEL="$value" ;;
        esac
        ;;
    cleanup_days)
        if [ -z "$value" ]; then
            CLEANUP_DAYS=""
        elif [[ "$value" =~ ^[0-9]+$ ]]; then
            CLEANUP_DAYS="$value"
        else
            config_warning "Invalid cleanup_days '$value' (use an integer number of days); ignoring"
        fi
        ;;
    lsp)
        case "$value" in
        true) LSP_ENABLED=true ;;
        false | "") LSP_ENABLED=false ;;
        *) config_warning "Invalid lsp '$value' (use true|false); ignoring" ;;
        esac
        ;;
    lsp_servers)
        case "$value" in
        "") ;;
        *[!A-Za-z0-9_,-]* | *,*,*,*,*) config_warning "Invalid lsp_servers '$value' (use a csv of go,ts,python,rust); ignoring" ;;
        *) LSP_SERVERS="$value" ;;
        esac
        ;;
    formatters)
        case "$value" in
        true) FORMATTERS_ENABLED=true ;;
        false | "") FORMATTERS_ENABLED=false ;;
        *) config_warning "Invalid formatters '$value' (use true|false); ignoring" ;;
        esac
        ;;
    memory)
        if [ -z "$value" ]; then
            MEMORY=""
        elif [[ "$value" =~ ^[0-9]+[bBkKmMgG]$ ]]; then
            MEMORY="$value"
        else
            config_warning "Invalid memory '$value' (e.g. 4g); ignoring"
        fi
        ;;
    cpus)
        if [ -z "$value" ]; then
            CPUS=""
        elif [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            CPUS="$value"
        else
            config_warning "Invalid cpus '$value' (e.g. 2); ignoring"
        fi
        ;;
    hardening)
        case "$value" in
        "" | off) HARDENING="off" ;;
        standard | strict) HARDENING="$value" ;;
        *) config_warning "Invalid hardening '$value' (use off|standard|strict); keeping off" ;;
        esac
        ;;
    integrity_check)
        case "$value" in
        "" | true) INTEGRITY_CHECK=true ;;
        false) INTEGRITY_CHECK=false ;;
        *) config_warning "Invalid integrity_check '$value' (use true|false); keeping true" ;;
        esac
        ;;
    image_strip_setuid) _config_apply_bool IMAGE_STRIP_SETUID "$value" ;;
    image_docker_cli) _config_apply_bool IMAGE_DOCKER_CLI "$value" ;;
    require_claude_sha) _config_apply_bool REQUIRE_CLAUDE_SHA "$value" ;;
    security_policy)
        case "$value" in
        strict | balanced | none) SECURITY_POLICY="$value" ;;
        off) SECURITY_POLICY="none" ;;
        *) config_warning "Invalid security_policy '$value' (use strict|balanced|none); keeping balanced" ;;
        esac
        ;;
    websearch_provider | theme) # legacy-migration: removed settings from the previous generation
        config_warning "Ignoring removed setting '$key' (not supported by Claude Code); remove it from $CONFIG_FILE"
        ;;
    esac
}

# Load config file into arrays, preserving each entry's original key suffix so
# save_config can re-emit it unchanged (re-running setup never renames keys).
# One pass: mount.* entries, legacy env.* (ignored with a warning: the
# host-environment passthrough was removed, secrets live in the profile's env
# file; see migrate_legacy_env_vars) and setting.* values. This reads the
# GLOBAL file only (the wizard saves what it returns); runtime commands call
# parse_config, which adds the active profile's overlay on top.
load_config() {
    if ! config_exists; then
        # Defaults are valid: say it once per invocation, as information.
        if [ -z "${_CONFIG_MISSING_NOTED:-}" ]; then
            config_info "No config file yet ($CONFIG_FILE): using defaults. Create it with: claude-dockerized install --only config"
            _CONFIG_MISSING_NOTED=1
        fi
        profile_resolve_env_file
        return 1
    fi

    CUSTOM_MOUNTS=()
    CUSTOM_MOUNT_KEYS=()
    config_reset_settings
    _load_config_file "$CONFIG_FILE"
    profile_resolve_env_file
    return 0
}

# Read one config file into the settings state. With <overlay>=overlay the
# file is a profile overlay: only overlay-safe keys apply, a same-named
# mount.* replaces the global one, and a setting that loosens the global
# security posture is ignored unless the file carries allow_loosen.<key>=true
# (see profile_overlay_apply_setting).
# Usage: _load_config_file <file> [overlay]
_load_config_file() {
    local file="$1" mode="${2:-global}" key value i
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Trim whitespace around key and value; skip comments
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        case "$key" in "" | \#*) continue ;; esac
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
        mount.*)
            # keep the suffix after "mount." so save_config re-emits it unchanged
            # `mount.<name>=-` in a profile overlay drops that global mount
            # (removing access needs no approval).
            if [ "$value" = - ]; then
                if [ "$mode" = overlay ]; then
                    _config_drop_mount "${key#mount.}"
                    PROFILE_DROPPED_MOUNTS+=("${key#mount.}")
                else
                    config_warning "Ignoring $key=- in $file: removing a mount only works in a profile overlay"
                fi
                continue
            fi
            if [ -n "$value" ] && [ -n "${key#mount.}" ]; then
                local replaced=false
                # A read-write mount from a profile overlay needs approval.
                if [ "$mode" = overlay ] && ! profile_overlay_mount_allowed "${key#mount.}" "$value" "$file"; then
                    continue
                fi
                if [ "$mode" = overlay ]; then
                    PROFILE_SET_KEYS+=("mount.${key#mount.}")
                    for i in "${!CUSTOM_MOUNT_KEYS[@]}"; do
                        if [ "${CUSTOM_MOUNT_KEYS[$i]}" = "${key#mount.}" ]; then
                            CUSTOM_MOUNTS[i]="$value"
                            replaced=true
                        fi
                    done
                fi
                if [ "$replaced" = false ]; then
                    CUSTOM_MOUNT_KEYS+=("${key#mount.}")
                    CUSTOM_MOUNTS+=("$value")
                fi
            fi
            ;;
        env.*)
            if [ -n "$value" ] && [ -n "${key#env.}" ]; then
                config_warning "Ignoring legacy '${key#env.}' (env.* passthrough was removed); move the value to the profile's env file instead."
            fi
            ;;
        setting.*)
            if [ "$mode" = overlay ]; then
                profile_overlay_apply_setting "${key#setting.}" "$value" "$file"
            else
                _config_apply_setting "${key#setting.}" "$value"
            fi
            ;;
        esac
    done <"$file"
}

# Remove every custom mount named <name>, keeping the arrays aligned.
# Usage: _config_drop_mount <name>
_config_drop_mount() {
    local -a keys=() mounts=()
    local i
    for i in "${!CUSTOM_MOUNT_KEYS[@]}"; do
        [ "${CUSTOM_MOUNT_KEYS[$i]}" = "$1" ] && continue
        keys+=("${CUSTOM_MOUNT_KEYS[$i]}")
        mounts+=("${CUSTOM_MOUNTS[$i]}")
    done
    CUSTOM_MOUNT_KEYS=("${keys[@]}")
    CUSTOM_MOUNTS=("${mounts[@]}")
}

# Allocate an unused "customN" key suffix for a new entry, avoiding collisions
# with already-used suffixes passed as arguments.
# Usage: key=$(next_custom_key "${CUSTOM_MOUNT_KEYS[@]}")
next_custom_key() {
    local n=1 existing
    while :; do
        local taken=false
        for existing in "$@"; do
            if [ "$existing" = "custom$n" ]; then
                taken=true
                break
            fi
        done
        if [ "$taken" = false ]; then
            echo "custom$n"
            return 0
        fi
        n=$((n + 1))
    done
}

# Save current arrays to config file, preserving original key names and
# skipping exact duplicate lines (idempotent across re-runs).
save_config() {
    mkdir -p "$CONFIG_DIR"
    # The default profile is not a wizard setting: an overwrite must not drop
    # it. Read it before the file is truncated below.
    local default_profile="$DEFAULT_PROFILE"
    [ -n "$default_profile" ] || default_profile=$(profile_config_default)

    {
        echo "# Claude Dockerized User Configuration"
        echo "# Generated by 'claude-dockerized install' - edit manually or re-run 'claude-dockerized install' to modify"
        echo ""
        echo "# Settings"
        echo "# SSH Agent Forwarding (enables git over SSH in container)"
        echo "# Automatically mounts SSH_AUTH_SOCK socket and passes the environment variable"
        echo "setting.ssh_agent_support=$SSH_AGENT_SUPPORT"
        echo "# GnuPG agent forwarding (public keyring + gpg-agent socket; enables git commit -S)"
        echo "setting.gpg_agent_support=$GPG_AGENT_SUPPORT"
        echo "# Allow GPG fallback to the full-control agent socket when the restricted"
        echo "# S.gpg-agent.extra is unavailable (NOT recommended)"
        echo "setting.gpg_allow_main_socket=$GPG_ALLOW_MAIN_SOCKET"
        echo "# Launch the host gpg-agent automatically when its socket is missing"
        echo "setting.gpg_autostart_agent=$GPG_AUTOSTART_AGENT"
        echo "# Relay the agent socket through a normal-filesystem socket (needed when"
        echo "# socketdir is on tmpfs, e.g. /run/user/<uid>/gnupg); requires socat"
        echo "setting.gpg_relay=$GPG_RELAY"
        echo "# Docker socket (opt-in; grants host Docker control — root-equivalent)"
        echo "setting.docker_socket=$DOCKER_SOCKET"
        echo "# Container network: bridge (default, isolated from host localhost) | host"
        echo "setting.network=$NETWORK"
        echo "# Security policy mode: strict | balanced | none (off = alias for none)"
        echo "setting.security_policy=$SECURITY_POLICY"
        echo "# Runtime hardening profile: off (default) | standard | strict"
        echo "setting.hardening=$HARDENING"
        echo "# Report persistent-path changes after each session (audit/sessions.jsonl)"
        echo "setting.integrity_check=$INTEGRITY_CHECK"
        echo "# Image build options (build/update): strip setuid bits, include the Docker CLI"
        echo "setting.image_strip_setuid=$IMAGE_STRIP_SETUID"
        echo "setting.image_docker_cli=$IMAGE_DOCKER_CLI"
        echo "# Refuse to build a Claude Code version whose sha256 was never recorded"
        echo "setting.require_claude_sha=$REQUIRE_CLAUDE_SHA"
        echo "# Optional container resource limits (empty = no limit)"
        echo "setting.memory=$MEMORY"
        echo "setting.cpus=$CPUS"
        echo "# Secrets are per profile: $PROFILES_DIR/<name>/env (never mounted)."
        echo "# Default profile when nothing selects one (omitted = default)."
        [ -z "$default_profile" ] || echo "setting.profile=$default_profile"
        echo "# Default model (passed as --model; empty = Claude default, /model still works)."
        echo "setting.model=$CLAUDE_MODEL"
        echo "# Local session-data retention in days (cleanupPeriodDays; empty = Claude default)."
        echo "setting.cleanup_days=$CLEANUP_DAYS"
        echo "# Native LSP support (binaries + .lsp.json in the generated home)."
        echo "setting.lsp=$LSP_ENABLED"
        echo "# Language servers to configure when setting.lsp=true (csv: go,ts,python,rust)."
        echo "setting.lsp_servers=$LSP_SERVERS"
        echo "# Native formatters (binaries + enabledPlugins in the generated home)."
        echo "setting.formatters=$FORMATTERS_ENABLED"
        echo ""
        echo "# Custom volume mounts (read-only by default)"
        echo "# Format: mount.<name>=<host_path>:<container_path>[:rw]"
        echo "# NOTE: paths containing ':' are not supported (used as separator)"

        if [ ${#CUSTOM_MOUNTS[@]} -gt 0 ]; then
            local seen_m=""
            local i
            for i in "${!CUSTOM_MOUNTS[@]}"; do
                local line="mount.${CUSTOM_MOUNT_KEYS[$i]}=${CUSTOM_MOUNTS[$i]}"
                [[ "$seen_m" == *"|$line|"* ]] && continue
                seen_m="$seen_m|$line|"
                echo "$line"
            done
        fi
    } >"$CONFIG_FILE"

    config_success "Saved configuration to $CONFIG_FILE"
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
