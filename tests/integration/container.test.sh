#!/bin/bash
# Container runtime integration test (needs a Docker daemon; skips otherwise).
#
# Starts the real image with the exact flags the wrapper builds
# (build_common_docker_args + build_standard_volume_args) and asserts the
# runtime security contract from inside: non-root, zero capabilities,
# no_new_privs, pinned Claude binary, read-only managed mounts, writable
# project and scratch dir, arbitrary host UIDs. Then runs the guard suites
# inside the image so the image's own bash/jq/node versions are what is tested.
#
# Usage: bash tests/integration/container.test.sh   (IMAGE=... to override)
# shellcheck disable=SC2016,SC2034,SC2317  # probe scripts expand in the container; globals feed config-lib

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
T_SUITE="container"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/../lib/assert.sh"

IMAGE="${IMAGE:-claude-dockerized:latest}"

if ! docker info >/dev/null 2>&1; then
    echo "container: skipped (no Docker daemon)"
    exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "container: building $IMAGE"
    docker build -t "$IMAGE" "$REPO_DIR" || {
        echo "FAIL: image build"
        exit 1
    }
fi

export TMPDIR="${TMPDIR:-/tmp}"
TMP="$(t_tmpdir)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

export HOME="$TMP/home"
export CONFIG_DIR="$HOME/.config/claude-dockerized"
export CCODE_HOME="$CONFIG_DIR/home"
export CLAUDE_DOCKERIZED_ALLOW_CONTAINER_SYNC=1
export CLAUDE_DOCKERIZED_SKIP_LSP_INSTALL=1
export NO_COLOR=1
PROJECT="$HOME/work/proj"
mkdir -p "$PROJECT" "$HOME"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config-lib.sh"
ensure_claude_dirs >/dev/null
parse_config >/dev/null 2>&1 || true
build_common_docker_args >/dev/null
build_standard_volume_args "$PROJECT" false >/dev/null

run_in() {
    docker run --rm -e CLAUDE_DOCKERIZED_WORKDIR=/work/proj --workdir /work/proj \
        "${DOCKER_COMMON_ARGS[@]}" "${VOLUME_ARGS[@]}" "$IMAGE" bash -c "$1"
}

probe="$(run_in '
echo "uid=$(id -u)"
echo "capeff=$(awk "/^CapEff/ {print \$2}" /proc/self/status)"
echo "capbnd=$(awk "/^CapBnd/ {print \$2}" /proc/self/status)"
echo "nnp=$(awk "/^NoNewPrivs/ {print \$2}" /proc/self/status)"
echo "claude_version=$(claude --version 2>/dev/null | cut -d" " -f1)"
[ -f /usr/local/bin/claude ] && [ ! -L /usr/local/bin/claude ] && echo "claude_realfile=yes"
touch /home/coder/.claude/settings.json 2>/dev/null && echo "settings_writable=yes"
touch /home/coder/.claude/hooks-guard/x 2>/dev/null && echo "hooks_writable=yes"
touch /home/coder/.claude/CLAUDE.md 2>/dev/null && echo "rules_writable=yes"
touch /work/proj/.probe 2>/dev/null && echo "project_writable=yes"
mkdir -p /tmp/claude && touch /tmp/claude/.probe 2>/dev/null && echo "scratch_writable=yes"
command -v sudo >/dev/null 2>&1 && echo "sudo_present=yes"
echo "setuid=$(find / -xdev -perm -4000 -type f 2>/dev/null | sort | tr "\n" " ")"
' 2>&1)"
value() { sed -n "s/^$1=//p" <<<"$probe" | head -n1; }

pinned="$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' "$REPO_DIR/Dockerfile" | head -n1)"
uid_ok() { [ "$(value uid)" = "$(id -u)" ] && [ "$(value uid)" != 0 ]; }
check "runs as the host uid, never root" uid_ok
assert_eq "$(value capeff)" 0000000000000000 "no effective capabilities"
assert_eq "$(value capbnd)" 0000000000000000 "empty capability bounding set"
assert_eq "$(value nnp)" 1 "no_new_privs set"
assert_eq "$(value claude_version)" "$pinned" "Claude binary matches the pinned ARG"
assert_eq "$(value claude_realfile)" yes "claude is a real file in /usr/local/bin"
assert_eq "$(value settings_writable)" "" "managed settings.json is read-only"
assert_eq "$(value hooks_writable)" "" "guard hooks are read-only"
assert_eq "$(value rules_writable)" "" "managed CLAUDE.md is read-only"
assert_eq "$(value project_writable)" yes "project is writable"
assert_eq "$(value scratch_writable)" yes "/tmp/claude is writable"
assert_eq "$(value sudo_present)" "" "no privilege-escalation binary in the image"
# Report-only: setuid binaries are neutralized by no_new_privs; removing them
# is the opt-in STRIP_SETUID build (see docs/security/BLUE.md).
echo "container: setuid inventory: $(value setuid)"

# An arbitrary host UID still gets a usable home via --group-add coder.
other="$(docker run --rm --user 4242:4242 --group-add coder --cap-drop=ALL \
    --security-opt no-new-privileges:true "$IMAGE" \
    bash -c 'id -u; touch /home/coder/.cache/claude/.probe && echo home_ok' 2>&1)"
check "arbitrary UID runs non-root" has_line 4242 "$other"
check "arbitrary UID can write the home tree" has_line home_ok "$other"

# Guard suites inside the image (its bash, jq, python3 and node).
for suite in claude-guard guard-failure-modes guard-bypass-corpus guard-eval; do
    out="$(docker run --rm --user "$(id -u):$(id -g)" --cap-drop=ALL \
        --security-opt no-new-privileges:true -v "$REPO_DIR:/repo:ro" "$IMAGE" \
        bash -c "node /repo/tests/$suite.test.mjs" 2>&1)"
    rc=$?
    assert_eq "$rc" 0 "guard suite $suite passes inside the image"
    [ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -20
done

t_summary
