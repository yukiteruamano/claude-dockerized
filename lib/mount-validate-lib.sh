#!/bin/bash
# mount-validate-lib.sh - the single validator for host and container paths:
# project directory, custom mounts (wrapper config, profile overlays, the
# wizard) and the container mount points they target (T-07). Sourced by
# lib/config-lib.sh; mounts-lib.sh builds docker arguments from what passes
# here. Not executable directly; no `set -e`: callers own error handling.

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
