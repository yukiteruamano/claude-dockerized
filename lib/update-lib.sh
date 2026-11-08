#!/bin/bash
# update-lib.sh - verified self-update for bin/claude-dockerized (T-12, T-13).
# Sourced by the wrapper. Not executable directly; no `set -e`.
#
# Trust model:
#   - Code is only applied from a SIGNED release tag (default channel "tags")
#     or a signed upstream commit (channel "branch"), verified against keys
#     pinned locally in $CONFIG_DIR/trust (never against keys that arrive
#     with the update, so a compromised upstream cannot rotate them).
#   - The fetch happens once; what is verified is exactly what is merged
#     (fast-forward only), and the user sees the log/diff before it lands.
#   - The previous commit and image are recorded so `rollback` can undo a
#     bad update; a failed rebuild prints the exact recovery command.
#   - The origin URL is pinned on first use; a changed remote is refused.
#
# Trust store layout ($CONFIG_DIR/trust, 0700):
#   gnupg/            private GNUPGHOME holding only the pinned public keys
#   fingerprints      one uppercase OpenPGP fingerprint per line
#   allowed_signers   ssh-keygen allowed-signers lines (SSH-signed tags)

UPDATE_TRUST_DIR="${UPDATE_TRUST_DIR:-$CONFIG_DIR/trust}"
UPDATE_STATE_DIR="${UPDATE_STATE_DIR:-$CONFIG_DIR/state}"

# Security-relevant paths highlighted in the pre-update preview.
UPDATE_SENSITIVE_RE='^(Dockerfile|entrypoint\.sh|install\.sh|bin/|lib/|hooks/|policies/|\.github/)'

_update_git() { git -C "$REPO_ROOT" "$@"; }

_update_ensure_dirs() {
    mkdir -p "$UPDATE_TRUST_DIR/gnupg" "$UPDATE_STATE_DIR" 2>/dev/null || return 1
    chmod 700 "$UPDATE_TRUST_DIR" "$UPDATE_TRUST_DIR/gnupg" 2>/dev/null || true
}

# Print the pinned OpenPGP fingerprints (uppercase, no spaces).
update_trusted_fprs() {
    [ -f "$UPDATE_TRUST_DIR/fingerprints" ] || return 0
    tr -d ' \t' <"$UPDATE_TRUST_DIR/fingerprints" | tr '[:lower:]' '[:upper:]' | grep -E '^[0-9A-F]{40,64}$' || true
}

# Is any signing key trusted yet? Usage: update_has_trust
update_has_trust() {
    [ -n "$(update_trusted_fprs)" ] || [ -s "$UPDATE_TRUST_DIR/allowed_signers" ]
}

# Pin a release-signing key: an armored/binary OpenPGP public key file or an
# ssh allowed-signers line file. Shows the fingerprint and asks on a TTY
# (never trusted silently: --yes does not skip this confirmation).
# Usage: update_trust_key <file>
update_trust_key() {
    local file="$1"
    if [ ! -f "$file" ]; then
        config_error "Key file not found: $file"
        return 1
    fi
    _update_ensure_dirs || {
        config_error "Cannot create the trust store at $UPDATE_TRUST_DIR"
        return 1
    }

    # SSH allowed-signers entries: "<principal> [options] <keytype> <key>".
    if grep -qE '^[^#[:space:]]+[[:space:]].*(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519)' "$file" 2>/dev/null; then
        config_info "SSH release signer(s) to trust:"
        grep -vE '^[[:space:]]*(#|$)' "$file" | sed 's/^/  /'
        _update_confirm_trust || return 1
        grep -vE '^[[:space:]]*(#|$)' "$file" >>"$UPDATE_TRUST_DIR/allowed_signers"
        chmod 600 "$UPDATE_TRUST_DIR/allowed_signers" 2>/dev/null || true
        config_success "Trusted SSH release signer(s) in $UPDATE_TRUST_DIR/allowed_signers"
        return 0
    fi

    command -v gpg >/dev/null 2>&1 || {
        config_error "gpg is required to trust an OpenPGP release key"
        return 1
    }
    local listing fprs uids
    listing=$(gpg --batch --with-colons --import-options show-only --import "$file" 2>/dev/null)
    # Primary-key fingerprints: the first fpr record after each pub record.
    fprs=$(printf '%s\n' "$listing" | awk -F: '$1=="pub"{want=1; next} $1=="fpr" && want {print $10; want=0}')
    uids=$(printf '%s\n' "$listing" | awk -F: '$1=="uid"{print $10}')
    if [ -z "$fprs" ]; then
        config_error "$file holds no OpenPGP public key"
        return 1
    fi
    config_info "OpenPGP release key(s) to trust:"
    printf '  fingerprint %s\n' $fprs
    [ -n "$uids" ] && printf '  uid %s\n' "$uids"
    config_info "Compare the fingerprint with the one published by the maintainer before accepting."
    _update_confirm_trust || return 1
    GNUPGHOME="$UPDATE_TRUST_DIR/gnupg" gpg --batch --quiet --import "$file" >/dev/null 2>&1 || {
        config_error "Could not import $file into the trust store"
        return 1
    }
    printf '%s\n' $fprs >>"$UPDATE_TRUST_DIR/fingerprints"
    sort -u "$UPDATE_TRUST_DIR/fingerprints" -o "$UPDATE_TRUST_DIR/fingerprints"
    chmod 600 "$UPDATE_TRUST_DIR/fingerprints" 2>/dev/null || true
    config_success "Trusted $(printf '%s\n' $fprs | wc -l | tr -d ' ') release key(s)"
}

# Trust decisions need a human: a TTY answer, or the explicit test opt-in.
_update_confirm_trust() {
    if [ "${CLAUDE_DOCKERIZED_TEST_HOOKS:-}" = 1 ] && [ "${CLAUDE_DOCKERIZED_TRUST_YES:-}" = 1 ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        config_error "Trusting a key needs an interactive confirmation (run from a terminal)."
        return 1
    fi
    local ans
    read -r -p "Trust this key for claude-dockerized updates? Type 'trust' to confirm: " ans || ans=""
    [ "$ans" = trust ] || {
        config_info "Not trusted."
        return 1
    }
}

# Verify <ref> against the pinned keys only. A release (tags channel) is a
# fully qualified refs/tags/vX.Y.Z that must be an annotated, signed tag
# object: a lightweight tag carries no signature of its own, so anyone who
# can push tags could label any maintainer-signed commit (WIP, feature) as a
# release. Any other ref (the branch channel's @{u}) must be a signed commit.
# Prints the signer on success. Usage: update_verify_ref <ref>
update_verify_ref() {
    local ref="$1" kind out rc=0
    kind=$(_update_git cat-file -t "$ref" 2>/dev/null)
    case "$ref" in
    refs/tags/*)
        if [ "$kind" != tag ]; then
            config_error "${ref#refs/tags/} is a lightweight tag: a release must be an annotated, signed tag."
            return 1
        fi
        # The signature covers the tag's own "tag <name>" header, not the ref
        # it is published under: a validly signed tag object renamed upstream
        # must not pass as another release.
        local signed_name
        signed_name=$(_update_git cat-file tag "$ref" 2>/dev/null | awk '/^tag /{print $2; exit}')
        [ "refs/tags/$signed_name" = "$ref" ] || return 1
        ;;
    *)
        [ "$kind" = commit ] || return 1
        ;;
    esac
    local -a cfg=(
        -c "gpg.program=gpg"
        -c "gpg.ssh.allowedSignersFile=$UPDATE_TRUST_DIR/allowed_signers"
    )
    if [ "$kind" = tag ]; then
        out=$(GNUPGHOME="$UPDATE_TRUST_DIR/gnupg" _update_git "${cfg[@]}" verify-tag --raw "$ref" 2>&1) || rc=$?
    else
        out=$(GNUPGHOME="$UPDATE_TRUST_DIR/gnupg" _update_git "${cfg[@]}" verify-commit --raw "$ref" 2>&1) || rc=$?
    fi
    [ "$rc" -eq 0 ] || return 1

    # OpenPGP: the signing (sub)key or its primary key must be pinned.
    local validsig
    validsig=$(printf '%s\n' "$out" | awk '$1=="[GNUPG:]" && $2=="VALIDSIG" {print $3; print $12}' | tr '[:lower:]' '[:upper:]')
    if [ -n "$validsig" ]; then
        local fpr
        while IFS= read -r fpr; do
            [ -n "$fpr" ] || continue
            if update_trusted_fprs | grep -qxF "$fpr"; then
                printf 'OpenPGP key %s\n' "$fpr"
                return 0
            fi
        done <<<"$validsig"
        return 1
    fi
    # SSH: git only succeeds when the key is in the pinned allowed_signers.
    if printf '%s\n' "$out" | grep -q 'Good "git" signature'; then
        printf '%s\n' "$(printf '%s\n' "$out" | grep -m1 'Good "git" signature')"
        return 0
    fi
    return 1
}

# Pin the origin URL on first use; refuse a changed remote afterwards.
# Usage: update_check_origin
update_check_origin() {
    local url pinned
    url=$(_update_git remote get-url origin 2>/dev/null) || {
        config_error "No 'origin' remote in $REPO_ROOT."
        return 1
    }
    _update_ensure_dirs || return 1
    if [ ! -s "$UPDATE_STATE_DIR/origin-url" ]; then
        printf '%s\n' "$url" >"$UPDATE_STATE_DIR/origin-url"
        return 0
    fi
    pinned=$(head -n1 "$UPDATE_STATE_DIR/origin-url")
    if [ "$url" != "$pinned" ]; then
        config_error "The origin remote changed: $url (pinned: $pinned)."
        config_info "If this is intended, run: git -C \"$REPO_ROOT\" remote set-url origin \"$pinned\" (or remove $UPDATE_STATE_DIR/origin-url to re-pin)."
        return 1
    fi
}

# Newest release tag (printed as refs/tags/vX.Y.Z, so a branch or another ref
# named like a release can never stand in for it) that fast-forwards HEAD, or
# the upstream tip for the branch channel. Prints nothing when already up to date.
# Returns 0 (target printed, or nothing to do), 1 (no upstream) or 2 (the
# checkout diverged from upstream / from a newer release: no forced update).
# Usage: update_select_target <tags|branch>
update_select_target() {
    local channel="$1" head tag commit skipped=""
    head=$(_update_git rev-parse HEAD)
    if [ "$channel" = branch ]; then
        commit=$(_update_git rev-parse '@{u}' 2>/dev/null) || return 1
        [ "$commit" = "$head" ] && return 0
        _update_git merge-base --is-ancestor HEAD "$commit" || {
            # Local commits on top of upstream are not a divergence.
            _update_git merge-base --is-ancestor "$commit" HEAD && return 0
            return 2
        }
        printf '%s' '@{u}'
        return 0
    fi
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        tag="refs/tags/$tag"
        commit=$(_update_git rev-parse --verify -q "$tag^{commit}" 2>/dev/null) || continue
        [ "$commit" = "$head" ] && break
        if _update_git merge-base --is-ancestor HEAD "$commit" 2>/dev/null; then
            [ -n "$skipped" ] && config_warning "Skipping release(s) that do not descend from this checkout:$skipped"
            printf '%s' "$tag"
            return 0
        fi
        # HEAD already contains this release: the older ones cannot apply either.
        _update_git merge-base --is-ancestor "$commit" HEAD 2>/dev/null && break
        skipped="$skipped ${tag#refs/tags/}"
    done < <(_update_git tag -l 'v[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$')
    if [ -n "$skipped" ]; then
        config_warning "Newer release(s) do not descend from this checkout:$skipped"
        return 2
    fi
    return 0
}

# Show what an update would change, flagging security-relevant files.
# Usage: update_preview <target>
update_preview() {
    local target="$1" n
    n=$(_update_git rev-list --count "HEAD..$target")
    config_info "Update to $target: $n commit(s)"
    _update_git --no-pager log --oneline --no-decorate "HEAD..$target" | head -n 30 | sed 's/^/  /'
    local changed sensitive
    changed=$(_update_git diff --name-only HEAD "$target")
    sensitive=$(printf '%s\n' "$changed" | grep -E "$UPDATE_SENSITIVE_RE" || true)
    _update_git --no-pager diff --stat HEAD "$target" | tail -n 1 | sed 's/^/  /'
    if [ -n "$sensitive" ]; then
        config_warning "Security-relevant files change (runs on your host / in the image / the guard):"
        printf '%s\n' "$sensitive" | sed 's/^/    /'
        config_info "Inspect with: git -C \"$REPO_ROOT\" diff HEAD $target -- <file>"
    fi
}

# Stage the rollback point (the commit before the update). The previous point
# stays valid until update_commit_rollback, so a refused merge loses nothing.
update_record_rollback() {
    _update_ensure_dirs || return 1
    _update_git rev-parse HEAD >"$UPDATE_STATE_DIR/last-good.next"
}

# Make the staged rollback point current. The :prev image marker is dropped:
# it only describes an image rebuilt after this point (see update_mark_prev_image).
update_commit_rollback() {
    mv -f "$UPDATE_STATE_DIR/last-good.next" "$UPDATE_STATE_DIR/last-good" || return 1
    rm -f "$UPDATE_STATE_DIR/prev-image"
}

# :prev holds the image from before the last update (set by the rebuild).
# Without the marker the last update did not touch the image, and rollback
# must not retag an older :prev over the current image.
update_has_prev_image() { [ -e "$UPDATE_STATE_DIR/prev-image" ]; }
update_mark_prev_image() {
    _update_ensure_dirs || return 1
    : >"$UPDATE_STATE_DIR/prev-image"
}

# An update applied the new code but its image rebuild has not succeeded yet.
update_rebuild_pending() { [ -e "$UPDATE_STATE_DIR/rebuild-pending" ]; }
update_set_rebuild_pending() {
    _update_ensure_dirs || return 1
    : >"$UPDATE_STATE_DIR/rebuild-pending"
}
update_clear_rebuild_pending() { rm -f "$UPDATE_STATE_DIR/rebuild-pending"; }

# Undo the last update: move the checkout back to the recorded commit and
# restore the previous image tag, then re-sync with the restored code.
# Usage: update_rollback <yes:true|false>
update_rollback() {
    local yes="$1" target branch
    target=$(head -n1 "$UPDATE_STATE_DIR/last-good" 2>/dev/null)
    if [ -z "$target" ] || ! _update_git cat-file -e "$target^{commit}" 2>/dev/null; then
        config_error "No rollback point recorded (run after an update)."
        return 1
    fi
    if [ "$(_update_git rev-parse HEAD)" = "$target" ]; then
        config_info "Already at the rollback point ($target)."
    else
        config_info "Rolling back the wrapper checkout to $target:"
        _update_git --no-pager log --oneline --no-decorate "$target..HEAD" | sed 's/^/  - /'
        if [ "$yes" != true ]; then
            [ -t 0 ] || {
                config_error "Rollback needs confirmation: run from a terminal or pass --yes."
                return 1
            }
            local ans
            read -r -p "Roll back? (y/N): " ans || ans=""
            [[ "$ans" =~ ^[Yy]$ ]] || {
                config_info "Aborted."
                return 1
            }
        fi
        if [ -n "$(_update_git status --porcelain --untracked-files=no)" ]; then
            config_error "The checkout has local changes; commit or stash them first."
            return 1
        fi
        branch=$(_update_git symbolic-ref --short -q HEAD) || branch=""
        if [ -n "$branch" ]; then
            _update_git checkout -q -B "$branch" "$target" || return 1
        else
            _update_git checkout -q "$target" || return 1
        fi
        config_success "Checkout restored to $target."
    fi
    if ! update_has_prev_image; then
        config_info "The last update did not change the image; it was left as is."
    elif command -v docker >/dev/null 2>&1 && docker image inspect "${IMAGE_NAME%%:*}:prev" >/dev/null 2>&1; then
        if docker tag "${IMAGE_NAME%%:*}:prev" "$IMAGE_NAME"; then
            config_success "Image restored from ${IMAGE_NAME%%:*}:prev."
            rm -f "$UPDATE_STATE_DIR/prev-image"
        fi
    else
        config_info "No previous image tag; rebuild with: claude-dockerized build"
    fi
    # The restored code and image belong together again.
    update_clear_rebuild_pending
    return 0
}

# Pinned Claude Code version chosen with --claude-version (empty = Dockerfile default).
update_saved_claude_version() {
    head -n1 "$UPDATE_STATE_DIR/claude-version" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true
}

update_save_claude_version() {
    _update_ensure_dirs || return 1
    printf '%s\n' "$1" >"$UPDATE_STATE_DIR/claude-version"
}

# Claude Code version the checked-out Dockerfile builds by default.
update_dockerfile_claude_version() {
    sed -n 's/^ARG CLAUDE_CODE_VERSION=\([0-9][0-9.]*\)$/\1/p' "$REPO_ROOT/Dockerfile" 2>/dev/null | head -n1
}

# Recorded sha256 of the Claude binary for <version> on this architecture
# (trust on first use: a later build of the same version must match).
update_claude_sha_file() {
    printf '%s/claude-%s-%s.sha256' "$UPDATE_STATE_DIR" "$1" "$(uname -m)"
}

# Claude Code version a build produces: an explicit --claude-version, the
# saved pin, else the Dockerfile default. Usage: update_claude_effective_version
update_claude_effective_version() {
    local v="${_UP_CLAUDE_VERSION:-}"
    [ -n "$v" ] || v=$(update_saved_claude_version)
    [ -n "$v" ] || v=$(update_dockerfile_claude_version)
    printf '%s' "$v"
}

# Does the checked-out Dockerfile pin the manifest checksum of <version> for
# this architecture (so its build verifies the binary without first use)?
# Usage: update_dockerfile_pins_claude <version>
update_dockerfile_pins_claude() {
    local df="$REPO_ROOT/Dockerfile" arg
    grep -qxF "ARG CLAUDE_CODE_MANIFEST_VERSION=$1" "$df" 2>/dev/null || return 1
    case "$(uname -m)" in
    x86_64) arg=CLAUDE_CODE_MANIFEST_SHA256_X64 ;;
    aarch64 | arm64) arg=CLAUDE_CODE_MANIFEST_SHA256_ARM64 ;;
    *) return 1 ;;
    esac
    grep -qE "^ARG $arg=[0-9a-f]{64}$" "$df" 2>/dev/null
}

# Recorded sha256 of <version> on this architecture, or nothing.
# Usage: update_claude_recorded_sha <version>
update_claude_recorded_sha() {
    [ -n "$1" ] || return 0
    head -n1 "$(update_claude_sha_file "$1")" 2>/dev/null | grep -E '^[0-9a-f]{64}$' || true
}

# Gate a build of <version> on a recorded sha256, so trust on first use is a
# visible decision: without a record it warns, or refuses under
# setting.require_claude_sha=true unless --trust-first-use was given.
# Usage: update_claude_sha_gate <version>
update_claude_sha_gate() {
    [ -n "$1" ] || return 0
    [ -z "$(update_claude_recorded_sha "$1")" ] || return 0
    update_dockerfile_pins_claude "$1" && return 0
    if [ "${REQUIRE_CLAUDE_SHA:-false}" = true ] && [ "${_TRUST_FIRST_USE:-false}" != true ]; then
        config_error "No recorded sha256 for Claude Code $1 ($(uname -m)) and setting.require_claude_sha=true."
        config_info "Trust this download once and record its hash with: claude-dockerized build --trust-first-use"
        return 1
    fi
    config_warning "No recorded sha256 for Claude Code $1 ($(uname -m)): this build trusts the download on first use; the hash is recorded and later builds of $1 must match."
}

# Record the sha256 of the Claude binary in <image> for <version>, once (a
# record is never replaced) and only when the image really runs <version>.
# Usage: update_record_claude_sha <version> <image>
update_record_claude_sha() {
    local version="$1" image="$2" sha_file actual sha
    [ -n "$version" ] || return 0
    sha_file=$(update_claude_sha_file "$version")
    [ -s "$sha_file" ] && return 0
    actual=$(docker run --rm --entrypoint bash "$image" -c "claude --version" 2>/dev/null | cut -d' ' -f1)
    [ "$actual" = "$version" ] || return 0
    sha=$(docker run --rm --entrypoint sha256sum "$image" /usr/local/bin/claude 2>/dev/null | cut -d' ' -f1)
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 0
    _update_ensure_dirs || return 1
    printf '%s\n' "$sha" >"$sha_file"
}
