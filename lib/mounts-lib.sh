#!/bin/bash
# mounts-lib.sh - docker run arguments: mounts and their validation, env, hardening, project paths
# Sourced by lib/config-lib.sh (which keeps the constants, config parsing and
# saving). Not executable directly; no `set -e`: callers own error handling.

# First line of a small git pointer file (.git, commondir, gitdir), at most
# 4 KiB read; empty when it is missing or not a regular file.
# Usage: line=$(_git_pointer_line <file>)
_git_pointer_line() {
    [ ! -L "$1" ] && [ -f "$1" ] || return 0
    head -c 4096 "$1" 2>/dev/null | head -n 1
}

# Detect a genuine linked git worktree and print the main repository's git
# directory (the "common dir") that must be mounted for git to work in it;
# prints nothing otherwise. The project is writable by the session, so its
# .git file is untrusted: git itself is never run on it, and the common dir is
# only accepted when the whole chain is consistent, as `git worktree add`
# writes it:
#   <project>/.git          "gitdir: <common>/worktrees/<name>"
#   <admin>/commondir       resolves to <common> (the admin dir's grandparent)
#   <admin>/gitdir          points back at <project>/.git
# and <common> is a git dir (objects/, refs/) outside the project. Anything
# else (a hand-written .git file naming another repo or any directory) is
# refused with a warning, so it can never pull a host path into the mounts.
# Usage: main_git_dir=$(detect_git_worktree "/canonical/project")
detect_git_worktree() {
    local project_dir="$1" line admin common back
    line=$(_git_pointer_line "$project_dir/.git")
    case "$line" in
    "gitdir: "?*) ;;
    *) return 0 ;;
    esac
    line=${line#gitdir: }
    [[ "$line" == /* ]] || line="$project_dir/$line"
    admin=$(canonical_host_path "$line")
    # An admin dir inside the project is already mounted: nothing to add.
    path_within "$admin" "$project_dir" && return 0

    local why=""
    if [ "$(basename "$(dirname "$admin")")" != worktrees ] || [ ! -d "$admin" ]; then
        why="it does not name <repo>/worktrees/<name>"
    else
        line=$(_git_pointer_line "$admin/commondir")
        [ -n "$line" ] && [[ "$line" != /* ]] && line="$admin/$line"
        common=""
        [ -n "$line" ] && common=$(canonical_host_path "$line")
        line=$(_git_pointer_line "$admin/gitdir")
        [ -n "$line" ] && [[ "$line" != /* ]] && line="$admin/$line"
        back=""
        [ -n "$line" ] && back=$(canonical_host_path "$line")
        if [ -z "$common" ] || [ "$common" != "$(dirname "$(dirname "$admin")")" ]; then
            why="its commondir does not lead back to the repository that holds it"
        elif [ "$back" != "$project_dir/.git" ]; then
            why="the repository does not list this directory as its worktree"
        elif [ ! -d "$common/objects" ] || [ ! -d "$common/refs" ]; then
            why="$common is not a git directory"
        elif path_within "$common" "$project_dir"; then
            return 0
        fi
    fi
    if [ -n "$why" ]; then
        config_warning "Not mounting the git directory named by $project_dir/.git: $why (git will not work in the container)."
        return 0
    fi
    echo "$common"
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

    # The same validator as every custom mount (credential stores, the
    # wrapper's own dirs, image system paths are refused).
    local spec
    if ! spec=$(validate_mount_spec "$git_common_dir" "$git_common_dir" ro); then
        config_warning "Not mounting the worktree's main git directory (see above); git will not work in the container."
        return 0
    fi

    config_info "Git worktree detected — mounting main .git directory (read-only) for git support"
    config_info "Main git directory: $git_common_dir"

    # Mount the main repo's .git directory at its real host path (read-only)
    GIT_WORKTREE_ARGS+=(-v "$spec")
}

# Build common Docker run arguments shared by run_claude and run_auth
# Append the flags of the opt-in hardening profile to DOCKER_COMMON_ARGS.
#   standard: an init process (reaps zombies), a pids limit against fork
#             bombs (T-23) and a private IPC namespace.
#   strict:   standard + read-only root filesystem with per-user tmpfs for
#             the paths tools write to (T-22). The read-only persistent
#             mounts of strict live in build_standard_volume_args. (Bridge
#             networking, T-06, is the default for every profile.)
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
}

# Say once per install that the network default moved from host to bridge
# (0.5.0) while the config does not choose a network.
# Usage: network_default_notice
network_default_notice() {
    [ "$NETWORK_EXPLICIT" = true ] && return 0
    local marker="$CONFIG_DIR/state/network-default-bridge"
    [ -e "$marker" ] && return 0
    config_info "The container network now defaults to bridge: services on the host's localhost are out of reach. Use host.docker.internal for services the host publishes on its Docker bridge, or set setting.network=host (claude-dockerized config edit) to restore the old behavior."
    { mkdir -p "$CONFIG_DIR/state" && : >"$marker"; } 2>/dev/null || true
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
    case "${NETWORK:-bridge}" in
    host | bridge) ;;
    *)
        config_warning "Invalid network '$NETWORK' (use host|bridge); falling back to bridge"
        NETWORK="bridge"
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
    # On the bridge network the host's loopback is out of reach (T-06); services
    # the host publishes on its bridge interface stay reachable by name.
    [ "$NETWORK" = bridge ] && DOCKER_COMMON_ARGS+=(--add-host "host.docker.internal:host-gateway")

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
    # Active profile: shown by the statusline, and the label lets
    # `profile delete|rename` find running sessions.
    DOCKER_COMMON_ARGS+=(-e "CLAUDE_DOCKERIZED_PROFILE=$PROFILE_NAME" --label "claude-dockerized.profile=$PROFILE_NAME")
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

# True when a generated-home mount source is a real <file|dir>, not a
# symlink: docker resolves a symlinked bind source on the host, so a link a
# session left in the read-write home would mount any host path into the next
# session. A refused source is skipped with a warning.
# Usage: home_mount_source_ok <path> file|dir
home_mount_source_ok() {
    local path="$1" kind="$2"
    if [ -L "$path" ]; then
        config_warning "Not mounting $path: it is a symlink (remove it on the host)"
        return 1
    fi
    case "$kind" in
    file) [ -f "$path" ] ;;
    *) [ -d "$path" ] ;;
    esac
}

# strict hardening: overlay read-only every existing git file the host reads
# as config or runs as code (git_host_exec_paths: the repository's and each
# submodule's config/config.worktree/hooks, linked worktrees'
# config.worktree). Only existing paths are overlaid (docker would create a
# missing source). A path docker cannot carry in a -v spec is reported.
# Usage: append_git_readonly_overlays <project_dir>
append_git_readonly_overlays() {
    local project_dir="$1" path rel
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        rel=${path#"$project_dir"/}
        case "$path" in
        *:* | *,*)
            config_warning "strict: cannot overlay $rel read-only (its path contains ':' or ','); it stays writable"
            continue
            ;;
        esac
        VOLUME_ARGS+=(-v "$path:$CONTAINER_WORKDIR/$rel:ro")
    done < <(git_host_exec_paths "$project_dir")
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
        [ "$HARDENING" = strict ] && append_git_readonly_overlays "$project_dir"
    fi

    local chome="$CCODE_HOME"
    # Mount sources only: the full security layer + LSP install already ran in
    # check_config/ensure_claude_dirs earlier in this process. Re-running it
    # here spawned a second throwaway container per `run`. Only create the
    # directories/files the -v sources below need.
    ensure_claude_mount_sources

    # A refused config or overlay may have carried tightenings (strict policy,
    # limits, read-only mounts): running on the defaults would be looser.
    local rejected="${CONFIG_REJECTED:-${PROFILE_REJECTED:-}}"
    if [ -n "$rejected" ]; then
        config_error "Refusing to start: $rejected contains control bytes and was ignored; fix it first."
        exit 1
    fi

    # The guard must be complete before a session starts: Claude Code skips a
    # hook whose script is missing, which would fail open.
    local guard_problem
    if guard_problem=$(guard_mirror_problem); then
        config_error "Refusing to start: the security guard is incomplete ($guard_problem)."
        config_info "Run 'claude-dockerized config sync' to restore it."
        exit 1
    fi

    # Managed policy (read-only directory, so no drop-in can be added;
    # highest precedence: hooks, deny rules, env).
    if [ -f "$chome/etc/claude-code/managed-settings.json" ]; then
        VOLUME_ARGS+=(-v "$chome/etc/claude-code:/etc/claude-code:ro")
    else
        config_warning "Managed policy not found at $chome/etc/claude-code/managed-settings.json"
    fi

    # Claude state (read-write directory: a single-file bind would make every
    # settings save fail with EBUSY). Credentials stay 0600.
    VOLUME_ARGS+=(-v "$chome/.claude:/home/coder/.claude:rw")

    # Security hooks (read-only overlay; complete, checked above).
    VOLUME_ARGS+=(-v "$chome/.claude/hooks-guard:/home/coder/.claude/hooks-guard:ro")

    # Managed session rules (read-only overlay).
    if home_mount_source_ok "$chome/.claude/CLAUDE.md" file; then
        VOLUME_ARGS+=(-v "$chome/.claude/CLAUDE.md:/home/coder/.claude/CLAUDE.md:ro")
    fi

    # Credentials (read-write, 0600) — auth persists across restarts/rebuilds.
    if home_mount_source_ok "$chome/.claude/.credentials.json" file; then
        safe_chmod 600 "$chome/.claude/.credentials.json" || true
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
        if home_mount_source_ok "$chome/.claude/$d" dir; then
            VOLUME_ARGS+=(-v "$chome/.claude/$d:/home/coder/.claude/$d:$persist")
        fi
    done

    # User skills: read-only in every profile (T-05), so a session cannot plant
    # or rewrite instructions that later sessions load; manage them from the
    # host. Created first: without the overlay the read-write ~/.claude parent
    # would let the session create skills/ itself.
    # With setting.share_skills=true a non-default profile mounts the default
    # profile's skills instead of its own (still read-only, and the only part
    # of another profile that is ever mounted; T-31).
    ensure_home_dir "$chome/.claude/skills" || true
    local skills_src="$chome/.claude/skills"
    if [ "$SHARE_SKILLS" = true ] && [ "$PROFILE_NAME" != default ]; then
        skills_src="$(profile_home_of default)/.claude/skills"
        mkdir -p "$skills_src" 2>/dev/null || true
    fi
    if home_mount_source_ok "$skills_src" dir; then
        VOLUME_ARGS+=(-v "$skills_src:/home/coder/.claude/skills:ro")
    fi

    # LSP config (regenerated when setting.lsp=true).
    if { [ -e "$chome/.claude/.lsp.json" ] || [ -L "$chome/.claude/.lsp.json" ]; } &&
        home_mount_source_ok "$chome/.claude/.lsp.json" file; then
        VOLUME_ARGS+=(-v "$chome/.claude/.lsp.json:/home/coder/.claude/.lsp.json:$persist")
    fi

    # MCP user-scope state (read-write; seeded by ensure_claude_mount_sources).
    if home_mount_source_ok "$chome/.claude.json" file; then
        VOLUME_ARGS+=(-v "$chome/.claude.json:/home/coder/.claude.json:rw")
    fi

    # Generated-home binaries: LSP servers and formatters installed by
    # ensure_lsp_formatters (read-write, on PATH in the container).
    # With setting.lsp_from=default a non-default profile uses the default
    # profile's binaries read-only (no per-profile installs; T-31).
    local bin_src="$chome/.local/bin" bin_mode="$persist"
    if [ "$LSP_FROM" = default ] && [ "$PROFILE_NAME" != default ]; then
        bin_src="$(profile_home_of default)/.local/bin"
        bin_mode=ro
        mkdir -p "$bin_src" 2>/dev/null || true
    fi
    if home_mount_source_ok "$bin_src" dir; then
        VOLUME_ARGS+=(-v "$bin_src:/home/coder/.local/bin:$bin_mode")
    fi

    # Sessions / history / caches (read-write).
    for d in "$chome/.local/share/claude:/home/coder/.local/share/claude" "$chome/.local/state/claude:/home/coder/.local/state/claude" "$chome/.cache/claude:/home/coder/.cache/claude"; do
        local src="${d%%:*}"
        if home_mount_source_ok "$src" dir; then
            VOLUME_ARGS+=(-v "$d:rw")
        fi
    done

    # MCP OAuth store for `mcp-remote`-based servers (generated home, always
    # read-write: tokens, not code, so strict keeps it writable; without it
    # the tokens die with the container, or cannot be written on a read-only
    # rootfs). Native Claude MCP OAuth lives in .credentials.json instead.
    if home_mount_source_ok "$chome/.mcp-auth" dir; then
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

# Build docker mount arguments from the CUSTOM_MOUNTS array: populates
# DOCKER_MOUNT_ARGS (each entry validated by validate_mount_spec).
build_mount_args() {
    DOCKER_MOUNT_ARGS=()
    GPG_SOCKET=""
    SSH_CONTAINER_SOCK=""
    # Stop the relays a previous call in the same process left behind.
    if [ -n "$GPG_RELAY_SOCKET" ]; then
        stop_socket_relay "$GPG_RELAY_SOCKET"
    fi
    GPG_RELAY_SOCKET=""
    if [ -n "$SSH_RELAY_SOCKET" ]; then
        stop_socket_relay "$SSH_RELAY_SOCKET"
    fi
    SSH_RELAY_SOCKET=""

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
            local ssh_src="$SSH_AUTH_SOCK"
            # The socket may live on the per-user /run tmpfs, which Docker
            # cannot bind: relay it through a socket on a normal filesystem.
            # Every concurrent session gets its own relay, all pointing at the
            # same host agent (which serves many clients at once).
            if { [[ "$ssh_src" == /run/* ]] || [ "${SSH_RELAY_FORCE:-false}" = true ]; } && [ "$GPG_RELAY" = true ]; then
                local ssh_relay
                if ssh_relay=$(start_socket_relay "$ssh_src" ssh); then
                    SSH_RELAY_SOCKET="$ssh_relay"
                    ssh_src="$ssh_relay"
                    # The relay path is host-side only: point the container at a
                    # stable path of its own.
                    SSH_CONTAINER_SOCK="/home/coder/.ssh-agent/ssh"
                else
                    config_warning "Could not start the SSH agent relay; is 'socat' installed on the host?"
                fi
            fi
            [ -n "$SSH_CONTAINER_SOCK" ] || SSH_CONTAINER_SOCK="$SSH_AUTH_SOCK"
            # --mount (not -v) so a stale/missing source fails loudly instead
            # of Docker creating a directory at the host socket path, which
            # would break the real ssh-agent.
            mount_bind "$ssh_src" "$SSH_CONTAINER_SOCK"
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
        if [ -n "$GPG_MIRROR_DIR" ] && [ -d "$GPG_MIRROR_DIR" ]; then
            mount_bind "$GPG_MIRROR_DIR" "/home/coder/.gnupg"
        else
            config_warning "GnuPG agent support enabled but the GnuPG mirror under $CCODE_HOME/.gnupg-sessions could not be prepared"
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
                if relay=$(start_socket_relay "$gpg_socket" gnupg); then
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
            if [ -n "$GPG_MIRROR_DIR" ] && [ -d "$GPG_MIRROR_DIR" ]; then
                ln -sfn "/home/coder/.gnupg-agent/S.gpg-agent" "$GPG_MIRROR_DIR/S.gpg-agent" 2>/dev/null ||
                    config_warning "Could not create the GnuPG agent socket symlink in $GPG_MIRROR_DIR"
            fi
        else
            config_warning "GnuPG agent support enabled but no usable agent socket (extra socket missing and main fallback disabled)"
        fi
    fi
}

# Build docker environment variable arguments for automatic (non-secret)
# forwarding: agent sockets, terminal detection and doctor state flags.
# User secrets travel exclusively via the profile's env file (--env-file, see
# build_env_file_args); the old env.* host passthrough was removed.
# Populates DOCKER_ENV_ARGS array with -e arguments
build_env_args() {
    DOCKER_ENV_ARGS=()

    # Handle SSH agent forwarding if enabled
    if [ "$SSH_AGENT_SUPPORT" = true ]; then
        if [ -n "${SSH_CONTAINER_SOCK:-}" ]; then
            DOCKER_ENV_ARGS+=(-e "SSH_AUTH_SOCK=$SSH_CONTAINER_SOCK")
        elif [ -n "${SSH_AUTH_SOCK:-}" ]; then
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

# Why a secrets file is not private to the current user, or return 1 when it
# is: it must be owned by this user, and group/others must have no permission
# bit at all (read leaks the secrets, write lets them be swapped). A mode that
# cannot be read counts as not private.
# Usage: reason=$(env_file_permission_problem <file>) && refuse
env_file_permission_problem() {
    local file="$1" mode=""
    if [ ! -O "$file" ]; then
        echo "it is not owned by you"
        return 0
    fi
    mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || true)
    case "$mode" in
    "" | *[!0-7]*)
        echo "its permissions could not be read"
        return 0
        ;;
    esac
    if [ $((8#$mode & 8#077)) -ne 0 ]; then
        echo "group/others have access (mode $mode)"
        return 0
    fi
    return 1
}

# Build the docker --env-file argument from the active profile's env file
# (profiles/<name>/env, resolved into ENV_FILE by profile_resolve_env_file).
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
    # The generated home (and the agent relay dir) are mounted: a secrets file
    # there would be readable and rewritable from the session (T-18).
    if path_within "$env_file" "$(canonical_host_path "$CCODE_HOME")" || path_within "$env_file" "$(canonical_host_path "$SOCKET_RELAY_DIR")"; then
        config_error "Refusing env file inside the generated home ($CCODE_HOME): it is mounted into the container."
        exit 1
    fi

    if [ ! -f "$env_file" ]; then
        config_error "env file not found: $env_file"
        exit 1
    fi

    # A secrets file anyone else can read or rewrite defeats its purpose: fail
    # closed, including when its permissions cannot be read at all.
    local problem
    if problem=$(env_file_permission_problem "$env_file"); then
        config_error "Refusing env file $env_file: $problem; run: chmod 600 \"$env_file\" (as its owner)"
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
