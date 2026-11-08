#!/bin/bash
# Behaviour of the small wrapper commands that had no dedicated test: models,
# stats, debug, exec, uninstall, upgrade, install --only build and the
# wrapper-level refusals (a project that would shadow the image, an env file
# other users can read).
#
# Runs the real bin/claude-dockerized against an isolated HOME with a fake
# `docker` first on PATH (see wrapper-dryrun.test.sh), so no Docker is needed.
#
# Usage: bash tests/commands.test.sh
# shellcheck disable=SC2088,SC2317  # literal ~ is config text; helpers run via check

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="commands"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

export TMPDIR="${TMPDIR:-/tmp/claude}"
TMP="$(t_tmpdir)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

export HOME="$TMP/home"
export CONFIG_DIR="$HOME/.config/claude-dockerized"
export CCODE_HOME="$CONFIG_DIR/home"
export CLAUDE_DOCKERIZED_ALLOW_CONTAINER_SYNC=1
export CLAUDE_DOCKERIZED_SKIP_LSP_INSTALL=1
export NO_COLOR=1
unset SSH_AUTH_SOCK GNUPGHOME DRY_RUN
PROJECT="$HOME/work/proj"
STUB="$TMP/stub"
CALLS="$TMP/calls"
mkdir -p "$PROJECT" "$STUB" "$CALLS" "$CONFIG_DIR"

cat >"$STUB/docker" <<'EOF'
#!/bin/bash
n=$(find "$DOCKER_STUB_CALLS" -type f | wc -l)
printf '%s\n' "$@" >"$DOCKER_STUB_CALLS/$(printf '%04d' "$n")"
case "$1" in
info) exit 0 ;;
image) exit 0 ;;
*) exit 0 ;;
esac
EOF
chmod +x "$STUB/docker"
export DOCKER_STUB_CALLS="$CALLS"
export PATH="$STUB:$REPO_DIR/bin:$PATH"

WRAPPER="$REPO_DIR/bin/claude-dockerized"

# wrapper <args...> — runs the wrapper from the project dir; sets OUT and RC.
wrapper() {
    rm -f "$CALLS"/*
    RC=0
    OUT="$(cd "$PROJECT" && "$WRAPPER" "$@" 2>&1)" || RC=$?
}

last_run() {
    local f
    for f in $(find "$CALLS" -type f | sort -r); do
        if [ "$(head -n1 "$f")" = run ]; then
            cat "$f"
            return 0
        fi
    done
    return 1
}
ran_container() { last_run >/dev/null; }
argv_has() { has_line "$1" "$(last_run)"; }

# --- models -------------------------------------------------------------------------
wrapper models
assert_eq "$RC" 0 "models exits 0"
check "models without a configured model says Claude default" has_text "Claude default" "$OUT"
printf 'setting.model=sonnet\n' >"$CONFIG_DIR/config"
wrapper models
check "models shows the configured model" has_text "Default model: sonnet" "$OUT"
check_not "models never starts a container" ran_container

# --- stats --------------------------------------------------------------------------
wrapper stats
assert_eq "$RC" 0 "stats exits 0"
check "stats names the generated home" has_text "$CCODE_HOME" "$OUT"
check "stats reports a missing login" has_text "login: missing" "$OUT"
mkdir -p "$CCODE_HOME/.claude" "$CCODE_HOME/.local/share/claude"
: >"$CCODE_HOME/.claude/.credentials.json"
wrapper stats
check "stats reports a present login without reading it" has_text "login: present" "$OUT"
check "stats lists the sessions dir size" has_text "$CCODE_HOME/.local/share/claude:" "$OUT"
check_not "stats never prints credential content" has_text "token" "$OUT"
check_not "stats never starts a container" ran_container

# --- debug --------------------------------------------------------------------------
wrapper debug paths
assert_eq "$RC" 0 "debug paths exits 0"
check "debug paths shows the managed policy" has_text "managed-settings.json" "$OUT"
check "debug paths shows the guard hooks dir" has_text "hooks-guard" "$OUT"
check_not "debug paths never starts a container" ran_container
wrapper debug doctor
assert_eq "$RC" 0 "debug doctor exits 0"
check "debug doctor runs claude doctor in the container" argv_has doctor

# --- exec ---------------------------------------------------------------------------
wrapper exec "say hi"
assert_eq "$RC" 0 "exec exits 0"
check "exec runs claude -p with the message" argv_has "-p"
check "exec passes the message" argv_has "say hi"
check "exec honours the configured model" argv_has "sonnet"
wrapper exec
assert_eq "$RC" 1 "exec without a message fails"
check "exec asks for a message" has_text "A message is required" "$OUT"
wrapper exec --dangerously-skip-permissions
assert_eq "$RC" 1 "exec refuses an option in place of the message"
check "exec explains the order" has_text "must come before any option" "$OUT"
check_not "exec never starts a container for a leading option" ran_container

# --- uninstall ----------------------------------------------------------------------
wrapper uninstall
assert_eq "$RC" 0 "uninstall exits 0"
check "uninstall explains the manual steps" has_text "claude-dockerized/bin" "$OUT"
check "uninstall leaves the config alone" has_text "left untouched" "$OUT"
check "uninstall deleted nothing" [ -f "$CONFIG_DIR/config" ]

# --- upgrade / rollback help ----------------------------------------------------------
wrapper upgrade --help
assert_eq "$RC" 0 "upgrade --help exits 0"
check "upgrade --help describes the verified update" has_text "update" "$OUT"
wrapper rollback --help
assert_eq "$RC" 0 "rollback --help exits 0"

# --- wrapper-level refusals -----------------------------------------------------------
mkdir -p "$HOME/usr" "$HOME/etc"
for dir in usr etc; do
    wrapper run "$HOME/$dir"
    assert_eq "$RC" 1 "run refuses ~/$dir (it would shadow /$dir in the image)"
    check "the refusal names the mount point for ~/$dir" has_text "/$dir" "$OUT"
    check_not "no container starts for ~/$dir" ran_container
done

# Secrets are per profile: the env file is <profiles>/default/env (never global).
mkdir -p "$CONFIG_DIR/profiles/default"
printf 'API_KEY=x\n' >"$CONFIG_DIR/profiles/default/env"
chmod 644 "$CONFIG_DIR/profiles/default/env"
: >"$CONFIG_DIR/config"
wrapper run "$PROJECT"
assert_eq "$RC" 1 "run refuses an env file readable by others"
check "the refusal tells how to fix it" has_text "chmod 600" "$OUT"
check_not "no container starts with an exposed env file" ran_container
chmod 600 "$CONFIG_DIR/profiles/default/env"
wrapper run "$PROJECT"
assert_eq "$RC" 0 "run accepts the same env file once it is 0600"
check "the env file reaches docker as --env-file" argv_has --env-file

# --- the bridge default is announced once, and never when a network is chosen (T-06) ---------
rm -f "$CONFIG_DIR/state/network-default-bridge"
sed -i '/^setting.network=/d' "$CONFIG_DIR/config" 2>/dev/null || true
wrapper run "$PROJECT"
check "the first run announces the bridge default" has_text "now defaults to bridge" "$OUT"
wrapper run "$PROJECT"
check_not "the notice is shown only once" has_text "now defaults to bridge" "$OUT"
rm -f "$CONFIG_DIR/state/network-default-bridge"
printf 'setting.network=host\n' >>"$CONFIG_DIR/config"
wrapper run "$PROJECT"
check_not "an explicit network gets no notice" has_text "now defaults to bridge" "$OUT"
check "an explicit host network reaches docker" argv_has host

# --- install --only build -------------------------------------------------------------
# install points the checkout at its upstream; a git stub that refuses
# `git branch` keeps the developer's .git/config untouched.
GIT_STUB="$TMP/git-stub"
mkdir -p "$GIT_STUB"
real_git="$(command -v git)"
cat >"$GIT_STUB/git" <<EOF
#!/bin/bash
for arg in "\$@"; do [ "\$arg" = branch ] && exit 1; done
exec "$real_git" "\$@"
EOF
chmod +x "$GIT_STUB/git"
PATH="$GIT_STUB:$PATH" wrapper install --yes --only build
assert_eq "$RC" 0 "install --only build exits 0"
check "install --only build goes through the wrapper's build" has_text "Building Claude Code Docker image" "$OUT"
check "install --only build records the Claude sha256 (claude --version run)" \
    grep -rqx -- "--entrypoint" "$CALLS"

t_summary
