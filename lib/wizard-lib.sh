#!/bin/bash
# wizard-lib.sh - interactive configuration (used by `claude-dockerized install` and `config`)
# Sourced by lib/config-lib.sh (which keeps the constants, config parsing and
# saving). Not executable directly; no `set -e`: callers own error handling.

# ============================================
# CONFIG MANAGEMENT (used by `claude-dockerized install`)
# ============================================

# Add a mount entry to arrays and optionally save
# New entries get an unused "customN" key suffix, preserving existing key names.
# add_mount <host_path> <container_path> [mode]   (mode: "ro" or "rw", default ro)
add_mount() {
    local host_path="$1"
    local container_path="$2"
    local mode="${3:-}"

    if [ -z "$host_path" ] || [ -z "$container_path" ]; then
        config_error "add_mount requires host_path and container_path"
        return 1
    fi

    # Container path must be absolute (relative paths resolve unpredictably)
    if [[ "$container_path" != /* ]]; then
        config_error "Container path must be absolute: $container_path"
        return 1
    fi

    # Same rules as build_mount_args (canonical path, sensitive dirs, mode).
    validate_mount_spec "$host_path" "$container_path" "${mode:-ro}" >/dev/null || return 1

    local expanded_path
    expanded_path=$(canonical_host_path "$host_path")
    if [ ! -e "$expanded_path" ]; then
        config_warning "Host path does not exist: $expanded_path"
    fi

    local mount_entry="$host_path:$container_path"
    [ -n "$mode" ] && mount_entry="$mount_entry:$mode"

    local key
    key=$(next_custom_key "${CUSTOM_MOUNT_KEYS[@]}")
    CUSTOM_MOUNT_KEYS+=("$key")
    CUSTOM_MOUNTS+=("$mount_entry")
}

# ============================================
# INTERACTIVE PROMPTS (used by `claude-dockerized install`)
# ============================================

# Suggest a container path based on host path
# suggest_container_path <host_path> [default]
suggest_container_path() {
    local host_path="$1"
    local default="${2:-/home/coder/$(basename "$host_path")}"

    # For common paths, suggest sensible defaults
    if [[ "$host_path" == *"/.gitconfig" ]]; then
        echo "/home/coder/.gitconfig"
    elif [[ "$host_path" == *"/.ssh" ]]; then
        echo "/home/coder/.ssh"
    elif [[ "$host_path" == *"/.config/git"* ]]; then
        echo "/home/coder/.config/git/$(basename "$host_path")"
    else
        echo "$default"
    fi
}

# Ask user how to handle existing config
# Sets global: CONFIG_MODE ("append", "overwrite", or "skip")
prompt_config_mode() {
    if ! config_exists; then
        CONFIG_MODE="new"
        return 0
    fi

    echo ""
    config_info "Configuration file already exists at $CONFIG_FILE"

    PS3="Choose an option: "
    select mode in "Append (add new entries)" "Overwrite (replace config)" "Skip (keep existing)"; do
        case "$mode" in
        "Append (add new entries)")
            CONFIG_MODE="append"
            config_success "Will append new entries to existing config"
            break
            ;;
        "Overwrite (replace config)")
            CONFIG_MODE="overwrite"
            config_warning "Will replace existing config"
            break
            ;;
        "Skip (keep existing)")
            CONFIG_MODE="skip"
            config_info "Skipping config setup"
            break
            ;;
        *)
            if [ -z "$mode" ]; then
                config_info "No selection (EOF); skipping setup."
                CONFIG_MODE="skip"
                break
            fi
            config_error "Invalid option"
            ;;
        esac
    done
    [ -n "${CONFIG_MODE:-}" ] || CONFIG_MODE="skip"
}

# Interactive mount addition
# Prompts user repeatedly until they enter a blank line
prompt_custom_mounts() {
    echo ""
    config_info "Configure custom volume mounts (optional)"
    echo "Enter host paths to mount in the container (read-only by default)"
    echo "Press Enter with empty input to finish"
    echo ""

    while true; do
        read -r -p "Host path: " host_path || host_path=""

        # Allow blank to exit
        if [ -z "$host_path" ]; then
            break
        fi

        # Expand a leading ~ for validation
        local expanded_path="$host_path"
        if [[ "$expanded_path" == "~"* ]]; then
            expanded_path="$HOME${expanded_path#"~"}"
        fi

        if [ ! -e "$expanded_path" ]; then
            config_warning "Path does not exist: $expanded_path"
            read -r -p "Continue anyway? (y/N): " proceed || proceed=""
            [[ "$proceed" =~ ^[Yy]$ ]] || continue
        fi

        # Suggest container path
        local suggested
        suggested=$(suggest_container_path "$host_path")
        read -r -p "Container path [$suggested]: " container_path || container_path=""
        container_path="${container_path:-$suggested}"

        # Ask about read-write
        read -r -p "Read-write? (y/N): " rw_mode || rw_mode=""
        local mode=""
        if [[ "$rw_mode" =~ ^[Yy]$ ]]; then
            mode="rw"
        fi

        # Add the mount (add_mount explains a refusal itself).
        if add_mount "$host_path" "$container_path" "$mode"; then
            config_success "Added mount: $host_path -> $container_path${mode:+ ($mode)}"
        fi
        echo ""
    done
}

# Interactive environment variable addition
# Prompts user repeatedly until they enter a blank line
# Write or replace one KEY=VALUE line in a dotenv secrets file, preserving
# every other line byte-for-byte. Creates the file with mode 600 when missing
# and fixes group/other-readable permissions with a warning. The value is never
# printed (only the key name is reported by callers).
# Usage: env_file_upsert <file> <KEY> <VALUE>
env_file_upsert() {
    local file="$1" key="$2" value="$3"

    if [ -z "$key" ] || ! [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
        config_error "Invalid variable name: $key (must be uppercase with underscores)"
        return 1
    fi
    case "$value" in
    *$'\n'*)
        config_error "Value for $key spans multiple lines; only single-line values are supported"
        return 1
        ;;
    esac

    local dir
    dir=$(dirname "$file")
    mkdir -p "$dir" 2>/dev/null || return 1
    if [ ! -f "$file" ]; then
        install -m 600 /dev/null "$file" 2>/dev/null || : >"$file" 2>/dev/null || return 1
    fi
    chmod 600 "$file" 2>/dev/null || true

    local tmp replaced=false
    tmp=$(mktemp "${file}.tmp.XXXXXX" 2>/dev/null) || return 1
    if [ -s "$file" ]; then
        local line
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
            "$key"=*)
                if [ "$replaced" = false ]; then
                    printf '%s=%s\n' "$key" "$value" >>"$tmp"
                    replaced=true
                fi
                ;;
            *)
                printf '%s\n' "$line" >>"$tmp"
                ;;
            esac
        done <"$file"
    fi
    if [ "$replaced" = false ]; then
        printf '%s=%s\n' "$key" "$value" >>"$tmp"
    fi
    cat "$tmp" >"$file" 2>/dev/null || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
}

# One-shot migration of legacy env.* entries into the secrets file. Values are
# taken from the current host environment and never printed; entries whose
# variable is unset are reported and skipped. Silent when nothing to migrate.
# Usage: migrate_legacy_env_vars
migrate_legacy_env_vars() {
    [ -f "$CONFIG_FILE" ] || return 0
    local vars
    vars=$(sed -nE 's/^[[:space:]]*env\.[^=[:space:]]+[[:space:]]*=[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$/\1/p' "$CONFIG_FILE" 2>/dev/null || true)
    [ -n "$vars" ] || return 0

    echo ""
    config_info "Legacy env.* entries found in $CONFIG_FILE."
    echo "Their values can be moved into the secrets file (setting.env_file)."
    read -r -p "Migrate now from the current host environment? (Y/n): " migrate || migrate=""
    [[ "$migrate" =~ ^[Nn]$ ]] && return 0

    [ -n "$ENV_FILE" ] || ENV_FILE="$CONFIG_DIR/env"
    local var_name var_value count=0 skipped=0
    while IFS= read -r var_name; do
        [ -n "$var_name" ] || continue
        var_value="${!var_name:-}"
        if [ -z "$var_value" ]; then
            config_warning "'$var_name' is not set in this shell; skipped (export it and re-run setup to migrate it)"
            skipped=$((skipped + 1))
            continue
        fi
        if env_file_upsert "$ENV_FILE" "$var_name" "$var_value"; then
            config_success "Migrated $var_name"
            count=$((count + 1))
        fi
        var_value=""
    done <<<"$vars"
    var_value=""
    config_info "Migrated $count variable(s), skipped $skipped."
}

prompt_env_vars() {
    echo ""
    config_info "Secrets and environment variables (optional)"
    echo "Values are stored in a secrets file (dotenv KEY=VALUE, mode 600) and"
    echo "loaded with docker --env-file. Nothing is ever printed back."
    echo "Press Enter with empty input to finish"
    echo ""

    echo "Common examples:"
    echo "  ANTHROPIC_API_KEY - Anthropic API key"
    echo "  CLAUDE_CODE_OAUTH_TOKEN - OAuth token (from: claude setup-token)"
    echo ""

    # Default location on first use.
    if [ -z "$ENV_FILE" ]; then
        ENV_FILE="$CONFIG_DIR/env"
    fi

    local var_name var_value
    while true; do
        read -r -p "Variable name (e.g. EXA_API_KEY): " var_name || var_name=""

        # Allow blank to exit
        if [ -z "$var_name" ]; then
            break
        fi

        # Validate variable name (basic check)
        if ! [[ "$var_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            config_error "Invalid variable name: $var_name (must be uppercase with underscores)"
            continue
        fi
        case "$var_name" in
        PATH | HOME | LD_PRELOAD | LD_LIBRARY_PATH | DOCKER_* | *_PROXY | *_proxy)
            config_warning "'$var_name' overrides container runtime behavior; prefer a narrower name unless intentional"
            ;;
        esac

        # Hidden input: never echoed, paste-friendly.
        read -r -s -p "Value for $var_name (hidden): " var_value || var_value=""
        echo ""
        if [ -z "$var_value" ]; then
            config_warning "Empty value; skipping $var_name"
            echo ""
            continue
        fi

        if env_file_upsert "$ENV_FILE" "$var_name" "$var_value"; then
            config_success "Saved $var_name to the secrets file"
        fi
        var_value=""
        echo ""
    done
    var_value=""
}

# Interactive SSH agent support prompt
# If SSH_AGENT_SUPPORT is already set (from a previous config), show current value
# and only ask if user wants to change it
prompt_ssh_agent_support() {
    echo ""
    config_info "SSH Agent Forwarding Support"

    if [ "$SSH_AGENT_SUPPORT" = true ]; then
        config_success "SSH agent forwarding is currently enabled"
        read -r -p "Keep SSH agent forwarding enabled? (Y/n): " ssh_agent || ssh_agent=""
        if [[ "$ssh_agent" =~ ^[Nn]$ ]]; then
            SSH_AGENT_SUPPORT=false
            config_info "SSH agent forwarding support disabled"
        else
            config_success "SSH agent forwarding support remains enabled"
        fi
    else
        echo "Enable this if you use SSH agent forwarding for git operations over SSH."
        echo "This mounts the SSH agent socket (private keys stay on the host) and the"
        echo "non-secret ~/.ssh/config and known_hosts files read-only."
        echo ""

        read -r -p "Enable SSH agent forwarding support? (y/N): " ssh_agent || ssh_agent=""
        if [[ "$ssh_agent" =~ ^[Yy]$ ]]; then
            SSH_AGENT_SUPPORT=true
            config_success "SSH agent forwarding support enabled"
        else
            SSH_AGENT_SUPPORT=false
            config_info "SSH agent forwarding support disabled"
        fi
    fi
}

# Interactive GnuPG agent forwarding prompt
# Shares only the public keyring and the host gpg-agent socket; private keys
# never enter the container.
prompt_gpg_agent_support() {
    echo ""
    config_info "GnuPG Agent Forwarding (git commit signing)"

    if [ "$GPG_AGENT_SUPPORT" = true ]; then
        config_success "GnuPG agent forwarding is currently enabled"
        read -r -p "Keep GnuPG agent forwarding enabled? (Y/n): " gpg_agent || gpg_agent=""
        if [[ "$gpg_agent" =~ ^[Nn]$ ]]; then
            GPG_AGENT_SUPPORT=false
            config_info "GnuPG agent forwarding disabled"
        else
            config_success "GnuPG agent forwarding remains enabled"
        fi
    else
        echo "Enable this to sign commits (git commit -S) with the keys held by your"
        echo "host gpg-agent. Only the public keyring and the agent socket are shared;"
        echo "your private keys never enter the container."
        echo ""

        read -r -p "Enable GnuPG agent forwarding? (y/N): " gpg_agent || gpg_agent=""
        if [[ "$gpg_agent" =~ ^[Yy]$ ]]; then
            GPG_AGENT_SUPPORT=true
            config_success "GnuPG agent forwarding enabled"
        else
            GPG_AGENT_SUPPORT=false
            config_info "GnuPG agent forwarding disabled"
        fi
    fi
}

# Interactive host Docker socket prompt
# Mounting the socket gives the container full control of the host Docker
# daemon (effectively root on the host), so it is opt-in.
prompt_docker_socket() {
    echo ""
    config_info "Host Docker Socket (opt-in)"

    if [ "$DOCKER_SOCKET" = true ]; then
        config_warning "Docker socket is currently mounted (container can control the host Docker daemon)"
        read -r -p "Keep the Docker socket mounted? (y/N): " keep_socket || keep_socket=""
        if [[ "$keep_socket" =~ ^[Yy]$ ]]; then
            config_success "Docker socket remains mounted"
        else
            DOCKER_SOCKET=false
            config_info "Docker socket disabled"
        fi
    else
        echo "Enable only if you need Docker-in-Docker or Testcontainers."
        echo "WARNING: it grants the container full control of the host Docker daemon."
        read -r -p "Mount the host Docker socket? (y/N): " enable_socket || enable_socket=""
        if [[ "$enable_socket" =~ ^[Yy]$ ]]; then
            DOCKER_SOCKET=true
            config_success "Docker socket mounted"
        else
            DOCKER_SOCKET=false
            config_info "Docker socket disabled"
        fi
    fi
}

# Interactive container network prompt
# host = simple (shares host network namespace); bridge = more isolated.
prompt_network() {
    echo ""
    config_info "Container Network"
    echo "  host   = shares the host network namespace (default, simple)"
    echo "  bridge = more isolated (reach host services via host.docker.internal)"
    read -r -p "Container network (host|bridge) [$NETWORK]: " network || network=""
    case "$network" in
    host | bridge)
        NETWORK="$network"
        ;;
    "")
        ;;
    *)
        config_warning "Invalid network '$network' (use host|bridge); keeping $NETWORK"
        ;;
    esac
    config_success "Container network: $NETWORK"
}

# Interactive hardening-profile prompt (Enter keeps the current value).
prompt_hardening() {
    echo ""
    config_info "Runtime Hardening (opt-in)"
    echo "  off      = today's runtime (default)"
    echo "  standard = + init process, pids limit, private IPC"
    echo "  strict   = + read-only root filesystem, read-only plugins/~/.local/bin"
    echo "             (skills are read-only in every profile)"
    echo "             and project .git hooks/config, bridge network (install plugins"
    echo "             and LSP binaries from the host)"
    echo ""
    local answer
    read -r -p "Hardening profile (off|standard|strict) [$HARDENING]: " answer || answer=""
    case "$answer" in
    "") ;;
    off | standard | strict) HARDENING="$answer" ;;
    *) config_warning "Invalid profile '$answer' (use off|standard|strict); keeping $HARDENING" ;;
    esac
    config_success "Hardening profile: $HARDENING"
}

# Interactive security policy prompt
# Selects which vendored policy pattern set the guard enforces.
prompt_security_policy() {
    echo ""
    config_info "Security Policy Mode"
    echo "Controls the vendored policy patterns enforced by the native hooks:"
    echo "  strict   = every pattern (may flag legitimate commands)"
    echo "  balanced = drop cloud/multi-tenant rules and common dev false positives (default)"
    echo "  none     = vendored patterns disabled (built-in backstops still apply)"
    echo "Remote flows (git SSH, remote MCP, registries) stay allowed in all modes."
    echo ""

    read -r -p "Security policy (strict|balanced|none) [$SECURITY_POLICY]: " security_policy || security_policy=""
    case "$security_policy" in
    strict | balanced | none)
        SECURITY_POLICY="$security_policy"
        ;;
    off)
        SECURITY_POLICY="none"
        ;;
    "")
        ;;
    *)
        config_warning "Invalid policy '$security_policy' (use strict|balanced|none); keeping $SECURITY_POLICY"
        ;;
    esac
    config_success "Security policy: $SECURITY_POLICY"
}

# Interactive container resource limit prompts (optional; empty = no limit).
prompt_memory() {
    echo ""
    config_info "Container Memory Limit (optional)"
    read -r -p "Memory limit, e.g. 4g ('none' = no limit, Enter keeps) [${MEMORY:-none}]: " memory || memory=""
    if [ -z "$memory" ]; then
        config_info "Memory limit: ${MEMORY:-none}"
    elif [ "$memory" = none ]; then
        MEMORY=""
        config_info "No memory limit"
    elif [[ "$memory" =~ ^[0-9]+[bBkKmMgG]$ ]]; then
        MEMORY="$memory"
        config_success "Memory limit: $MEMORY"
    else
        config_warning "Invalid memory limit '$memory' (e.g. 4g); keeping ${MEMORY:-(none)}"
    fi
}

prompt_cpus() {
    echo ""
    config_info "Container CPU Limit (optional)"
    read -r -p "CPU limit, e.g. 2 ('none' = no limit, Enter keeps) [${CPUS:-none}]: " cpus || cpus=""
    if [ -z "$cpus" ]; then
        config_info "CPU limit: ${CPUS:-none}"
    elif [ "$cpus" = none ]; then
        CPUS=""
        config_info "No CPU limit"
    elif [[ "$cpus" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        CPUS="$cpus"
        config_success "CPU limit: $CPUS"
    else
        config_warning "Invalid CPU limit '$cpus' (e.g. 2); keeping ${CPUS:-(none)}"
    fi
}

# Interactive default-model prompt. Empty means the Claude default
# (/model still works inside sessions).
prompt_model() {
    echo ""
    config_info "Default Model (optional)"
    echo "Empty = Claude default. Passed as --model on run/exec."
    echo ""
    read -r -p "Model [${CLAUDE_MODEL:-(default)}]: " model_name || model_name=""
    case "$model_name" in
    "")
        ;;
    *[!A-Za-z0-9._-]*)
        config_warning "Invalid model (letters, numbers, . - or _ only); keeping ${CLAUDE_MODEL:-(default)}"
        ;;
    *)
        CLAUDE_MODEL="$model_name"
        config_success "Model: $model_name"
        ;;
    esac
}

# Interactive session-retention prompt (cleanupPeriodDays).
prompt_cleanup_days() {
    echo ""
    config_info "Session-Data Retention (optional)"
    read -r -p "Retention in days ('default' = Claude default, Enter keeps) [${CLEANUP_DAYS:-default}]: " cleanup || cleanup=""
    if [ -z "$cleanup" ]; then
        config_info "Retention: ${CLEANUP_DAYS:-Claude default}"
    elif [ "$cleanup" = default ]; then
        CLEANUP_DAYS=""
        config_info "Claude default retention"
    elif [[ "$cleanup" =~ ^[0-9]+$ ]]; then
        CLEANUP_DAYS="$cleanup"
        config_success "Retention: $CLEANUP_DAYS days"
    else
        config_warning "Invalid retention '$cleanup' (use an integer); keeping ${CLEANUP_DAYS:-(default)}"
    fi
}

# Interactive LSP prompt. Binaries and .lsp.json live in the generated home.
prompt_lsp() {
    echo ""
    config_info "Native LSP Support (optional)"
    echo "Installs language-server binaries into the generated home"
    echo "(~/.local/bin) and writes .lsp.json. Servers: go,ts,python,rust."
    echo ""
    local lsp_hint="y/N"
    [ "$LSP_ENABLED" = true ] && lsp_hint="Y/n"
    read -r -p "Enable LSP support? ($lsp_hint): " lsp_answer || lsp_answer=""
    [ -z "$lsp_answer" ] && [ "$LSP_ENABLED" = true ] && lsp_answer=y
    if [[ "$lsp_answer" =~ ^[Yy]$ ]]; then
        LSP_ENABLED=true
        read -r -p "Servers (csv) [$LSP_SERVERS]: " servers || servers=""
        if [ -n "$servers" ]; then
            case "$servers" in
            *[!A-Za-z0-9_,-]* | *,*,*,*,*)
                config_warning "Invalid server list; keeping $LSP_SERVERS"
                ;;
            *) LSP_SERVERS="$servers" ;;
            esac
        fi
        config_success "LSP enabled: $LSP_SERVERS"
    else
        LSP_ENABLED=false
        config_info "LSP support disabled"
    fi
}

# Interactive formatters prompt.
prompt_formatters() {
    echo ""
    config_info "Native Formatters (optional)"
    echo "Installs formatter binaries into the generated home and enables"
    echo "the formatter plugins."
    echo ""
    local fmt_hint="y/N"
    [ "$FORMATTERS_ENABLED" = true ] && fmt_hint="Y/n"
    read -r -p "Enable formatters? ($fmt_hint): " fmt_answer || fmt_answer=""
    [ -z "$fmt_answer" ] && [ "$FORMATTERS_ENABLED" = true ] && fmt_answer=y
    if [[ "$fmt_answer" =~ ^[Yy]$ ]]; then
        FORMATTERS_ENABLED=true
        config_success "Formatters enabled"
    else
        FORMATTERS_ENABLED=false
        config_info "Formatters disabled"
    fi
}

# Interactive GnuPG forwarding detail prompts (socket choice, autostart, relay).
# Only asked when GnuPG forwarding itself is enabled; otherwise the safe
# defaults from a fresh config apply.
prompt_gpg_agent_options() {
    [ "$GPG_AGENT_SUPPORT" = true ] || return 0
    echo ""
    config_info "GnuPG Agent Details"

    if [ "$GPG_ALLOW_MAIN_SOCKET" = true ]; then
        read -r -p "Keep allowing fallback to the full-control agent socket? (y/N): " gpg_main || gpg_main=""
        if [[ "$gpg_main" =~ ^[Yy]$ ]]; then
            config_success "Full-control socket fallback remains allowed"
        else
            GPG_ALLOW_MAIN_SOCKET=false
            config_info "Full-control socket fallback disabled"
        fi
    else
        echo "The restricted S.gpg-agent.extra socket is preferred; the full-control"
        echo "main socket is never used unless you opt in (NOT recommended)."
        echo ""
        read -r -p "Allow fallback to the full-control agent socket? (y/N): " gpg_main || gpg_main=""
        if [[ "$gpg_main" =~ ^[Yy]$ ]]; then
            GPG_ALLOW_MAIN_SOCKET=true
            config_warning "Full-control agent socket fallback enabled"
        else
            GPG_ALLOW_MAIN_SOCKET=false
            config_info "Full-control socket fallback disabled"
        fi
    fi

    if [ "$GPG_AUTOSTART_AGENT" = true ]; then
        read -r -p "Keep starting the host gpg-agent automatically when its socket is missing? (Y/n): " gpg_auto || gpg_auto=""
        if [[ "$gpg_auto" =~ ^[Nn]$ ]]; then
            GPG_AUTOSTART_AGENT=false
            config_info "GPG agent autostart disabled"
        else
            config_success "GPG agent autostart remains enabled"
        fi
    else
        read -r -p "Start the host gpg-agent automatically when its socket is missing? (y/N): " gpg_auto || gpg_auto=""
        if [[ "$gpg_auto" =~ ^[Yy]$ ]]; then
            GPG_AUTOSTART_AGENT=true
            config_success "GPG agent autostart enabled"
        else
            config_info "GPG agent autostart disabled"
        fi
    fi

    if [ "$GPG_RELAY" = true ]; then
        echo "The relay forwards the agent socket through a normal filesystem when"
        echo "socketdir is on tmpfs (requires socat on the host)."
        read -r -p "Keep the GPG socket relay enabled? (Y/n): " gpg_relay || gpg_relay=""
        if [[ "$gpg_relay" =~ ^[Nn]$ ]]; then
            GPG_RELAY=false
            config_info "GPG socket relay disabled"
        else
            config_success "GPG socket relay remains enabled"
        fi
    else
        read -r -p "Relay the agent socket through a normal filesystem when needed? (y/N): " gpg_relay || gpg_relay=""
        if [[ "$gpg_relay" =~ ^[Yy]$ ]]; then
            GPG_RELAY=true
            config_success "GPG socket relay enabled"
        else
            config_info "GPG socket relay disabled"
        fi
    fi
}

# ============================================
# SETUP ORCHESTRATION (used by `claude-dockerized install`)
# ============================================

# Main entry point for interactive configuration setup
# Handles: mode selection, prompts, config persistence
interactive_config_setup() {
    prompt_config_mode

    case "$CONFIG_MODE" in
    skip)
        echo ""
        echo "Skipping custom configuration setup."
        echo "You can run 'claude-dockerized install' again later to configure custom mounts and environment variables."
        ;;
    append | overwrite)
        [ "$CONFIG_MODE" = "append" ] && load_config
        migrate_legacy_env_vars
        prompt_ssh_agent_support
        prompt_gpg_agent_support
        prompt_gpg_agent_options
        prompt_docker_socket
        prompt_network
        prompt_security_policy
        prompt_hardening
        prompt_memory
        prompt_cpus
        prompt_model
        prompt_cleanup_days
        prompt_lsp
        prompt_formatters
        prompt_custom_mounts
        prompt_env_vars
        save_config
        print_config
        ;;
    new)
        migrate_legacy_env_vars
        read -r -p "Would you like to configure custom mounts and environment variables now? (y/N): " setup_custom || setup_custom=""
        if [[ "$setup_custom" =~ ^[Yy]$ ]]; then
            prompt_ssh_agent_support
            prompt_gpg_agent_support
            prompt_gpg_agent_options
            prompt_docker_socket
            prompt_network
            prompt_security_policy
            prompt_hardening
            prompt_memory
            prompt_cpus
            prompt_model
            prompt_cleanup_days
            prompt_lsp
            prompt_formatters
            prompt_custom_mounts
            prompt_env_vars
            if [ ${#CUSTOM_MOUNTS[@]} -gt 0 ] || [ "$SSH_AGENT_SUPPORT" = true ] || [ "$GPG_AGENT_SUPPORT" = true ] || [ "$DOCKER_SOCKET" = true ] || [ "$NETWORK" != "host" ] || [ -n "$MEMORY" ] || [ -n "$CPUS" ] || [ "$SECURITY_POLICY" != "balanced" ] || [ "$HARDENING" != "off" ] || [ -n "$ENV_FILE" ] || [ -n "$CLAUDE_MODEL" ] || [ -n "$CLEANUP_DAYS" ] || [ "$LSP_ENABLED" = true ] || [ "$FORMATTERS_ENABLED" = true ]; then
                save_config
                print_config
            else
                config_info "No custom configuration added."
            fi
        else
            init_config_file
            config_info "You can run 'claude-dockerized install' again later to configure custom mounts and environment variables."
        fi
        ;;
    esac
}