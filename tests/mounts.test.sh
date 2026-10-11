#!/bin/bash
# Mount and path validation contract (threat T-07 / T-18): custom mounts,
# project directory and env file must never expose host secrets, the wrapper's
# own config, the docker socket, or shadow the managed read-only mounts.
# No Docker needed: sources config-lib.sh with an isolated HOME/CONFIG_DIR.
#
# Usage: bash tests/mounts.test.sh
# shellcheck disable=SC2034,SC2088,SC2317  # globals feed config-lib.sh; literal ~ is config text; helpers run via check/gap

# No `set -u`: config-lib.sh is sourced by callers that do not use it.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="mounts"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

export TMPDIR="${TMPDIR:-/tmp/claude}"
TMP="$(t_tmpdir)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

export HOME="$TMP/home"
export CONFIG_DIR="$HOME/.config/claude-dockerized"
export CCODE_HOME="$CONFIG_DIR/home"
export NO_COLOR=1
mkdir -p "$HOME/.ssh" "$HOME/.gnupg" "$HOME/data" "$HOME/work/proj" "$CCODE_HOME/.claude" "$CONFIG_DIR"
ln -s "$HOME/.ssh" "$HOME/ssh-link"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config-lib.sh"
SSH_AGENT_SUPPORT=false
GPG_AGENT_SUPPORT=false

# mount_ok <spec> — build_mount_args accepts the entry (runs in a subshell
# because refusals call exit).
mount_ok() {
    (
        CUSTOM_MOUNTS=("$1")
        build_mount_args >/dev/null 2>&1
    )
}
mount_refused() { ! mount_ok "$1"; }

# mount_mode <spec> — the mode docker receives for the entry.
mount_mode() {
    (
        CUSTOM_MOUNTS=("$1")
        build_mount_args >/dev/null 2>&1 || exit 1
        printf '%s' "${DOCKER_MOUNT_ARGS[1]##*:}"
    )
}

add_mount_ok() {
    (
        CUSTOM_MOUNTS=()
        CUSTOM_MOUNT_KEYS=()
        add_mount "$@" >/dev/null 2>&1
    )
}

# --- baseline behaviour that already holds --------------------------------------
check "plain data mount accepted" mount_ok "~/data:/data"
assert_eq "$(mount_mode "~/data:/data")" ro "mounts default to read-only"
assert_eq "$(mount_mode "~/data:/data:rw")" rw "explicit rw honoured"
check "~/.ssh refused" mount_refused "~/.ssh:/home/coder/.ssh"
check "~/.ssh subpath refused" mount_refused "$HOME/.ssh/config:/x"
check "~/.gnupg refused" mount_refused "~/.gnupg:/g"
check "relative container path refused" mount_refused "~/data:data"
check "entry without a container path refused" mount_refused "~/data"
check_not "add_mount refuses ~/.ssh" add_mount_ok "~/.ssh" /s
check_not "add_mount refuses an unknown mode" add_mount_ok "~/data" /d Z
check "add_mount accepts ro" add_mount_ok "~/data" /d ro

# --- canonicalization gaps (T-07) --------------------------------------------------
check "T-07 ~/./.ssh refused" mount_refused "$HOME/./.ssh:/x"
check "T-07 ~//.ssh refused" mount_refused "$HOME//.ssh:/x"
check "T-07 ~/work/../.ssh refused" mount_refused "$HOME/work/../.ssh:/x"
check "T-07 symlink to ~/.ssh refused" mount_refused "$HOME/ssh-link:/x"
check "T-07 the whole home refused" mount_refused "$HOME:/h"
check "T-07 / refused" mount_refused "/:/host"
check "T-07 ~/.config refused" mount_refused "$HOME/.config:/c"
check "T-07 wrapper CONFIG_DIR refused" mount_refused "$CONFIG_DIR:/c"
check "T-07 generated home refused" mount_refused "$CCODE_HOME:/c"
check "T-07 docker socket via custom mount refused" mount_refused "/var/run/docker.sock:/var/run/docker.sock"

# --- mode allowlist (T-07) -----------------------------------------------------------
for mode in Z z rshared "ro,z" "rw,rshared"; do
    check "T-07 mode '$mode' refused" mount_refused "~/data:/data:$mode"
done

# --- managed targets must not be shadowed (T-07) -------------------------------------
for target in /home/coder/.claude/hooks-guard/policies /home/coder/.claude/settings.json \
    /home/coder/.claude /usr/local/bin /etc/claude-code; do
    check "T-07 target $target refused" mount_refused "~/data:$target"
done

# --- project directory (T-07) --------------------------------------------------------
project_ok() { validate_project_dir "$1" >/dev/null 2>&1; }
project_refused() { ! project_ok "$1"; }
check "a project subdir is accepted" project_ok "$HOME/work/proj"
check_not "\$HOME refused as project" project_ok "$HOME"
check_not "/ refused as project" project_ok /
check_not "ancestor of \$HOME refused" project_ok "$(dirname "$HOME")"
check "T-07 ~/.ssh refused as project" project_refused "$HOME/.ssh"
check "T-07 ~/.gnupg refused as project" project_refused "$HOME/.gnupg"
check "T-07 CONFIG_DIR refused as project" project_refused "$CONFIG_DIR"
check "T-07 ~/.config refused as project" project_refused "$HOME/.config"

# A project below $HOME lands at its path minus $HOME: ~/usr must not become /usr.
mkdir -p "$HOME/usr/bin" "$HOME/bin" "$HOME/etc/claude-code" "$HOME/lib" "$HOME/opt/app" "$HOME/work/usr"
for dir in usr bin etc lib usr/bin etc/claude-code; do
    check "T-07 project at ~/$dir would shadow /$dir" project_refused "$HOME/$dir"
done
check "a project named like a system dir deeper down is accepted" project_ok "$HOME/work/usr"
check "a project below ~/opt is accepted" project_ok "$HOME/opt/app"

# --- targets are normalised before the shadowing check (T-07) ---------------------------
for target in /etc/./claude-code /usr/local/../bin /home/coder/.claude/../.claude/hooks-guard /usr//bin /bin/sh; do
    check "T-07 target $target refused" mount_refused "~/data:$target"
done

# --- host sources holding credentials or runtime state (T-07) ---------------------------
mkdir -p "$HOME/.aws" "$HOME/.kube" "$HOME/.docker" "$HOME/.claude" "$HOME/.config/gcloud" "$HOME/.config/gh"
for src in .aws .kube .docker .claude .config/gcloud .config/gh; do
    check "T-07 ~/$src refused as a mount source" mount_refused "~/$src:/data"
done
: >"$HOME/.netrc"
: >"$HOME/.npmrc"
check "T-07 ~/.netrc refused as a mount source" mount_refused "~/.netrc:/home/coder/.netrc"
check "T-07 ~/.npmrc refused as a mount source" mount_refused "~/.npmrc:/home/coder/.npmrc"
for src in /etc /etc/shadow /etc/ssh /root /proc/1 /sys /dev /run /run/user /var/run/foo; do
    check "T-07 host $src refused as a mount source" mount_refused "$src:/data"
done
for sock in docker podman containerd crio; do
    : >"$HOME/data/$sock.sock"
    check "T-07 $sock.sock refused" mount_refused "~/data/$sock.sock:/data/$sock.sock"
done
check "a mount from /opt is still accepted" mount_ok "/opt:/data"

# --- env file placement (T-18) -------------------------------------------------------
env_file_ok() {
    (
        ENV_FILE="$1"
        build_env_file_args >/dev/null 2>&1
    )
}
env_file_refused() { ! env_file_ok "$1"; }
printf 'A=1\n' >"$CONFIG_DIR/env"
chmod 600 "$CONFIG_DIR/env"
mkdir -p "$CCODE_HOME/.claude/plugins"
printf 'A=1\n' >"$CCODE_HOME/.claude/plugins/env"
check "env file in CONFIG_DIR accepted" env_file_ok "$CONFIG_DIR/env"
check_not "env file outside CONFIG_DIR refused" env_file_ok "$HOME/data/env"
check_not "env file escaping via .. refused" env_file_ok "$CONFIG_DIR/../../data/env"
check "T-18 env file inside the mounted generated home refused" env_file_refused "$CCODE_HOME/.claude/plugins/env"
printf 'A=1\n' >"$CONFIG_DIR/env-open"
chmod 644 "$CONFIG_DIR/env-open"
check "T-18 env file readable by others refused" env_file_refused "$CONFIG_DIR/env-open"
chmod 600 "$CONFIG_DIR/env-open"
check "the same env file accepted once it is 0600" env_file_ok "$CONFIG_DIR/env-open"

# setting.env_file may be written with a leading ~: the layer check and the config
# summary must resolve it exactly like the run path does (they used to look for a
# literal "~" directory and report "env file not found").
tilde_env_report() {
    (
        ENV_FILE="~/.config/claude-dockerized/env"
        check_security_layer 2>&1
    )
}
check_not "layer check finds an env file written with ~" has_text "env file not found" "$(tilde_env_report)"
check "layer check accepts its permissions" has_text "env file permissions ok" "$(tilde_env_report)"
tilde_summary() { (ENV_FILE="~/.config/claude-dockerized/env"; print_config 2>&1); }
check "config summary counts the keys of a ~ env file" has_text "(1 keys)" "$(tilde_summary)"

# --- relay dir: stale relays are removed with rm -rf, so the override is constrained ------
relay_ok() { (GPG_RELAY_DIR="$1"; relay_dir_ok); }
check "relay dir inside CONFIG_DIR accepted" relay_ok "$CONFIG_DIR/gnupg-relay"
check "relay dir named like a relay dir under \$HOME accepted" relay_ok "$HOME/run/gnupg-relay"
check_not "arbitrary \$HOME directory refused as relay dir" relay_ok "$HOME/Documents"
check_not "\$HOME itself refused as relay dir" relay_ok "$HOME"
check_not "/ refused as relay dir" relay_ok /

# --- legitimate mounts keep working -----------------------------------------------------
mkdir -p "$HOME/.config/git"
: >"$HOME/.config/git/gitignore_global"
check "a ~/.config subpath is accepted" mount_ok "~/.config/git/gitignore_global:/home/coder/.config/git/gitignore_global"
check "the git identity file is accepted" mount_ok "~/.gitconfig:/home/coder/.gitconfig"
ln -s "$HOME/data" "$HOME/data-link"
canonical_spec() {
    (
        CUSTOM_MOUNTS=("$1")
        build_mount_args >/dev/null 2>&1 || exit 1
        printf '%s' "${DOCKER_MOUNT_ARGS[1]}"
    )
}
assert_eq "$(canonical_spec "~/data-link:/data")" "$HOME/data:/data:ro" "docker receives the canonical host path"
assert_eq "$(canonical_spec "~/work/../data:/data:rw")" "$HOME/data:/data:rw" "dot-dot segments are resolved"
assert_eq "$(canonical_spec "~/data:/opt//app/./x/../data")" "$HOME/data:/opt/app/data:ro" "target is passed normalised"
check "a mount under /home/coder is accepted" mount_ok "~/data:/home/coder/data"
check "a mount under /opt is accepted" mount_ok "~/data:/opt/data"

t_summary
