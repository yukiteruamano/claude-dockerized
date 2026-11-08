#!/bin/bash
# agent-lib.sh - forwarded GnuPG / SSH agents, the GnuPG mirror and the socket relay
# Sourced by lib/config-lib.sh (which keeps the constants, config parsing and
# saving). Not executable directly; no `set -e`: callers own error handling.

# Resolve the host's gpg-agent socket path.
# Prefers an explicit override (GPG_AGENT_SOCKET, used by tests), then gpgconf.
# Prints an empty string when neither is available.
resolve_gpg_agent_socket() {
    if [ -n "${GPG_AGENT_SOCKET:-}" ]; then
        echo "$GPG_AGENT_SOCKET"
        return 0
    fi
    if command -v gpgconf >/dev/null 2>&1; then
        gpgconf --list-dirs agent-socket 2>/dev/null || true
    fi
}

# Resolve the host's restricted gpg-agent "extra" socket path. This socket only
# allows signing/decryption, so a forwarded container cannot reconfigure the
# host agent. Prefers an explicit override (GPG_AGENT_EXTRA_SOCKET, used by
# tests), then gpgconf. Prints an empty string when neither is available.
resolve_gpg_agent_extra_socket() {
    if [ -n "${GPG_AGENT_EXTRA_SOCKET:-}" ]; then
        echo "$GPG_AGENT_EXTRA_SOCKET"
        return 0
    fi
    if command -v gpgconf >/dev/null 2>&1; then
        gpgconf --list-dirs agent-extra-socket 2>/dev/null || true
    fi
}

# Print the value of a command-override test seam (GPG_AGENT_PROBE_CMD,
# GPG_AGENT_LAUNCH_CMD, GPG_RELAY_CMD) only when the test suite opts in with
# CLAUDE_DOCKERIZED_TEST_HOOKS=1: outside tests an inherited variable must
# never run arbitrary shell on the host. Usage: cmd=$(test_seam NAME)
test_seam() {
    [ "${CLAUDE_DOCKERIZED_TEST_HOOKS:-}" = 1 ] || return 0
    printf '%s' "${!1:-}"
}

# Return 0 when the host gpg-agent looks reachable, 1 otherwise. Socket
# presence alone is not enough: a stale socket file would pass for "running",
# so on a real host the agent is probed with gpg-connect-agent (2s timeout).
# Test seams:
#   - GPG_AGENT_PROBE_CMD replaces the probe with an arbitrary command
#     (tests only, see test_seam).
#   - GPG_AGENT_SOCKET / GPG_AGENT_EXTRA_SOCKET (plain test sockets, not real
#     agents) skip the probe and trust the socket.
# Usage: gpg_agent_is_running
gpg_agent_is_running() {
    local extra main
    extra=$(resolve_gpg_agent_extra_socket)
    main=$(resolve_gpg_agent_socket)

    if { [ -z "$extra" ] || [ ! -S "$extra" ]; } && { [ -z "$main" ] || [ ! -S "$main" ]; }; then
        return 1
    fi

    local probe_cmd
    probe_cmd=$(test_seam GPG_AGENT_PROBE_CMD)
    if [ -n "$probe_cmd" ]; then
        bash -c "$probe_cmd" >/dev/null 2>&1 && return 0
        return 1
    fi

    # Test sockets are not real agents: trust the socket.
    if [ -n "${GPG_AGENT_SOCKET:-}" ] || [ -n "${GPG_AGENT_EXTRA_SOCKET:-}" ]; then
        return 0
    fi

    # Without the probe tooling, fall back to trusting the socket.
    if ! command -v gpg-connect-agent >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        return 0
    fi
    if timeout 2 gpg-connect-agent --no-autostart 'getinfo version' /bye >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Prepare the host GnuPG agent before its socket is mounted. When the restricted
# extra socket is missing, launch the host agent (unless autostart is disabled)
# and wait briefly for it to appear. Never fails the run: it reports actionable
# warnings and lets build_mount_args skip the socket.
# Usage: ensure_gpg_agent_ready
ensure_gpg_agent_ready() {
    [ "$GPG_AGENT_SUPPORT" = true ] || return 0

    if ! command -v gpgconf >/dev/null 2>&1; then
        config_warning "gpgconf not found on the host; cannot prepare the GnuPG agent"
        return 0
    fi

    local extra main
    extra=$(resolve_gpg_agent_extra_socket)
    main=$(resolve_gpg_agent_socket)

    # Ready only when the socket we will actually mount is usable: the restricted
    # extra socket, or the main one when explicitly allowed. A live main socket
    # alone must not short-circuit, or a missing extra socket is never repaired.
    if [ -n "$extra" ] && [ -S "$extra" ]; then
        if gpg_agent_is_running; then
            return 0
        fi
    elif [ "$GPG_ALLOW_MAIN_SOCKET" = true ] && [ -n "$main" ] && [ -S "$main" ]; then
        if gpg_agent_is_running; then
            return 0
        fi
    fi

    if [ "$GPG_AUTOSTART_AGENT" != true ]; then
        config_warning "GnuPG agent socket not available and autostart is disabled (setting.gpg_autostart_agent=false)"
        return 0
    fi

    # A previous `-v` mount can leave an empty directory where the agent socket
    # belongs, which blocks gpg-agent from creating it. Remove empty ones (rmdir
    # refuses non-empty directories) before launching.
    local dir
    for dir in "$extra" "$main"; do
        if [ -n "$dir" ] && [ -d "$dir" ] && [ ! -S "$dir" ]; then
            if rmdir "$dir" 2>/dev/null; then
                config_warning "Removed an empty directory blocking the GnuPG agent socket: $dir"
            fi
        fi
    done

    config_info "Starting host gpg-agent for GnuPG forwarding..."
    local launch_cmd
    launch_cmd=$(test_seam GPG_AGENT_LAUNCH_CMD)
    if [ -n "$launch_cmd" ]; then
        bash -c "$launch_cmd" >/dev/null 2>&1 || true
    else
        gpgconf --launch gpg-agent >/dev/null 2>&1 || config_warning "gpgconf --launch gpg-agent failed"
    fi

    # The socket appears asynchronously; give it up to ~2s.
    local i
    for ((i = 0; i < 20; i++)); do
        extra=$(resolve_gpg_agent_extra_socket)
        if [ -n "$extra" ] && [ -S "$extra" ]; then
            return 0
        fi
        main=$(resolve_gpg_agent_socket)
        if [ -n "$main" ] && [ -S "$main" ]; then
            return 0
        fi
        sleep 0.1
    done

    # Still missing: report the most likely cause (a non-empty directory
    # squatting on the socket path, e.g. created by an earlier Docker -v mount).
    if { [ -n "$extra" ] && [ -d "$extra" ]; } || { [ -n "$main" ] && [ -d "$main" ]; }; then
        config_warning "The GnuPG agent socket path is a non-empty directory, not a socket."
        config_info "Remove it on the host (usually under \$XDG_RUNTIME_DIR/gnupg) and re-run."
    else
        config_warning "Could not start the host gpg-agent; run 'gpgconf --launch gpg-agent' manually"
    fi
    return 0
}

# Validate the forwarded SSH agent before its socket is mounted. Deliberately
# never starts ssh-agent: a fresh agent would carry no host keys.
# Usage: ensure_ssh_agent_ready
ensure_ssh_agent_ready() {
    [ "$SSH_AGENT_SUPPORT" = true ] || return 0

    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
        config_warning "SSH agent support enabled but SSH_AUTH_SOCK is not set in this environment"
        return 0
    fi

    if [ ! -S "$SSH_AUTH_SOCK" ]; then
        config_warning "SSH agent support enabled but $SSH_AUTH_SOCK is not a socket"
        if [ -d "$SSH_AUTH_SOCK" ]; then
            config_info "That path is a directory; remove it or point SSH_AUTH_SOCK at the real agent socket"
        fi
        return 0
    fi

    # The socket exists. Do not query it here (ssh-add against a non-agent
    # socket can block); the forwarded agent is used by git/ssh directly.
    return 0
}

# Directory holding the per-session GnuPG mirrors. Each wrapper process owns
# one subdirectory named after its PID (one wrapper process = one session): a
# mirror shared between sessions would let a new session delete the keyboxd and
# agent sockets of a running one, and the keyboxd started by the first container
# would vanish with it.
gpg_mirror_root() {
    printf '%s' "$CCODE_HOME/.gnupg-sessions"
}

# True when $1 is a mirror directory this wrapper created (<root>/<pid>), so
# the recursive removals below can never reach anything else.
gpg_mirror_dir_ok() {
    local dir="$1" root
    root=$(gpg_mirror_root)
    [ -n "$CCODE_HOME" ] || return 1
    case "$dir" in
    "$root"/*[!0-9]*) return 1 ;;
    "$root"/[0-9]*) return 0 ;;
    esac
    return 1
}

# Kernel boot id, used to tell a live session directory from one left behind by
# a previous boot. PIDs restart from a low number after a reboot, so "that PID
# is alive" alone would keep a dead session's directory forever. Empty when the
# host does not expose it (non-Linux), which disables the check.
# Usage: boot_id=$(kernel_boot_id)
kernel_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

# True when the session directory $1 was created by a previous boot (and is
# therefore stale, whatever the PID recorded in its name is doing now).
# Usage: session_dir_from_previous_boot <dir>
session_dir_from_previous_boot() {
    local dir="$1" recorded="" current
    # The mirror is mounted read-write: read the marker only when it is a
    # regular file, and only its first bytes (a link to /dev/zero must not
    # hang the wrapper).
    if [ ! -L "$dir/boot-id" ] && [ -f "$dir/boot-id" ]; then
        recorded=$(head -c 64 "$dir/boot-id" 2>/dev/null | head -n 1 || true)
    fi
    current=$(kernel_boot_id)
    [ -n "$recorded" ] && [ -n "$current" ] && [ "$recorded" != "$current" ]
}

# Remove mirrors of wrapper processes that no longer exist (crash, kill -9) and
# mirrors left over from a previous boot.
# Usage: cleanup_stale_gpg_mirrors
cleanup_stale_gpg_mirrors() {
    local root d pid
    root=$(gpg_mirror_root)
    [ -d "$root" ] || return 0
    for d in "$root"/*; do
        gpg_mirror_dir_ok "$d" || continue
        pid=${d##*/}
        [ "$pid" = "$$" ] && continue
        if session_dir_from_previous_boot "$d"; then
            rm -rf "$d" 2>/dev/null || true
            continue
        fi
        kill -0 "$pid" 2>/dev/null && continue
        rm -rf "$d" 2>/dev/null || true
    done
}

# Delete the shared mirror that versions up to 0.4.4 kept at $CCODE_HOME/.gnupg.
# Guarded: that path is only ever a mirror we generated, unless the user pointed
# GNUPGHOME at it, in which case it is their GnuPG home and must stay.
# Usage: cleanup_legacy_gpg_mirror
cleanup_legacy_gpg_mirror() {
    local legacy
    [ -n "${CCODE_HOME:-}" ] || return 0
    legacy="$CCODE_HOME/.gnupg"
    [ -d "$legacy" ] || return 0
    if [ "$(canonical_host_path "${GNUPGHOME:-$HOME/.gnupg}")" = "$(canonical_host_path "$legacy")" ]; then
        return 0
    fi
    rm -rf "$legacy" 2>/dev/null || true
}

# Copy one file into the mirror through a staged file and a rename
# (safe_write_file): the host keyboxd may be writing pubring.kbx /
# public-keys.d/pubring.db while the session starts, and a torn copy would
# leave gpg unusable inside the container; the mirror is mounted read-write,
# so nothing a session left there is ever followed.
# Usage: mirror_file <source> <destination>
mirror_file() {
    local src="$1" dest="$2"
    [ -f "$src" ] || return 1
    safe_write_file "$dest" 600 <"$src"
}

# Remove this session's mirror once its container has exited.
# Usage: remove_gpg_mirror
remove_gpg_mirror() {
    [ -n "${GPG_MIRROR_DIR:-}" ] || return 0
    if gpg_mirror_dir_ok "$GPG_MIRROR_DIR"; then
        rm -rf "$GPG_MIRROR_DIR" 2>/dev/null || true
    fi
    GPG_MIRROR_DIR=""
}

# Mirror the host's *public* GnuPG material into a per-session directory
# ($GPG_MIRROR_DIR, under $CCODE_HOME/.gnupg-sessions) so the container can use
# the host gpg-agent (forwarded via its socket) without ever receiving the
# private keys. Only public files are copied; private-keys-v1.d, the agent
# sockets and random_seed are deliberately excluded. GPG_MIRROR_DIR stays empty
# when nothing could be mirrored, and the caller then skips the mount.
# Usage: ensure_gpg_mirror
ensure_gpg_mirror() {
    local host_gpg_home="${GNUPGHOME:-$HOME/.gnupg}"
    local root dest
    root=$(gpg_mirror_root)
    GPG_MIRROR_DIR=""

    cleanup_legacy_gpg_mirror
    cleanup_stale_gpg_mirrors

    if [ ! -d "$host_gpg_home" ]; then
        config_warning "GnuPG agent support enabled but no GnuPG home found at $host_gpg_home"
        return 0
    fi

    # One mirror per session (this process is the session): concurrent sessions
    # need their own copy because the container starts its own keyboxd on it.
    # A directory already named after this PID was left by an earlier session
    # whose container could still write it (crash, PID reuse): it may hold
    # planted symlinks, so it is removed and the mirror starts from scratch.
    dest="$root/$$"
    ensure_home_dir "$root" 700 || return 0
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        rm -rf "$dest" 2>/dev/null || true
    fi
    mkdir -m 700 "$dest" 2>/dev/null || {
        config_warning "Could not create a fresh GnuPG mirror at $dest"
        return 0
    }
    GPG_MIRROR_DIR="$dest"
    kernel_boot_id | safe_write_file "$dest/boot-id" 600 || true

    # Public keyring (GnuPG 2.x keybox) plus its lock/trust files. With keyboxd
    # the database can also live under public-keys.d/, so mirror that too.
    # Private keys (private-keys-v1.d) are never copied.
    local f
    for f in pubring.kbx trustdb.gpg sshcontrol; do
        mirror_file "$host_gpg_home/$f" "$dest/$f" || true
    done
    if [ -f "$host_gpg_home/public-keys.d/pubring.db" ]; then
        ensure_home_dir "$dest/public-keys.d" 700 || true
        mirror_file "$host_gpg_home/public-keys.d/pubring.db" "$dest/public-keys.d/pubring.db" || true
    fi

    # Mirror the config verbatim, including `use-keyboxd`: on such hosts GnuPG
    # keeps the public keyring in the keyboxd database (public-keys.d/), so the
    # container must run keyboxd to read it. entrypoint.sh launches it at boot;
    # `no-autostart` (below) still prevents a keyless local gpg-agent. A config
    # the host does not have is not mirrored (the mirror starts empty anyway).
    mirror_file "$host_gpg_home/common.conf" "$dest/common.conf" || true

    # Never let the container's gpg auto-start a keyless local agent: the real
    # agent is the host's, reached through the forwarded socket. Built from
    # the host copy and written once (never appended in the mounted mirror).
    {
        if [ -f "$host_gpg_home/gpg.conf" ]; then
            cat "$host_gpg_home/gpg.conf" 2>/dev/null
            grep -qE '^[[:space:]]*no-autostart([[:space:]]|$)' "$host_gpg_home/gpg.conf" 2>/dev/null ||
                echo "no-autostart"
        else
            echo "no-autostart"
        fi
    } | safe_write_file "$dest/gpg.conf" 600 || true

    # Without a public keyring gpg cannot build a signature even when the agent
    # socket is forwarded: warn instead of failing silently later.
    if [ ! -f "$dest/pubring.kbx" ] && [ ! -f "$dest/public-keys.d/pubring.db" ]; then
        config_warning "No public GnuPG keyring found in $host_gpg_home (commit signing will not work)"
    fi

    # The agent socket is bind-mounted by the wrapper, never linked: only the
    # symlink that build_mount_args creates belongs here. Clear it (and any
    # socket a reused session directory could carry) so a second mount in the
    # same process starts clean.
    rm -f "$dest/S.gpg-agent" "$dest/S.keyboxd" "$dest/S.keyboxd.lock" 2>/dev/null || true
}

# True when SOCKET_RELAY_DIR is a safe location to manage relays in. Stale
# relay directories are removed with rm -rf, so an overridden path must be
# inside the wrapper config or at least be named like a relay dir (never e.g.
# ~/Documents).
# Usage: relay_dir_ok && ...
relay_dir_ok() {
    [ -n "$SOCKET_RELAY_DIR" ] || return 1
    case "$SOCKET_RELAY_DIR" in
    / | "") return 1 ;;
    esac
    case "$SOCKET_RELAY_DIR" in
    "$CONFIG_DIR"/*) return 0 ;;
    "$HOME"/*/agent-relay* | "$HOME"/agent-relay*) return 0 ;;
    "$HOME"/*/gnupg-relay* | "$HOME"/gnupg-relay*) return 0 ;;
    esac
    return 1
}

# Remove relay directories whose relay process and owning wrapper are both
# gone (crash, kill -9, stale session) or that a previous boot left behind.
# Runs before starting a new relay and from `clean`. NOTE: concurrent sessions
# never share a directory (each one owns <dir>/<pid>-<kind>); while its owner
# (the <pid> in the name) is alive a directory is kept, so a session that has
# created its directory but not yet written the relay pid never loses it.
# Usage: cleanup_stale_relays
cleanup_stale_relays() {
    relay_dir_ok || return 0
    [ -d "$SOCKET_RELAY_DIR" ] || return 0
    local d pid owner
    for d in "$SOCKET_RELAY_DIR"/*; do
        [ -d "$d" ] || continue
        if session_dir_from_previous_boot "$d"; then
            rm -rf "$d" 2>/dev/null || true
            continue
        fi
        pid=$(cat "$d/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        owner=${d##*/}
        owner=${owner%%-*}
        case "$owner" in
        "" | *[!0-9]*) ;;
        *) kill -0 "$owner" 2>/dev/null && continue ;;
        esac
        rm -rf "$d" 2>/dev/null || true
    done
}

# Relay an agent socket through a socket on a normal filesystem so Docker can
# bind it. One relay per session and kind; the wrapper stops it when the
# container exits, and concurrent sessions each get their own relay pointing at
# the same host agent. Uses `socat` by default; GPG_RELAY_CMD overrides the
# command for tests only (see test_seam; it receives RELAY_SOCK and RELAY_REAL
# in its environment).
# Usage: relay_socket=$(start_socket_relay <real_socket> [gnupg|ssh])
start_socket_relay() {
    local real="$1" kind="${2:-gnupg}"
    [ -n "$real" ] && [ -S "$real" ] || return 1
    relay_dir_ok || return 1

    local template
    template=$(test_seam GPG_RELAY_CMD)
    if [ -z "$template" ]; then
        command -v socat >/dev/null 2>&1 || return 1
        # Single quotes are intentional: expanded later via RELAY_SOCK/RELAY_REAL env.
        # shellcheck disable=SC2016
        template='socat "UNIX-LISTEN:$RELAY_SOCK,fork,max-children=8,mode=600" "UNIX-CONNECT:$RELAY_REAL"'
    fi

    mkdir -p "$SOCKET_RELAY_DIR" 2>/dev/null || return 1
    chmod 700 "$SOCKET_RELAY_DIR" 2>/dev/null || true
    # Keep the path short: Unix socket paths are limited to ~108 chars, and the
    # relay dir already nests under the wrapper config dir. PID + kind is unique
    # per live session (stale dirs are purged before each start).
    local dir sock pid i
    dir="$SOCKET_RELAY_DIR/$$-$kind"
    sock="$dir/relay.sock"
    if [ "${#sock}" -ge 108 ]; then
        config_warning "$kind relay path too long for a Unix socket (${#sock} chars); skipping relay"
        return 1
    fi
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || true
    kernel_boot_id >"$dir/boot-id" 2>/dev/null || true

    # `exec` makes $! the relay process itself (not a wrapping bash), so
    # stop_socket_relay reliably kills it.
    RELAY_SOCK="$sock" RELAY_REAL="$real" bash -c "exec $template" >/dev/null 2>&1 &
    pid=$!
    echo "$pid" >"$dir/pid" 2>/dev/null || true

    for ((i = 0; i < 20; i++)); do
        if [ -S "$sock" ]; then
            echo "$sock"
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done

    kill "$pid" 2>/dev/null || true
    rm -rf "$dir" 2>/dev/null || true
    return 1
}

# Stop a relay started by start_socket_relay and remove its directory.
# Usage: stop_socket_relay <relay_socket>
stop_socket_relay() {
    local sock="$1"
    [ -n "$sock" ] || return 0
    local dir
    dir=$(dirname "$sock")
    # Only ever touch directories we own under SOCKET_RELAY_DIR.
    case "$dir" in
    "$SOCKET_RELAY_DIR"/*) ;;
    *) return 0 ;;
    esac
    local pid
    pid=$(cat "$dir/pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -rf "$dir" 2>/dev/null || true
}
