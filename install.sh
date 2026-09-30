#!/bin/bash
# Bootstrap installer: clone (or reuse) the self-contained checkout at
# ${XDG_DATA_HOME:-$HOME/.local/share}/claude-dockerized, then run the
# built-in `claude-dockerized install` wizard. bin/ holds only the
# `claude-dockerized` binary; there is no second `install` binary.
#
# Recommended (inspect before running):
#   curl -fsSLO https://raw.githubusercontent.com/yukiteruamano/claude-dockerized/master/install.sh
#   less install.sh && bash install.sh
# One-liner (does everything: download, config, PATH, completions, aliases):
#   curl -fsSL https://raw.githubusercontent.com/yukiteruamano/claude-dockerized/master/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --yes --only config,completions,aliases,global
#
# Environment:
#   CCODE_REPO_URL     source repository (https://, ssh:// or git@ URL, or a
#                      local path); unauthenticated http:// and git:// are refused
#   CCODE_REF          release tag or commit to check out (e.g. v1.2.0)
#   CCODE_INSTALL_DIR  target checkout
#
# An existing checkout is never updated from here: use
# `claude-dockerized update`, which verifies signed releases first.
set -e

DEFAULT_REPO_URL="https://github.com/yukiteruamano/claude-dockerized.git"

# Refuse transports without authentication/integrity (MITM-able).
# Usage: check_repo_url <url>
check_repo_url() {
    case "$1" in
    https://* | ssh://* | git@*:* | /*) return 0 ;;
    esac
    echo "error: refusing repository URL '$1' (use https://, ssh://, git@host:path or a local path)" >&2
    return 1
}

# Check out CCODE_REF (tag or commit) and report its signature status.
# Usage: checkout_ref <dir> <ref>
checkout_ref() {
    local dir="$1" ref="$2"
    [ -n "$ref" ] || return 0
    if ! git -C "$dir" -c advice.detachedHead=false checkout -q "$ref"; then
        echo "error: could not check out CCODE_REF=$ref" >&2
        return 1
    fi
    if git -C "$dir" verify-tag "$ref" >/dev/null 2>&1; then
        echo "Checked out $ref (signature valid for your GnuPG keyring)."
    else
        echo "Checked out $ref (signature not verified locally; pin the release key with"
        echo "  claude-dockerized update --trust-key <key-file>  before the next update)."
    fi
}

main() {
    local repo_url="${CCODE_REPO_URL:-$DEFAULT_REPO_URL}"
    local install_dir="${CCODE_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-dockerized}"
    local ref="${CCODE_REF:-}"

    # Forwarded install args. A piped `curl | bash` has no TTY for prompts,
    # so default to --yes (full setup) unless the caller already passed
    # --yes or asks for help. Explicit `bash -s -- --yes ...` keeps working.
    local -a forward_args=("$@")
    local has_yes=false has_help=false a
    for a in "$@"; do
        case "$a" in
        --yes) has_yes=true ;;
        -h | --help) has_help=true ;;
        esac
    done
    if [ "$has_help" = false ] && [ "$has_yes" = false ] && [ ! -t 0 ]; then
        forward_args=(--yes "$@")
    fi

    # Running from a local checkout (./install.sh): use it directly, no
    # cloning. When piped via curl BASH_SOURCE is empty/a pipe, so skip this.
    local script_src="${BASH_SOURCE[0]:-}" own_root=""
    if [ -n "$script_src" ] && [ -f "$script_src" ]; then
        own_root="$(cd "$(dirname "$(readlink -f "$script_src" 2>/dev/null || echo "$script_src")")" && pwd)"
    fi
    if [ -n "$own_root" ] && [ -x "$own_root/bin/claude-dockerized" ]; then
        exec "$own_root/bin/claude-dockerized" install "${forward_args[@]}"
    fi

    if [ -d "$install_dir" ] && [ ! -d "$install_dir/.git" ]; then
        echo "error: $install_dir exists and is not a git checkout (remove it or set CCODE_INSTALL_DIR)" >&2
        exit 1
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "error: git is required to install claude-dockerized" >&2
        exit 1
    fi

    if [ ! -d "$install_dir" ]; then
        check_repo_url "$repo_url" || exit 1
        echo "Cloning claude-dockerized into $install_dir ..."
        git clone "$repo_url" "$install_dir"
        checkout_ref "$install_dir" "$ref" || exit 1
    else
        # Reused checkout: repair upstream tracking (manual checkouts via
        # init + remote add lack @{u}) but never pull unverified code.
        local br
        br=$(git -C "$install_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
        if [ -n "$br" ] && [ "$br" != "HEAD" ] &&
            ! git -C "$install_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 &&
            git -C "$install_dir" rev-parse --verify "refs/remotes/origin/$br" >/dev/null 2>&1; then
            if git -C "$install_dir" branch --set-upstream-to="origin/$br" "$br" >/dev/null 2>&1; then
                echo "Tracking upstream: $br -> origin/$br (self-update enabled)"
            else
                echo "warning: could not set upstream tracking in $install_dir" >&2
            fi
        fi
        echo "Using the existing checkout at $install_dir (update it with: claude-dockerized update)."
    fi

    if [ ! -x "$install_dir/bin/claude-dockerized" ]; then
        echo "error: $install_dir/bin/claude-dockerized not found or not executable" >&2
        exit 1
    fi

    exec "$install_dir/bin/claude-dockerized" install "${forward_args[@]}"
}

# Called on the last line so a truncated download never runs a partial script.
main "$@"
