#!/bin/bash
# Supply-chain contract (T-12, T-24, T-29): every external input of the image,
# the bootstrap installer and CI is pinned, and no floating reference sneaks
# back in. Static checks only (no network, no Docker).
#
# Usage: bash tests/supply-chain.test.sh
# shellcheck disable=SC2317  # helpers run via check

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="supply-chain"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

DF="$REPO_DIR/Dockerfile"
matches() { grep -Eq -- "$1" "$2"; }

# --- image inputs (T-24) ------------------------------------------------------------------
check "base image pinned by digest" matches '^FROM debian:trixie-slim@sha256:[0-9a-f]{64}$' "$DF"
check "NVM installer fetched by commit" matches 'nvm-sh/nvm/\$\{NVM_COMMIT\}/install\.sh' "$DF"
check "NVM commit is a full SHA" matches '^ARG NVM_COMMIT=[0-9a-f]{40}$' "$DF"
check "Node pinned to an exact release" matches '^ARG NODE_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$DF"
check_not "Node never floats to --lts" matches 'nvm install --lts' "$DF"
check "uv pinned to an exact release" matches '^ARG UV_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$DF"
check "uv comes from its versioned release tarball" matches 'github\.com/astral-sh/uv/releases/download/\$\{UV_VERSION\}/uv-\$\{uv_target\}\.tar\.gz' "$DF"
check "uv tarball sha256 pinned for x86_64" matches '^ARG UV_SHA256_X86_64=[0-9a-f]{64}$' "$DF"
check "uv tarball sha256 pinned for aarch64" matches '^ARG UV_SHA256_AARCH64=[0-9a-f]{64}$' "$DF"
check "uv tarball verified before extraction" matches 'echo "\$\{uv_sha\}  /tmp/uv\.tar\.gz" \| sha256sum -c -' "$DF"
check_not "no piped uv installer" matches 'astral\.sh/uv/.*install\.sh' "$DF"
check "installed uv version is asserted" matches 'uv --version \| grep -q "\^uv \$\{UV_VERSION\}"' "$DF"
check "pnpm pinned to an exact release" matches '^ARG PNPM_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$DF"
check "pnpm installed at the pinned version" matches 'npm install -g pnpm@\$\{PNPM_VERSION\}' "$DF"
check "installed pnpm version is asserted" matches 'pnpm --version \| grep -qx' "$DF"
check "Docker apt key checked by fingerprint" matches 'grep -qx "\$DOCKER_APT_KEY_FPR"' "$DF"
check "Docker apt key fingerprint pinned" matches '^ARG DOCKER_APT_KEY_FPR=[0-9A-F]{40}$' "$DF"
check "Claude pinned to an exact release" matches '^ARG CLAUDE_CODE_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$DF"
check "installed Claude version is asserted" matches 'claude --version \| grep -q "\^\$\{CLAUDE_CODE_VERSION\} "' "$DF"
check "Claude binary sha256 verified when recorded" matches 'echo "\$\{CLAUDE_CODE_SHA256\}  \$\{claude_bin\}" \| sha256sum -c -' "$DF"
check "Claude manifest sha256 pinned for linux-x64" matches '^ARG CLAUDE_CODE_MANIFEST_SHA256_X64=[0-9a-f]{64}$' "$DF"
check "Claude manifest sha256 pinned for linux-arm64" matches '^ARG CLAUDE_CODE_MANIFEST_SHA256_ARM64=[0-9a-f]{64}$' "$DF"
check "Claude binary verified against the manifest pin" matches 'echo "\$\{manifest_sha\}  \$\{claude_bin\}" \| sha256sum -c -' "$DF"
assert_eq "$(sed -n 's/^ARG CLAUDE_CODE_MANIFEST_VERSION=//p' "$DF")" "$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' "$DF")" "the manifest pins belong to the default Claude version"
claude_arg_line=$(grep -n '^ARG CLAUDE_CODE_VERSION=' "$DF" | cut -d: -f1)
first_run_line=$(grep -n '^RUN ' "$DF" | head -n1 | cut -d: -f1)
check "Claude version ARG declared after the base layers (no apt cache bust)" [ "$claude_arg_line" -gt "$first_run_line" ]
check_not "no 'latest' tags" matches '(:latest|@latest)([^[:alnum:]]|$)' "$DF"
check_not "no npm install of the agent" matches 'npm (install|i|add) .*@anthropic' "$DF"

# --- bootstrap installer (T-12) ------------------------------------------------------------
IS="$REPO_DIR/install.sh"
check "install.sh runs through main on its last line" [ "$(grep -v '^[[:space:]]*$' "$IS" | tail -n1)" = 'main "$@"' ]
check "install.sh refuses unauthenticated transports" matches 'refusing repository URL' "$IS"
check "install.sh supports a pinned CCODE_REF" matches 'CCODE_REF' "$IS"
check_not "install.sh never pulls an existing checkout" matches 'pull --ff-only|git -C "\$install_dir" (pull|merge)' "$IS"
url_ok() {
    (
        # shellcheck source=/dev/null
        eval "$(sed -n '/^check_repo_url() {/,/^}/p' "$IS")"
        check_repo_url "$1" 2>/dev/null
    )
}
for url in https://github.com/o/r.git ssh://git@github.com/o/r.git git@github.com:o/r.git /srv/mirror/r.git; do
    check "install.sh accepts $url" url_ok "$url"
done
for url in http://github.com/o/r.git git://github.com/o/r.git ftp://x/r.git "file://x" "-oProxyCommand=x"; do
    check_not "install.sh refuses $url" url_ok "$url"
done
# install_fn <name> <args...> — runs one install.sh function in a subshell.
install_fn() {
    (
        # shellcheck source=/dev/null
        eval "$(sed -n "/^$1() {/,/^}/p" "$IS")"
        # shellcheck source=/dev/null
        eval "$(sed -n '/^check_ref_name() {/,/^}/p' "$IS")"
        "$@"
    )
}
for ref in v1.2.0 0123abc feature/x; do
    check "install.sh accepts CCODE_REF=$ref" install_fn check_ref_name "$ref" 2>/dev/null
done
for ref in --orphan=x -b "v1..v2" "HEAD@{1}" "v1^" "a b" "" /abs; do
    check_not "install.sh refuses CCODE_REF='$ref'" install_fn check_ref_name "$ref" 2>/dev/null
done
check "install.sh describes the keyring it verified against" matches 'your own GnuPG keyring' "$IS"
check_not "install.sh never calls the local keyring a trusted release check" matches 'signature valid for your GnuPG keyring\)' "$IS"

if command -v git >/dev/null 2>&1; then
    export TMPDIR="${TMPDIR:-/tmp/claude}"
    REF_REPO="$(t_tmpdir)/ref-repo"
    git_q() { git -C "$REF_REPO" -c user.name=t -c user.email=t@example.invalid "$@" >/dev/null 2>&1; }
    git init -q "$REF_REPO"
    git_q commit --allow-empty -m tagged
    git_q tag -a v1.0.0 -m v1.0.0
    tagged="$(git -C "$REF_REPO" rev-parse HEAD)"
    git_q commit --allow-empty -m branch
    git_q branch v1.0.0
    checked_out() { [ "$(git -C "$REF_REPO" rev-parse HEAD)" = "$1" ]; }
    install_fn checkout_ref "$REF_REPO" v1.0.0 >/dev/null 2>&1
    check "CCODE_REF prefers the tag over a same-named branch" checked_out "$tagged"
    check_not "CCODE_REF '--orphan=x' is refused" install_fn checkout_ref "$REF_REPO" --orphan=x 2>/dev/null
    check_not "a refused CCODE_REF leaves no orphan branch" git -C "$REF_REPO" rev-parse --verify -q refs/heads/x
    check_not "an unknown CCODE_REF fails" install_fn checkout_ref "$REF_REPO" v9.9.9 2>/dev/null
    rm -rf "$(dirname "$REF_REPO")"
fi

# --- CI (T-29) -----------------------------------------------------------------------------
for wf in "$REPO_DIR"/.github/workflows/*.yml; do
    name="$(basename "$wf")"
    while IFS= read -r use; do
        check "$name: $use pinned by commit SHA" matches '@[0-9a-f]{40}( |$)' <(printf '%s\n' "$use")
    done < <(grep -Eo 'uses: [^ ]+( # .*)?' "$wf" | sed 's/^uses: //')
    check "$name: least-privilege token" matches '^permissions:' "$wf"
done
check "Dependabot watches the actions" matches 'package-ecosystem: github-actions' "$REPO_DIR/.github/dependabot.yml"

# --- release version (docs/security/YELLOW.md#releases) ---------------------------------------
# WRAPPER_VERSION is bumped before tagging: it may be ahead of the latest tag
# but never behind it, or `version` would report a stale release. Pre-release
# tags (vX.Y.Z-rcN) are ignored: `sort -V` would rank them above the release.
wrapper_version="$(sed -n 's/^WRAPPER_VERSION="\(.*\)"$/\1/p' "$REPO_DIR/bin/claude-dockerized")"
check "WRAPPER_VERSION is a plain x.y.z" matches '^[0-9]+\.[0-9]+\.[0-9]+$' <(printf '%s\n' "$wrapper_version")
latest_tag="$(git -C "$REPO_DIR" tag -l 'v[0-9]*' 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -V | tail -n 1)"
if [ -n "$latest_tag" ]; then
    newest="$(printf '%s\n%s\n' "$wrapper_version" "$latest_tag" | sort -V | tail -n 1)"
    assert_eq "$newest" "$wrapper_version" "WRAPPER_VERSION ($wrapper_version) is not behind the latest tag (v$latest_tag)"
fi

t_summary
