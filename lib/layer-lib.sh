#!/bin/bash
# layer-lib.sh - the security layer: managed policy, user settings, hooks mirror, sync and checks
# Sourced by lib/config-lib.sh (which keeps the constants, config parsing and
# saving). Not executable directly; no `set -e`: callers own error handling.

# Ensure all required Claude Code directories exist on host, inside the
# self-contained CCODE_HOME tree (see CONSTANTS). Fresh start only: existing
# files are never overwritten, and the host XDG dirs are left untouched.
ensure_claude_dirs() {
    mkdir -p "$CCODE_HOME/.claude/hooks-guard/policies" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.claude/plugins" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.claude/skills" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.claude/agents" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.claude/commands" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.local/bin" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.local/share/claude" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.local/state/claude" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.cache/claude" 2>/dev/null || true
    # Credentials placeholder (0600): created once so the fine-grained bind
    # mount has a source even before the first `claude auth login`.
    if [ ! -f "$CCODE_HOME/.claude/.credentials.json" ]; then
        : >"$CCODE_HOME/.claude/.credentials.json" 2>/dev/null || true
        chmod 600 "$CCODE_HOME/.claude/.credentials.json" 2>/dev/null || true
    fi
    # MCP OAuth store for `mcp-remote` servers (0700, tokens are credentials).
    # Lives in the generated home: the host ~/.mcp-auth is never shared.
    mkdir -p "$CCODE_HOME/.mcp-auth" 2>/dev/null || true
    chmod 700 "$CCODE_HOME/.mcp-auth" 2>/dev/null || true
    # claude-dockerized directory + generated security layer
    ensure_claude_dockerized_config
}

# Create only the mount sources build_standard_volume_args needs, without
# regenerating the security layer or reinstalling LSP/formatters. Called on
# the second pass of a `run` (check_config already did the full ensure).
# Usage: ensure_claude_mount_sources
ensure_claude_mount_sources() {
    mkdir -p "$CCODE_HOME/.claude/hooks-guard/policies" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.claude/plugins" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.claude/skills" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.claude/agents" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.claude/commands" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.local/bin" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.local/share/claude" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.local/state/claude" 2>/dev/null || true
    mkdir -p "$CCODE_HOME/.cache/claude" 2>/dev/null || true
    if [ ! -f "$CCODE_HOME/.claude/.credentials.json" ]; then
        : >"$CCODE_HOME/.claude/.credentials.json" 2>/dev/null || true
        chmod 600 "$CCODE_HOME/.claude/.credentials.json" 2>/dev/null || true
    fi
    [ -f "$CCODE_HOME/.claude.json" ] || printf '{}\n' >"$CCODE_HOME/.claude.json" 2>/dev/null || true
    mkdir -p "$HOME/.mcp-auth" 2>/dev/null || true
}

# Ensure the claude-dockerized directory and its generated security layer exist.
# This directory is the host-side source of truth for the sandbox: its
# CLAUDE.md rules, native hooks and policy data are mirrored read-only into
# the generated home, next to the rendered managed policy (never mounted as a
# whole, so a session cannot reach or edit these sources).
# Files are only created when missing — user edits are never overwritten.
# Check whether a file parses as JSON. Tries node, then python3; without either
# the check is skipped (return 2 = unknown, never a false failure).
# Usage: json_valid <file> (0 valid, 1 invalid, 2 unknown)
json_valid() {
    if command -v node >/dev/null 2>&1; then
        node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$1" >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
        return $?
    fi
    return 2
}

# Render the managed Claude policy (config/managed-settings.json in the repo)
# to <output>, honoring the parsed wrapper settings. Pure bash + sed on known
# key lines, so the security policy never depends on optional host tooling:
#   - setting.cleanup_days  -> cleanupPeriodDays (line dropped when empty)
#   - security_policy        -> env.CLAUDE_DOCKERIZED_POLICY (pinned mode);
#                              strict also adds allowManagedPermissionRulesOnly
#   - setting.formatters    -> enabledPlugins; plugin hooks need
#                              allowManagedHooksOnly off, so it is dropped
# The model is never written: it travels as --model (see bin/claude-dockerized)
# so /model keeps working and persists in the user settings.
# Usage: write_managed_settings <output>
write_managed_settings() {
    local output="$1" repo_dir
    repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    local src="$repo_dir/config/managed-settings.json"
    [ -f "$src" ] || return 1

    local -a sed_args=()
    case "$CLEANUP_DAYS" in
    '') sed_args+=(-e '/^  "cleanupPeriodDays": /d') ;;
    *[!0-9]*) sed_args+=(-e '/^  "cleanupPeriodDays": /d') ;;
    *) sed_args+=(-e "s/^  \"cleanupPeriodDays\": [0-9]*,/  \"cleanupPeriodDays\": $CLEANUP_DAYS,/") ;;
    esac
    # Pin the policy mode in the managed env (project settings cannot inject
    # another one); only known modes reach the file.
    case "$SECURITY_POLICY" in
    strict | none) sed_args+=(-e "s/^    \"CLAUDE_DOCKERIZED_POLICY\": \"balanced\"/    \"CLAUDE_DOCKERIZED_POLICY\": \"$SECURITY_POLICY\"/") ;;
    esac
    if [ "$SECURITY_POLICY" = strict ]; then
        sed_args+=(-e '/^  "allowManagedHooksOnly": true,/a\
  "allowManagedPermissionRulesOnly": true,')
    fi
    if [ "$FORMATTERS_ENABLED" = true ]; then
        sed_args+=(-e 's/^  "allowManagedHooksOnly": true,/  "enabledPlugins": {"prettier@claude": true, "ruff@claude": true},/')
    fi

    sed "${sed_args[@]}" "$src" >"$output" 2>/dev/null || return 1
    local v=0
    json_valid "$output" || v=$?
    [ "$v" -eq 1 ] && return 1
    return 0
}

# Seed or migrate the user-level ~/.claude/settings.json (read-write in the
# container, so /model, /config and /permissions persist). A missing file is
# seeded from config/user-settings.default.json; a legacy file that still
# carries the old wrapper-managed policy or disableAllHooks (T-16) is backed
# up to .bak and rewritten with only the user's own keys
# (lib/migrate-settings.js). Without node the legacy file is backed up and
# reseeded. Otherwise the file is never touched.
# Usage: ensure_user_settings <settings.json>
ensure_user_settings() {
    local target="$1" repo_dir
    repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    local defaults="$repo_dir/config/user-settings.default.json"
    [ -f "$defaults" ] || return 0

    if [ ! -f "$target" ]; then
        cp "$defaults" "$target" 2>/dev/null && config_success "Seeded user settings at $target"
        return 0
    fi
    grep -qE 'claude-guard-bash\.sh|"disableAllHooks"' "$target" 2>/dev/null || return 0

    cp "$target" "$target.bak" 2>/dev/null || return 0
    local migrated
    migrated=$(mktemp 2>/dev/null) || return 0
    if command -v node >/dev/null 2>&1 &&
        node "$repo_dir/lib/migrate-settings.js" "$target" "$defaults" "$migrated" >/dev/null 2>&1; then
        cat "$migrated" >"$target" 2>/dev/null || true
        config_success "Migrated settings.json to user scope (policy now in managed-settings.json; backup kept)"
    else
        cat "$defaults" >"$target" 2>/dev/null || true
        config_warning "Reseeded user settings.json from defaults (legacy copy kept as settings.json.bak)"
    fi
    rm -f "$migrated"
}

# Atomically replace <dest> with <src> (same-dir temp + mv, so a concurrent
# session never reads a half-written file). Usage: atomic_install <src> <dest>
atomic_install() {
    local src="$1" dest="$2" tmp
    tmp=$(mktemp "$dest.tmp.XXXXXX" 2>/dev/null) || return 1
    if cat "$src" >"$tmp" 2>/dev/null && chmod 644 "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
}

# Directory holding this library's checkout root (lib/ -> repo root), used to
# locate the versioned security sources. Usage: repo_dir=$(layer_repo_dir)
layer_repo_dir() {
    cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd
}

# Install the native PreToolUse hooks from the versioned repo copy.
# Usage: install_guard_hooks <repo_dir>
install_guard_hooks() {
    local repo_dir="$1"
    # Install the native PreToolUse hooks from the versioned repo copy
    # (hooks/*.sh + hooks/guard-eval.js) so the guard can be linted and
    # reviewed like the rest of the code. When the installed copy predates the
    # current guard version (marker string below), it is backed up and
    # refreshed — never silently overwritten.
    local guard_src_bash="$repo_dir/hooks/claude-guard-bash.sh"
    local guard_src_file="$repo_dir/hooks/claude-guard-file.sh"
    local guard_src_eval="$repo_dir/hooks/guard-eval.js"
    local installed_guard_ver repo_guard_ver
    installed_guard_ver=$(grep -oE 'CLAUDE_DOCKERIZED_GUARD_VERSION=[0-9]+' "$CONFIG_DIR/hooks/claude-guard-bash.sh" 2>/dev/null | head -1)
    repo_guard_ver=$(grep -oE 'CLAUDE_DOCKERIZED_GUARD_VERSION=[0-9]+' "$guard_src_bash" 2>/dev/null | head -1)
    # Content, not just the marker, decides (T-15): an edited or tampered copy
    # that keeps the version string is refreshed too (backed up first).
    local guard_differs=false gf
    for gf in claude-guard-bash.sh claude-guard-file.sh guard-eval.js; do
        [ -f "$repo_dir/hooks/$gf" ] || continue
        cmp -s "$repo_dir/hooks/$gf" "$CONFIG_DIR/hooks/$gf" 2>/dev/null || guard_differs=true
    done
    if [ ! -f "$CONFIG_DIR/hooks/claude-guard-bash.sh" ] || [ "$installed_guard_ver" != "$repo_guard_ver" ] || [ "$guard_differs" = true ]; then
        if [ -f "$guard_src_bash" ] && [ -f "$guard_src_file" ]; then
            if [ -f "$CONFIG_DIR/hooks/claude-guard-bash.sh" ]; then
                cp "$CONFIG_DIR/hooks/claude-guard-bash.sh" "$CONFIG_DIR/hooks/claude-guard-bash.sh.bak" 2>/dev/null || true
                cp "$CONFIG_DIR/hooks/claude-guard-file.sh" "$CONFIG_DIR/hooks/claude-guard-file.sh.bak" 2>/dev/null || true
                [ -f "$CONFIG_DIR/hooks/guard-eval.js" ] && cp "$CONFIG_DIR/hooks/guard-eval.js" "$CONFIG_DIR/hooks/guard-eval.js.bak" 2>/dev/null
                config_warning "Backed up previous guard hooks to *.bak"
            fi
            if cp "$guard_src_bash" "$CONFIG_DIR/hooks/claude-guard-bash.sh" 2>/dev/null \
                && cp "$guard_src_file" "$CONFIG_DIR/hooks/claude-guard-file.sh" 2>/dev/null; then
                chmod +x "$CONFIG_DIR/hooks/claude-guard-bash.sh" "$CONFIG_DIR/hooks/claude-guard-file.sh" 2>/dev/null || true
                [ -f "$guard_src_eval" ] && cp "$guard_src_eval" "$CONFIG_DIR/hooks/guard-eval.js" 2>/dev/null || true
                config_success "Installed security hooks at $CONFIG_DIR/hooks/"
            else
                config_warning "Could not install security hooks (copy failed; base rules still active)"
            fi
        else
            config_warning "Security hooks source not found in $repo_dir/hooks (base rules still active)"
        fi
    else
        [ -f "$guard_src_eval" ] && [ ! -f "$CONFIG_DIR/hooks/guard-eval.js" ] && cp "$guard_src_eval" "$CONFIG_DIR/hooks/guard-eval.js" 2>/dev/null || true
        chmod +x "$CONFIG_DIR/hooks/claude-guard-bash.sh" "$CONFIG_DIR/hooks/claude-guard-file.sh" 2>/dev/null || true
    fi
}

# Seed/refresh the vendored policy pattern data.
# Usage: install_policy_data <repo_dir>
install_policy_data() {
    local repo_dir="$1"
    # Seed/refresh the vendored policy pattern data. The set is versioned
    # (policies/VERSION): when the repo version differs from the installed one,
    # or any rule file (or the marker) is missing, the copies are refreshed
    # (existing files backed up first). The source lives next to this library
    # in the repo (policies/); the copies are mirrored read-only into the
    # container hooks-guard dir (see below).
    local policy_src policy_dest
    policy_src="$repo_dir/policies"
    policy_dest="$CONFIG_DIR/hooks/policies"
    mkdir -p "$policy_dest" 2>/dev/null || true

    local -a policy_files=(unsafe-tool-patterns.json prompt-injection-patterns.json allow-patterns.json)
    local src_ver inst_ver pf policy_refresh=false
    src_ver=""
    inst_ver=""
    [ -f "$policy_src/VERSION" ] && src_ver=$(cat "$policy_src/VERSION" 2>/dev/null || true)
    [ -f "$policy_dest/VERSION" ] && inst_ver=$(cat "$policy_dest/VERSION" 2>/dev/null || true)
    [ ! -f "$policy_dest/VERSION" ] && policy_refresh=true
    [ "$src_ver" != "$inst_ver" ] && policy_refresh=true
    for pf in "${policy_files[@]}"; do
        [ -f "$policy_dest/$pf" ] || policy_refresh=true
    done
    # The vendored deny sets must match the repo byte for byte (T-15); only
    # allow-patterns.json is a local customization point.
    for pf in unsafe-tool-patterns.json prompt-injection-patterns.json; do
        [ -f "$policy_src/$pf" ] || continue
        cmp -s "$policy_src/$pf" "$policy_dest/$pf" 2>/dev/null || policy_refresh=true
    done

    if [ "$policy_refresh" = true ]; then
        for pf in "${policy_files[@]}"; do
            if [ -f "$policy_dest/$pf" ] && [ -f "$policy_src/$pf" ]; then
                cp "$policy_dest/$pf" "$policy_dest/$pf.bak" 2>/dev/null || true
            fi
        done
        for pf in "${policy_files[@]}"; do
            if [ -f "$policy_src/$pf" ]; then
                if cp "$policy_src/$pf" "$policy_dest/$pf" 2>/dev/null; then
                    config_success "Installed policy patterns at $policy_dest/$pf"
                else
                    config_warning "Could not install $pf (copy failed; base rules still active)"
                fi
            else
                config_warning "Policy source not found at $policy_src/$pf (base rules still active)"
            fi
        done
        if [ -f "$policy_src/VERSION" ]; then
            cp "$policy_src/VERSION" "$policy_dest/VERSION" 2>/dev/null || true
        fi
    fi
}

# True when <file> carries every marker of the current session-rules template;
# older copies are regenerated (with a backup) by install_session_rules.
# Usage: session_rules_current <file>
session_rules_current() {
    local file="$1" marker
    [ -f "$file" ] || return 1
    for marker in "Language Tooling" "## Tool Usage" "## Core Workflow" "private-keys-v1.d" "id_ed25519" \
        "setting.env_file" "Manejo remoto" "managed-settings.json" "/permissions"; do
        grep -qF -- "$marker" "$file" 2>/dev/null || return 1
    done
}

# (Re)generate the managed session rules ($CONFIG_DIR/CLAUDE.md) from
# config/session-rules.md when missing or predating the template markers. A
# pre-existing file is backed up first.
# Usage: install_session_rules <repo_dir>
install_session_rules() {
    local src="$1/config/session-rules.md"
    session_rules_current "$CONFIG_DIR/CLAUDE.md" && return 0
    if [ ! -f "$src" ]; then
        config_warning "Session rules template not found at $src (previous CLAUDE.md kept)"
        return 0
    fi
    if [ -f "$CONFIG_DIR/CLAUDE.md" ]; then
        cp "$CONFIG_DIR/CLAUDE.md" "$CONFIG_DIR/CLAUDE.md.bak" 2>/dev/null || true
        config_warning "Backed up previous CLAUDE.md to CLAUDE.md.bak"
    fi
    if cp "$src" "$CONFIG_DIR/CLAUDE.md" 2>/dev/null; then
        config_success "Created security rules at $CONFIG_DIR/CLAUDE.md"
    else
        config_warning "Could not install the session rules (copy failed)"
    fi
}

# Mirror the security layer into the generated home.
# Usage: mirror_security_layer
mirror_security_layer() {
    local pf
    # Mirror the security layer into the generated home: hooks-guard and
    # CLAUDE.md (read-only overlays) and the managed policy (etc/claude-code).
    # These copies are wrapper-managed and overwritten on every run, so edit
    # the sources in "$CONFIG_DIR" instead.
    local claude_dir="$CCODE_HOME/.claude"
    if [ -d "$claude_dir" ]; then
        mkdir -p "$claude_dir/hooks-guard/policies" 2>/dev/null || true
        if [ -f "$CONFIG_DIR/hooks/claude-guard-bash.sh" ]; then
            cp "$CONFIG_DIR/hooks/claude-guard-bash.sh" "$claude_dir/hooks-guard/claude-guard-bash.sh" 2>/dev/null || true
            cp "$CONFIG_DIR/hooks/claude-guard-file.sh" "$claude_dir/hooks-guard/claude-guard-file.sh" 2>/dev/null || true
            chmod +x "$claude_dir/hooks-guard/"*.sh 2>/dev/null || true
        fi
        if [ -f "$CONFIG_DIR/hooks/guard-eval.js" ]; then
            cp "$CONFIG_DIR/hooks/guard-eval.js" "$claude_dir/hooks-guard/guard-eval.js" 2>/dev/null || true
        fi
        for pf in unsafe-tool-patterns.json prompt-injection-patterns.json allow-patterns.json; do
            if [ -f "$CONFIG_DIR/hooks/policies/$pf" ]; then
                cp "$CONFIG_DIR/hooks/policies/$pf" "$claude_dir/hooks-guard/policies/$pf" 2>/dev/null || true
            fi
        done
        if [ -f "$CONFIG_DIR/hooks/policies/VERSION" ]; then
            cp "$CONFIG_DIR/hooks/policies/VERSION" "$claude_dir/hooks-guard/policies/VERSION" 2>/dev/null || true
        fi
        if [ -f "$CONFIG_DIR/CLAUDE.md" ]; then
            cp "$CONFIG_DIR/CLAUDE.md" "$claude_dir/CLAUDE.md" 2>/dev/null || true
        fi
        # Pin the policy mode next to the hooks (read-only mount): the hooks
        # prefer it over the env var, which project settings could inject.
        printf '%s\n' "${SECURITY_POLICY:-balanced}" >"$claude_dir/hooks-guard/policy-mode" 2>/dev/null ||
            config_warning "Could not pin the policy mode in hooks-guard/policy-mode (hooks would fall back to the environment)"
        # Regenerate the managed policy (mounted read-only at /etc/claude-code,
        # highest precedence: user and project settings cannot relax it) and
        # seed/migrate the read-write user settings.
        local managed_dir="$CCODE_HOME/etc/claude-code" managed_tmp
        mkdir -p "$managed_dir" 2>/dev/null || true
        managed_tmp=$(mktemp 2>/dev/null) || managed_tmp=""
        if [ -n "$managed_tmp" ]; then
            if write_managed_settings "$managed_tmp"; then
                atomic_install "$managed_tmp" "$managed_dir/managed-settings.json" ||
                    config_warning "Could not write managed-settings.json"
            else
                config_warning "Could not render managed-settings.json (previous copy kept)"
            fi
            rm -f "$managed_tmp"
        fi
        ensure_user_settings "$claude_dir/settings.json"
        # LSP config (regenerated when enabled so server paths stay correct);
        # formatters alone also need their binaries.
        [ "$LSP_ENABLED" = true ] && write_lsp_json "$claude_dir/.lsp.json"
        ensure_lsp_formatters
    fi
}

# Remove legacy artifacts of the previous generation.
# Usage: remove_legacy_artifacts
remove_legacy_artifacts() {
    # Remove legacy artifacts from the previous generation (kept out of the
    # new tree so stale mounts cannot shadow the fine-grained ones).
    # NOTE(legacy-migration): the paths below name the previous generation on
    # purpose; they are only ever removed, never read or mounted.
    rm -f "$CCODE_HOME/.config/opencode/opencode.json" 2>/dev/null || true # legacy-migration
    rm -f "$CONFIG_DIR/opencode.json" 2>/dev/null || true # legacy-migration
    if [ -f "$CONFIG_DIR/plugins/security-guard.js" ]; then
        mv "$CONFIG_DIR/plugins/security-guard.js" "$CONFIG_DIR/plugins/security-guard.js.legacy-bak" 2>/dev/null || true
        config_info "Retired legacy plugins/security-guard.js (native hooks replace it)"
    fi
    local shared_link="$HOME/.config/opencode/plugins/security-guard.js" # legacy-migration
    if [ -L "$shared_link" ]; then
        local link_target
        link_target=$(readlink "$shared_link" 2>/dev/null || true)
        case "$link_target" in
        *opencode-dockerized*|*claude-dockerized*) # legacy-migration
            rm -f "$shared_link" 2>/dev/null || true
            config_info "Removed legacy security-guard symlink from host config"
            ;;
        esac
    fi
}



ensure_claude_dockerized_config() {
    mkdir -p "$CONFIG_DIR/hooks/policies" 2>/dev/null || return 0

    local repo_dir
    repo_dir="$(layer_repo_dir)"

    install_guard_hooks "$repo_dir"
    install_policy_data "$repo_dir"
    install_session_rules "$repo_dir"
    mirror_security_layer
    remove_legacy_artifacts
}

# Compare the versioned security layer (repo sources vs installed copies).
# Prints one status line per component and returns 1 when anything is stale.
# Pure reads only; never writes. Backs `config sync --check`.
# Usage: check_security_layer
check_security_layer() {
    local stale=false
    local repo_dir
    repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

    local repo_guard inst_guard
    repo_guard=$(grep -oE 'CLAUDE_DOCKERIZED_GUARD_VERSION=[0-9]+' "$repo_dir/hooks/claude-guard-bash.sh" 2>/dev/null | head -1)
    inst_guard=$(grep -oE 'CLAUDE_DOCKERIZED_GUARD_VERSION=[0-9]+' "$CONFIG_DIR/hooks/claude-guard-bash.sh" 2>/dev/null | head -1)
    if [ -n "$repo_guard" ] && [ "$repo_guard" = "$inst_guard" ]; then
        config_success "guard hooks $repo_guard (in sync)"
    else
        config_warning "guard hooks stale (repo ${repo_guard:-missing} vs installed ${inst_guard:-missing})"
        stale=true
    fi

    local src_ver inst_ver
    src_ver=$(cat "$repo_dir/policies/VERSION" 2>/dev/null || true)
    inst_ver=$(cat "$CONFIG_DIR/hooks/policies/VERSION" 2>/dev/null || true)
    if [ -n "$src_ver" ] && [ "$src_ver" = "$inst_ver" ]; then
        config_success "policy patterns v$src_ver (in sync)"
    else
        config_warning "policy patterns stale (repo ${src_ver:-missing} vs installed ${inst_ver:-missing})"
        stale=true
    fi

    # The managed policy must match a fresh render of the repo template for
    # the current wrapper config (sync rewrites it otherwise); any other
    # difference is drift or tampering.
    local managed_settings="$CCODE_HOME/etc/claude-code/managed-settings.json" rendered
    rendered=$(mktemp 2>/dev/null) || rendered=""
    if [ -n "$rendered" ] && write_managed_settings "$rendered" && cmp -s "$rendered" "$managed_settings"; then
        config_success "managed-settings.json (in sync)"
    else
        config_warning "managed-settings.json stale or missing"
        stale=true
    fi
    [ -n "$rendered" ] && rm -f "$rendered"

    # The user settings must exist, parse, and carry neither the legacy
    # wrapper policy nor disableAllHooks (T-16; sync migrates both away).
    local user_settings="$CCODE_HOME/.claude/settings.json" v=0
    if [ ! -f "$user_settings" ]; then
        config_warning "user settings.json missing (seeded on sync)"
        stale=true
    elif grep -q 'claude-guard-bash.sh' "$user_settings" 2>/dev/null; then
        config_warning "user settings.json still carries the legacy policy (migrated on sync)"
        stale=true
    elif grep -q '"disableAllHooks"' "$user_settings" 2>/dev/null; then
        config_warning "user settings.json sets disableAllHooks (dropped on sync)"
        stale=true
    else
        json_valid "$user_settings" || v=$?
        if [ "$v" -eq 1 ]; then
            config_warning "user settings.json is not valid JSON (reseeded on sync)"
            stale=true
        else
            config_success "user settings.json (writable preferences)"
        fi
    fi

    # Managed session rules must carry the current markers (sync regenerates
    # them with a backup when they predate the template).
    if session_rules_current "$CONFIG_DIR/CLAUDE.md"; then
        config_success "CLAUDE.md rules (in sync)"
    else
        config_warning "CLAUDE.md rules stale or missing"
        stale=true
    fi

    # The fine-grained mounts must carry the installed layer.
    local mirror_guard
    mirror_guard=$(grep -oE 'CLAUDE_DOCKERIZED_GUARD_VERSION=[0-9]+' "$CCODE_HOME/.claude/hooks-guard/claude-guard-bash.sh" 2>/dev/null | head -1)
    if [ -n "$inst_guard" ] && [ "$mirror_guard" = "$inst_guard" ]; then
        config_success "hooks-guard mirror $mirror_guard (in sync)"
    else
        config_warning "hooks-guard mirror stale (installed ${inst_guard:-missing} vs mirror ${mirror_guard:-missing})"
        stale=true
    fi

    # The pinned mode must be the configured one: without it the hooks fall back
    # to an environment variable that project settings could inject.
    local pinned_mode
    pinned_mode=$(head -n 1 "$CCODE_HOME/.claude/hooks-guard/policy-mode" 2>/dev/null)
    if [ "$pinned_mode" != "${SECURITY_POLICY:-balanced}" ]; then
        config_warning "hooks-guard policy-mode is '${pinned_mode:-missing}' (expected '${SECURITY_POLICY:-balanced}'; reseeded on sync)"
        stale=true
    fi

    if [ ! -f "$CCODE_HOME/.claude/hooks-guard/policies/VERSION" ]; then
        config_warning "hooks-guard policies mirror missing (reseeded on sync)"
        stale=true
    fi

    # Byte-for-byte integrity of the enforced layer (T-15): a hook or deny set
    # edited without bumping its version marker is drift (or tampering).
    local lf mirror="$CCODE_HOME/.claude/hooks-guard" content_ok=true
    for lf in claude-guard-bash.sh claude-guard-file.sh guard-eval.js \
        policies/unsafe-tool-patterns.json policies/prompt-injection-patterns.json; do
        local src="$repo_dir/hooks/$lf"
        [[ "$lf" == policies/* ]] && src="$repo_dir/$lf"
        if ! cmp -s "$src" "$CONFIG_DIR/hooks/$lf" 2>/dev/null; then
            config_warning "$lf differs from the repo copy (local edit or tampering; sync restores it, keeping a .bak)"
            content_ok=false
        elif ! cmp -s "$CONFIG_DIR/hooks/$lf" "$mirror/$lf" 2>/dev/null; then
            config_warning "$lf mirror differs from the installed copy (re-mirrored on sync)"
            content_ok=false
        fi
    done
    if ! cmp -s "$CONFIG_DIR/hooks/policies/allow-patterns.json" "$mirror/policies/allow-patterns.json" 2>/dev/null; then
        config_warning "allow-patterns.json mirror differs from the installed copy (re-mirrored on sync)"
        content_ok=false
    fi
    if [ "$content_ok" = true ]; then
        config_success "guard and policy content verified (byte-identical to the repo)"
    else
        stale=true
    fi

    # The user-managed MCP file is never touched by sync, but an unparsable
    # file breaks sessions: fail the check early.
    local uoc
    for uoc in "$CCODE_HOME/.claude.json" "$CCODE_HOME/.claude/.mcp.json"; do
        [ -f "$uoc" ] || continue
        v=0; json_valid "$uoc" || v=$?
        if [ "$v" -eq 1 ]; then
            config_warning "$uoc is not valid JSON (fix it; sync never edits this file)"
            stale=true
        fi
    done

    # LSP config must parse when LSP support is enabled.
    if [ "$LSP_ENABLED" = true ]; then
        local lsp_json="$CCODE_HOME/.claude/.lsp.json"
        if [ ! -f "$lsp_json" ]; then
            config_warning ".lsp.json missing (reseeded on sync)"
            stale=true
        else
            v=0; json_valid "$lsp_json" || v=$?
            if [ "$v" -eq 0 ]; then
                config_success ".lsp.json valid (in sync)"
            elif [ "$v" -eq 1 ]; then
                config_warning ".lsp.json is not valid JSON (reseeded on sync)"
                stale=true
            fi
        fi
    fi

    # The secrets file is never read for values here; only its permissions.
    if [ -n "${ENV_FILE:-}" ]; then
        # setting.env_file may start with ~: resolve it like build_env_file_args does
        local env_file_path
        env_file_path=$(canonical_host_path "$ENV_FILE")
        if [ ! -f "$env_file_path" ]; then
            config_warning "env file not found: $ENV_FILE"
            stale=true
        else
            local mode=""
            mode=$(stat -c '%a' "$env_file_path" 2>/dev/null || stat -f '%Lp' "$env_file_path" 2>/dev/null || true)
            if [ -n "$mode" ] && [ $((8#$mode & 8#044)) -ne 0 ]; then
                config_warning "env file is readable by group/others ($ENV_FILE); run: chmod 600"
            else
                config_success "env file permissions ok"
            fi
        fi
    fi

    # Global host integration (bin/ on PATH + rc lines): informational only.
    # It is shell convenience, not the security layer, so declining aliases
    # or completions never reads as drift. `claude-dockerized install`
    # repairs it; sync never edits rc files.
    check_global_install || config_info "Shell integration is incomplete (see above); run 'claude-dockerized install' to repair it."

    if [ "$stale" = true ]; then
        return 1
    fi
    return 0
}

# Print a one-line hint when the installed security layer drifts from the repo.
# Pure reads only (see check_security_layer).
# Usage: maybe_drift_hint
maybe_drift_hint() {
    check_security_layer >/dev/null 2>&1 || echo "Security layer drift detected: run 'claude-dockerized config sync' to refresh."
}

# Refresh the versioned security layer from the repo and report the result.
# With --check it only reports drift (exit 1 when stale) and writes nothing.
# Local-only: no Docker required.
# Usage: sync_security_layer [--check]
sync_security_layer() {
    case "${1:-}" in
    "" | --check) ;;
    *)
        config_error "Usage: claude-dockerized config sync [--check]"
        return 1
        ;;
    esac
    # Host-only: inside a container CONFIG_DIR is ephemeral, so syncing there
    # creates a junk layer instead of updating the host. Tests override with
    # CLAUDE_DOCKERIZED_ALLOW_CONTAINER_SYNC=1.
    if [ -z "${CLAUDE_DOCKERIZED_ALLOW_CONTAINER_SYNC:-}" ] && { [ -f /.dockerenv ] || [ -f /run/.containerenv ]; }; then
        config_error "config sync is host-only; run it on the host, not inside a container."
        return 1
    fi
    if [ "${1:-}" = "--check" ]; then
        if check_security_layer; then
            config_success "Security layer is in sync with the repo."
            return 0
        fi
        config_error "Security layer is stale; run 'config sync' without --check to refresh."
        return 1
    fi

    config_info "Refreshing security layer from the repo..."
    ensure_claude_dirs
    ensure_claude_dockerized_config
    # Repair an unparsable user settings.json (preferences are only lost
    # when the file is already broken; the broken copy is kept as .bak).
    local user_settings="$CCODE_HOME/.claude/settings.json" v
    if [ -f "$user_settings" ]; then
        v=0; json_valid "$user_settings" || v=$?
        if [ "$v" -eq 1 ]; then
            mv "$user_settings" "$user_settings.bak" 2>/dev/null || true
            ensure_user_settings "$user_settings"
            config_warning "Backed up broken settings.json to settings.json.bak and reseeded it"
        fi
    fi
    # Drop the legacy ~/.local/bin symlink (nothing is ever installed there
    # anymore; the binary is reached via <install>/bin on PATH). A real file
    # is never touched. Binaries must stay executable for PATH resolution.
    # Also drop the obsolete second `install` binary: bin/ holds only
    # `claude-dockerized` now (kept in sync as the config sync always does).
    cleanup_legacy_symlink || true
    local stale_install=""
    stale_install="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin" 2>/dev/null && pwd)/install"
    if [ -n "$stale_install" ] && [ -e "$stale_install" ]; then
        rm -f "$stale_install" 2>/dev/null || true
        config_info "Removed obsolete install binary ($stale_install; use 'claude-dockerized install')"
    fi
    if [ -e "$CCODE_BIN_DIR/install" ]; then
        rm -f "$CCODE_BIN_DIR/install" 2>/dev/null || true
        config_info "Removed obsolete $CCODE_BIN_DIR/install (use 'claude-dockerized install')"
    fi
    local want_bin
    want_bin=$(repo_script_path)
    if [ -n "$want_bin" ] && [ -e "$want_bin" ] && [ ! -x "$want_bin" ]; then
        if chmod +x "$want_bin" 2>/dev/null; then
            config_success "Made the claude-dockerized binary executable"
        else
            config_warning "Binary is not executable ($want_bin)"
        fi
    fi
    echo ""
    if check_security_layer; then
        config_success "Security layer synced with the repo."
        return 0
    fi
    config_warning "Security layer still reports stale items after refresh (see above)."
    return 1
}

# Reject inline secrets in Claude configs: every credential must use
# environment-variable substitution or an apiKeyHelper script so secrets never
# rest in a file the agent can read. Heuristic on key names; only offending key
# names are reported, never values.
# Called on every run; exits non-zero with remediation.
# Usage: validate_claude_config || exit 1
validate_claude_config() {
    local oc
    for oc in "$CCODE_HOME/etc/claude-code/managed-settings.json" "$CCODE_HOME/.claude/settings.json" "$CCODE_HOME/.claude.json"; do
        [ -f "$oc" ] || continue
        local hits m keys=""
        hits=$(grep -oE '"[A-Za-z0-9_.-]*(apiKey|api_key|api-key|accessToken|access_token|clientSecret|client_secret|token|secret|password|passwd|authorization|bearer|API_KEY|SECRET|TOKEN|PASSWORD|PASSWD)[A-Za-z0-9_.-]*"[[:space:]]*:[[:space:]]*"[^"]*"' "$oc" 2>/dev/null || true)
        [ -n "$hits" ] || continue
        while IFS= read -r m; do
            # shellcheck disable=SC2016 # '$' is an intentional literal (env-var refs like $VAR/${VAR})
            case "$m" in
            *'$'* | *apiKeyHelper*) continue ;;
            esac
            keys="$keys $(printf '%s' "$m" | grep -oE '^"[A-Za-z_.-]+\"' || true)"
        done <<<"$hits"
        case "$keys" in
        "" | " ") ;;
        *)
            config_error "Inline secrets in $oc ($keys ): move credentials to env references or apiKeyHelper."
            config_info "Put the values in setting.env_file instead (see README)."
            return 1
            ;;
        esac
    done
    return 0
}