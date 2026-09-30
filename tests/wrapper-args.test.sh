#!/bin/bash
# Contract test for the wrapper's docker argument building and security-layer
# mirroring. No Docker required: it sources config-lib.sh with an isolated
# HOME/CONFIG_DIR and asserts the resulting files and docker flags.
#
# Usage: bash tests/wrapper-args.test.sh
# shellcheck disable=SC2034,SC2088  # globals feed sourced config-lib.sh; literal ~ appears in messages

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export TMPDIR="${TMPDIR:-/tmp/claude}"
mkdir -p "$TMPDIR" 2>/dev/null || export TMPDIR="/tmp"
TMP="$(mktemp -d -p "$TMPDIR")"
trap 'rm -r "$TMP" 2>/dev/null || true' EXIT

# Sync tests run through sync_security_layer, which refuses to run inside
# containers (host-only); allow it here. A dedicated assertion below verifies
# the refusal without this override.
export CLAUDE_DOCKERIZED_ALLOW_CONTAINER_SYNC=1
# Hermetic tests: never install LSP binaries from the network.
export CLAUDE_DOCKERIZED_SKIP_LSP_INSTALL=1
# The GPG command-override seams below are honored only with this opt-in.
export CLAUDE_DOCKERIZED_TEST_HOOKS=1

# Some assertions need a real AF_UNIX socket file; node is the most portable way
# to create one here (present in the image and on CI runners).
have_node=false
command -v node >/dev/null 2>&1 && have_node=true

fail() {
    echo "FAIL: $1"
    exit 1
}

export HOME="$TMP/home"
export CONFIG_DIR="$TMP/cfg"
export CCODE_HOME="$CONFIG_DIR/home"
# Simulate an installed user: this checkout's bin/ is on PATH (Doom-style,
# no symlink in ~/.local/bin). check_global_install requires PATH resolution.
export PATH="$REPO_DIR/bin:$PATH"
PROJECT="$TMP/proj"
CLAUDE_DIR="$CCODE_HOME/.claude"

mkdir -p \
    "$HOME/.mcp-auth" \
    "$HOME/.npm" \
    "$CLAUDE_DIR/hooks-guard" \
    "$CLAUDE_DIR/plugins" \
    "$CCODE_HOME/.local/share/claude" \
    "$CCODE_HOME/.local/state/claude" \
    "$CCODE_HOME/.cache/claude" \
    "$CCODE_HOME/.local/bin" \
    "$CONFIG_DIR/hooks/policies" \
    "$PROJECT"

: >"$HOME/.gitconfig"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config-lib.sh"

# Generate the security layer and mirror it into the generated home.
ensure_claude_dirs

[ -x "$CLAUDE_DIR/hooks-guard/claude-guard-bash.sh" ] ||
    fail "bash guard hook was not mirrored into the generated home"
[ -x "$CLAUDE_DIR/hooks-guard/claude-guard-file.sh" ] ||
    fail "file guard hook was not mirrored into the generated home"
grep -q 'CLAUDE_DOCKERIZED_GUARD_VERSION' "$CLAUDE_DIR/hooks-guard/claude-guard-bash.sh" ||
    fail "mirrored guard is missing its version marker"
[ -f "$CLAUDE_DIR/hooks-guard/guard-eval.js" ] ||
    fail "guard-eval.js was not mirrored into the generated home"
grep -q 'Security Rules' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "security rules were not mirrored into the generated home"
[ -f "$CLAUDE_DIR/hooks-guard/policies/allow-patterns.json" ] ||
    fail "policy patterns were not mirrored into the generated home"

# Versioned policy set: the VERSION marker is seeded and matches the repo copy.
[ -f "$CONFIG_DIR/hooks/policies/VERSION" ] ||
    fail "policy VERSION marker was not seeded"
[ "$(cat "$CONFIG_DIR/hooks/policies/VERSION")" = "$(cat "$REPO_DIR/policies/VERSION")" ] ||
    fail "policy VERSION marker does not match the repo"

# Managed policy (managed-settings.json, mounted at the highest-precedence
# /etc/claude-code path): auto-updates off, bypass disabled, hooks wired,
# policy mode pinned. The user settings.json keeps preferences only.
MANAGED="$CLAUDE_DIR/managed-settings.json"
[ -f "$MANAGED" ] ||
    fail "managed-settings.json was not generated"
grep -q 'DISABLE_AUTOUPDATER' "$MANAGED" ||
    fail "managed policy must disable auto-updates"
grep -q 'disableBypassPermissionsMode' "$MANAGED" ||
    fail "managed policy must disable bypass-permissions mode"
grep -q 'claude-guard-bash.sh' "$MANAGED" ||
    fail "managed policy must wire the bash guard hook"
grep -q 'claude-guard-file.sh' "$MANAGED" ||
    fail "managed policy must wire the file guard hook"
grep -q 'Read(./.env)' "$MANAGED" ||
    fail "managed policy must deny .env reads"
grep -q '"CLAUDE_DOCKERIZED_POLICY": "balanced"' "$MANAGED" ||
    fail "managed policy must pin the policy mode in env"
[ "$(cat "$CLAUDE_DIR/hooks-guard/policy-mode")" = balanced ] ||
    fail "policy mode must be pinned next to the hooks"
[ -f "$CLAUDE_DIR/settings.json" ] ||
    fail "user settings.json was not generated"
if grep -qE '"(hooks|env|sandbox|deny)"' "$CLAUDE_DIR/settings.json"; then
    fail "user settings.json must not carry policy keys (hooks/env/sandbox/deny)"
fi

# GnuPG private keys must be denied by the managed settings and listed as
# secrets in the managed rules (defense in depth even though they are never mounted).
grep -q 'private-keys-v1.d' "$MANAGED" ||
    fail "GnuPG private keys must be denied in the managed settings"
grep -q 'private-keys-v1.d' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "GnuPG private keys must be listed as secrets in the managed rules"

# Managed rules carry the quality bar and the remote-allow section.
grep -q '## Core Workflow' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "Core Workflow section must be present in the managed rules"
grep -q 'Verify by execution' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "Core Workflow must require verification by execution"
grep -q 'Manejo remoto' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "remote-handling section must be present in the managed rules"
grep -q '/etc/claude-code/managed-settings.json' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "managed rules must point at the managed policy"
grep -q 'reported to the user after the session' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "managed rules must explain the session integrity report"
grep -q 'ruff check' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "Python rules must require ruff"
grep -q 'tsc --noEmit' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "JS/TS rules must require tsc --noEmit"
grep -q 'cargo clippy' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "Rust rules must require clippy"
grep -q 'staticcheck' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "Go rules must mention staticcheck"
grep -q 'shellcheck' "$CLAUDE_DIR/CLAUDE.md" ||
    fail "Bash rules must require shellcheck"

# Credentials placeholder exists with 0600.
[ -f "$CCODE_HOME/.claude/.credentials.json" ] ||
    fail "credentials placeholder was not created"
[ "$(stat -c '%a' "$CCODE_HOME/.claude/.credentials.json")" = 600 ] ||
    fail "credentials file must be 600"

build_standard_volume_args "$PROJECT" false
build_common_docker_args

volumes="$(printf '%s\n' "${VOLUME_ARGS[@]}")"
common="$(printf '%s\n' "${DOCKER_COMMON_ARGS[@]}")"

# Managed policy at the managed-settings path, user settings.json alongside,
# both read-only single-file mounts (option A).
grep -qx -- "$CCODE_HOME/.claude/managed-settings.json:/etc/claude-code/managed-settings.json:ro" <<<"$volumes" ||
    fail "managed policy must be mounted read-only at /etc/claude-code/managed-settings.json"
grep -qx -- "$CCODE_HOME/.claude/settings.json:/home/coder/.claude/settings.json:ro" <<<"$volumes" ||
    fail "user settings.json must be mounted read-only (file mount)"

# ~/.claude comes from the generated home read-write (a single-file bind
# would make /model fail with EBUSY); the guard and rules overlay it ro.
grep -qx -- "$CCODE_HOME/.claude:/home/coder/.claude:rw" <<<"$volumes" ||
    fail "generated ~/.claude must be mounted read-write as a directory"
grep -qx -- "$CCODE_HOME/.claude/hooks-guard:/home/coder/.claude/hooks-guard:ro" <<<"$volumes" ||
    fail "hooks-guard must be mounted read-only"
grep -qx -- "$CCODE_HOME/.claude/CLAUDE.md:/home/coder/.claude/CLAUDE.md:ro" <<<"$volumes" ||
    fail "CLAUDE.md must be mounted read-only"
if grep -qE -- ":/home/coder/\.claude/settings\.json" <<<"$volumes"; then
    fail "settings.json must not be a single-file bind (EBUSY on save)"
fi

# The host ~/.claude and the wrapper config dir are never mounted.
if grep -qE -- "^$HOME/\.claude:" <<<"$volumes"; then
    fail "the host ~/.claude must never be mounted"
fi

# MCP state and binaries must be read-write.
grep -qx -- "$CCODE_HOME/.claude.json:/home/coder/.claude.json:rw" <<<"$volumes" ||
    fail ".claude.json must be mounted read-write"
grep -qx -- "$CCODE_HOME/.local/bin:/home/coder/.local/bin:rw" <<<"$volumes" ||
    fail ".local/bin must be mounted read-write (LSP/formatters)"

# MCP OAuth store must be read-write.
grep -qx -- "$HOME/.mcp-auth:/home/coder/.mcp-auth:rw" <<<"$volumes" ||
    fail ".mcp-auth must be mounted read-write"

# ~/.npmrc and ~/.gitconfig are NOT mounted (no secret mounts).
for banned in "$HOME/.npmrc" "$HOME/.gitconfig"; do
    if grep -qF -- "$banned:" <<<"$volumes"; then
        fail "$banned must not be mounted"
    fi
done

# Nothing from the wrapper config dir may be mounted except the generated home
# (CCODE_HOME lives inside CONFIG_DIR). Matching paths, not the project name,
# keeps this independent of where TMPDIR points.
while IFS= read -r vol; do
    case "$vol" in
    "$CCODE_HOME"/* | "$CCODE_HOME":*) ;;
    "$CONFIG_DIR" | "$CONFIG_DIR":* | "$CONFIG_DIR"/*)
        fail "wrapper CONFIG_DIR must not be mounted into the container ($vol)"
        ;;
    esac
done <<<"$volumes"

# No inline permission payloads and no legacy auto-update vars.
if grep -qE 'OPENCODE_|OCODE_' <<<"$common"; then
    fail "legacy env vars must not be passed anymore"
fi

# Security policy mode follows the config (passed with the common args).
grep -qx -- 'CLAUDE_DOCKERIZED_POLICY=balanced' <<<"$(printf '%s\n' "${DOCKER_COMMON_ARGS[@]}")" ||
    fail "policy flag must default to balanced"

# Rootless runtime: the container runs as the host user, never as root.
grep -qx -- '--user' <<<"$common" ||
    fail "--user must be set (rootless runtime)"
grep -qx -- "$(id -u):$(id -g)" <<<"$common" ||
    fail "--user must map the host UID/GID"
grep -qx -- '--group-add' <<<"$common" ||
    fail "--group-add must be set (arbitrary-UID home writes)"
grep -qx -- 'coder' <<<"$common" ||
    fail "--group-add coder value missing"
if grep -q '^HOST_UID=\|^HOST_GID=' <<<"$common"; then
    fail "HOST_UID/HOST_GID must not be passed anymore (no runtime remap)"
fi

# Image contract for the `--group-add coder` above: the image's last USER is
# non-root and the home is owned coder:coder + group-writable.
dockerfile="$REPO_DIR/Dockerfile"
grep -Eq '^[[:space:]]*chown -R coder:coder /home/coder' "$dockerfile" ||
    fail "Dockerfile must chown the home to coder:coder"
grep -Eq '^[[:space:]]*chmod -R g\+rwX /home/coder' "$dockerfile" ||
    fail "Dockerfile must make the home group-writable (chmod -R g+rwX)"
last_user="$(grep -E '^USER ' "$dockerfile" | tail -n1)"
[ "$last_user" = "USER coder" ] ||
    fail "last USER must be 'coder' (non-root image), got: '$last_user'"

# Pinned native install: version ARG, official installer, no npm/pnpm agent install.
grep -Eq '^ARG CLAUDE_CODE_VERSION=2\.1\.284' "$dockerfile" ||
    fail "Dockerfile must pin ARG CLAUDE_CODE_VERSION=2.1.284"
grep -q 'https://claude.ai/install.sh' "$dockerfile" ||
    fail "Dockerfile must use the native installer (claude.ai/install.sh)"
# Image-provided CLIs must live outside the home bin dir: the generated home's
# .local/bin is over-mounted at runtime and would shadow them (claude/uv).
# They must be materialized as real files: the installer lays down symlinks
# into ~/.local/share/claude/versions/, which is itself shadow-mounted.
grep -q '/usr/local/bin' "$dockerfile" ||
    fail "Dockerfile must move image CLIs to /usr/local/bin (home .local/bin is shadow-mounted)"
grep -q 'cp -aL' "$dockerfile" ||
    fail "Dockerfile must dereference installer symlinks (their targets are shadow-mounted too)"
grep -q 'test ! -L /usr/local/bin/claude' "$dockerfile" ||
    fail "Dockerfile must assert the installed claude is a real file, not a link"
if grep -qE 'npm (install|add).*(-g|@anthropic)|pnpm add -g.*@opencode' "$dockerfile"; then
    fail "Dockerfile must not install the agent via npm/pnpm"
fi
grep -Eq '^FROM debian:trixie-slim' "$dockerfile" ||
    fail "Dockerfile must stay on debian:trixie-slim"
# Node (an exact LTS release via NVM) and uv stay; their pins are checked in
# tests/supply-chain.test.sh.
grep -q 'nvm install ${NODE_VERSION}' "$dockerfile" ||
    fail "Dockerfile must keep Node via NVM (pinned NODE_VERSION)"
grep -q 'astral.sh/uv/${UV_VERSION}/install.sh' "$dockerfile" ||
    fail "Dockerfile must keep uv (pinned UV_VERSION)"
grep -Eq '^CMD \["claude"\]' "$dockerfile" ||
    fail 'Dockerfile CMD must be ["claude"]'

# Project confinement: "/", $HOME and any ancestor of $HOME must be refused.
validate_project_dir "$PROJECT" >/dev/null 2>&1 ||
    fail "a project subdirectory must be accepted"
if validate_project_dir "/" >/dev/null 2>&1; then
    fail "must refuse '/' as the project"
fi
if validate_project_dir "$HOME" >/dev/null 2>&1; then
    fail "must refuse \$HOME as the project"
fi
if validate_project_dir "$(dirname "$HOME")" >/dev/null 2>&1; then
    fail "must refuse an ancestor of \$HOME as the project"
fi

# Custom mounts of SSH/GnuPG private material must be refused.
mkdir -p "$HOME/.ssh" "$HOME/.gnupg"
for bad in "$HOME/.ssh" "$HOME/.gnupg"; do
    CUSTOM_MOUNTS=("$bad:/home/coder/leak")
    CUSTOM_MOUNT_KEYS=(bad)
    if (build_mount_args) >/dev/null 2>&1; then
        fail "mounting $bad must be refused"
    fi
done
CUSTOM_MOUNTS=()
CUSTOM_MOUNT_KEYS=()
if add_mount "$HOME/.gnupg" /home/coder/leak >/dev/null 2>&1; then
    fail "add_mount must refuse ~/.gnupg"
fi

# A mount without an absolute container path must be rejected.
CUSTOM_MOUNTS=("/tmp/hostonly")
CUSTOM_MOUNT_KEYS=(bad)
if (build_mount_args) >/dev/null 2>&1; then
    fail "a mount without an absolute container path must be rejected"
fi
CUSTOM_MOUNTS=("/tmp/hostonly:relative")
CUSTOM_MOUNT_KEYS=(bad)
if (build_mount_args) >/dev/null 2>&1; then
    fail "a mount with a relative container path must be rejected"
fi
CUSTOM_MOUNTS=()
CUSTOM_MOUNT_KEYS=()

# Cheap hardening flags.
grep -qx -- '--security-opt' <<<"$common" ||
    fail "--security-opt must be set"
grep -qx -- 'no-new-privileges:true' <<<"$common" ||
    fail "no-new-privileges must be set"
grep -qx -- '--cap-drop=ALL' <<<"$common" ||
    fail "--cap-drop=ALL must be set"

# Docker socket access is a supplementary group, not a root runtime step.
if [ -S /var/run/docker.sock ]; then
    build_standard_volume_args "$PROJECT" true
    volumes_sock="$(printf '%s\n' "${VOLUME_ARGS[@]}")"
    grep -qx -- "$(stat -c '%g' /var/run/docker.sock)" <<<"$volumes_sock" ||
        fail "docker socket GID must be granted via --group-add"
    build_standard_volume_args "$PROJECT" false
fi

# SSH agent forwarding: mount only the agent socket plus the non-secret
# config/known_hosts files (read-only). Private keys must never be mounted.
mkdir -p "$HOME/.ssh"
: >"$HOME/.ssh/config"
: >"$HOME/.ssh/known_hosts"
SSH_AGENT_SUPPORT=true
if [ "$have_node" = true ]; then
    ssh_sock="$TMP/ssh-agent.sock"
    node -e 'require("net").createServer().listen(process.argv[1])' "$ssh_sock" >/dev/null 2>&1 &
    ssh_sock_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$ssh_sock" ] && break; sleep 0.1; done
    SSH_AUTH_SOCK="$ssh_sock"
    build_mount_args
    build_env_args
    ssh_mounts="$(printf '%s\n' "${DOCKER_MOUNT_ARGS[@]}")"
    ssh_envs="$(printf '%s\n' "${DOCKER_ENV_ARGS[@]}")"
    grep -qxF -- "type=bind,source=$ssh_sock,target=$ssh_sock" <<<"$ssh_mounts" ||
        fail "SSH agent socket must be mounted (--mount, not -v)"
    grep -qx -- "$HOME/.ssh/config:/home/coder/.ssh/config:ro" <<<"$ssh_mounts" ||
        fail "~/.ssh/config must be mounted read-only"
    grep -qx -- "$HOME/.ssh/known_hosts:/home/coder/.ssh/known_hosts:ro" <<<"$ssh_mounts" ||
        fail "~/.ssh/known_hosts must be mounted read-only"
    if grep -qE '(^|/)id_|\.ssh:/home/coder/\.ssh(:|$)' <<<"$ssh_mounts"; then
        fail "SSH private material must never be mounted"
    fi
    grep -qx -- "SSH_AUTH_SOCK=$ssh_sock" <<<"$ssh_envs" ||
        fail "SSH_AUTH_SOCK must be passed"
    grep -qx -- 'CLAUDE_DOCKERIZED_SSH_AGENT=true' <<<"$ssh_envs" ||
        fail "doctor SSH flag must be true when forwarding is enabled"
    kill "$ssh_sock_pid" 2>/dev/null || true
    wait "$ssh_sock_pid" 2>/dev/null || true
fi
SSH_AGENT_SUPPORT=false
unset SSH_AUTH_SOCK

# GnuPG agent forwarding: only public material is mirrored and mounted.
mkdir -p "$HOME/.gnupg/private-keys-v1.d"
: >"$HOME/.gnupg/pubring.kbx"
: >"$HOME/.gnupg/gpg.conf"
: >"$HOME/.gnupg/private-keys-v1.d/secret.key"
export GNUPGHOME="$HOME/.gnupg"
GPG_AGENT_SOCKET=""
GPG_AGENT_EXTRA_SOCKET=""
GPG_AGENT_SUPPORT=true
# Keep the test hermetic: never launch a real gpg-agent here.
GPG_AUTOSTART_AGENT=false
build_mount_args
build_env_args
gpg_mounts="$(printf '%s\n' "${DOCKER_MOUNT_ARGS[@]}")"
gpg_envs="$(printf '%s\n' "${DOCKER_ENV_ARGS[@]}")"
grep -qxF -- "type=bind,source=$CCODE_HOME/.gnupg,target=/home/coder/.gnupg" <<<"$gpg_mounts" ||
    fail "GnuPG public keyring must be mounted"
if grep -q 'private-keys-v1.d' <<<"$gpg_mounts"; then
    fail "private-keys-v1.d must never be mounted"
fi
if grep -qF -- "source=$HOME/.gnupg,target" <<<"$gpg_mounts"; then
    fail "host ~/.gnupg must not be mounted directly"
fi
[ -f "$CCODE_HOME/.gnupg/pubring.kbx" ] ||
    fail "public keyring was not mirrored"
if [ -e "$CCODE_HOME/.gnupg/private-keys-v1.d" ]; then
    fail "private keys must not be mirrored"
fi
grep -qx -- 'GNUPGHOME=/home/coder/.gnupg' <<<"$gpg_envs" ||
    fail "GNUPGHOME must point at the mirrored keyring"
grep -qx -- 'CLAUDE_DOCKERIZED_GPG_AGENT=true' <<<"$gpg_envs" ||
    fail "doctor GPG flag must be true when forwarding is enabled"

# The mirrored gpg.conf must disable auto-start (the real agent is on the host).
grep -qE '^[[:space:]]*no-autostart([[:space:]]|$)' "$CCODE_HOME/.gnupg/gpg.conf" ||
    fail "mirrored gpg.conf must contain no-autostart"

# `use-keyboxd` must be mirrored verbatim.
printf 'use-keyboxd\n' >"$HOME/.gnupg/common.conf"
mkdir -p "$HOME/.gnupg/public-keys.d"
: >"$HOME/.gnupg/public-keys.d/pubring.db"
ensure_gpg_mirror
grep -qiE '^[[:space:]]*use-keyboxd([[:space:]]|$)' "$CCODE_HOME/.gnupg/common.conf" ||
    fail "use-keyboxd must be mirrored into common.conf"
[ -f "$CCODE_HOME/.gnupg/public-keys.d/pubring.db" ] ||
    fail "keyboxd public DB must be mirrored"

# A stale keyboxd socket from a previous run must be cleared before mounting.
: >"$CCODE_HOME/.gnupg/S.keyboxd"
ensure_gpg_mirror
[ ! -e "$CCODE_HOME/.gnupg/S.keyboxd" ] ||
    fail "stale keyboxd socket must be cleared from the mirror"

# The image entrypoint must start keyboxd so gpg can read that DB.
grep -q 'gpgconf --launch keyboxd' "$REPO_DIR/entrypoint.sh" ||
    fail "entrypoint must launch keyboxd for GnuPG forwarding"

# The entrypoint must use the wrapper workdir variable (no legacy names).
grep -q 'CLAUDE_DOCKERIZED_WORKDIR' "$REPO_DIR/entrypoint.sh" ||
    fail "entrypoint must resolve CLAUDE_DOCKERIZED_WORKDIR"
if grep -qE 'OCODE|OPENCODE|opencode' "$REPO_DIR/entrypoint.sh"; then
    fail "entrypoint must not mention the previous generation"
fi

# Prefer the restricted "extra" socket; fall back to the main one when missing.
if [ "$have_node" = true ]; then
    gpg_main="$TMP/gpg-main.sock"
    gpg_extra="$TMP/gpg-extra.sock"
    node -e 'require("net").createServer().listen(process.argv[1])' "$gpg_main" >/dev/null 2>&1 &
    gpg_main_pid=$!
    node -e 'require("net").createServer().listen(process.argv[1])' "$gpg_extra" >/dev/null 2>&1 &
    gpg_extra_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -S "$gpg_main" ] && [ -S "$gpg_extra" ] && break
        sleep 0.1
    done

    GPG_AGENT_SOCKET="$gpg_main"
    GPG_AGENT_EXTRA_SOCKET="$gpg_extra"
    build_mount_args
    gpg_sel="$(printf '%s\n' "${DOCKER_MOUNT_ARGS[@]}")"
    grep -qxF -- "type=bind,source=$gpg_extra,target=/home/coder/.gnupg-agent/S.gpg-agent" <<<"$gpg_sel" ||
        fail "restricted extra socket must be preferred as the agent socket"

    # The agent socket must be exposed through a symlink in the mirror, never a
    # nested bind mount (Docker can shadow the latter).
    [ -L "$CCODE_HOME/.gnupg/S.gpg-agent" ] ||
        fail "the mirror must contain an S.gpg-agent symlink"
    [ "$(readlink "$CCODE_HOME/.gnupg/S.gpg-agent")" = "/home/coder/.gnupg-agent/S.gpg-agent" ] ||
        fail "S.gpg-agent symlink must point at the dedicated agent path"
    if grep -qF -- "target=/home/coder/.gnupg/S.gpg-agent" <<<"$gpg_sel"; then
        fail "the agent socket must not be mounted inside the mirror (nested bind)"
    fi

    # Without the restricted extra socket and without explicit opt-in, the main
    # (full-control) socket must NOT be used.
    GPG_ALLOW_MAIN_SOCKET=false
    GPG_AGENT_EXTRA_SOCKET="$TMP/does-not-exist.sock"
    build_mount_args
    gpg_sel="$(printf '%s\n' "${DOCKER_MOUNT_ARGS[@]}")"
    if grep -qF -- "type=bind,source=$gpg_main,target=/home/coder/.gnupg-agent/S.gpg-agent" <<<"$gpg_sel"; then
        fail "main agent socket must not be used without explicit opt-in"
    fi

    # Explicit opt-in allows the fallback.
    GPG_ALLOW_MAIN_SOCKET=true
    build_mount_args
    gpg_sel="$(printf '%s\n' "${DOCKER_MOUNT_ARGS[@]}")"
    grep -qxF -- "type=bind,source=$gpg_main,target=/home/coder/.gnupg-agent/S.gpg-agent" <<<"$gpg_sel" ||
        fail "must fall back to the main agent socket when explicitly allowed"
    GPG_ALLOW_MAIN_SOCKET=false

    kill "$gpg_main_pid" "$gpg_extra_pid" 2>/dev/null || true
    wait "$gpg_main_pid" 2>/dev/null || true
    wait "$gpg_extra_pid" 2>/dev/null || true
fi

# Preflight autostart: with the extra socket missing and autostart enabled, the
# launch command runs and the newly created socket is mounted.
if [ "$have_node" = true ]; then
    lazy_extra="$TMP/lazy-extra.sock"
    GPG_AGENT_SOCKET="$TMP/lazy-main.sock"
    GPG_AGENT_EXTRA_SOCKET="$lazy_extra"
    GPG_AGENT_LAUNCH_CMD="node -e 'require(\"net\").createServer().listen(process.argv[1])' \"$lazy_extra\" & echo \$! > \"$TMP/lazy.pid\""
    GPG_AUTOSTART_AGENT=true
    build_mount_args
    lazy_mounts="$(printf '%s\n' "${DOCKER_MOUNT_ARGS[@]}")"
    grep -qxF -- "type=bind,source=$lazy_extra,target=/home/coder/.gnupg-agent/S.gpg-agent" <<<"$lazy_mounts" ||
        fail "autostart must launch the agent and mount the newly created socket"
    kill "$(cat "$TMP/lazy.pid" 2>/dev/null)" 2>/dev/null || true

    # With autostart disabled the launch command must not run and nothing mounts.
    rm -f "$lazy_extra"
    GPG_AUTOSTART_AGENT=false
    build_mount_args
    if grep -qF -- "type=bind,source=$lazy_extra,target=/home/coder/.gnupg-agent/S.gpg-agent" <<<"$(printf '%s\n' "${DOCKER_MOUNT_ARGS[@]}")"; then
        fail "autostart disabled must not mount a missing socket"
    fi
    unset GPG_AGENT_LAUNCH_CMD
fi

# A stray empty directory at the agent socket path must be removed so the
# agent can create its socket (P0 cleanup).
if [ "$have_node" = true ]; then
    stray_dir="$TMP/stray-gpg.sock"
    mkdir -p "$stray_dir"
    GPG_AGENT_SUPPORT=true
    GPG_AGENT_SOCKET=""
    GPG_AGENT_EXTRA_SOCKET="$stray_dir"
    GPG_AUTOSTART_AGENT=true
    GPG_AGENT_LAUNCH_CMD="node -e 'require(\"net\").createServer().listen(process.argv[1])' \"$stray_dir\" & echo \$! > \"$TMP/stray.pid\""
    build_mount_args
    [ ! -d "$stray_dir" ] || fail "an empty stray directory must be removed before launch"
    [ -S "$stray_dir" ] || fail "the agent socket must exist after the cleanup and launch"
    kill "$(cat "$TMP/stray.pid" 2>/dev/null)" 2>/dev/null || true
    unset GPG_AGENT_LAUNCH_CMD
    GPG_AGENT_SUPPORT=false
fi

# Liveness probe: an existing but unresponsive socket must trigger a launch,
# while a responsive agent must not be relaunched.
if [ "$have_node" = true ]; then
    live_extra="$TMP/live-extra.sock"
    node -e 'require("net").createServer().listen(process.argv[1])' "$live_extra" >/dev/null 2>&1 &
    live_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$live_extra" ] && break; sleep 0.1; done
    GPG_AGENT_SUPPORT=true
    GPG_AGENT_SOCKET=""
    GPG_AGENT_EXTRA_SOCKET="$live_extra"

    rm -f "$TMP/launched.marker"
    GPG_AGENT_PROBE_CMD="true"
    GPG_AUTOSTART_AGENT=true
    GPG_AGENT_LAUNCH_CMD="touch \"$TMP/launched.marker\""
    build_mount_args
    [ ! -e "$TMP/launched.marker" ] ||
        fail "a responsive gpg-agent must not be relaunched"

    GPG_AGENT_PROBE_CMD="false"
    build_mount_args
    [ -e "$TMP/launched.marker" ] ||
        fail "an unresponsive gpg-agent socket must trigger a relaunch"

    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true
    unset GPG_AGENT_PROBE_CMD GPG_AGENT_LAUNCH_CMD
fi

# GPG socket relay: a socket Docker cannot bind (e.g. on tmpfs) is relayed
# through a socket on a normal filesystem.
if [ "$have_node" = true ]; then
    cat >"$TMP/relay.js" <<'EOF'
require("net").createServer().listen(process.env.RELAY_SOCK)
EOF
    real_sock="$TMP/real-agent.sock"
    node -e 'require("net").createServer().listen(process.argv[1])' "$real_sock" >/dev/null 2>&1 &
    real_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$real_sock" ] && break; sleep 0.1; done

    GPG_RELAY_CMD="node $TMP/relay.js"
    relay=$(start_gpg_relay "$real_sock")
    [ -S "$relay" ] || fail "start_gpg_relay must create a listening socket"
    case "$relay" in "$GPG_RELAY_DIR"/*) ;; *) fail "relay socket must live under GPG_RELAY_DIR" ;; esac
    stop_gpg_relay "$relay"
    [ ! -e "$relay" ] || fail "stop_gpg_relay must remove the relay socket"

    # stop_gpg_relay must only touch paths under GPG_RELAY_DIR.
    victim="$TMP/victim-dir"
    mkdir -p "$victim"
    stop_gpg_relay "$victim/S.gpg-agent.extra"
    [ -d "$victim" ] || fail "stop_gpg_relay must not delete paths outside GPG_RELAY_DIR"
    rm -rf "$victim"

    # relay_dir_ok rejects unsafe roots.
    if GPG_RELAY_DIR=/ relay_dir_ok; then
        fail "relay_dir_ok must reject /"
    fi
    GPG_RELAY_DIR="$TMP/cfg/gnupg-relay"

    # Stale relay dirs (dead pid) are purged.
    stale_dir="$GPG_RELAY_DIR/stale-test"
    mkdir -p "$stale_dir"
    echo 999999 >"$stale_dir/pid"
    cleanup_stale_relays
    [ ! -d "$stale_dir" ] || fail "cleanup_stale_relays must remove dead relay dirs"

    # build_mount_args must use the relay when forced (tmpfs case).
    GPG_AGENT_SUPPORT=true
    GPG_AGENT_SOCKET=""
    GPG_AGENT_EXTRA_SOCKET="$real_sock"
    GPG_AUTOSTART_AGENT=false
    GPG_RELAY=true
    GPG_RELAY_FORCE=true
    build_mount_args
    relay_mounts="$(printf '%s\n' "${DOCKER_MOUNT_ARGS[@]}")"
    case "$GPG_RELAY_SOCKET" in "$GPG_RELAY_DIR"/*) ;; *) fail "build_mount_args must start a relay" ;; esac
    grep -qF -- "source=$GPG_RELAY_SOCKET,target=/home/coder/.gnupg-agent/S.gpg-agent" <<<"$relay_mounts" ||
        fail "the mount must use the relay socket"
    stop_gpg_relay "$GPG_RELAY_SOCKET"
    GPG_RELAY_SOCKET=""

    # With the relay disabled, the real socket is mounted directly.
    GPG_RELAY=false
    build_mount_args
    relay_mounts="$(printf '%s\n' "${DOCKER_MOUNT_ARGS[@]}")"
    grep -qF -- "source=$real_sock,target=/home/coder/.gnupg-agent/S.gpg-agent" <<<"$relay_mounts" ||
        fail "with the relay disabled the real socket must be mounted"
    GPG_RELAY=true
    GPG_RELAY_FORCE=false

    kill "$real_pid" 2>/dev/null || true
    wait "$real_pid" 2>/dev/null || true
    unset GPG_RELAY_CMD

    # Overlong relay paths must fail gracefully.
    long_base="$TMP/cfg/$(printf 'd%.0s' $(seq 1 120))"
    GPG_RELAY_DIR_SAVED="$GPG_RELAY_DIR"
    GPG_RELAY_DIR="$long_base"
    if start_gpg_relay "$real_sock" >/dev/null 2>&1; then
        GPG_RELAY_DIR="$GPG_RELAY_DIR_SAVED"
        fail "start_gpg_relay must refuse an overlong socket path"
    fi
    GPG_RELAY_DIR="$GPG_RELAY_DIR_SAVED"
fi
GPG_AGENT_SUPPORT=false
unset GNUPGHOME

# Doctor state flags follow the config (disabled means skipped, not failure).
SSH_AGENT_SUPPORT=false
GPG_AGENT_SUPPORT=false
build_env_args
state_envs="$(printf '%s\n' "${DOCKER_ENV_ARGS[@]}")"
grep -qx -- 'CLAUDE_DOCKERIZED_SSH_AGENT=false' <<<"$state_envs" ||
    fail "doctor SSH flag must reflect the config"
grep -qx -- 'CLAUDE_DOCKERIZED_GPG_AGENT=false' <<<"$state_envs" ||
    fail "doctor GPG flag must reflect the config"

# Secrets file (setting.env_file): consumed host-side, never mounted.
printf 'ANTHROPIC_API_KEY=test-key\n# comment\n\nPLAIN_OK=1\n' >"$CONFIG_DIR/env"
chmod 600 "$CONFIG_DIR/env"
ENV_FILE="$CONFIG_DIR/env"
build_env_file_args
envfile_args="$(printf '%s\n' "${DOCKER_ENV_FILE_ARGS[@]}")"
grep -qxF -- "--env-file" <<<"$envfile_args" || fail "--env-file flag missing"
grep -qxF -- "$CONFIG_DIR/env" <<<"$envfile_args" || fail "env file path missing"
build_mount_args
if grep -qF -- "$CONFIG_DIR/env" <<<"$(printf '%s\n' "${DOCKER_MOUNT_ARGS[@]}")"; then
    fail "env file must never be mounted"
fi
# Outside CONFIG_DIR it must be refused (could be mounted).
ENV_FILE="$TMP/outside.env"
: >"$TMP/outside.env"
if (build_env_file_args) >/dev/null 2>&1; then
    fail "env file outside CONFIG_DIR must be refused"
fi
# Missing file must fail loudly.
ENV_FILE="$CONFIG_DIR/does-not-exist.env"
if (build_env_file_args) >/dev/null 2>&1; then
    fail "missing env file must fail"
fi
ENV_FILE=""

# env_file_upsert: create/replace/preserve/permissions; value never printed.
UPF="$TMP/envtest"
env_file_upsert "$UPF" FOO first >/dev/null || fail "upsert must create"
[ "$(stat -c '%a' "$UPF")" = 600 ] || fail "env file must be 600"
env_file_upsert "$UPF" BAR second >/dev/null || fail "upsert must append"
printf '# comment\n' >>"$UPF"
env_file_upsert "$UPF" FOO third >/dev/null || fail "upsert must replace"
[ "$(grep -c '^FOO=' "$UPF")" -eq 1 ] || fail "replaced key must not duplicate"
grep -qx 'BAR=second' "$UPF" || fail "other keys preserved"
grep -qx '# comment' "$UPF" || fail "comments preserved"
if env_file_upsert "$UPF" 'bad-name' x >/dev/null 2>&1; then
    fail "invalid names must be rejected"
fi
out=$(env_file_upsert "$UPF" FOO third 2>&1)
grep -q 'third' <<<"$out" && fail "value must never be printed"
[ "$(grep -c '^FOO=third$' "$UPF")" -eq 1 ] || fail "idempotent replace"

# migrate_legacy_env_vars: moves values from host env, reports names only.
printf 'env.mig1=MIG_TEST_VAR\nsetting.gpg_agent_support=false\n' >"$CONFIG_FILE"
export MIG_TEST_VAR="mig-test-value"
mig_out=$(printf 'Y\n' | migrate_legacy_env_vars 2>&1)
grep -q 'MIG_TEST_VAR' <<<"$mig_out" || fail "migration must report key names"
grep -qx 'MIG_TEST_VAR=mig-test-value' "$CONFIG_DIR/env" || fail "migration must write the value"
[ "$(stat -c '%a' "$CONFIG_DIR/env")" = 600 ] || fail "migrated env file must be 600"
if grep -q 'mig-test-value' <<<"$mig_out"; then
    fail "migration must never print values"
fi
unset MIG_TEST_VAR

# Optional model is honored (passed as CLI flag by the wrapper, stored for doctor).
CLAUDE_MODEL="sonnet"
[ "$CLAUDE_MODEL" = "sonnet" ] || fail "model must load"
CLAUDE_MODEL='x";evil'
if [[ "$CLAUDE_MODEL" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "invalid model must be rejected by validation"
fi
CLAUDE_MODEL=""

# Cleanup days accept integers and reject the rest.
printf 'setting.cleanup_days=30\n' >"$CONFIG_FILE"
load_config >/dev/null 2>&1 || true
[ "$CLEANUP_DAYS" = "30" ] || fail "valid cleanup_days must load"
printf 'setting.cleanup_days=never\n' >"$CONFIG_FILE"
load_config >/dev/null 2>&1 || true
[ "$CLEANUP_DAYS" = "7" ] || fail "invalid cleanup_days must keep the default"

# LSP settings load; unknown servers are warned but kept for the doctor to report.
printf 'setting.lsp=true\nsetting.lsp_servers=go,ts\nsetting.formatters=true\n' >"$CONFIG_FILE"
load_config >/dev/null 2>&1 || true
[ "$LSP_ENABLED" = true ] || fail "lsp must load"
[ "$LSP_SERVERS" = "go,ts" ] || fail "lsp_servers must load"
[ "$FORMATTERS_ENABLED" = true ] || fail "formatters must load"
ensure_claude_dirs
[ -f "$CLAUDE_DIR/.lsp.json" ] || fail ".lsp.json must be generated when lsp is enabled"
grep -q 'gopls' "$CLAUDE_DIR/.lsp.json" || fail ".lsp.json must contain gopls"
LSP_ENABLED=false
FORMATTERS_ENABLED=false

# Removed settings warn instead of failing.
printf 'setting.websearch_provider=exa\nsetting.theme=catppuccin\n' >"$CONFIG_FILE"
removed_out=$(load_config 2>&1) || true
grep -q 'Ignoring removed setting' <<<"$removed_out" || fail "removed settings must warn"

# Inline secrets in the user settings must block the run.
user_settings="$CLAUDE_DIR/settings.json"
cp "$user_settings" "$TMP/settings.json.orig"
printf '{"permissions":{"deny":[]},"env":{"ANTHROPIC_API_KEY":"live-secret"}}' >"$user_settings"
if (validate_claude_config) >/dev/null 2>&1; then
    cp "$TMP/settings.json.orig" "$user_settings"
    fail "inline secrets must block the run"
fi
cp "$TMP/settings.json.orig" "$user_settings"

# Optional resource limits are honored.
MEMORY="4g"
CPUS="2"
build_common_docker_args
common_lim="$(printf '%s\n' "${DOCKER_COMMON_ARGS[@]}")"
grep -qx -- '--memory' <<<"$common_lim" || fail "--memory not added when setting.memory is set"
grep -qx -- '4g' <<<"$common_lim" || fail "memory value not passed"
grep -qx -- '--cpus' <<<"$common_lim" || fail "--cpus not added when setting.cpus is set"
grep -qx -- '2' <<<"$common_lim" || fail "cpus value not passed"

# Container network defaults to host, honors bridge, and rejects garbage.
NETWORK="host"
build_common_docker_args
common_net="$(printf '%s\n' "${DOCKER_COMMON_ARGS[@]}")"
grep -qx -- '--network' <<<"$common_net" || fail "--network flag missing"
grep -qx -- 'host' <<<"$common_net" || fail "default network must be host"
NETWORK="bridge"
build_common_docker_args
common_net="$(printf '%s\n' "${DOCKER_COMMON_ARGS[@]}")"
grep -qx -- 'bridge' <<<"$common_net" || fail "bridge network must be honored"
NETWORK="bogus"
build_common_docker_args
common_net="$(printf '%s\n' "${DOCKER_COMMON_ARGS[@]}")"
grep -qx -- 'host' <<<"$common_net" || fail "invalid network must fall back to host"
if grep -qx -- 'bogus' <<<"$common_net"; then
    fail "invalid network value must never reach docker"
fi
NETWORK="host"

# config sync refreshes a stale guard copy (and --check detects drift).
printf '// CLAUDE_DOCKERIZED_GUARD_VERSION=0\n' >"$CONFIG_DIR/hooks/claude-guard-bash.sh"
if sync_security_layer --check >/dev/null 2>&1; then
    fail "--check must detect a stale guard copy"
fi
sync_security_layer >/dev/null 2>&1 || fail "sync must refresh a stale guard copy"
[ -f "$CONFIG_DIR/hooks/claude-guard-bash.sh.bak" ] ||
    fail "sync must back up the stale guard copy"
sync_security_layer --check >/dev/null 2>&1 || fail "must be in sync after refresh"

# Tampering with the managed policy is drift: --check reports it (content
# comparison, not a version marker) and sync restores the template.
printf '{"hooks":{}}\n' >"$MANAGED"
if sync_security_layer --check >/dev/null 2>&1; then
    fail "--check must detect a tampered managed policy"
fi
sync_security_layer >/dev/null 2>&1 || fail "sync must restore the managed policy"
grep -q 'claude-guard-bash.sh' "$MANAGED" || fail "sync must rewire the hooks in the managed policy"

# Content integrity (T-15): an installed hook edited without touching its
# version marker, or a tampered mirror, is drift; sync restores the repo copy
# and keeps a backup of the edited one.
printf '\nexit 0 # tampered\n' >>"$CONFIG_DIR/hooks/claude-guard-file.sh"
if sync_security_layer --check >/dev/null 2>&1; then
    fail "--check must detect an edited hook that keeps its version marker"
fi
sync_security_layer >/dev/null 2>&1 || fail "sync must restore an edited hook"
cmp -s "$REPO_DIR/hooks/claude-guard-file.sh" "$CONFIG_DIR/hooks/claude-guard-file.sh" ||
    fail "sync must restore the repo copy of the edited hook"
grep -q 'tampered' "$CONFIG_DIR/hooks/claude-guard-file.sh.bak" ||
    fail "sync must back up the edited hook"
printf '[]' >"$CLAUDE_DIR/hooks-guard/policies/unsafe-tool-patterns.json"
if sync_security_layer --check >/dev/null 2>&1; then
    fail "--check must detect a tampered policy mirror"
fi
sync_security_layer >/dev/null 2>&1 || fail "sync must re-mirror the policies"
cmp -s "$REPO_DIR/policies/unsafe-tool-patterns.json" "$CLAUDE_DIR/hooks-guard/policies/unsafe-tool-patterns.json" ||
    fail "sync must restore the mirrored deny set"

# Merge: a user settings.json with extras keeps them, drops policy keys the
# template no longer carries (deny/hooks live in the managed policy; a stray
# disableAllHooks would silence it) and stays valid JSON.
user_settings="$CLAUDE_DIR/settings.json"
node -e '
const fs = require("node:fs");
const p = process.argv[1];
const s = JSON.parse(fs.readFileSync(p, "utf8"));
s.permissions.allow.push("Bash(mycmd *)");
s.permissions.deny = ["Bash(everything *)"];
s.disableAllHooks = true;
s.customUserKey = { keep: true };
fs.writeFileSync(p, JSON.stringify(s, null, 2));
' "$user_settings"
sync_out=$(sync_security_layer 2>&1) || fail "sync with user extras must succeed"
grep -qF -- 'Bash(mycmd *)' "$user_settings" ||
    fail "merge must preserve custom allow entries"
grep -qF -- 'customUserKey' "$user_settings" ||
    fail "merge must preserve unknown user keys"
if grep -qF -- 'Bash(everything *)' "$user_settings"; then
    fail "merge must drop user deny rules (policy lives in the managed file)"
fi
if grep -q 'disableAllHooks' "$user_settings"; then
    fail "merge must drop disableAllHooks"
fi
grep -q 'overrode' <<<"$sync_out" ||
    fail "merge must report overridden keys"
if command -v node >/dev/null 2>&1; then
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$user_settings" ||
        fail "merged settings.json must be valid JSON"
fi
rm -f "$user_settings.bak"

# Broken settings.json is backed up and reseeded, never silently dropped.
printf 'not json{{{' >"$user_settings"
sync_security_layer >/dev/null 2>&1 || fail "sync must survive broken settings.json"
[ -f "$user_settings.bak" ] || fail "broken settings.json must be backed up"
grep -q 'enabledPlugins' "$user_settings" || fail "settings.json must be reseeded"

# --check must not write anything.
before_hashes=$(find "$CONFIG_DIR" "$CCODE_HOME" -type f -exec md5sum {} + 2>/dev/null | sort)
sync_security_layer --check >/dev/null 2>&1 || fail "must be in sync now"
after_hashes=$(find "$CONFIG_DIR" "$CCODE_HOME" -type f -exec md5sum {} + 2>/dev/null | sort)
[ "$before_hashes" = "$after_hashes" ] || fail "--check must not modify files"

# Empty/valid settings load silently; invalid memory/cpus are ignored.
printf 'setting.model=sonnet\nsetting.memory=2g\nsetting.cpus=1.5\nsetting.cleanup_days=7\n' >"$CONFIG_FILE"
load_config >"$TMP/load.out" 2>&1 || true
if [ -s "$TMP/load.out" ]; then
    cat "$TMP/load.out"
    fail "valid settings must load silently"
fi
[ "$MEMORY" = "2g" ] || fail "valid memory must load"
[ "$CPUS" = "1.5" ] || fail "valid cpus must load"
[ "$CLAUDE_MODEL" = "sonnet" ] || fail "valid model must load"
printf 'setting.memory=bogus\nsetting.cpus=9x\nsetting.model=x";evil\n' >"$CONFIG_FILE"
load_config >/dev/null 2>&1 || true
[ -z "$MEMORY" ] || fail "invalid memory must be ignored"
[ -z "$CPUS" ] || fail "invalid cpus must be ignored"
[ -z "$CLAUDE_MODEL" ] || fail "invalid model must be ignored"

# sync rejects unknown arguments.
if sync_security_layer --bogus >/dev/null 2>&1; then
    fail "sync must reject unknown arguments"
fi

# PATH install watch: nothing may live in ~/.local/bin; a legacy symlink is
# stale and sync removes it, while a real file is never touched.
mkdir -p "$HOME/.local/bin" 2>/dev/null || true
ln -sf "$REPO_DIR/bin/claude-dockerized" "$HOME/.local/bin/claude-dockerized" 2>/dev/null || true
if check_global_install >/dev/null 2>&1; then
    # If PATH happens to resolve (CI images with bin/ on PATH), the legacy
    # symlink still counts as stale only via the dedicated assertion below.
    :
fi
sync_security_layer >/dev/null 2>&1 || fail "sync must succeed with a legacy symlink present"
[ ! -L "$HOME/.local/bin/claude-dockerized" ] ||
    fail "sync must remove the legacy ~/.local/bin symlink (nothing lives there anymore)"
# A non-symlink file must survive sync untouched.
printf 'not-a-link' >"$HOME/.local/bin/claude-dockerized"
sync_security_layer >/dev/null 2>&1 || fail "sync must succeed with a real file present"
[ -f "$HOME/.local/bin/claude-dockerized" ] && [ ! -L "$HOME/.local/bin/claude-dockerized" ] ||
    fail "sync must not replace a non-symlink file"
grep -qx 'not-a-link' "$HOME/.local/bin/claude-dockerized" ||
    fail "sync must not modify a real file"
rm -f "$HOME/.local/bin/claude-dockerized" 2>/dev/null
# repo_script_path must point at bin/claude-dockerized (no .sh, no symlink).
[ "$(repo_script_path)" = "$(readlink -f "$REPO_DIR/bin/claude-dockerized")" ] ||
    fail "repo_script_path must point at bin/claude-dockerized"

# sync is host-only: inside a container it must refuse (unless overridden).
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    if (unset CLAUDE_DOCKERIZED_ALLOW_CONTAINER_SYNC; sync_security_layer --check) >/dev/null 2>&1; then
        fail "sync must refuse inside containers"
    fi
fi

# NO_COLOR strips ANSI codes (TERM=dumb behaves the same).
if NO_COLOR=1 bash -c 'source "$0" >/dev/null 2>&1; config_info hi' "$REPO_DIR/lib/config-lib.sh" | grep -q $'\x1b'; then
    fail "NO_COLOR must strip ANSI codes"
fi
if TERM=dumb bash -c 'source "$0" >/dev/null 2>&1; config_info hi' "$REPO_DIR/lib/config-lib.sh" | grep -q $'\x1b'; then
    fail "dumb terminals must not get ANSI codes"
fi

# Model/cleanup/LSP/formatters prompts accept valid values and reject the rest.
prompt_model >/dev/null <<EOF
not a model!!
EOF
[ -z "$CLAUDE_MODEL" ] || fail "invalid model must be rejected"
prompt_model >/dev/null <<EOF
sonnet
EOF
[ "$CLAUDE_MODEL" = "sonnet" ] || fail "valid model must be accepted"
prompt_cleanup_days >/dev/null <<EOF
never
EOF
[ "$CLEANUP_DAYS" = "7" ] || fail "invalid cleanup_days must keep the previous value"
prompt_lsp >/dev/null <<EOF
n
EOF
[ "$LSP_ENABLED" = false ] || fail "declined LSP must stay disabled"
prompt_formatters >/dev/null <<EOF
n
EOF
[ "$FORMATTERS_ENABLED" = false ] || fail "declined formatters must stay disabled"
CLAUDE_MODEL=""
CLEANUP_DAYS="7"
LSP_ENABLED=false
FORMATTERS_ENABLED=false

# Drift hint appears only when stale.
printf '// CLAUDE_DOCKERIZED_GUARD_VERSION=0\n' >"$CONFIG_DIR/hooks/claude-guard-bash.sh"
hint=$(maybe_drift_hint 2>&1) || true
grep -q 'config sync' <<<"$hint" || fail "drift hint must mention config sync"
sync_security_layer >/dev/null 2>&1 || fail "sync must refresh"
hint=$(maybe_drift_hint 2>&1) || true
[ -z "$hint" ] || fail "no hint when in sync"

# dry_run_print: one flag per line, *_CONTENT redacted.
dry_out=$(dry_run_print docker run -it --name x -e TERM=t -e 'FOO_CONTENT={"a":1}' --env-file /tmp/f image claude)
grep -qx 'docker run' <<<"$dry_out" || fail "dry run must start with a header line"
[ "$(printf '%s' "$dry_out" | wc -l)" -gt 3 ] || fail "dry run must be multiline"
grep -qx '  <redacted>' <<<"$dry_out" || fail "dry run must redact *_CONTENT values"
if grep -q '{"a":1}' <<<"$dry_out"; then
    fail "dry run must not leak redacted values"
fi

# Config mode select must not hang on EOF (existing config file present).
if command -v timeout >/dev/null 2>&1; then
    if ! printf '' | timeout 10 bash -c 'source "$0" >/dev/null 2>&1; prompt_config_mode' "$REPO_DIR/lib/config-lib.sh" >/dev/null 2>&1; then
        fail "prompt_config_mode must survive EOF"
    fi
fi

# Doctor inner script must stay syntactically valid.
bash -n "$REPO_DIR/lib/doctor-container.sh" ||
    fail "doctor inner script must pass bash -n"

# `claude-dockerized install` flags: --help, unknown options, and fully non-interactive --yes.
"$REPO_DIR/bin/claude-dockerized" install --help >/dev/null 2>&1 || fail "install --help must exit 0"
if "$REPO_DIR/bin/claude-dockerized" install --bogus >/dev/null 2>&1; then
    fail "install must reject unknown options"
fi
if "$REPO_DIR/bin/claude-dockerized" install --only bogus >/dev/null 2>&1; then
    fail "install must reject unknown --only sections"
fi
SETUP_HOME="$TMP/setuphome"
mkdir -p "$SETUP_HOME"
: >"$SETUP_HOME/.bashrc"
: >"$SETUP_HOME/.zshrc"
: >"$SETUP_HOME/.bashrc"
if ! env -u CONFIG_DIR -u CCODE_HOME HOME="$SETUP_HOME" "$REPO_DIR/bin/claude-dockerized" install --yes --only global <&- >/dev/null 2>&1; then
    fail "install --yes --only global must succeed with closed stdin"
fi
[ ! -L "$SETUP_HOME/.local/bin/claude-dockerized" ] ||
    fail "install must never create a symlink in ~/.local/bin"
grep -qF -- 'claude-dockerized/bin' "$SETUP_HOME/.bashrc" ||
    fail "install --yes --only global must add bin/ to PATH"
if ! env -u CONFIG_DIR -u CCODE_HOME HOME="$SETUP_HOME" "$REPO_DIR/bin/claude-dockerized" install --yes <&- >/dev/null 2>&1; then
    fail "install --yes must succeed with closed stdin"
fi
[ -f "$SETUP_HOME/.config/claude-dockerized/config" ] ||
    fail "install --yes must create the default config"

# resolve_editor prefers $EDITOR, falls back, or fails cleanly.
[ "$(EDITOR=myeditor resolve_editor)" = myeditor ] || fail "resolve_editor must prefer EDITOR"
if PATH=/nonexistent-tmp-dir resolve_editor >/dev/null 2>&1; then
    fail "resolve_editor must fail with no editors on PATH"
fi

# Stale managed aliases migrate to the PATH-based form; foreign same-name
# lines survive.
ALIAS_HOME="$TMP/aliashome"
mkdir -p "$ALIAS_HOME"
printf '# Claude Dockerized aliases\nalias ccd='"'"'/OLD/path/claude-dockerized.sh'"'"'\nalias myown='"'"'echo hi'"'"'\n' >"$ALIAS_HOME/.bashrc"
env -u CONFIG_DIR -u CCODE_HOME HOME="$ALIAS_HOME" "$REPO_DIR/bin/claude-dockerized" install --yes --only aliases <&- >/dev/null 2>&1 ||
    fail "install --yes --only aliases must succeed"
grep -qxF -- "alias ccd='claude-dockerized'" "$ALIAS_HOME/.bashrc" ||
    fail "stale alias must migrate to the PATH-based form"
grep -qxF -- "alias ccd-run='claude-dockerized run'" "$ALIAS_HOME/.bashrc" ||
    fail "missing alias must be added in PATH form"
grep -qxF -- "alias myown='echo hi'" "$ALIAS_HOME/.bashrc" ||
    fail "custom lines must be preserved"
[ "$(grep -c '^alias ccd=' "$ALIAS_HOME/.bashrc")" -eq 1 ] ||
    fail "no duplicate alias lines"
env -u CONFIG_DIR -u CCODE_HOME HOME="$ALIAS_HOME" "$REPO_DIR/bin/claude-dockerized" install --yes --only aliases <&- >/dev/null 2>&1 ||
    fail "re-run must succeed"
[ "$(grep -c '^alias ccd=' "$ALIAS_HOME/.bashrc")" -eq 1 ] ||
    fail "re-run must stay idempotent"
# Installing aliases must never create a symlink; the command comes from PATH.
[ ! -L "$ALIAS_HOME/.local/bin/claude-dockerized" ] ||
    fail "alias install must not create a ~/.local/bin symlink"

# --only limits sections: global-only run touches no completions/aliases/config.
ONLY_HOME="$TMP/onlyhome"
mkdir -p "$ONLY_HOME"
: >"$ONLY_HOME/.bashrc"
env -u CONFIG_DIR -u CCODE_HOME HOME="$ONLY_HOME" "$REPO_DIR/bin/claude-dockerized" install --yes --only global <&- >/dev/null 2>&1 ||
    fail "install --yes --only global must succeed"
[ ! -L "$ONLY_HOME/.local/bin/claude-dockerized" ] ||
    fail "--only global must never create a symlink"
grep -qF -- 'claude-dockerized/bin' "$ONLY_HOME/.bashrc" ||
    fail "--only global must add bin/ to PATH"
if grep -q "Claude Dockerized completion" "$ONLY_HOME/.bashrc"; then
    fail "--only global must not touch completions"
fi
if grep -q "Claude Dockerized aliases" "$ONLY_HOME/.bashrc"; then
    fail "--only global must not touch aliases"
fi
[ ! -e "$ONLY_HOME/.config/claude-dockerized/config" ] ||
    fail "--only global must not create config"

# bin/ must hold only the claude-dockerized binary (no second install binary).
[ -x "$REPO_DIR/bin/claude-dockerized" ] ||
    fail "bin/claude-dockerized must exist and be executable"
[ ! -e "$REPO_DIR/bin/install" ] ||
    fail "bin/install must not exist (bin/ holds only claude-dockerized)"
[ ! -e "$REPO_DIR/bin/opencode-dockerized" ] ||
    fail "bin/opencode-dockerized must not exist anymore"

# Piped/curl installs (closed stdin, no --yes) must still perform the full
# setup: config, PATH, completions and aliases — no second manual run needed.
PIPE_HOME="$TMP/pipehome"
mkdir -p "$PIPE_HOME"
: >"$PIPE_HOME/.bashrc"
: >"$PIPE_HOME/.zshrc"
if ! env -u CONFIG_DIR -u CCODE_HOME HOME="$PIPE_HOME" "$REPO_DIR/bin/claude-dockerized" install <&- >/dev/null 2>&1; then
    fail "install with closed stdin and no --yes must succeed (auto --yes)"
fi
[ -f "$PIPE_HOME/.config/claude-dockerized/config" ] ||
    fail "piped install must create the default config"
grep -qF -- 'claude-dockerized/bin' "$PIPE_HOME/.bashrc" ||
    fail "piped install must add bin/ to PATH"
grep -qF -- "alias ccd='claude-dockerized'" "$PIPE_HOME/.bashrc" ||
    fail "piped install must add aliases"
grep -q "Claude Dockerized completion" "$PIPE_HOME/.bashrc" ||
    fail "piped install must add completions"

# config sync must remove the obsolete second install binary when present.
: >"$CONFIG_DIR/hooks/policies/VERSION"
touch "$CCODE_BIN_DIR" 2>/dev/null || true
STALE_BIN="$TMP/stale-bin-install"
mkdir -p "$STALE_BIN"
: >"$STALE_BIN/install"
CCODE_BIN_DIR_SAVED="$CCODE_BIN_DIR"
CCODE_BIN_DIR="$STALE_BIN"
sync_security_layer >/dev/null 2>&1 || true
CCODE_BIN_DIR="$CCODE_BIN_DIR_SAVED"
[ ! -e "$STALE_BIN/install" ] ||
    fail "sync must remove the obsolete install binary"

# No previous-generation names anywhere except marked migration lines and
# vendored-policy attribution (see PLAN.md acceptance).
if grep -rniE 'opencode|OCODE|OPENCODE' --exclude-dir=.git --exclude=PLAN.md "$REPO_DIR" 2>/dev/null \
    | grep -v 'policies/LICENSE.opencode-policy' \
    | grep -v 'policies/README.md' \
    | grep -v 'tests/security-guard.test.mjs' \
    | grep -v 'tests/wrapper-args.test.sh' \
    | grep -v 'legacy-migration' \
    | grep -q .; then
    grep -rniE 'opencode|OCODE|OPENCODE' --exclude-dir=.git --exclude=PLAN.md "$REPO_DIR" 2>/dev/null \
        | grep -v 'policies/LICENSE.opencode-policy' \
        | grep -v 'policies/README.md' \
        | grep -v 'tests/security-guard.test.mjs' \
        | grep -v 'tests/wrapper-args.test.sh' \
        | grep -v 'legacy-migration'
    fail "previous-generation names must not remain outside migration markers and attribution"
fi

echo "wrapper-args test passed"
