#!/bin/bash
# lsp-lib.sh - opt-in LSP servers and formatters installed into the generated home
# Sourced by lib/config-lib.sh (which keeps the constants, config parsing and
# saving). Not executable directly; no `set -e`: callers own error handling.

# Pinned LSP/formatter releases (T-14). Bump deliberately, like any other pin.
LSP_NPM_TS="typescript-language-server@6.0.1 typescript@7.0.2"
LSP_NPM_PYRIGHT="pyright@1.1.414"
FMT_NPM_PRETTIER="prettier@3.9.9"
FMT_RUFF_VERSION="0.16.9"
LSP_GOPLS_VERSION="v0.23.0"

# A generated-home binary counts as installed only when it resolves to an
# executable file. `-e` is true for dangling symlinks' parents and false for
# the link itself, which caused reinstall loops when uv/npm left a stale link
# (the throwaway installer links $bindir/<tool> -> .lsp/...). Usage: lsp_bin_ok <path>
lsp_bin_ok() {
    [ -n "${1:-}" ] || return 1
    [ -x "$1" ] && [ -e "$1" ] || return 1
    [ ! -L "$1" ] && return 0
    # Resolve relative symlink targets (readlink without -f: no coreutils dep).
    local target link_dir="$1"
    target=$(readlink "$1" 2>/dev/null) || return 1
    case "$target" in
    /*) [ -x "$target" ] ;;
    *) link_dir=$(dirname "$1"); [ -x "$link_dir/$target" ] ;;
    esac
}

# Repair a uv-created link that points at the throwaway container's absolute
# mount path (/opt/lsp-bin/...): uv links the executable with an absolute
# target, which dangles on the host where that path does not exist. When the
# real binary is present under $bindir, rewrite the link relative so the
# shared-home tree stays host-portable (the container installs, the home
# persists). Returns 0 when nothing needed doing or the repair succeeded.
# Usage: lsp_repair_uv_link <bindir>
lsp_repair_uv_link() {
    local bindir="${1:-}" link target resolved rest
    [ -n "$bindir" ] || return 0
    link="$bindir/.lsp/uv-bin/ruff"
    [ -L "$link" ] || return 0
    lsp_bin_ok "$link" && return 0
    target=$(readlink "$link" 2>/dev/null) || return 0
    case "$target" in
    /opt/lsp-bin/*) ;;
    *) return 0 ;;
    esac
    resolved="$bindir/${target#/opt/lsp-bin/}"
    [ -x "$resolved" ] || return 0
    rest="${resolved#"$bindir/.lsp/"}"
    case "$rest" in
    "$resolved") return 0 ;; # outside the .lsp tree: don't guess
    *) ln -sfn "../$rest" "$link" 2>/dev/null || return 0 ;;
    esac
    lsp_bin_ok "$link"
}

# Expected version-stamp for the current LSP/formatter request (pins + server
# list + flags). Compared against $bindir/.lsp-versions so a pin bump
# reinstalls once and an installed set stays silent afterwards.
# Usage: lsp_expected_stamp
lsp_expected_stamp() {
    printf 'ruff=%s\nnpm_ts=%s\nnpm_pyright=%s\nnpm_prettier=%s\ngo=%s\nlsp_servers=%s\nlsp=%s\nformatters=%s\n' \
        "$FMT_RUFF_VERSION" "$LSP_NPM_TS" "$LSP_NPM_PYRIGHT" "$FMT_NPM_PRETTIER" \
        "$LSP_GOPLS_VERSION" "$LSP_SERVERS" "$LSP_ENABLED" "$FORMATTERS_ENABLED"
}

# Install LSP servers and formatters into the generated home (never
# system-wide; persists across rebuilds). The npm and uv packages install
# inside a throwaway container of the image (no capabilities, no new
# privileges, npm --ignore-scripts), never on the host, from pinned versions
# into ~/.local/bin/.lsp (the only generated-home path mounted, so the tools
# resolve in-container). gopls/rust-analyzer need host toolchains: pinned
# gopls, rustup's signed channel. Only missing tools are installed; failures
# are reported, never fatal. Skipped with CLAUDE_DOCKERIZED_SKIP_LSP_INSTALL=1.
# Usage: ensure_lsp_formatters
ensure_lsp_formatters() {
    [ -n "${CLAUDE_DOCKERIZED_SKIP_LSP_INSTALL:-}" ] && return 0
    [ "$LSP_ENABLED" = true ] || [ "$FORMATTERS_ENABLED" = true ] || return 0
    # One check per wrapper process: check_config already ran it before
    # run_claude's build_standard_volume_args in the same process; a second
    # call must not spawn a second throwaway container (double "Installing..."
    # log per `run`). A failed attempt also skips the retry here and is
    # retried on the next wrapper invocation.
    [ -n "${_LSP_FORMATTERS_DONE:-}" ] && return 0
    local bindir="$CCODE_HOME/.local/bin"
    mkdir -p "$bindir" 2>/dev/null || return 0
    # Heal a container-absolute uv link from a previous install before
    # deciding what is missing: a repaired tree skips docker entirely.
    lsp_repair_uv_link "$bindir" || true

    local -a npm_pkgs=() npm_bins=()
    local want_ruff=false entry
    if [ "$LSP_ENABLED" = true ]; then
        local IFS_save="$IFS"
        IFS=','
        for entry in $LSP_SERVERS; do
            entry="$(printf '%s' "$entry" | sed 's/^ *//;s/ *$//')"
            case "$entry" in
            "") ;;
            ts | typescript)
                if ! lsp_bin_ok "$bindir/typescript-language-server"; then
                    # shellcheck disable=SC2206 # intentional split of the pinned list
                    npm_pkgs+=($LSP_NPM_TS)
                    npm_bins+=(typescript-language-server tsserver)
                fi
                ;;
            python)
                if ! lsp_bin_ok "$bindir/pyright-langserver"; then
                    npm_pkgs+=("$LSP_NPM_PYRIGHT")
                    npm_bins+=(pyright pyright-langserver)
                fi
                if ! lsp_bin_ok "$bindir/ruff"; then want_ruff=true; fi
                ;;
            go)
                if ! lsp_bin_ok "$bindir/gopls" && command -v go >/dev/null 2>&1; then
                    config_info "Installing gopls $LSP_GOPLS_VERSION with the host Go toolchain..."
                    if ! GOBIN="$bindir" go install "golang.org/x/tools/gopls@$LSP_GOPLS_VERSION"; then
                        config_warning "gopls install failed (see above)"
                    fi
                fi
                ;;
            rust)
                if ! lsp_bin_ok "$bindir/rust-analyzer" && command -v rustup >/dev/null 2>&1; then
                    if ! { rustup component add rust-analyzer && ln -sf "$(rustup which rust-analyzer)" "$bindir/rust-analyzer"; }; then
                        config_warning "rust-analyzer install failed (see above)"
                    fi
                fi
                ;;
            *) config_warning "Unknown LSP server '$entry' (use go,ts,python,rust); skipping" ;;
            esac
        done
        IFS="$IFS_save"
    fi
    if [ "$FORMATTERS_ENABLED" = true ]; then
        if ! lsp_bin_ok "$bindir/prettier"; then
            npm_pkgs+=("$FMT_NPM_PRETTIER")
            npm_bins+=(prettier)
        fi
        if ! lsp_bin_ok "$bindir/ruff"; then want_ruff=true; fi
    fi
    if [ "${#npm_pkgs[@]}" -eq 0 ] && [ "$want_ruff" = false ]; then
        # Nothing missing: record the stamp so future version bumps are
        # detected, then stay silent (no per-run "Installing..." noise).
        lsp_expected_stamp >"$bindir/.lsp-versions" 2>/dev/null || true
        _LSP_FORMATTERS_DONE=1
        return 0
    fi
    local image="${IMAGE_NAME:-claude-dockerized:latest}"
    if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
        config_warning "LSP/formatters pending: build the image first (claude-dockerized build), then run again."
        _LSP_FORMATTERS_DONE=1
        return 0
    fi

    # Runs inside the image as the host user; the only writable mount is the
    # generated home's .local/bin.
    # shellcheck disable=SC2016 # expanded inside the container
    local script='
set -e
dest=/opt/lsp-bin
if [ -n "$NPM_PKGS" ]; then
    # shellcheck disable=SC2086
    npm install --prefix "$dest/.lsp/node" --no-audit --no-fund --ignore-scripts --no-save $NPM_PKGS
    local b
    for b in $NPM_BINS; do ln -sfn ".lsp/node/node_modules/.bin/$b" "$dest/$b"; done
fi
if [ "$WANT_RUFF" = true ]; then
    UV_TOOL_DIR="$dest/.lsp/uv-tools" UV_TOOL_BIN_DIR="$dest/.lsp/uv-bin" UV_CACHE_DIR=/tmp/uv-cache \
        uv tool install --force "ruff==$RUFF_VERSION"
    ln -sfn .lsp/uv-bin/ruff "$dest/ruff"
fi
'
    config_info "Installing pinned LSP/formatters in a throwaway container: ${npm_pkgs[*]}$([ "$want_ruff" = true ] && printf ' ruff==%s' "$FMT_RUFF_VERSION")"
    local out
    if ! out=$(docker run --rm --user "$(id -u):$(id -g)" --cap-drop=ALL --security-opt no-new-privileges:true \
        -e HOME=/tmp -e "NPM_PKGS=${npm_pkgs[*]}" -e "NPM_BINS=${npm_bins[*]}" \
        -e "WANT_RUFF=$want_ruff" -e "RUFF_VERSION=$FMT_RUFF_VERSION" \
        -v "$bindir:/opt/lsp-bin:rw" --entrypoint bash "$image" -c "$script" 2>&1); then
        config_warning "LSP/formatter install failed:"
        printf '%s\n' "$out" | tail -n 8 >&2
        _LSP_FORMATTERS_DONE=1
        return 0
    fi
    # Verify the links resolve before declaring success: a dangling symlink
    # (stale .lsp tree, partial uv/npm install) must retry next run, not stay
    # silent with a "success" log.
    local verify_fail=false b
    lsp_repair_uv_link "$bindir" || true
    for b in "${npm_bins[@]}"; do
        lsp_bin_ok "$bindir/$b" || { config_warning "LSP binary missing after install: $b (retry on next run)"; verify_fail=true; }
    done
    if [ "$want_ruff" = true ] && ! lsp_bin_ok "$bindir/ruff"; then
        config_warning "LSP binary missing after install: ruff (retry on next run)"
        verify_fail=true
    fi
    if [ "$verify_fail" = true ]; then
        printf '%s\n' "$out" | tail -n 8 >&2
        _LSP_FORMATTERS_DONE=1
        return 0
    fi
    lsp_expected_stamp >"$bindir/.lsp-versions" 2>/dev/null || true
    _LSP_FORMATTERS_DONE=1
    config_success "LSP/formatters installed into $bindir"
}

# Write the .lsp.json for the configured servers (paths point at the generated
# home binaries, which are on PATH inside the container).
# Usage: write_lsp_json <output>
write_lsp_json() {
    local output="$1" first=true
    {
        printf '{\n'
        local IFS_save="$IFS"
        IFS=','
        local entry
        for entry in $LSP_SERVERS; do
            entry="$(printf '%s' "$entry" | sed 's/^ *//;s/ *$//')"
            case "$entry" in
            go) lang='"go": {"command": "gopls", "args": ["serve"], "extensionToLanguage": {".go": "go"}}' ;;
            ts|typescript) lang='"typescript": {"command": "typescript-language-server", "args": ["--stdio"], "extensionToLanguage": {".ts": "typescript", ".tsx": "typescript", ".js": "javascript", ".jsx": "javascript"}}' ;;
            python) lang='"python": {"command": "pyright-langserver", "args": ["--stdio"], "extensionToLanguage": {".py": "python"}}' ;;
            rust) lang='"rust": {"command": "rust-analyzer", "args": [], "extensionToLanguage": {".rs": "rust"}}' ;;
            *) continue ;;
            esac
            if [ "$first" = true ]; then first=false; else printf ',\n'; fi
            printf '  %s' "$lang"
        done
        IFS="$IFS_save"
        printf '\n}\n'
    } >"$output" 2>/dev/null || true
}