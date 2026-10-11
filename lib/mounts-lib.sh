#!/bin/bash
# mounts-lib.sh - docker run arguments: mounts and their validation, env, hardening, project paths
# Sourced by lib/config-lib.sh (which keeps the constants, config parsing and
# saving). Not executable directly; no `set -e`: callers own error handling.

# Compute the container mount path for a project directory.
# Strips $HOME prefix so the path is portable across machines/users.
# Example: /home/user/projects/acme/frontend -> /projects/acme/frontend
#          /opt/work/myproject                -> /opt/work/myproject (unchanged)
# Usage: container_path=$(compute_container_path "/home/user/projects/myapp")
compute_container_path() {
    local host_path="$1"

    if [[ "$host_path" == "$HOME"/* ]]; then
        echo "${host_path#"$HOME"}"
    else
        echo "$host_path"
    fi
}

# Lexically resolve ".", ".." and duplicate slashes of an absolute container
# path. No filesystem access: the path lives in the image, not on the host.
# Usage: normalize_container_path <abs path>
normalize_container_path() {
    local out="" part
    local -a parts=()
    IFS=/ read -ra parts <<<"$1"
    for part in "${parts[@]}"; do
        case "$part" in
        "" | .) ;;
        ..) out="${out%/*}" ;;
        *) out="$out/$part" ;;
        esac
    done
    printf '%s' "${out:-/}"
}

# Container paths a host directory must never be mounted on: the image's system
# directories and the managed security layer. A project mounted there would
# replace the binaries the guard hooks run with (T-04, T-07).
# Usage: reason=$(container_path_reason <abs container path>) && refuse
container_path_reason() {
    local t
    t=$(normalize_container_path "$1")
    case "$t" in
    / | /usr | /usr/local | /usr/local/lib | /bin | /sbin | /lib | /lib64 | /etc | /home | /home/coder)
        echo "it is a system directory of the image"
        ;;
    /bin/* | /sbin/* | /lib/* | /lib64/* | /usr/bin | /usr/bin/* | /usr/sbin | /usr/sbin/* | \
        /usr/lib | /usr/lib/* | /usr/lib64 | /usr/lib64/* | /usr/local/bin | /usr/local/bin/* | \
        /usr/local/lib/claude-dockerized | /usr/local/lib/claude-dockerized/* | \
        /etc/claude-code | /etc/claude-code/* | /home/coder/.claude | /home/coder/.claude/* | \
        /proc | /proc/* | /sys | /sys/* | /dev | /dev/*)
        echo "it would shadow the image or the managed security layer"
        ;;
    *) return 1 ;;
    esac
}

# Reject project directories that would expose the host home or the whole
# filesystem to the sandbox: "/", $HOME, and any ancestor of $HOME (e.g. /home)
# are refused. Only a project subdirectory is allowed.
# Usage: validate_project_dir "/abs/path" || exit 1
validate_project_dir() {
    local project_dir="$1"

    if [ -z "$project_dir" ]; then
        config_error "A project directory is required."
        return 1
    fi

    if [ "$project_dir" = "/" ]; then
        config_error "Refusing to run with '/' as the project."
        config_info "Pass a project subdirectory instead (e.g. ~/projects/my-app)."
        return 1
    fi

    if [ "$project_dir" = "$HOME" ]; then
        config_error "Refusing to run with the home directory ($HOME) as the project."
        config_info "Pass a project subdirectory instead."
        return 1
    fi

    # Any ancestor of $HOME (e.g. /home) would expose the home through the mount.
    case "$HOME" in
    "$project_dir"/*)
        config_error "Refusing to run with '$project_dir' as the project: it contains your home directory."
        config_info "Pass a project subdirectory instead (e.g. ~/projects/my-app)."
        return 1
        ;;
    esac

    # Secrets and the wrapper's own layer are never a project (T-07).
    local reason
    if reason=$(sensitive_host_path_reason "$(canonical_host_path "$project_dir")"); then
        config_error "Refusing to run with '$project_dir' as the project: $reason."
        config_info "Pass a project subdirectory instead (e.g. ~/projects/my-app)."
        return 1
    fi

    # The project is mounted at its path minus $HOME: ~/usr or ~/etc would land
    # on the image's own /usr or /etc.
    local container_path
    container_path=$(compute_container_path "$project_dir")
    if reason=$(container_path_reason "$container_path"); then
        config_error "Refusing to run with '$project_dir' as the project: it would be mounted at $container_path and $reason."
        config_info "Rename the directory or move it outside \$HOME-relative system paths (usr, bin, etc, lib, ...)."
        return 1
    fi

    return 0
}

# Detect if a directory is a git worktree and return the main repo's .git directory path
# A worktree has a .git FILE (not directory) containing "gitdir: <path>"
# Returns (via stdout): "<git_common_dir>" if worktree, empty string otherwise
# Usage: main_git_dir=$(detect_git_worktree "/path/to/worktree")
detect_git_worktree() {
    local project_dir="$1"

    # Quick check: if .git is a directory (normal repo) or doesn't exist, not a worktree
    if [ ! -f "$project_dir/.git" ]; then
        return 0
    fi

    # Use git to reliably resolve paths (handles relative/absolute gitdir pointers)
    if ! command -v git >/dev/null 2>&1; then
        config_warning "Git worktree detected but 'git' is not installed on the host — git info will be unavailable in container"
        return 0
    fi

    # git rev-parse --git-common-dir gives us the shared .git directory
    local git_common_dir
    git_common_dir=$(git -C "$project_dir" rev-parse --git-common-dir 2>/dev/null) || return 0

    # Resolve to absolute path
    if [[ "$git_common_dir" != /* ]]; then
        git_common_dir=$(cd "$project_dir" && cd "$git_common_dir" && pwd)
    else
        git_common_dir=$(cd "$git_common_dir" && pwd)
    fi

    # Sanity check: the common dir should be a real .git directory
    if [ ! -d "$git_common_dir/objects" ] || [ ! -d "$git_common_dir/refs" ]; then
        return 0
    fi

    echo "$git_common_dir"
}

# Build Docker volume/bind args needed for git worktree support
# When the project is a git worktree, the .git file points to the main repo's
# .git directory which lives outside the project dir. We mount the main .git
# directory (read-only) at its real host path so the gitdir pointer resolves
# correctly inside the container.
#
# Read-only is intentional: it preserves the sandbox boundary (container only
# has write access to the mounted project directory). Read operations like
# git log, status, diff, and branch work. Write operations (commit, stash,
# fetch) will fail — run those on the host.
#
# Populates GIT_WORKTREE_ARGS array
# Usage: build_git_worktree_args "/path/to/project"
build_git_worktree_args() {
    local project_dir="$1"

    GIT_WORKTREE_ARGS=()

    local git_common_dir
    git_common_dir=$(detect_git_worktree "$project_dir")

    if [ -z "$git_common_dir" ]; then
        return 0
    fi

    config_info "Git worktree detected — mounting main .git directory (read-only) for git support"
    config_info "Main git directory: $git_common_dir"

    # Mount the main repo's .git directory at its real host path (read-only)
    GIT_WORKTREE_ARGS+=(-v "$git_common_dir:$git_common_dir:ro")
}

# Build common Docker run arguments shared by run_claude and run_auth
# Append the flags of the opt-in hardening profile to DOCKER_COMMON_ARGS.
#   standard: an init process (reaps zombies), a pids limit against fork
#             bombs (T-23) and a private IPC namespace.
#   strict:   standard + read-only root filesystem with per-user tmpfs for
#             the paths tools write to (T-22), and bridge networking unless
#             setting.network was set explicitly (T-06). The read-only
#             persistent mounts of strict live in build_standard_volume_args.
# Usage: append_hardening_args
append_hardening_args() {
    case "$HARDENING" in
    standard | strict) ;;
    *) return 0 ;;
    esac
    DOCKER_COMMON_ARGS+=(--init --pids-limit 4096 --ipc private)
    [ "$HARDENING" = strict ] || return 0

    local owner d
    owner="uid=$(id -u),gid=$(id -g),mode=0700"
    DOCKER_COMMON_ARGS+=(--read-only --tmpfs "/tmp:rw,nosuid,nodev,mode=1777")
    for d in /home/coder/.claude /home/coder/.cache /home/coder/.config /home/coder/.npm \
        /home/coder/.local/share /home/coder/.local/state; do
        DOCKER_COMMON_ARGS+=(--tmpfs "$d:rw,nosuid,nodev,$owner")
    done
    if [ "$NETWORK_EXPLICIT" != true ] && [ "$NETWORK" = host ]; then
        NETWORK=bridge
        local i
        for i in "${!DOCKER_COMMON_ARGS[@]}"; do
            if [ "${DOCKER_COMMON_ARGS[$i]}" = --network ]; then
                DOCKER_COMMON_ARGS[i + 1]=bridge
            fi
        done
        DOCKER_COMMON_ARGS+=(--add-host "host.docker.internal:host-gateway")
    fi
}

# Populates DOCKER_COMMON_ARGS array
# The container runs as the host user directly (no root): --user starts the
# process with the host UID/GID, so entrypoint.sh needs no privilege dropping or
# UID/GID remapping. --group-add coder keeps the group-writable (g+rwX) home
# tree accessible to any host UID; the name resolves against the container's
# /etc/group (gid 1000 here), so the host does not need a "coder" group.
# no-new-privileges neutralizes setuid binaries and cap-drop removes Linux
# capabilities the non-root process never needs.
# Security note: unlike the previous generation, no permission rules travel
# inline — Claude Code has no inline-config equivalent. The managed policy
# (permissions, hooks, DISABLE_AUTOUPDATER) is delivered read-only as
# /etc/claude-code/managed-settings.json (see build_standard_volume_args),
# and the hooks enforce the policy modes.
# Usage: build_common_docker_args
build_common_docker_args() {
    # shellcheck disable=SC2034  # DOCKER_COMMON_ARGS is used by callers that source this file
    # Block runs whose managed config carries inline secrets.
    validate_claude_config || exit 1
    # Allowlist the network mode (config values are user-edited).
    case "${NETWORK:-host}" in
    host | bridge) ;;
    *)
        config_warning "Invalid network '$NETWORK' (use host|bridge); falling back to host"
        NETWORK="host"
        ;;
    esac
    DOCKER_COMMON_ARGS=(
        --rm
        --network "$NETWORK"
        --user "$(id -u):$(id -g)"
        --group-add coder
        --security-opt no-new-privileges:true
        --cap-drop=ALL
        -e "TERM=${TERM:-xterm-256color}"
    )

    # Optional resource limits (setting.memory / setting.cpus).
    [ -n "$MEMORY" ] && DOCKER_COMMON_ARGS+=(--memory "$MEMORY")
    [ -n "$CPUS" ] && DOCKER_COMMON_ARGS+=(--cpus "$CPUS")

    # Opt-in runtime hardening profile (setting.hardening; default off keeps
    # the historic runtime unchanged). See docs/security/BLUE.md.
    append_hardening_args

    # Pass terminal identification variables so applications inside the container
    # can detect the host terminal and use its capabilities correctly.
    # Required for kitty OSC 99 terminal-mediated desktop notifications, true-color
    # rendering, and other terminal-specific features. All are conditional so they
    # have no effect on non-kitty terminals.
    local term_var
    for term_var in TERM_PROGRAM TERM_PROGRAM_VERSION KITTY_WINDOW_ID COLORTERM; do
        if [ -n "${!term_var}" ]; then
            DOCKER_COMMON_ARGS+=(-e "$term_var=${!term_var}")
        fi
    done

    # Security policy mode consumed by the mounted hooks
    # (strict | balanced | none). Defaults to balanced when unset.
    DOCKER_COMMON_ARGS+=(-e "CLAUDE_DOCKERIZED_POLICY=$SECURITY_POLICY")
    DOCKER_COMMON_ARGS+=(-e "CLAUDE_DOCKERIZED_HARDENING=$HARDENING")

    # Claude Code self-update is disabled via env.DISABLE_AUTOUPDATER=1 in the
    # managed policy (see write_managed_settings); the wrapper `update`
    # command (image rebuild) is the only supported upgrade path.
    # The default model travels as a CLI flag (see bin/claude-dockerized), not
    # as an env var, so user sessions can still switch with /model.
    if [ ! -f "$CCODE_HOME/etc/claude-code/managed-settings.json" ]; then
        config_warning "Managed policy not found (run 'claude-dockerized config sync')"
    fi
}

# Build standard volume mount arguments for Claude Code directories. The
# policy is a read-only /etc/claude-code (managed settings, highest
# precedence); ~/.claude comes from the generated home read-write (user
# settings, credentials, plugins, memory) with the guard hooks and CLAUDE.md
# overlaid read-only. The host ~/.claude and $CONFIG_DIR are never mounted.
# Populates VOLUME_ARGS and CONTAINER_WORKDIR
# The project is mounted at a path derived from the host path (with $HOME stripped)
# so that sessions stay portable across machines/users.
build_standard_volume_args() {
    local project_dir="$1"
    local include_docker_socket="${2:-false}"

    VOLUME_ARGS=()

    # Compute container-side mount path: strip $HOME prefix for portability
    # e.g. /home/user/projects/acme/frontend -> /projects/acme/frontend
    CONTAINER_WORKDIR=$(compute_container_path "$project_dir")

    # Project directory (read-write) — mounted at the computed path
    # Skipped when no project is given (e.g. auth) or when it resolves to $HOME itself
    if [ -n "$project_dir" ] && [ -n "$CONTAINER_WORKDIR" ]; then
        VOLUME_ARGS+=(-v "$project_dir:$CONTAINER_WORKDIR")
        build_git_worktree_args "$project_dir"
        # strict: the git files the HOST executes are read-only overlays on
        # the read-write project (T-01); commit/branch/fetch keep working.
        if [ "$HARDENING" = strict ] && [ -d "$project_dir/.git" ]; then
            [ -f "$project_dir/.git/config" ] &&
                VOLUME_ARGS+=(-v "$project_dir/.git/config:$CONTAINER_WORKDIR/.git/config:ro")
            [ -d "$project_dir/.git/hooks" ] &&
                VOLUME_ARGS+=(-v "$project_dir/.git/hooks:$CONTAINER_WORKDIR/.git/hooks:ro")
        fi
    fi

    local chome="$CCODE_HOME"
    # Mount sources only: the full security layer + LSP install already ran in
    # check_config/ensure_claude_dirs earlier in this process. Re-running it
    # here spawned a second throwaway container per `run`. Only create the
    # directories/files the -v sources below need.
    ensure_claude_mount_sources

    # Managed policy (read-only directory, so no drop-in can be added;
    # highest precedence: hooks, deny rules, env).
    if [ -f "$chome/etc/claude-code/managed-settings.json" ]; then
        VOLUME_ARGS+=(-v "$chome/etc/claude-code:/etc/claude-code:ro")
    else
        config_warning "Managed policy not found at $chome/etc/claude-code/managed-settings.json"
    fi

    # Claude state (read-write directory: a single-file bind would make every
    # settings save fail with EBUSY). Credentials stay 0600.
    chmod 600 "$chome/.claude/.credentials.json" 2>/dev/null || true
    VOLUME_ARGS+=(-v "$chome/.claude:/home/coder/.claude:rw")

    # Security hooks (read-only overlay).
    if [ -d "$chome/.claude/hooks-guard" ]; then
        VOLUME_ARGS+=(-v "$chome/.claude/hooks-guard:/home/coder/.claude/hooks-guard:ro")
    else
        config_warning "Security hooks not found at $chome/.claude/hooks-guard"
    fi

    # Managed session rules (read-only overlay).
    if [ -f "$chome/.claude/CLAUDE.md" ]; then
        VOLUME_ARGS+=(-v "$chome/.claude/CLAUDE.md:/home/coder/.claude/CLAUDE.md:ro")
    fi

    # Credentials (read-write, 0600) — auth persists across restarts/rebuilds.
    if [ -f "$chome/.claude/.credentials.json" ]; then
        chmod 600 "$chome/.claude/.credentials.json" 2>/dev/null || true
        VOLUME_ARGS+=(-v "$chome/.claude/.credentials.json:/home/coder/.claude/.credentials.json:rw")
    fi

    # Paths that later sessions (or the host) execute: read-write by default,
    # read-only under setting.hardening=strict (T-05; install plugins and LSP
    # binaries from the host then).
    local persist="rw"
    [ "$HARDENING" = strict ] && persist="ro"

    # User plugins / agents / commands.
    local d
    for d in plugins agents commands; do
        if [ -d "$chome/.claude/$d" ]; then
            VOLUME_ARGS+=(-v "$chome/.claude/$d:/home/coder/.claude/$d:$persist")
        fi
    done

    # User skills: read-only in every profile (T-05), so a session cannot plant
    # or rewrite instructions that later sessions load; manage them from the
    # host. Created first: without the overlay the read-write ~/.claude parent
    # would let the session create skills/ itself.
    mkdir -p "$chome/.claude/skills" 2>/dev/null || true
    if [ -d "$chome/.claude/skills" ]; then
        VOLUME_ARGS+=(-v "$chome/.claude/skills:/home/coder/.claude/skills:ro")
    fi

    # LSP config (regenerated when setting.lsp=true).
    if [ -f "$chome/.claude/.lsp.json" ]; then
        VOLUME_ARGS+=(-v "$chome/.claude/.lsp.json:/home/coder/.claude/.lsp.json:$persist")
    fi

    # MCP user-scope state (read-write).
    if [ -f "$chome/.claude.json" ]; then
        VOLUME_ARGS+=(-v "$chome/.claude.json:/home/coder/.claude.json:rw")
    else
        printf '{}\n' >"$chome/.claude.json" 2>/dev/null || true
        [ -f "$chome/.claude.json" ] && VOLUME_ARGS+=(-v "$chome/.claude.json:/home/coder/.claude.json:rw")
    fi

    # Generated-home binaries: LSP servers and formatters installed by
    # ensure_lsp_formatters (read-write, on PATH in the container).
    if [ -d "$chome/.local/bin" ]; then
        VOLUME_ARGS+=(-v "$chome/.local/bin:/home/coder/.local/bin:$persist")
    fi

    # Sessions / history / caches (read-write).
    for d in "$chome/.local/share/claude:/home/coder/.local/share/claude" "$chome/.local/state/claude:/home/coder/.local/state/claude" "$chome/.cache/claude:/home/coder/.cache/claude"; do
        local src="${d%%:*}"
        if [ -d "$src" ]; then
            VOLUME_ARGS+=(-v "$d:rw")
        fi
    done

    # MCP OAuth store for `mcp-remote`-based servers (generated home, always
    # read-write: tokens, not code, so strict keeps it writable; without it
    # the tokens die with the container, or cannot be written on a read-only
    # rootfs). Native Claude MCP OAuth lives in .credentials.json instead.
    if [ -d "$chome/.mcp-auth" ]; then
        VOLUME_ARGS+=(-v "$chome/.mcp-auth:/home/coder/.mcp-auth:rw")
    fi

    # Agent-compatible skills directory (optional, read-only).
    if [ -d "$HOME/.agents" ]; then
        VOLUME_ARGS+=(-v "$HOME/.agents:/home/coder/.agents:ro")
    fi

    # Docker socket (optional, for Docker-in-Docker operations). The container
    # runs as a non-root numeric UID, so access is granted with a supplementary
    # --group-add (the socket's GID) instead of a runtime `usermod` that required
    # root. It is appended to VOLUME_ARGS because it is part of what this
    # function contributes to the `docker run` command.
    # WARNING: root-equivalent on the host — enable only for Docker-in-Docker /
    # Testcontainers (setting.docker_socket=true).
    if [ "$include_docker_socket" = true ] && [ -S /var/run/docker.sock ]; then
        config_warning "Docker socket mounted: root-equivalent on the host (disable with setting.docker_socket=false when not needed)"
        VOLUME_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
        VOLUME_ARGS+=(--group-add "$(stat -c '%g' /var/run/docker.sock 2>/dev/null || stat -f '%g' /var/run/docker.sock)")
    fi
}

# Add a bind mount for a socket/file. Docker's `--mount` spec separates fields
# with commas, so fall back to `-v` when a path contains one.
# Usage: mount_bind <source> <target>
mount_bind() {
    local src="$1" dst="$2"
    case "$src$dst" in
        *,*) DOCKER_MOUNT_ARGS+=(-v "$src:$dst") ;;
        *) DOCKER_MOUNT_ARGS+=(--mount "type=bind,source=$src,target=$dst") ;;
    esac
}

# Canonical absolute form of a host path: leading ~ expanded, symlinks and
# `.`/`..`/`//` resolved (readlink -m tolerates missing components; falls back
# to the literal path where unavailable, e.g. macOS without coreutils).
# Usage: canonical_host_path <path>
canonical_host_path() {
    local p="$1" c
    if [[ "$p" == "~"* ]]; then
        p="$HOME${p#"~"}"
    fi
    if c=$(readlink -m -- "$p" 2>/dev/null) && [ -n "$c" ]; then
        printf '%s' "$c"
    else
        printf '%s' "$p"
    fi
}

# Is <path> equal to <dir> or inside it? Usage: path_within <path> <dir>
path_within() {
    [ -n "$2" ] && { [ "$1" = "$2" ] || [[ "$1" == "$2/"* ]]; }
}

# Explain why a canonical host path must never reach the container, or return
# 1 when it is acceptable. Shared by custom mounts and the project dir (T-07).
# Usage: reason=$(sensitive_host_path_reason <canonical>) && refuse
sensitive_host_path_reason() {
    local c="$1" home_c config_c ccode_c
    home_c=$(canonical_host_path "$HOME")
    config_c=$(canonical_host_path "$CONFIG_DIR")
    ccode_c=$(canonical_host_path "$CCODE_HOME")
    if [ "$c" = / ] || [ "$c" = "$home_c" ] || [[ "$home_c" == "$c/"* ]]; then
        echo "it is the filesystem root, your home or one of its ancestors"
    elif path_within "$c" "$home_c/.ssh"; then
        echo "it would expose SSH private keys (use setting.ssh_agent_support=true)"
    elif path_within "$c" "$home_c/.gnupg"; then
        echo "it would expose GnuPG private keys (use setting.gpg_agent_support=true)"
    elif path_within "$c" "$config_c" || path_within "$c" "$ccode_c"; then
        echo "it holds the wrapper's own config, security layer and secrets file"
    elif [ "$c" = "$home_c/.config" ]; then
        echo "it holds every application's config and credentials (mount a single subdirectory instead)"
    elif path_within "$c" /root || path_within "$c" /proc || path_within "$c" /sys || path_within "$c" /dev ||
        path_within "$c" /run || path_within "$c" /var/run; then
        echo "it is a system runtime directory (sockets, devices, other accounts' state)"
    elif [ "$c" = /etc ] || path_within "$c" /etc/shadow || path_within "$c" /etc/gshadow ||
        path_within "$c" /etc/sudoers || path_within "$c" /etc/sudoers.d || path_within "$c" /etc/ssh; then
        echo "it holds system credentials and privilege configuration"
    else
        local store
        for store in .aws .kube .docker .claude .mcp-auth .netrc .npmrc .git-credentials .pgpass .config/gcloud .config/gh; do
            if path_within "$c" "$home_c/$store"; then
                echo "it holds credentials (~/$store)"
                return 0
            fi
        done
        return 1
    fi
    return 0
}

# Validate one custom mount; prints the canonical "host:container:mode" docker
# spec, or explains the refusal on stderr and returns 1 (T-07).
# Usage: spec=$(validate_mount_spec <host> <container> [mode]) || exit 1
validate_mount_spec() {
    local host="$1" container="$2" mode="${3:-ro}" c reason
    if [ -z "$host" ] || [ -z "$container" ] || [[ "$container" != /* ]]; then
        config_error "Invalid mount '$host:$container': container path must be absolute" >&2
        return 1
    fi
    case "$mode" in
    ro | rw) ;;
    *)
        config_error "Invalid mount mode '$mode' for $host (use ro or rw)" >&2
        return 1
        ;;
    esac
    c=$(canonical_host_path "$host")
    if reason=$(sensitive_host_path_reason "$c"); then
        config_error "Refusing to mount $host: $reason." >&2
        return 1
    fi
    # Container runtime sockets are root-equivalent: only setting.docker_socket
    # may add the Docker one.
    case "$c" in
    */docker.sock | */podman.sock | */containerd.sock | */crio.sock | */buildkitd.sock)
        config_error "Refusing to mount $host: a container runtime socket is root-equivalent (Docker only via setting.docker_socket=true)." >&2
        return 1
        ;;
    esac
    # Never shadow the managed read-only mounts or the image's system dirs.
    local t
    t=$(normalize_container_path "$container")
    case "$t" in
    "" | /home/coder | /home/coder/.claude | /home/coder/.claude/* | /etc/claude-code | /etc/claude-code/* | \
        /usr | /usr/* | /bin | /sbin | /lib | /lib64 | /etc | /proc | /proc/* | /sys | /sys/* | /dev | /dev/*)
        config_error "Refusing to mount over $container: it would shadow the image or the managed security layer." >&2
        return 1
        ;;
    esac
    if container_path_reason "$t" >/dev/null; then
        config_error "Refusing to mount over $container: it would shadow the image or the managed security layer." >&2
        return 1
    fi
    printf '%s:%s:%s' "$c" "$t" "$mode"
}

# Build docker mount arguments from the CUSTOM_MOUNTS array: populates
# DOCKER_MOUNT_ARGS (each entry validated by validate_mount_spec).
build_mount_args() {
    DOCKER_MOUNT_ARGS=()
    GPG_SOCKET=""
    # Stop a relay left over from a previous call in the same process.
    if [ -n "$GPG_RELAY_SOCKET" ]; then
        stop_gpg_relay "$GPG_RELAY_SOCKET"
    fi
    GPG_RELAY_SOCKET=""

    # Host-side preflight for the forwarded agents (no-op when disabled). It
    # launches the GPG agent if needed and reports why a socket is unusable.
    ensure_ssh_agent_ready
    ensure_gpg_agent_ready
    cleanup_stale_relays

    local mount
    for mount in "${CUSTOM_MOUNTS[@]}"; do
        # Expand a leading ~ to the home directory (only at the start of the
        # host path; ':' inside paths is the field separator and unsupported)
        if [[ "$mount" == "~"* ]]; then
            mount="$HOME${mount#"~"}"
        fi

        # A mount entry must be host_path:container_path[:mode] (':' is the
        # field separator; paths containing ':' are unsupported).
        if [[ "$mount" != *:* ]]; then
            config_error "Invalid mount '$mount': expected host_path:container_path"
            exit 1
        fi
        local host_path="${mount%%:*}"
        local rest="${mount#*:}"
        local container_path="${rest%%:*}"
        local mode=""
        [[ "$rest" == *:* ]] && mode="${rest#*:}"

        local spec
        spec=$(validate_mount_spec "$host_path" "$container_path" "$mode") || exit 1
        DOCKER_MOUNT_ARGS+=(-v "$spec")
    done

    # Handle SSH agent forwarding if enabled. ensure_ssh_agent_ready has already
    # reported why a socket is unusable, so only a valid socket is mounted here.
    if [ "$SSH_AGENT_SUPPORT" = true ]; then
        if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
            # --mount (not -v) so a stale/missing source fails loudly instead
            # of Docker creating a directory at the host socket path, which
            # would break the real ssh-agent.
            mount_bind "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK"
        fi

        # Mount only the non-secret SSH files (read-only) so host-key
        # verification and host aliases keep working. Private keys (id_*,
        # *.pem, *.key) are never mounted; keys are used via the forwarded agent.
        local ssh_file
        for ssh_file in config known_hosts known_hosts2; do
            if [ -f "$HOME/.ssh/$ssh_file" ]; then
                DOCKER_MOUNT_ARGS+=(-v "$HOME/.ssh/$ssh_file:/home/coder/.ssh/$ssh_file:ro")
            fi
        done
    fi

    # Handle GnuPG agent forwarding if enabled: mount the mirrored public
    # keyring (rw so GPG can write lock files) and the host agent socket. The
    # private keys stay on the host; only public material is shared. The socket
    # is bind-mounted with --mount (a stale source fails loudly instead of Docker
    # creating a directory) at the container's GNUPGHOME path (and at its own XDG
    # path when applicable) so GPG discovers it without any host symlink.
    if [ "$GPG_AGENT_SUPPORT" = true ]; then
        GPG_SOCKET=""
        ensure_gpg_mirror
        if [ -d "$CCODE_HOME/.gnupg" ]; then
            mount_bind "$CCODE_HOME/.gnupg" "/home/coder/.gnupg"
        else
            config_warning "GnuPG agent support enabled but $CCODE_HOME/.gnupg could not be prepared"
        fi

        local main_socket extra_socket gpg_socket
        main_socket=$(resolve_gpg_agent_socket)
        extra_socket=$(resolve_gpg_agent_extra_socket)

        # Prefer the restricted "extra" socket (sign/decrypt only) so the
        # container cannot reconfigure the host agent. The full-control main
        # socket is only used when explicitly opted in.
        if [ -n "$extra_socket" ] && [ -S "$extra_socket" ]; then
            gpg_socket="$extra_socket"
        elif [ -n "$main_socket" ] && [ -S "$main_socket" ] && [ "$GPG_ALLOW_MAIN_SOCKET" = true ]; then
            gpg_socket="$main_socket"
            config_warning "Using the full-control GnuPG agent socket (setting.gpg_allow_main_socket=true)"
        else
            gpg_socket=""
        fi

        if [ -n "$gpg_socket" ] && [ -S "$gpg_socket" ]; then
            GPG_SOCKET="$gpg_socket"
            local mount_socket="$gpg_socket"
            # Docker cannot bind a socket from a per-user tmpfs (/run/user/...):
            # it creates an empty directory instead. Relay it through a socket on
            # a normal filesystem and mount that.
            if { [[ "$gpg_socket" == /run/* ]] || [ "${GPG_RELAY_FORCE:-false}" = true ]; } && [ "$GPG_RELAY" = true ]; then
                local relay
                if relay=$(start_gpg_relay "$gpg_socket"); then
                    GPG_RELAY_SOCKET="$relay"
                    mount_socket="$relay"
                else
                    config_warning "Could not start the GnuPG relay; is 'socat' installed on the host?"
                fi
            fi
            if [[ "$mount_socket" == /run/* ]]; then
                config_warning "GnuPG agent socket is on tmpfs and no relay is available; Docker may not be able to bind it."
            fi
            # Mount the socket at a dedicated path OUTSIDE the mirror. A socket
            # mounted *inside* another bind mount (the mirror) can be shadowed by
            # Docker, which left the agent socket invisible to gpg.
            mount_bind "$mount_socket" "/home/coder/.gnupg-agent/S.gpg-agent"
            # Expose it to gpg through GNUPGHOME with a symlink (gpg follows it).
            # ensure_gpg_mirror clears any previous link before each run.
            if [ -d "$CCODE_HOME/.gnupg" ]; then
                ln -sfn "/home/coder/.gnupg-agent/S.gpg-agent" "$CCODE_HOME/.gnupg/S.gpg-agent" 2>/dev/null ||
                    config_warning "Could not create the GnuPG agent socket symlink in $CCODE_HOME/.gnupg"
            fi
        else
            config_warning "GnuPG agent support enabled but no usable agent socket (extra socket missing and main fallback disabled)"
        fi
    fi
}

# Build docker environment variable arguments for automatic (non-secret)
# forwarding: agent sockets, terminal detection and doctor state flags.
# User secrets travel exclusively via setting.env_file (--env-file); the old
# env.* host passthrough was removed.
# Populates DOCKER_ENV_ARGS array with -e arguments
build_env_args() {
    DOCKER_ENV_ARGS=()

    # Handle SSH agent forwarding if enabled
    if [ "$SSH_AGENT_SUPPORT" = true ]; then
        if [ -n "$SSH_AUTH_SOCK" ]; then
            DOCKER_ENV_ARGS+=(-e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
        fi
    fi

    # Handle GnuPG agent forwarding if enabled. GNUPGHOME points at the mirrored
    # public keyring; XDG_RUNTIME_DIR is forwarded only when the agent socket
    # lives under it, so gpgconf inside the container resolves the mounted path.
    if [ "$GPG_AGENT_SUPPORT" = true ]; then
        DOCKER_ENV_ARGS+=(-e "GNUPGHOME=/home/coder/.gnupg")

        if [ -n "${GPG_SOCKET:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [[ "$GPG_SOCKET" == "$XDG_RUNTIME_DIR"/* ]]; then
            DOCKER_ENV_ARGS+=(-e "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR")
        fi
    fi

    # Forwarding state for `doctor` (non-secret): lets the in-container
    # diagnostics skip checks for forwardings the user disabled on purpose
    # instead of reporting them as failures. Model/LSP/formatters/env-file
    # state is included so `doctor` can report the effective setup (key names
    # only, never values).
    DOCKER_ENV_ARGS+=(-e "CLAUDE_DOCKERIZED_SSH_AGENT=$SSH_AGENT_SUPPORT")
    DOCKER_ENV_ARGS+=(-e "CLAUDE_DOCKERIZED_GPG_AGENT=$GPG_AGENT_SUPPORT")
    DOCKER_ENV_ARGS+=(-e "CLAUDE_DOCKERIZED_MODEL=$CLAUDE_MODEL")
    DOCKER_ENV_ARGS+=(-e "CLAUDE_DOCKERIZED_LSP=$LSP_ENABLED")
    DOCKER_ENV_ARGS+=(-e "CLAUDE_DOCKERIZED_FORMATTERS=$FORMATTERS_ENABLED")
    DOCKER_ENV_ARGS+=(-e "CLAUDE_DOCKERIZED_ENV_FILE=$([ -n "$ENV_FILE" ] && echo yes || echo no)")
}

# Build the docker --env-file argument from setting.env_file.
# The file holds secrets (dotenv KEY=VALUE lines) and is consumed host-side by
# `docker run --env-file`, so values never appear on the wrapper command line.
# The file itself is never mounted: it must live under CONFIG_DIR, which no
# mount ever serves. This is the only way user secrets reach the container
# (the old env.* host passthrough was removed).
# Populates DOCKER_ENV_FILE_ARGS array.
# Usage: build_env_file_args
build_env_file_args() {
    DOCKER_ENV_FILE_ARGS=()

    [ -n "$ENV_FILE" ] || return 0

    # Expand a leading ~, then canonicalize so `..` segments cannot escape the
    # containment check below (readlink -m needs no existing file; fall back to
    # the literal path where it is unavailable, e.g. macOS).
    local env_file
    env_file=$(canonical_host_path "$ENV_FILE")

    case "$env_file" in
    "$CONFIG_DIR" | "$CONFIG_DIR"/*) ;;
    *)
        config_error "Refusing env file outside \$CONFIG_DIR ($CONFIG_DIR): it could be mounted into the container."
        exit 1
        ;;
    esac
    # The generated home (and the GnuPG relay dir) are mounted: a secrets file
    # there would be readable and rewritable from the session (T-18).
    if path_within "$env_file" "$(canonical_host_path "$CCODE_HOME")" || path_within "$env_file" "$(canonical_host_path "$GPG_RELAY_DIR")"; then
        config_error "Refusing env file inside the generated home ($CCODE_HOME): it is mounted into the container."
        exit 1
    fi

    if [ ! -f "$env_file" ]; then
        config_error "env file not found: $env_file"
        exit 1
    fi

    # A secrets file readable by group/others defeats its purpose: fail closed.
    local mode=""
    mode=$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file" 2>/dev/null || true)
    if [ -n "$mode" ] && [ $((8#$mode & 8#044)) -ne 0 ]; then
        config_error "Refusing env file readable by group/others ($env_file); run: chmod 600 \"$env_file\""
        exit 1
    fi

    # Light format check (never prints values, only line numbers): docker
    # ignores blank lines and `#` comments, needs KEY=VALUE otherwise, does
    # not understand an `export ` prefix, and may choke on CRLF line endings.
    local line lineno=0 CR
    CR=$(printf '\r')
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        case "$line" in
        "" | \#*) continue ;;
        esac
        case "$line" in
        *"$CR"*) config_warning "env file line $lineno has CRLF line endings; use LF only" ;;
        esac
        case "$line" in
        *=*) ;;
        *)
            config_warning "env file line $lineno has no '=' and will be ignored by docker"
            continue
            ;;
        esac
        case "$line" in
        export\ * | export\	*)
            config_warning "env file line $lineno uses an 'export ' prefix, which docker does not strip"
            ;;
        esac
    done <"$env_file"

    # shellcheck disable=SC2034 # populated here, consumed by bin/claude-dockerized and tests
    DOCKER_ENV_FILE_ARGS=(--env-file "$env_file")
}