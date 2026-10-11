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

# Mirror the host's *public* GnuPG material into $CCODE_HOME/.gnupg so the
# container can use the host gpg-agent (forwarded via its socket) without ever
# receiving the private keys. Only public files are copied; private-keys-v1.d,
# the agent sockets and random_seed are deliberately excluded.
# Usage: ensure_gpg_mirror
ensure_gpg_mirror() {
    local host_gpg_home="${GNUPGHOME:-$HOME/.gnupg}"
    local dest="$CCODE_HOME/.gnupg"

    if [ ! -d "$host_gpg_home" ]; then
        config_warning "GnuPG agent support enabled but no GnuPG home found at $host_gpg_home"
        return 0
    fi

    mkdir -p "$dest" 2>/dev/null || return 0
    chmod 700 "$dest" 2>/dev/null || true

    # Public keyring (GnuPG 2.x keybox) plus its lock/trust files. With keyboxd
    # the database can also live under public-keys.d/, so mirror that too.
    # Private keys (private-keys-v1.d) are never copied.
    local f
    for f in pubring.kbx trustdb.gpg sshcontrol; do
        if [ -f "$host_gpg_home/$f" ]; then
            install -m 600 "$host_gpg_home/$f" "$dest/$f" 2>/dev/null ||
                cp "$host_gpg_home/$f" "$dest/$f" 2>/dev/null || true
        fi
    done
    if [ -f "$host_gpg_home/public-keys.d/pubring.db" ]; then
        mkdir -p "$dest/public-keys.d" 2>/dev/null || true
        install -m 600 "$host_gpg_home/public-keys.d/pubring.db" "$dest/public-keys.d/pubring.db" 2>/dev/null ||
            cp "$host_gpg_home/public-keys.d/pubring.db" "$dest/public-keys.d/pubring.db" 2>/dev/null || true
    fi

    # Mirror the config verbatim, including `use-keyboxd`: on such hosts GnuPG
    # keeps the public keyring in the keyboxd database (public-keys.d/), so the
    # container must run keyboxd to read it. entrypoint.sh launches it at boot;
    # `no-autostart` (below) still prevents a keyless local gpg-agent. Stale
    # mirrored config is removed when the host has none.
    local conf
    for conf in gpg.conf common.conf; do
        if [ -f "$host_gpg_home/$conf" ]; then
            install -m 600 "$host_gpg_home/$conf" "$dest/$conf" 2>/dev/null ||
                cp "$host_gpg_home/$conf" "$dest/$conf" 2>/dev/null || true
        else
            rm -f "$dest/$conf" 2>/dev/null || true
        fi
    done

    # Never let the container's gpg auto-start a keyless local agent: the real
    # agent is the host's, reached through the forwarded socket.
    if [ -f "$dest/gpg.conf" ]; then
        grep -qE '^[[:space:]]*no-autostart([[:space:]]|$)' "$dest/gpg.conf" 2>/dev/null ||
            echo "no-autostart" >>"$dest/gpg.conf" 2>/dev/null || true
    else
        echo "no-autostart" >"$dest/gpg.conf" 2>/dev/null || true
    fi

    # Without a public keyring gpg cannot build a signature even when the agent
    # socket is forwarded: warn instead of failing silently later.
    if [ ! -f "$dest/pubring.kbx" ] && [ ! -f "$dest/public-keys.d/pubring.db" ]; then
        config_warning "No public GnuPG keyring found in $host_gpg_home (commit signing will not work)"
    fi

    # Clear any stale agent entry from earlier versions: the socket is
    # bind-mounted by the wrapper, never linked. A previous `-v` mount or a
    # Docker run with a missing source can leave a directory here, which would
    # block the socket mount and the real host agent.
    if [ -d "$dest/S.gpg-agent" ] && [ ! -S "$dest/S.gpg-agent" ]; then
        rmdir "$dest/S.gpg-agent" 2>/dev/null ||
            config_warning "Stray directory at $dest/S.gpg-agent; remove it on the host before mounting the agent socket"
    fi
    rm -f "$dest/S.gpg-agent" 2>/dev/null || true

    # Clear a stale keyboxd socket/lock from a previous run: the container starts
    # a fresh keyboxd, and a dead socket file would otherwise confuse gpgconf.
    rm -f "$dest/S.keyboxd" "$dest/S.keyboxd.lock" 2>/dev/null || true
}

# True when GPG_RELAY_DIR is a safe location to manage relays in. Stale relay
# directories are removed with rm -rf, so an overridden path must be inside
# the wrapper config or at least be named like a relay dir (never e.g. ~/Documents).
# Usage: relay_dir_ok && ...
relay_dir_ok() {
    [ -n "$GPG_RELAY_DIR" ] || return 1
    case "$GPG_RELAY_DIR" in
        / | "") return 1 ;;
    esac
    case "$GPG_RELAY_DIR" in
        "$CONFIG_DIR"/*) return 0 ;;
        "$HOME"/*/gnupg-relay* | "$HOME"/gnupg-relay*) return 0 ;;
    esac
    return 1
}

# Remove relay directories whose socat process is gone (crash, kill -9, stale
# session). Runs before starting a new relay.
# Usage: cleanup_stale_relays
cleanup_stale_relays() {
    relay_dir_ok || return 0
    [ -d "$GPG_RELAY_DIR" ] || return 0
    local d pid
    for d in "$GPG_RELAY_DIR"/*; do
        [ -d "$d" ] || continue
        pid=$(cat "$d/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        rm -rf "$d" 2>/dev/null || true
    done
}

# Relay a GnuPG agent socket through a socket on a normal filesystem so Docker
# can bind it. One process per session; the wrapper stops it when the container
# exits. Uses `socat` by default; GPG_RELAY_CMD overrides the command for tests
# only (see test_seam; it receives RELAY_SOCK and RELAY_REAL in its environment).
# Usage: relay_socket=$(start_gpg_relay <real_socket>)
start_gpg_relay() {
    local real="$1"
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

    mkdir -p "$GPG_RELAY_DIR" 2>/dev/null || return 1
    chmod 700 "$GPG_RELAY_DIR" 2>/dev/null || true
    # Keep the path short: Unix socket paths are limited to ~108 chars, and the
    # relay dir already nests under the wrapper config dir. The PID alone is
    # unique per live process (stale dirs are purged before each start).
    local dir sock pid i
    dir="$GPG_RELAY_DIR/$$"
    sock="$dir/relay.sock"
    if [ "${#sock}" -ge 108 ]; then
        config_warning "GPG relay path too long for a Unix socket (${#sock} chars); skipping relay"
        return 1
    fi
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || true

    # `exec` makes $! the relay process itself (not a wrapping bash), so
    # stop_gpg_relay reliably kills it.
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

# Stop a relay started by start_gpg_relay and remove its directory.
# Usage: stop_gpg_relay <relay_socket>
stop_gpg_relay() {
    local sock="$1"
    [ -n "$sock" ] || return 0
    local dir
    dir=$(dirname "$sock")
    # Only ever touch directories we own under GPG_RELAY_DIR.
    case "$dir" in
        "$GPG_RELAY_DIR"/*) ;;
        *) return 0 ;;
    esac
    local pid
    pid=$(cat "$dir/pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -rf "$dir" 2>/dev/null || true
}