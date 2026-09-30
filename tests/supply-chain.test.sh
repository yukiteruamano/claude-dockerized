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
check "uv installer URL is versioned" matches 'astral\.sh/uv/\$\{UV_VERSION\}/install\.sh' "$DF"
check "installed uv version is asserted" matches 'uv --version \| grep -q "\^uv \$\{UV_VERSION\}"' "$DF"
check "Docker apt key checked by fingerprint" matches 'grep -qx "\$DOCKER_APT_KEY_FPR"' "$DF"
check "Docker apt key fingerprint pinned" matches '^ARG DOCKER_APT_KEY_FPR=[0-9A-F]{40}$' "$DF"
check "Claude pinned to an exact release" matches '^ARG CLAUDE_CODE_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$DF"
check "installed Claude version is asserted" matches 'claude --version \| grep -q "\^\$\{CLAUDE_CODE_VERSION\} "' "$DF"
check "Claude binary sha256 verified when recorded" matches 'sha256sum -c -' "$DF"
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

# --- CI (T-29) -----------------------------------------------------------------------------
for wf in "$REPO_DIR"/.github/workflows/*.yml; do
    name="$(basename "$wf")"
    while IFS= read -r use; do
        check "$name: $use pinned by commit SHA" matches '@[0-9a-f]{40}( |$)' <(printf '%s\n' "$use")
    done < <(grep -Eo 'uses: [^ ]+( # .*)?' "$wf" | sed 's/^uses: //')
    check "$name: least-privilege token" matches '^permissions:' "$wf"
done
check "Dependabot watches the actions" matches 'package-ecosystem: github-actions' "$REPO_DIR/.github/dependabot.yml"

t_summary
