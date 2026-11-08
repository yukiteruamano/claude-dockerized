#!/bin/bash
# profile-overlay-lib.sh - a profile's config overlay on top of the global
# config: which settings it may override, the loosening guard and its
# approvals (T-34), the profile's own guard allow rules (T-36) and extra
# permission rules. Sourced by lib/config-lib.sh. Not executable directly;
# no `set -e`: callers own error handling.

# shellcheck disable=SC2034 # PROFILE_* state is consumed by the other libs and bin/claude-dockerized

# ENV_FILE is the profile's own secrets file when it exists; there is no
# global secrets file. Usage: profile_resolve_env_file
profile_resolve_env_file() {
    ENV_FILE=""
    [ -f "$PROFILE_ENV_FILE" ] && ENV_FILE="$PROFILE_ENV_FILE"
    return 0
}

# Global variable behind a setting whose looseness is checked key by key;
# empty for the rest (network and the resource limits are checked after the
# whole overlay is loaded, see _profile_overlay_post_checks).
# Usage: profile_key_var <key>
profile_key_var() {
    case "$1" in
    ssh_agent_support) echo SSH_AGENT_SUPPORT ;;
    gpg_agent_support) echo GPG_AGENT_SUPPORT ;;
    gpg_allow_main_socket) echo GPG_ALLOW_MAIN_SOCKET ;;
    docker_socket) echo DOCKER_SOCKET ;;
    share_skills) echo SHARE_SKILLS ;;
    lsp_from) echo LSP_FROM ;;
    security_policy) echo SECURITY_POLICY ;;
    hardening) echo HARDENING ;;
    integrity_check) echo INTEGRITY_CHECK ;;
    esac
}

# Strictness rank of a security_policy / hardening value (higher = stricter).
# Usage: _profile_rank <value>
_profile_rank() {
    case "$1" in
    none | off) echo 0 ;;
    balanced | standard) echo 1 ;;
    strict) echo 2 ;;
    *) echo 0 ;;
    esac
}

# Is going from <old> to <new> a weaker security posture?
# Usage: profile_value_loosens <key> <old> <new>
profile_value_loosens() {
    local key="$1" old="$2" new="$3"
    case "$key" in
    security_policy | hardening) [ "$(_profile_rank "$new")" -lt "$(_profile_rank "$old")" ] ;;
    docker_socket | ssh_agent_support | gpg_agent_support | gpg_allow_main_socket)
        [ "$old" = false ] && [ "$new" = true ]
        ;;
    integrity_check) [ "$old" = true ] && [ "$new" = false ] ;;
    # The two read-only exceptions to the isolation of accounts: the default
    # profile's skills, and its .local/bin (code that profile's sessions can write).
    share_skills) [ "$old" = false ] && [ "$new" = true ] ;;
    lsp_from) [ -z "$old" ] && [ "$new" = default ] ;;
    *) return 1 ;;
    esac
}

# Settings a profile may override. Image build options and the default
# profile stay global. Usage: profile_overlay_key_ok <key>
profile_overlay_key_ok() {
    case "$1" in
    ssh_agent_support | gpg_agent_support | gpg_allow_main_socket | gpg_autostart_agent | gpg_relay | \
        docker_socket | network | security_policy | hardening | integrity_check | model | claude_version | cleanup_days | \
        lsp | lsp_servers | formatters | memory | cpus | share_skills | lsp_from) return 0 ;;
    esac
    return 1
}

# Has the overlay approved loosening <key> to exactly <value>? The approval
# line names the value as written, so editing the value voids it.
# Usage: profile_loosen_approved <overlay_file> <key> <value>
profile_loosen_approved() {
    grep -qxF "allow_loosen.$2=$3" "$1" 2>/dev/null
}

# Print a warning once per process (settings are parsed several times per
# command). Usage: _profile_warn_once <id> <message>
_profile_warn_once() {
    case "|$_PROFILE_WARNED|" in *"|$1|"*) return 0 ;; esac
    _PROFILE_WARNED="$_PROFILE_WARNED|$1"
    config_warning "$2"
}

# Apply one setting of a profile overlay. A setting that loosens the global
# posture is dropped (the stricter global value stays) unless the overlay
# approves that exact value, which `profile set --allow-loosen` writes.
# Usage: profile_overlay_apply_setting <key> <value> <overlay_file>
profile_overlay_apply_setting() {
    local key="$1" value="$2" file="$3" var before="" after=""
    if ! profile_overlay_key_ok "$key"; then
        config_warning "Ignoring setting.$key in $file: it cannot be overridden per profile"
        return 0
    fi
    var=$(profile_key_var "$key")
    [ -z "$var" ] || before="${!var}"
    _config_apply_setting "$key" "$value"
    PROFILE_SET_KEYS+=("$key")
    [ -n "$var" ] || return 0
    after="${!var}"
    profile_value_loosens "$key" "$before" "$after" || return 0
    if profile_loosen_approved "$file" "$key" "$value"; then
        PROFILE_LOOSENED+=("$key=$after")
        return 0
    fi
    printf -v "$var" '%s' "$before"
    PROFILE_UNAPPROVED+=("$key")
    _profile_warn_once "$PROFILE_NAME:$key" "Profile '$PROFILE_NAME' loosens $key (${before:-unset} -> ${after:-unset}) without approval; keeping ${before:-unset} (approve with: claude-dockerized profile set $PROFILE_NAME $key \"$value\" --allow-loosen)"
}

# May an overlay mount be added? A read-write mount exposes host files for
# writing and needs approval of that exact spec; read-only mounts are free
# (validate_mount_spec still vets every mount). Records what it decides.
# Usage: profile_overlay_mount_allowed <name> <spec> <overlay_file>
profile_overlay_mount_allowed() {
    case "$2" in *:rw) ;; *) return 0 ;; esac
    if profile_loosen_approved "$3" "mount.$1" "$2"; then
        PROFILE_LOOSENED+=("mount.$1=rw")
        return 0
    fi
    PROFILE_UNAPPROVED+=("mount.$1")
    _profile_warn_once "$PROFILE_NAME:mount.$1" "Profile '$PROFILE_NAME' adds a read-write mount (mount.$1=$2) without approval; ignoring it (approve with: claude-dockerized profile set $PROFILE_NAME mount.$1 \"$2\" --allow-loosen)"
    return 1
}

# Raw value of setting.<key> in an overlay (last assignment, trimmed); returns
# 1 when the overlay does not set it. Usage: _profile_overlay_raw <file> <key>
_profile_overlay_raw() {
    local v
    grep -q "^[[:space:]]*setting\\.$2[[:space:]]*=" "$1" 2>/dev/null || return 1
    v=$(sed -n "s/^[[:space:]]*setting\\.$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -n 1)
    printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# Bytes of a docker memory size (4g, 512m, 100k, 2048b) as a decimal string
# (awk doubles: a huge size cannot wrap around); fails when unparsable.
# Usage: _profile_mem_bytes <size>
_profile_mem_bytes() {
    [[ "$1" =~ ^([0-9]+)([bBkKmMgG])$ ]] || return 1
    awk -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[2]}" \
        'BEGIN { m = (u ~ /[bB]/) ? 1 : (u ~ /[kK]/) ? 1024 : (u ~ /[mM]/) ? 1048576 : 1073741824; printf "%.0f\n", n * m }'
}

# Does <new> lift or raise the limit <old>? Docker reads 0 (and an empty
# value) as no limit at all, so those count as lifting; a global limit that is
# itself 0 or empty leaves nothing to loosen.
# Usage: _profile_limit_loosens <memory|cpus> <old> <new>
_profile_limit_loosens() {
    local kind="$1" old="$2" new="$3" o n
    [ -n "$old" ] || return 1
    if [ "$kind" = memory ]; then
        o=$(_profile_mem_bytes "$old") || return 1
        if [ -n "$new" ]; then
            n=$(_profile_mem_bytes "$new") || return 1
        fi
    else
        o="$old"
        n="$new"
    fi
    if awk -v o="$o" 'BEGIN { exit !(o + 0 == 0) }'; then
        return 1
    fi
    [ -n "$new" ] || return 0
    awk -v o="$o" -v n="$n" 'BEGIN { exit !(n + 0 == 0 || n + 0 > o + 0) }'
}

# Checks that need the whole overlay: the network (an overlay network=host
# leaves the global bridge network) and the resource limits (dropping or
# raising a global memory/cpus limit). A loosening without approval is
# reverted to the global value.
# Usage: _profile_overlay_post_checks <file> <g_network> <g_explicit> <g_memory> <g_cpus>
_profile_overlay_post_checks() {
    local file="$1" raw kind var old new
    if raw=$(_profile_overlay_raw "$file" network) && [ "$2" = bridge ] && [ "$NETWORK" = host ]; then
        if profile_loosen_approved "$file" network "$raw"; then
            PROFILE_LOOSENED+=("network=host")
        else
            NETWORK="$2"
            NETWORK_EXPLICIT="$3"
            PROFILE_UNAPPROVED+=("network")
            _profile_warn_once "$PROFILE_NAME:network" "Profile '$PROFILE_NAME' loosens network (bridge -> host) without approval; keeping bridge (approve with: claude-dockerized profile set $PROFILE_NAME network \"$raw\" --allow-loosen)"
        fi
    fi
    for kind in memory cpus; do
        raw=$(_profile_overlay_raw "$file" "$kind") || continue
        if [ "$kind" = memory ]; then
            var=MEMORY old="$4"
        else
            var=CPUS old="$5"
        fi
        new="${!var}"
        _profile_limit_loosens "$kind" "$old" "$new" || continue
        if profile_loosen_approved "$file" "$kind" "$raw"; then
            PROFILE_LOOSENED+=("$kind=${raw:-none}")
        else
            printf -v "$var" '%s' "$old"
            PROFILE_UNAPPROVED+=("$kind")
            _profile_warn_once "$PROFILE_NAME:$kind" "Profile '$PROFILE_NAME' lifts the global $kind limit ($old -> ${raw:-none}) without approval; keeping $old (approve with: claude-dockerized profile set $PROFILE_NAME $kind \"$raw\" --allow-loosen)"
        fi
    done
}

# sha256 of a file (sha256sum, or shasum on macOS); empty when neither works.
# Usage: profile_sha256_file <file>
profile_sha256_file() {
    { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1" 2>/dev/null; } | cut -d' ' -f1
}

# A profile's own guard allow rules (profiles/<name>/allow-patterns.json,
# T-36) apply only while the overlay approves that exact content: the line
# allow_loosen.allow_patterns=<sha256 of the file>, written by
# `profile approve NAME allow-patterns`. Editing the file voids it. Sets
# PROFILE_ALLOW_PATTERNS to the file when approved.
# Usage: _profile_allow_patterns_check <overlay_file>
_profile_allow_patterns_check() {
    local overlay="$1" rules sha
    PROFILE_ALLOW_PATTERNS=""
    rules="$(dirname "$overlay")/allow-patterns.json"
    [ -f "$rules" ] || return 0
    sha=$(profile_sha256_file "$rules")
    if [ -n "$sha" ] && profile_loosen_approved "$overlay" allow_patterns "$sha"; then
        PROFILE_ALLOW_PATTERNS="$rules"
        PROFILE_LOOSENED+=("allow_patterns=${sha:0:12}")
        return 0
    fi
    PROFILE_UNAPPROVED+=("allow_patterns")
    _profile_warn_once "$PROFILE_NAME:allow_patterns" "Profile '$PROFILE_NAME' has guard allow rules ($rules) that are not approved or changed since; ignoring them (review and approve with: claude-dockerized profile approve $PROFILE_NAME allow-patterns)"
}

# Layer an overlay file on top of the settings loaded so far. Fills
# PROFILE_LOOSENED (approved loosenings) and PROFILE_UNAPPROVED (dropped ones).
# Usage: profile_apply_overlay_file <file>
profile_apply_overlay_file() {
    local file="$1" g_n="$NETWORK" g_e="$NETWORK_EXPLICIT" g_m="$MEMORY" g_c="$CPUS"
    PROFILE_LOOSENED=()
    PROFILE_UNAPPROVED=()
    PROFILE_SET_KEYS=()
    PROFILE_DROPPED_MOUNTS=()
    _profile_allow_patterns_check "$file"
    [ -f "$file" ] || return 0
    _load_config_file "$file" overlay
    _profile_overlay_post_checks "$file" "$g_n" "$g_e" "$g_m" "$g_c"
}

# Layer the active profile's overlay on top of the global settings.
# Usage: profile_apply_overlay
profile_apply_overlay() {
    profile_apply_overlay_file "$PROFILE_CONFIG_FILE"
}

# Settings of a candidate overlay file that would still need approval, one
# per line (evaluated against the global config in a subshell, nothing is
# printed or changed). Usage: profile_overlay_unapproved <file>
profile_overlay_unapproved() {
    (
        config_reset_settings
        CUSTOM_MOUNTS=()
        CUSTOM_MOUNT_KEYS=()
        [ -f "$CONFIG_FILE" ] && _load_config_file "$CONFIG_FILE" 2>/dev/null
        profile_apply_overlay_file "$1" 2>/dev/null
        printf '%s\n' "${PROFILE_UNAPPROVED[@]}"
    )
}

# What a profile's overlay does to the global posture: "approved:<key>" for
# each loosening that is in effect and "unapproved:<key>" for each one that is
# dropped. Usage: profile_overlay_state <name>
profile_overlay_state() {
    (
        # shellcheck disable=SC2034 # read by activate_profile
        PROFILE_FLAG="$1"
        activate_profile
        parse_config >/dev/null 2>&1 || true
        local item
        for item in "${PROFILE_LOOSENED[@]}"; do
            printf 'approved:%s\n' "${item%%=*}"
        done
        for item in "${PROFILE_UNAPPROVED[@]}"; do
            printf 'unapproved:%s\n' "$item"
        done
    )
}

# Why a profile permission line is invalid, or nothing (and status 0). Only
# the tightening kinds exist (deny, ask); a rule is a tool name with an
# optional specifier and must stay JSON-safe without escaping (no quotes,
# backslashes or control characters), since write_managed_settings
# inserts it with sed. Usage: profile_permission_rule_error <kind> <rule>
profile_permission_rule_error() {
    case "$1" in
    deny | ask) ;;
    *)
        echo "'$1' is not deny or ask (a profile can only add restrictions)"
        return 1
        ;;
    esac
    if ! [[ "$2" =~ ^[A-Za-z][A-Za-z0-9_]*(\([^\"\\[:cntrl:]]*\))?$ ]]; then
        echo "'$2' is not a permission rule like Tool or Tool(specifier) (no quotes or backslashes)"
        return 1
    fi
}

# Extra permission rules of the active profile (profiles/<name>/permissions:
# lines "deny RULE" or "ask RULE", # comments), merged into its managed
# policy. Prints "kind<TAB>rule" per valid line; an invalid line is skipped
# with a warning. Usage: profile_permission_rules
profile_permission_rules() {
    local file="${PROFILE_DIR:-}/permissions" line kind rule reason lineno=0
    [ -n "${PROFILE_DIR:-}" ] && [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in "" | \#*) continue ;; esac
        kind="${line%%[[:space:]]*}"
        rule="${line#"$kind"}"
        rule="${rule#"${rule%%[![:space:]]*}"}"
        if ! reason=$(profile_permission_rule_error "$kind" "$rule"); then
            _profile_warn_once "$PROFILE_NAME:permissions:$lineno" "Ignoring line $lineno of $file: $reason"
            continue
        fi
        printf '%s\t%s\n' "$kind" "$rule"
    done <"$file"
}

# One warning per run when the profile weakens the global posture on purpose.
# Usage: profile_report_loosened
profile_report_loosened() {
    local item
    for item in "${PROFILE_LOOSENED[@]}"; do
        config_warning "Profile '$PROFILE_NAME' loosens the global security posture: $item (approved with --allow-loosen)"
    done
}
