#!/bin/bash
# End-to-end wrapper contract with a stubbed docker CLI (no Docker needed).
#
# Runs the real bin/claude-dockerized against an isolated HOME/CONFIG_DIR with
# a fake `docker` first on PATH. The stub records every invocation (one
# argument per line) so the full `docker run` argv of each command can be
# asserted: rootless flags, read-only managed mounts, no socket unless opted
# in, host-only refusals and the default (unhardened) runtime profile.
#
# Threats: T-20 (docker socket off by default), T-27 (root refused), T-28
# (rootless flags on every entry point) - see docs/security/THREAT-MODEL.md.
#
# Usage: bash tests/wrapper-dryrun.test.sh
# shellcheck disable=SC2088,SC2317  # literal ~ is config text; helpers run via check/gap

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="wrapper-dryrun"
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
mkdir -p "$PROJECT" "$STUB" "$CALLS"

# Fake docker: records argv, answers `info` / `image inspect`, and returns
# DOCKER_STUB_RUN_RC for `run`.
cat >"$STUB/docker" <<'EOF'
#!/bin/bash
n=$(find "$DOCKER_STUB_CALLS" -type f | wc -l)
printf '%s\n' "$@" >"$DOCKER_STUB_CALLS/$(printf '%04d' "$n")"
case "$1" in
info) exit 0 ;;
image) [ -z "${DOCKER_STUB_NO_IMAGE:-}" ] ;;
run)
    # Simulate a session that plants a file in a persistent path.
    [ -n "${DOCKER_STUB_PLANT:-}" ] && printf '#!/bin/sh\n' >"$DOCKER_STUB_PLANT"
    exit "${DOCKER_STUB_RUN_RC:-0}"
    ;;
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

# last_run — argv (one per line) of the last recorded `docker run`.
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
argv_has_text() { has_text "$1" "$(last_run)"; }
# argv_pair <flag> <value> — the flag is immediately followed by the value.
argv_pair() {
    last_run | grep -qxF -A1 -- "$1" && last_run | grep -xF -A1 -- "$1" | grep -qxF -- "$2"
}

# --- run: rootless runtime + managed mounts -----------------------------------
wrapper run "$PROJECT"
assert_eq "$RC" 0 "run exits 0"
check "run starts a container" ran_container
check "--rm" argv_has --rm
check "--user maps the host uid:gid" argv_pair --user "$(id -u):$(id -g)"
check "--cap-drop=ALL" argv_has --cap-drop=ALL
check "no-new-privileges" argv_pair --security-opt no-new-privileges:true
check "--group-add coder" argv_pair --group-add coder
check "policy mode passed" argv_has "CLAUDE_DOCKERIZED_POLICY=balanced"
check "managed settings mounted read-only" argv_has_text "/.claude/settings.json:/home/coder/.claude/settings.json:ro"
check "guard hooks mounted read-only" argv_has_text "/.claude/hooks-guard:/home/coder/.claude/hooks-guard:ro"
check "managed CLAUDE.md mounted read-only" argv_has_text "/.claude/CLAUDE.md:/home/coder/.claude/CLAUDE.md:ro"
check "project mounted at its home-relative path" argv_has_text "$PROJECT:/work/proj"
check "workdir is the project" argv_pair --workdir /work/proj
check "image then claude as the command" argv_pair "claude-dockerized:latest" claude
check_not "docker socket not mounted by default" argv_has_text "docker.sock"
check_not "wrapper CONFIG_DIR never mounted" argv_has_text "$CONFIG_DIR:"
check_not "~/.ssh never mounted" argv_has_text "$HOME/.ssh:"
check_not "privileged never used" argv_has --privileged

check "managed policy mounted at the managed-settings path" argv_has_text "/.claude/managed-settings.json:/etc/claude-code/managed-settings.json:ro"

# The configured policy is what gets pinned, and a configured model does not
# trigger the old "template overrode" noise (config is parsed before the
# managed layer is generated).
mkdir -p "$CONFIG_DIR"
printf 'setting.security_policy=strict\nsetting.model=sonnet\n' >"$CONFIG_DIR/config"
wrapper run "$PROJECT"
assert_eq "$(cat "$CCODE_HOME/.claude/hooks-guard/policy-mode")" strict "configured policy pinned next to the hooks"
check "configured policy pinned in the managed env" grep -q '"CLAUDE_DOCKERIZED_POLICY": "strict"' "$CCODE_HOME/.claude/managed-settings.json"
check_not "no 'template overrode' warning on a normal run" has_text "overrode" "$OUT"
check "model flag passed" argv_pair claude --model
rm -f "$CONFIG_DIR/config"
wrapper run "$PROJECT"

# Default runtime profile is unchanged (hardening is opt-in, see Phase 3).
check "default network is host" argv_pair --network host
check_not "no read-only rootfs by default" argv_has --read-only
check_not "no pids limit by default" argv_has_text "--pids-limit"

# --- session integrity report (default on) ----------------------------------------
mkdir -p "$PROJECT/.git/hooks"
DOCKER_STUB_PLANT="$PROJECT/.git/hooks/pre-push" wrapper run "$PROJECT"
check "a hook planted during the session is reported" has_text ".git/hooks/pre-push" "$OUT"
check "the report is logged" grep -q 'pre-push' "$CONFIG_DIR/audit/sessions.jsonl"
wrapper run "$PROJECT"
check_not "a clean session reports nothing" has_text "Session integrity" "$OUT"
printf 'setting.integrity_check=false\n' >"$CONFIG_DIR/config"
DOCKER_STUB_PLANT="$PROJECT/.git/hooks/post-merge" wrapper run "$PROJECT"
check_not "integrity_check=false disables the report" has_text "Session integrity" "$OUT"
rm -f "$CONFIG_DIR/config"

# --- other container entry points share the same rootless flags ---------------
wrapper exec "summarize"
check "exec runs claude -p" argv_pair claude -p
check "exec keeps --cap-drop=ALL" argv_has --cap-drop=ALL
check "exec keeps --user" argv_pair --user "$(id -u):$(id -g)"

wrapper auth
check "auth runs claude auth login" argv_pair auth login
check_not "auth mounts no project" argv_has_text "$PROJECT:"
check "auth keeps no-new-privileges" argv_pair --security-opt no-new-privileges:true

wrapper doctor
check "doctor runs a bash script" argv_pair bash -c
check "doctor keeps --cap-drop=ALL" argv_has --cap-drop=ALL

# --- host-only refusals (no container is started) ------------------------------
for sub in "mcp add srv" "mcp remove srv" "plugin install p" "plugin remove p"; do
    # shellcheck disable=SC2086  # intentional word splitting of the subcommand
    wrapper $sub
    assert_eq "$RC" 1 "'$sub' is host-only"
    check_not "'$sub' starts no container" ran_container
done

# --- project directory validation ------------------------------------------------
wrapper run "$HOME"
assert_eq "$RC" 1 "run refuses \$HOME"
check_not "run \$HOME starts no container" ran_container
wrapper run /
assert_eq "$RC" 1 "run refuses /"
wrapper run "$TMP/does-not-exist"
assert_eq "$RC" 1 "run refuses a missing dir"
ln -s "$HOME" "$TMP/home-link"
wrapper run "$TMP/home-link"
assert_eq "$RC" 1 "run refuses a symlink to \$HOME"

# --- missing image ---------------------------------------------------------------
DOCKER_STUB_NO_IMAGE=1 wrapper run "$PROJECT"
assert_eq "$RC" 1 "run fails without the image"
check_not "no container without the image" ran_container

# --- dry run prints instead of running ---------------------------------------------
DRY_RUN=true wrapper run "$PROJECT"
assert_eq "$RC" 0 "dry run exits 0"
check "dry run prints the docker command" has_text "docker run" "$OUT"
check_not "dry run starts no container" ran_container

# --- root is refused before anything else ------------------------------------------
cat >"$STUB/id" <<'EOF'
#!/bin/bash
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
chmod +x "$STUB/id"
wrapper run "$PROJECT"
assert_eq "$RC" 1 "root is refused"
check "root refusal explains why" has_text "Do not run this wrapper as root" "$OUT"
check_not "root starts no container" ran_container
rm -f "$STUB/id"

# --- CLI contract (exit code, pass-through args, help) -------------------------------
DOCKER_STUB_RUN_RC=130 wrapper run "$PROJECT"
assert_eq "$RC" 130 "run propagates the container exit code (UX-01)"
wrapper run "$PROJECT" -- --resume
check "UX-02 run passes extra args to claude" argv_has --resume
wrapper help
check "UX-03 help names the command, not the install path" lacks_text "$REPO_DIR/bin" "$OUT"
wrapper run --help
check "UX-04 run --help prints usage" [ "$RC" = 0 ]

t_summary
