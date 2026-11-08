#!/bin/bash
# layer-lib.sh - the security layer: managed policy, user settings, hooks mirror, sync and checks
# Sourced by lib/config-lib.sh (which keeps the constants, config parsing and
# saving). Not executable directly; no `set -e`: callers own error handling.

# --- Host writes into the generated home ------------------------------------
# Most of $CCODE_HOME is mounted read-write, so a session can leave a symlink,
# a FIFO or a directory exactly where the wrapper writes next time. A plain
# `>`, cp or chmod would follow such a link and overwrite (or chmod) any host
# file the user can write, e.g. ~/.bashrc. Every host write into the generated
# home therefore goes through the helpers below: the content is staged in a
# private directory of $CCODE_HOME (never mounted, same filesystem) and renamed
# into place; rename(2) replaces a symlink instead of following it.

# Private staging directory (0700, never mounted). Usage: dir=$(home_stage_dir)
home_stage_dir() {
    local d="$CCODE_HOME/.wrapper-tmp"
    [ -n "${CCODE_HOME:-}" ] && [ ! -L "$d" ] || return 1
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null || return 1
    printf '%s' "$d"
}

# True when <path> is a regular file that is not a symlink: the only kind of
# generated-home file the wrapper reads or keeps (a FIFO would hang a read, a
# link would redirect it to a host file). Usage: home_file_regular <path>
home_file_regular() {
    [ ! -L "$1" ] && [ -f "$1" ]
}

# Write stdin to <dest> (mode 644 by default) without following a symlink at
# <dest>; refuses when <dest> is a directory or its parent is a symlink.
# Usage: <producer> | safe_write_file <dest> [mode]
safe_write_file() {
    local dest="$1" mode="${2:-644}" dir stage tmp
    dir=$(dirname "$dest")
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
        config_warning "Refusing to write $dest: its directory is missing or a symlink"
        cat >/dev/null
        return 1
    fi
    if [ -d "$dest" ] && [ ! -L "$dest" ]; then
        config_warning "Refusing to write $dest: a directory is in the way (remove it on the host)"
        cat >/dev/null
        return 1
    fi
    if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
        config_warning "Replacing the symlink or special file at $dest (never followed)"
        rm -f "$dest" 2>/dev/null || true
    fi
    if ! stage=$(home_stage_dir) || ! tmp=$(mktemp "$stage/write.XXXXXX" 2>/dev/null); then
        config_warning "Could not stage a write to $dest"
        cat >/dev/null
        return 1
    fi
    if cat >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
}

# Copy <src> to <dest> through safe_write_file. <src> itself must be a regular
# file (never read through a symlink). Usage: safe_copy_file <src> <dest> [mode]
safe_copy_file() {
    home_file_regular "$1" || return 1
    safe_write_file "$2" "${3:-644}" <"$1"
}

# chmod a generated-home file only when it is a regular file (chmod follows a
# symlink to whatever host file it names). Usage: safe_chmod <mode> <path>
safe_chmod() {
    home_file_regular "$2" && chmod "$1" "$2" 2>/dev/null
}

# Make <dir> a real directory: a symlink in its place (planted by a session,
# or left behind) is removed first, so neither mkdir nor a later bind mount of
# it is redirected to a host directory. Usage: ensure_home_dir <dir> [mode]
ensure_home_dir() {
    local d="$1"
    if [ -L "$d" ]; then
        config_warning "Replacing the symlink at $d with a directory (never followed)"
        rm -f "$d" 2>/dev/null || return 1
    fi
    mkdir -p "$d" 2>/dev/null || return 1
    [ -z "${2:-}" ] || chmod "$2" "$d" 2>/dev/null || true
}

# Make <file> a regular file, seeding it from stdin when it is missing or not
# a regular file (a symlink is replaced, never followed). An existing regular
# file is kept as is. Usage: <seed> | ensure_home_file <file> <mode>
ensure_home_file() {
    local f="$1" mode="$2"
    if home_file_regular "$f"; then
        cat >/dev/null
        return 0
    fi
    safe_write_file "$f" "$mode"
}

# Create the generated-home directories and files every session mounts.
# Usage: ensure_home_tree
ensure_home_tree() {
    local d
    for d in .claude .claude/hooks-guard .claude/hooks-guard/policies .claude/plugins .claude/skills \
        .claude/agents .claude/commands .local .local/bin .local/share .local/share/claude \
        .local/state .local/state/claude .cache .cache/claude; do
        ensure_home_dir "$CCODE_HOME/$d" || true
    done
    # MCP OAuth store for `mcp-remote` servers (0700, tokens are credentials).
    # Lives in the generated home: the host ~/.mcp-auth is never shared.
    ensure_home_dir "$CCODE_HOME/.mcp-auth" 700 || true
    # Credentials placeholder (0600): created once so the fine-grained bind
    # mount has a source even before the first `claude auth login`.
    ensure_home_file "$CCODE_HOME/.claude/.credentials.json" 600 </dev/null || true
    safe_chmod 600 "$CCODE_HOME/.claude/.credentials.json" || true
    printf '{}\n' | ensure_home_file "$CCODE_HOME/.claude.json" 644 || true
}

# Ensure all required Claude Code directories exist on host, inside the
# self-contained CCODE_HOME tree (see CONSTANTS). Fresh start only: existing
# files are never overwritten, and the host XDG dirs are left untouched.
ensure_claude_dirs() {
    ensure_home_tree
    # claude-dockerized directory + generated security layer
    ensure_claude_dockerized_config
}

# Create only the mount sources build_standard_volume_args needs, without
# regenerating the security layer or reinstalling LSP/formatters. Called on
# the second pass of a `run` (check_config already did the full ensure).
# Usage: ensure_claude_mount_sources
ensure_claude_mount_sources() {
    ensure_home_tree
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
    # The active profile's own deny/ask rules go first in their arrays (the
    # template's entries follow, so every inserted line keeps its comma).
    # profile_permission_rules only lets JSON-safe rules through.
    local kind rule
    while IFS=$'\t' read -r kind rule; do
        [ -n "$kind" ] || continue
        sed_args+=(-e "/^    \"$kind\": \[\$/a\\
      \"$rule\",")
    done < <(profile_permission_rules)

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
# up to $CONFIG_DIR/backups (outside every mount) and rewritten with only the
# user's own keys (lib/migrate-settings.js). Without node the legacy file is
# backed up and reseeded. A symlink or special file in its place (planted by a
# session) is never followed: it is replaced by the defaults. Otherwise the
# file is never touched.
# Usage: ensure_user_settings <settings.json>
ensure_user_settings() {
    local target="$1" repo_dir
    repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    local defaults="$repo_dir/config/user-settings.default.json"
    [ -f "$defaults" ] || return 0

    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
        config_warning "user settings.json is a symlink or special file; replacing it with the defaults (never followed)"
        safe_copy_file "$defaults" "$target" 644
        return 0
    fi
    if [ ! -f "$target" ]; then
        safe_copy_file "$defaults" "$target" 644 && config_success "Seeded user settings at $target"
        return 0
    fi
    grep -qE 'claude-guard-bash\.sh|"disableAllHooks"' "$target" 2>/dev/null || return 0

    local backup migrated
    backup=$(user_settings_backup "$target") || return 0
    migrated=$(mktemp 2>/dev/null) || return 0
    if command -v node >/dev/null 2>&1 &&
        node "$repo_dir/lib/migrate-settings.js" "$backup" "$defaults" "$migrated" >/dev/null 2>&1; then
        safe_copy_file "$migrated" "$target" 644 || true
        config_success "Migrated settings.json to user scope (policy now in managed-settings.json; backup kept at $backup)"
    else
        safe_copy_file "$defaults" "$target" 644 || true
        config_warning "Reseeded user settings.json from defaults (legacy copy kept at $backup)"
    fi
    rm -f "$migrated"
}

# Back up the user settings.json to $CONFIG_DIR/backups/user-settings (0700,
# never mounted) and print the backup path. A backup inside the read-write
# ~/.claude would be a write target a session could redirect with a symlink.
# Usage: backup=$(user_settings_backup <settings.json>)
user_settings_backup() {
    local src="$1" dir backup
    home_file_regular "$src" || return 1
    dir="$CONFIG_DIR/backups/user-settings"
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$CONFIG_DIR/backups" "$dir" 2>/dev/null || return 1
    backup="$dir/${PROFILE_NAME:-default}.settings.json.$(date +%Y%m%d%H%M%S).$$.bak"
    cp "$src" "$backup" 2>/dev/null && chmod 600 "$backup" 2>/dev/null || return 1
    printf '%s' "$backup"
}

# Atomically replace <dest> with <src> (staged + rename, so a concurrent
# session never reads a half-written file and a symlink at <dest> is replaced,
# not followed). Usage: atomic_install <src> <dest>
atomic_install() {
    safe_write_file "$2" 644 <"$1" 2>/dev/null
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
        "profile's host secrets file" "Manejo remoto" "managed-settings.json" "/permissions"; do
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

# Header that separates the global rules from a profile's own rules in the
# mirrored CLAUDE.md (also how tests and doctor find the profile part).
SESSION_RULES_PROFILE_HEADER="## Profile rules"

# Write the session rules a profile's sessions read: the global rules
# ($CONFIG_DIR/CLAUDE.md) first, then the profile's own
# profiles/<name>/CLAUDE.md when it has one. The profile part is appended,
# never a replacement, and it lives outside every mount, like the global one.
# Usage: session_rules_render <dest>
session_rules_render() {
    local dest="$1" extra="${PROFILE_DIR:-}/CLAUDE.md" rules
    # Rendered in memory first: a failed read must not install half the rules.
    rules=$(
        cat "$CONFIG_DIR/CLAUDE.md" || exit 1
        if [ -n "${PROFILE_DIR:-}" ] && [ -s "$extra" ]; then
            printf '\n%s (%s)\n\n' "$SESSION_RULES_PROFILE_HEADER" "${PROFILE_NAME:-default}"
            echo "These rules add to the global rules above; where they conflict, the global rules win."
            echo
            cat "$extra" || exit 1
        fi
    ) || return 1
    # The destination sits in the read-write ~/.claude: staged + renamed.
    printf '%s\n' "$rules" | safe_write_file "$dest" 644
}

# Write the allow-patterns.json the guard of this profile reads: the installed
# global rules, plus the profile's approved rules (PROFILE_ALLOW_PATTERNS,
# T-36) merged by lib/merge-allow-patterns.js. Fails closed to the global
# rules alone when the merge is impossible (no node, invalid file).
# Usage: allow_patterns_render <dest>
allow_patterns_render() {
    local dest="$1" global="$CONFIG_DIR/hooks/policies/allow-patterns.json" repo_dir tmp
    [ -f "$global" ] || return 1
    tmp=$(mktemp "$dest.tmp.XXXXXX" 2>/dev/null) || return 1
    repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    if [ -n "${PROFILE_ALLOW_PATTERNS:-}" ]; then
        if command -v node >/dev/null 2>&1 &&
            node "$repo_dir/lib/merge-allow-patterns.js" "$global" "$PROFILE_ALLOW_PATTERNS" "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$dest" && return 0
        fi
        config_warning "Could not merge the allow rules of profile '${PROFILE_NAME:-default}' (node missing or invalid file); using the global rules only"
    fi
    cp "$global" "$tmp" && mv -f "$tmp" "$dest" && return 0
    rm -f "$tmp"
    return 1
}

# Copy one guard file into the hooks-guard mirror; a failure is reported (the
# guard would run stale or not at all; guard_mirror_problem then refuses the
# session). Usage: _mirror_guard_file <src> <dest> <mode>
_mirror_guard_file() {
    safe_copy_file "$1" "$2" "$3" ||
        config_warning "Could not mirror $(basename "$1") into $(dirname "$2") (the guard would run a stale copy)"
}

# Why the hooks-guard mirror cannot enforce the policy (missing, not
# executable, or differing from the installed layer), or return 1 when it is
# complete. A hook script that does not exist makes Claude Code skip the hook,
# which fails open: sessions refuse to start instead (see
# build_standard_volume_args). Usage: problem=$(guard_mirror_problem) && refuse
guard_mirror_problem() {
    local mirror="$CCODE_HOME/.claude/hooks-guard" f
    for f in claude-guard-bash.sh claude-guard-file.sh; do
        if [ ! -x "$mirror/$f" ] || [ -L "$mirror/$f" ]; then
            echo "$f is missing or not executable in $mirror"
            return 0
        fi
    done
    for f in claude-guard-bash.sh claude-guard-file.sh guard-eval.js policies/unsafe-tool-patterns.json \
        policies/prompt-injection-patterns.json policies/allow-patterns.json; do
        if ! home_file_regular "$mirror/$f"; then
            echo "$f is missing from $mirror"
            return 0
        fi
        case "$f" in
        policies/allow-patterns.json) ;; # rendered per profile (checked by config sync --check)
        *)
            if ! cmp -s "$CONFIG_DIR/hooks/$f" "$mirror/$f" 2>/dev/null; then
                echo "$f in $mirror differs from the installed layer"
                return 0
            fi
            ;;
        esac
    done
    if [ "$(head -n 1 "$mirror/policy-mode" 2>/dev/null)" != "${SECURITY_POLICY:-balanced}" ]; then
        echo "the pinned policy mode in $mirror/policy-mode is not '${SECURITY_POLICY:-balanced}'"
        return 0
    fi
    return 1
}

# Mirror the security layer into the generated home. Copy failures are
# reported; check_security_layer and guard_mirror_problem (which refuses the
# session) catch what they leave behind.
# Usage: mirror_security_layer
mirror_security_layer() {
    local pf
    # Mirror the security layer into the generated home: hooks-guard and
    # CLAUDE.md (read-only overlays) and the managed policy (etc/claude-code).
    # These copies are wrapper-managed and overwritten on every run, so edit
    # the sources in "$CONFIG_DIR" instead.
    local claude_dir="$CCODE_HOME/.claude"
    if [ -d "$claude_dir" ]; then
        ensure_home_dir "$claude_dir/hooks-guard" || true
        ensure_home_dir "$claude_dir/hooks-guard/policies" || true
        local gf
        for gf in claude-guard-bash.sh claude-guard-file.sh guard-eval.js; do
            if [ -f "$CONFIG_DIR/hooks/$gf" ]; then
                local gmode=755
                [ "$gf" = guard-eval.js ] && gmode=644
                _mirror_guard_file "$CONFIG_DIR/hooks/$gf" "$claude_dir/hooks-guard/$gf" "$gmode"
            else
                config_warning "Guard file $CONFIG_DIR/hooks/$gf is missing; sessions refuse to start until 'claude-dockerized config sync' restores it"
            fi
        done
        for pf in unsafe-tool-patterns.json prompt-injection-patterns.json VERSION; do
            if [ -f "$CONFIG_DIR/hooks/policies/$pf" ]; then
                _mirror_guard_file "$CONFIG_DIR/hooks/policies/$pf" "$claude_dir/hooks-guard/policies/$pf" 644
            else
                config_warning "Policy file $CONFIG_DIR/hooks/policies/$pf is missing (run 'claude-dockerized config sync')"
            fi
        done
        if ! allow_patterns_render "$claude_dir/hooks-guard/policies/allow-patterns.json"; then
            config_warning "Could not mirror allow-patterns.json into $claude_dir/hooks-guard/policies"
        fi
        if [ -f "$CONFIG_DIR/CLAUDE.md" ]; then
            session_rules_render "$claude_dir/CLAUDE.md" ||
                config_warning "Could not mirror the session rules into $claude_dir/CLAUDE.md"
        fi
        # Pin the policy mode next to the hooks (read-only mount): the hooks
        # prefer it over the env var, which project settings could inject.
        if ! printf '%s\n' "${SECURITY_POLICY:-balanced}" | safe_write_file "$claude_dir/hooks-guard/policy-mode" 644; then
            config_warning "Could not pin the policy mode in hooks-guard/policy-mode (hooks would fall back to the environment)"
        fi
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
    local stale=false repo_dir check
    repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    for check in _layer_check_versions _layer_check_managed _layer_check_user_settings \
        _layer_check_rules _layer_check_mirror _layer_check_user_files _layer_check_env_file; do
        "$check" "$repo_dir" || stale=true
    done

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

# Installed guard hooks and policy data match the repo versions.
# Usage: _layer_check_versions <repo_dir>
_layer_check_versions() {
    local stale=false repo_dir="$1"
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
    [ "$stale" = false ]
}

# The managed policy matches a fresh render for the current config.
# Usage: _layer_check_managed
_layer_check_managed() {
    local stale=false
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
    [ "$stale" = false ]
}

# The user settings exist, parse and carry no policy or disableAllHooks.
# Usage: _layer_check_user_settings
_layer_check_user_settings() {
    local stale=false
    # The user settings must exist, parse, and carry neither the legacy
    # wrapper policy nor disableAllHooks (T-16; sync migrates both away).
    local user_settings="$CCODE_HOME/.claude/settings.json" v=0
    if [ -L "$user_settings" ] || { [ -e "$user_settings" ] && [ ! -f "$user_settings" ]; }; then
        config_warning "user settings.json is a symlink or special file (replaced on sync, never followed)"
        stale=true
    elif [ ! -f "$user_settings" ]; then
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
    [ "$stale" = false ]
}

# The managed session rules carry the current template markers.
# Usage: _layer_check_rules
_layer_check_rules() {
    local stale=false
    # Managed session rules must carry the current markers (sync regenerates
    # them with a backup when they predate the template).
    if session_rules_current "$CONFIG_DIR/CLAUDE.md"; then
        config_success "CLAUDE.md rules (in sync)"
    else
        config_warning "CLAUDE.md rules stale or missing"
        stale=true
    fi
    [ "$stale" = false ]
}

# The read-only mirror in the generated home carries the installed layer.
# Usage: _layer_check_mirror <repo_dir>
_layer_check_mirror() {
    local stale=false repo_dir="$1"
    local inst_guard
    inst_guard=$(grep -oE 'CLAUDE_DOCKERIZED_GUARD_VERSION=[0-9]+' "$CONFIG_DIR/hooks/claude-guard-bash.sh" 2>/dev/null | head -1)
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
    # The mirror must be what allow_patterns_render produces for this profile
    # (global rules, plus its approved own rules).
    local expected_allow
    expected_allow=$(mktemp 2>/dev/null) || expected_allow=""
    if [ -z "$expected_allow" ] || ! allow_patterns_render "$expected_allow" 2>/dev/null ||
        ! cmp -s "$expected_allow" "$mirror/policies/allow-patterns.json" 2>/dev/null; then
        config_warning "allow-patterns.json mirror differs from the installed copy (re-mirrored on sync)"
        content_ok=false
    fi
    [ -z "$expected_allow" ] || rm -f "$expected_allow"
    if [ "$content_ok" = true ]; then
        config_success "guard and policy content verified (byte-identical to the repo)"
    else
        stale=true
    fi
    [ "$stale" = false ]
}

# User-managed JSON (MCP, LSP) parses.
# Usage: _layer_check_user_files
_layer_check_user_files() {
    local stale=false
    local v=0
    # The user-managed MCP file is never touched by sync, but an unparsable
    # file breaks sessions: fail the check early.
    local uoc
    for uoc in "$CCODE_HOME/.claude.json" "$CCODE_HOME/.claude/.mcp.json"; do
        home_file_regular "$uoc" || continue
        v=0; json_valid "$uoc" || v=$?
        if [ "$v" -eq 1 ]; then
            config_warning "$uoc is not valid JSON (fix it; sync never edits this file)"
            stale=true
        fi
    done

    # LSP config must parse when LSP support is enabled.
    if [ "$LSP_ENABLED" = true ]; then
        local lsp_json="$CCODE_HOME/.claude/.lsp.json"
        if ! home_file_regular "$lsp_json"; then
            config_warning ".lsp.json missing or not a regular file (reseeded on sync)"
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
    [ "$stale" = false ]
}

# The profile's secrets file exists and is private (values never read).
# Usage: _layer_check_env_file
_layer_check_env_file() {
    local stale=false
    # The secrets file is never read for values here; only its permissions.
    if [ -n "${ENV_FILE:-}" ]; then
        # resolve it like build_env_file_args does
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
    [ "$stale" = false ]
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
    local user_settings="$CCODE_HOME/.claude/settings.json" v backup defaults
    defaults="$(layer_repo_dir)/config/user-settings.default.json"
    if home_file_regular "$user_settings"; then
        v=0; json_valid "$user_settings" || v=$?
        if [ "$v" -eq 1 ] && backup=$(user_settings_backup "$user_settings") &&
            safe_copy_file "$defaults" "$user_settings" 644; then
            config_warning "Backed up broken settings.json to $backup and reseeded it"
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
        home_file_regular "$oc" || continue
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
            config_info "Put the values in the profile's env file instead (claude-dockerized profile edit <name> env)."
            return 1
            ;;
        esac
    done
    return 0
}