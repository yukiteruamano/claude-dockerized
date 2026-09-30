#!/bin/bash
# Verified self-update contract (`update` / `upgrade` / `rollback`) against a
# local bare origin, with an ephemeral OpenPGP release key (T-12, T-13).
#
# The current working tree is committed into a throwaway bare repo and an
# "installed" clone of it runs the real wrapper; docker is stubbed (records
# calls). Covers: --check exit codes, --help, flag validation, origin
# pinning, signed/unsigned/untrusted/rewritten tags, preview, fast-forward
# only, rollback point, rollback, Claude version pin, divergence.
#
# Usage: bash tests/self-update.test.sh
# shellcheck disable=SC2317  # helpers run via check

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="self-update"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

if ! command -v gpg >/dev/null 2>&1; then
    echo "self-update: skipped (gpg not installed)"
    exit 0
fi

export TMPDIR="${TMPDIR:-/tmp/claude}"
TMP="$(t_tmpdir)"
cleanup() {
    GNUPGHOME="$SIGNER" gpgconf --kill all >/dev/null 2>&1 || true
    GNUPGHOME="$OTHER" gpgconf --kill all >/dev/null 2>&1 || true
    rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

export HOME="$TMP/home"
export CONFIG_DIR="$HOME/.config/claude-dockerized"
export CCODE_HOME="$CONFIG_DIR/home"
export CLAUDE_DOCKERIZED_ALLOW_CONTAINER_SYNC=1
export CLAUDE_DOCKERIZED_SKIP_LSP_INSTALL=1
export NO_COLOR=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
: >"$GIT_CONFIG_GLOBAL"
mkdir -p "$HOME"

# --- ephemeral release keys: the maintainer's and an impostor's --------------------
SIGNER="$TMP/signer-gnupg"
OTHER="$TMP/other-gnupg"
mkdir -m 700 "$SIGNER" "$OTHER"
gen_key() {
    GNUPGHOME="$1" gpg --batch --quiet --passphrase '' --quick-gen-key "$2" ed25519 sign never 2>/dev/null
    GNUPGHOME="$1" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'
}
SIGNER_FPR="$(gen_key "$SIGNER" "Release <release@example.invalid>")"
OTHER_FPR="$(gen_key "$OTHER" "Impostor <impostor@example.invalid>")"
GNUPGHOME="$SIGNER" gpg --batch --armor --export "$SIGNER_FPR" >"$TMP/release.asc"
check "release key generated" [ -n "$SIGNER_FPR" ]
check "impostor key generated" [ -n "$OTHER_FPR" ]

STUB="$TMP/stub"
CALLS="$TMP/calls"
mkdir -p "$STUB" "$CALLS"
cat >"$STUB/docker" <<'EOF'
#!/bin/bash
n=$(find "$DOCKER_STUB_CALLS" -type f | wc -l)
printf '%s\n' "$@" >"$DOCKER_STUB_CALLS/$(printf '%04d' "$n")"
case "$1" in
run) printf '%s (Claude Code)\n' "${DOCKER_STUB_CLAUDE_VERSION:-2.1.284}" ;;
esac
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

# up <args...> — runs the installed wrapper (no TTY); sets OUT and RC.
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
# release <tag> <signer-home|unsigned> — tag the seed tip and push it.
release() {
    if [ "$2" = unsigned ]; then
        git -C "$SEED" tag -a "$1" -m "$1"
    else
        GNUPGHOME="$2" git -C "$SEED" -c gpg.program=gpg -c user.signingkey="$3" tag -s "$1" -m "$1"
    fi
    git -C "$SEED" push -q origin "$1"
}
built_image() { grep -rqx build "$CALLS" 2>/dev/null; }
docker_called_with() { grep -rqxF -- "$1" "$CALLS" 2>/dev/null; }

# --- up to date ------------------------------------------------------------------------
up update --check
assert_eq "$RC" 0 "--check exits 0 when up to date"
check "origin URL pinned on first use" [ -s "$CONFIG_DIR/state/origin-url" ]
before="$(head_of "$INSTALL")"
up update --no-build
assert_eq "$RC" 0 "update when already up to date exits 0"

# --- --help and flag validation never touch git ----------------------------------------------
upstream_commit "second"
release v0.2.0 "$SIGNER" "$SIGNER_FPR"
up update --help
assert_eq "$RC" 0 "--help exits 0"
check "--help prints usage" has_text "Usage:" "$OUT"
assert_eq "$(head_of "$INSTALL")" "$before" "--help does not pull"
for bad in "--claude-version 1.2" "--claude-version 2.1.0;id" "--channel nightly" "--bogus"; do
    # shellcheck disable=SC2086  # intentional word splitting of the flags
    up update $bad
    assert_eq "$RC" 1 "refused flags: $bad"
done
assert_eq "$(head_of "$INSTALL")" "$before" "refused flags never pull"

# --- no trusted key yet: the signed release is not applied (T-12) ---------------------------
up update --check
assert_eq "$RC" 100 "--check exits 100 when a release is available"
check "--check says it is not verified yet" has_text "NOT verified" "$OUT"
up update --yes --no-build
assert_eq "$RC" 1 "an unverifiable release is refused"
assert_eq "$(head_of "$INSTALL")" "$before" "refused release left the checkout untouched"
check "refusal explains how to pin a key" has_text "--trust-key" "$OUT"
check_not "refusal never builds" built_image
up update --yes --no-build --allow-unsigned
assert_eq "$RC" 1 "--allow-unsigned needs a TTY confirmation"
assert_eq "$(head_of "$INSTALL")" "$before" "--allow-unsigned without a TTY changes nothing"

# --- pin the maintainer key -------------------------------------------------------------------
up update --trust-key "$TMP/release.asc"
assert_eq "$RC" 1 "trusting a key needs a confirmation"
check_not "nothing pinned without confirmation" [ -s "$CONFIG_DIR/trust/fingerprints" ]
CLAUDE_DOCKERIZED_TEST_HOOKS=1 CLAUDE_DOCKERIZED_TRUST_YES=1 up update --trust-key "$TMP/release.asc"
assert_eq "$RC" 0 "release key pinned"
check "fingerprint recorded" grep -qx "$SIGNER_FPR" "$CONFIG_DIR/trust/fingerprints"
assert_eq "$(stat -c '%a' "$CONFIG_DIR/trust")" 700 "trust store is 0700"

# --- dry run previews, changes nothing ------------------------------------------------------------
up update --dry-run
assert_eq "$RC" 0 "--dry-run exits 0"
check "preview lists the commits" has_text "second" "$OUT"
check "preview names the signer" has_text "$SIGNER_FPR" "$OUT"
assert_eq "$(head_of "$INSTALL")" "$before" "--dry-run changes nothing"
up update --no-build
assert_eq "$RC" 1 "without a TTY the update needs --yes"
assert_eq "$(head_of "$INSTALL")" "$before" "unconfirmed update changes nothing"

# --- verified update, fast-forward, rebuild with a rollback point (T-13) ----------------------------
up update --yes
assert_eq "$RC" 0 "verified update applied"
assert_eq "$(head_of "$INSTALL")" "$(git -C "$SEED" rev-parse 'v0.2.0^{commit}')" "checkout is at the signed release"
check "rollback point recorded" grep -qx "$before" "$CONFIG_DIR/state/last-good"
check "image rebuilt" built_image
check "previous image tagged for rollback" docker_called_with "claude-dockerized:prev"
check "the new code re-synced the security layer" [ -f "$CCODE_HOME/etc/claude-code/managed-settings.json" ]

# --- Claude version pin: rebuild even when up to date, kept for later builds --------------------------------
DOCKER_STUB_CLAUDE_VERSION=2.1.300 up update --yes --claude-version 2.1.300
assert_eq "$RC" 0 "up to date + --claude-version rebuilds"
check "requested Claude version reaches the build" docker_called_with "CLAUDE_CODE_VERSION=2.1.300"
assert_eq "$(cat "$CONFIG_DIR/state/claude-version" 2>/dev/null)" 2.1.300 "Claude version pin saved"
check "binary sha256 recorded for the pinned version (TOFU)" [ -s "$CONFIG_DIR/state/claude-2.1.300-$(uname -m).sha256" ]
DOCKER_STUB_CLAUDE_VERSION=2.1.300 up build
check "a later build reuses the pinned version" docker_called_with "CLAUDE_CODE_VERSION=2.1.300"
up update --yes --claude-version 2.1.301
assert_eq "$RC" 1 "a build reporting another Claude version fails"

# --- impostor, unsigned and rewritten releases are refused --------------------------------------------
released="$(head_of "$INSTALL")"
upstream_commit "third"
release v0.3.0 "$OTHER" "$OTHER_FPR"
up update --yes --no-build
assert_eq "$RC" 1 "a release signed by an untrusted key is refused"
assert_eq "$(head_of "$INSTALL")" "$released" "impostor release not applied"
upstream_commit "fourth"
release v0.4.0 unsigned
up update --yes --no-build
assert_eq "$RC" 1 "an unsigned release is refused"
assert_eq "$(head_of "$INSTALL")" "$released" "unsigned release not applied"
git -C "$SEED" tag -d v0.2.0 >/dev/null
git -C "$SEED" tag -a v0.2.0 -m "rewritten" HEAD
git -C "$SEED" push -q -f origin v0.2.0
up update --yes --no-build
assert_eq "$RC" 1 "a rewritten release tag makes the update fail"
check "rewritten tag is reported" has_text "rewritten upstream" "$OUT"
assert_eq "$(head_of "$INSTALL")" "$released" "rewritten tag changes nothing"

# --- rollback ----------------------------------------------------------------------------------------------
up rollback
assert_eq "$RC" 1 "rollback needs --yes without a TTY"
up rollback --yes
assert_eq "$RC" 0 "rollback succeeds"
assert_eq "$(head_of "$INSTALL")" "$before" "checkout restored to the rollback point"
check "image restored from :prev" docker_called_with "claude-dockerized:prev"

# --- divergence and a changed origin -------------------------------------------------------------------------
printf 'local\n' >"$INSTALL/LOCAL.test"
git -C "$INSTALL" add LOCAL.test
git -C "$INSTALL" commit -q -m "local change"
diverged="$(head_of "$INSTALL")"
up update --yes --no-build --channel branch
assert_eq "$RC" 1 "diverged checkout refused"
assert_eq "$(head_of "$INSTALL")" "$diverged" "diverged checkout left untouched"
git -C "$INSTALL" remote set-url origin "$TMP/elsewhere.git"
up update --check
assert_eq "$RC" 1 "a changed origin remote is refused"
check "changed origin is explained" has_text "origin remote changed" "$OUT"

t_summary
