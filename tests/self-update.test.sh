#!/bin/bash
# Self-update contract (`update` / `upgrade`) against a local bare origin.
#
# The current working tree is committed into a throwaway bare repo; an
# "installed" clone of it runs the real wrapper. docker is stubbed (records
# calls) so rebuilds are observable without a daemon. Covers: --check exit
# codes, --help never touching git, divergence / missing upstream refusals,
# --claude-version validation, and the supply-chain gaps closed in Phase 4.
#
# Usage: bash tests/self-update.test.sh
# shellcheck disable=SC2317  # helpers run via check/gap

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="self-update"
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
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
: >"$GIT_CONFIG_GLOBAL"
mkdir -p "$HOME"

STUB="$TMP/stub"
CALLS="$TMP/calls"
mkdir -p "$STUB" "$CALLS"
cat >"$STUB/docker" <<'EOF'
#!/bin/bash
n=$(find "$DOCKER_STUB_CALLS" -type f | wc -l)
printf '%s\n' "$@" >"$DOCKER_STUB_CALLS/$(printf '%04d' "$n")"
exit 0
EOF
chmod +x "$STUB/docker"
export DOCKER_STUB_CALLS="$CALLS"
export PATH="$STUB:$PATH"

ORIGIN="$TMP/origin.git"
SEED="$TMP/seed"
INSTALL="$TMP/install"

git init -q --bare "$ORIGIN"
mkdir -p "$SEED"
tar -C "$REPO_DIR" --exclude=.git -cf - . | tar -C "$SEED" -xf -
git -C "$SEED" init -q -b master
git -C "$SEED" add -A
git -C "$SEED" commit -q -m "initial"
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -q origin master
git clone -q "$ORIGIN" "$INSTALL"

WRAPPER="$INSTALL/bin/claude-dockerized"

# up <args...> — runs the installed wrapper; sets OUT and RC.
up() {
    rm -f "$CALLS"/*
    RC=0
    OUT="$("$WRAPPER" "$@" 2>&1 </dev/null)" || RC=$?
}
head_of() { git -C "$1" rev-parse HEAD; }
upstream_commit() {
    printf '%s\n' "$1" >>"$SEED/CHANGELOG.test"
    git -C "$SEED" add CHANGELOG.test
    git -C "$SEED" commit -q -m "$1"
    git -C "$SEED" push -q origin master
}
built_image() { grep -rqx build "$CALLS" 2>/dev/null; }
build_arg_set() { grep -rqxF -- "$1" "$CALLS" 2>/dev/null; }

# --- up to date ---------------------------------------------------------------------
up update --check
gap UX-05 "--check exits 0 when up to date" [ "$RC" = 0 ]
before="$(head_of "$INSTALL")"
up update --no-build
gap UX-06 "update when already up to date exits 0" [ "$RC" = 0 ]

# --- --help never touches git or docker -------------------------------------------------
upstream_commit "second"
up update --help
check "--help prints usage" has_text "Usage:" "$OUT"
gap UX-07 "--help does not pull" [ "$(head_of "$INSTALL")" = "$before" ]
git -C "$INSTALL" reset -q --hard "$before"

# --- update available ---------------------------------------------------------------------
up update --check
assert_eq "$RC" 1 "--check exits 1 when an update is available"
assert_eq "$(head_of "$INSTALL")" "$before" "--check never pulls"
check_not "--check never builds" built_image

# --- flag validation -------------------------------------------------------------------------
up update --claude-version 1.2
assert_eq "$RC" 1 "malformed --claude-version refused"
up update --claude-version '2.1.0;id'
assert_eq "$RC" 1 "--claude-version with shell metacharacters refused"
up update --bogus
assert_eq "$RC" 1 "unknown flag refused"
assert_eq "$(head_of "$INSTALL")" "$before" "refused flags never pull"

# --- supply chain (T-12): unsigned upstream code is never applied ---------------------------
up update --yes --no-build
gap T-12 "an unsigned upstream commit is not applied" [ "$(head_of "$INSTALL")" = "$before" ]
git -C "$INSTALL" reset -q --hard "$before"

# --- rebuild after an update records a rollback point (T-13) --------------------------------
up update --yes --claude-version 2.1.300
check "requested Claude version reaches the build" build_arg_set "CLAUDE_CODE_VERSION=2.1.300"
gap T-13 "previous image is tagged for rollback before rebuilding" build_arg_set "claude-dockerized:prev"
git -C "$INSTALL" reset -q --hard "$before"

# --- divergence and missing upstream -----------------------------------------------------------
printf 'local\n' >"$INSTALL/LOCAL.test"
git -C "$INSTALL" add LOCAL.test
git -C "$INSTALL" commit -q -m "local change"
diverged="$(head_of "$INSTALL")"
up update --yes --no-build
assert_eq "$RC" 1 "diverged checkout refused"
assert_eq "$(head_of "$INSTALL")" "$diverged" "diverged checkout left untouched"
check "divergence is explained" has_text "diverged" "$OUT"

git -C "$INSTALL" branch -q --unset-upstream
up update --check
assert_eq "$RC" 1 "missing upstream refused"
check "missing upstream is explained" has_text "upstream" "$OUT"

t_summary
