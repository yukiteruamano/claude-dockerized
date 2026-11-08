#!/bin/bash
# profile-edit-lib.sh - the `profile edit|set|unset|approve` commands and the
# overlay validation they share (values, mounts, whole-file problems).
# Sourced by lib/config-lib.sh; dispatched by manage_profiles in
# lib/profile-cmd-lib.sh. Not executable directly; no `set -e`.

# Usage: profile_cmd_edit NAME [config|env]
profile_cmd_edit() {
    local name="${1:-}" what="${2:-config}" editor target
    _profile_require "$name" || return 1
    if ! editor=$(resolve_editor); then
        config_error "No editor found (set \$EDITOR or install sensible-editor, vi or nano)"
        return 1
    fi
    case "$what" in
    config)
        target="$(profile_dir_of "$name")/config"
        [ -f "$target" ] || printf '# Overlay of profile %s: setting.* and mount.* override the global config.\n# Loosening a security setting needs: claude-dockerized profile set %s KEY VALUE --allow-loosen\n' "$name" "$name" >"$target"
        _profile_edit_overlay "$name" "$editor" "$target"
        ;;
    env)
        target="$(profile_dir_of "$name")/env"
        [ -f "$target" ] || install -m 600 /dev/null "$target" 2>/dev/null || : >"$target"
        chmod 600 "$target" 2>/dev/null || true
        "$editor" "$target"
        chmod 600 "$target" 2>/dev/null || true
        ;;
    rules)
        # Session rules of this profile, appended after the global CLAUDE.md
        # on the next run (session_rules_render).
        target="$(profile_dir_of "$name")/CLAUDE.md"
        [ -f "$target" ] || printf '<!-- Rules for profile %s: appended after the global session rules; the global rules win on conflict. -->\n' "$name" >"$target"
        "$editor" "$target"
        config_info "Profile '$name': rules take effect on the next run."
        ;;
    permissions)
        # Extra deny/ask rules merged into this profile's managed policy
        # (profile_permission_rules); there is no allow.
        target="$(profile_dir_of "$name")/permissions"
        [ -f "$target" ] || printf '# Extra managed permission rules of profile %s (one per line):\n#   deny Tool(specifier)   e.g. deny WebFetch\n#   ask  Tool(specifier)   e.g. ask Bash(npm publish *)\n# Only deny and ask exist: a profile cannot allow what the global policy denies.\n' "$name" >"$target"
        "$editor" "$target"
        config_info "Profile '$name': permission rules take effect on the next run."
        ;;
    allow-patterns)
        # Guard allow rules of this profile (T-36): inert until approved.
        target="$(profile_dir_of "$name")/allow-patterns.json"
        [ -f "$target" ] || printf '[]\n' >"$target"
        "$editor" "$target"
        _profile_report_pruned "$name" "$(profile_prune_orphan_approvals "$(profile_dir_of "$name")/config")"
        config_info "Profile '$name': review and activate them with: claude-dockerized profile approve $name allow-patterns"
        ;;
    *)
        config_error "Usage: claude-dockerized profile edit NAME [config|env|rules|permissions|allow-patterns]"
        return 1
        ;;
    esac
}

# Usage: profile_cmd_approve NAME allow-patterns [--yes]
# Approve the current content of profiles/<name>/allow-patterns.json (T-36):
# validate it, list its rules, confirm, then pin its sha256 in the overlay.
# An allow rule only skips the vendored deny rules; the built-in backstops
# still run, which the confirmation says.
profile_cmd_approve() {
    local name="${1:-}" what="${2:-}" yes=false rules cfg sha listing answer
    _profile_require "$name" || return 1
    [ "${3:-}" = --yes ] && yes=true
    if [ "$what" != allow-patterns ]; then
        config_error "Usage: claude-dockerized profile approve NAME allow-patterns [--yes]"
        return 1
    fi
    rules="$(profile_dir_of "$name")/allow-patterns.json"
    if [ ! -f "$rules" ]; then
        config_error "Profile '$name' has no allow rules (create them with: claude-dockerized profile edit $name allow-patterns)"
        return 1
    fi
    if ! command -v node >/dev/null 2>&1; then
        config_error "node is needed to validate the allow rules"
        return 1
    fi
    local repo_dir
    repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    if ! listing=$(node "$repo_dir/lib/merge-allow-patterns.js" "$CONFIG_DIR/hooks/policies/allow-patterns.json" "$rules" 2>&1); then
        config_error "Invalid allow rules in $rules: $listing"
        return 1
    fi
    config_warning "These rules let matching commands skip the vendored deny rules of the guard in profile '$name' (the built-in backstops still apply):"
    printf '%s\n' "${listing:-  (no rules)}" | sed 's/^/  /' >&2
    if [ "$yes" != true ]; then
        if [ ! -t 0 ]; then
            config_error "Confirm with --yes (no terminal to ask on)."
            return 1
        fi
        read -r -p "Approve exactly this content? (y/N): " answer || answer=""
        [[ "$answer" =~ ^[Yy]$ ]] || {
            config_info "Not approved."
            return 1
        }
    fi
    sha=$(profile_sha256_file "$rules")
    [ -n "$sha" ] || {
        config_error "Cannot hash $rules (sha256sum or shasum needed)"
        return 1
    }
    cfg="$(profile_dir_of "$name")/config"
    [ -f "$cfg" ] || : >"$cfg"
    profile_file_unset "$cfg" allow_loosen.allow_patterns
    profile_file_set "$cfg" allow_loosen.allow_patterns "$sha" || return 1
    config_success "Profile '$name': allow rules approved (sha256 ${sha:0:12}…); editing the file voids the approval."
}

# Edit an overlay and check it on save the way `profile set` would; on a TTY
# offer to reopen it while problems remain. Returns 1 when problems are left.
# Usage: _profile_edit_overlay <name> <editor> <file>
_profile_edit_overlay() {
    local name="$1" editor="$2" file="$3" problems answer
    while :; do
        "$editor" "$file"
        _profile_report_pruned "$name" "$(profile_prune_orphan_approvals "$file")"
        problems=$(profile_overlay_problems "$file")
        if [ -z "$problems" ]; then
            config_success "Profile '$name': overlay checked, no problems."
            return 0
        fi
        config_warning "Profile '$name': the overlay has problems (runs ignore these lines):"
        printf '%s\n' "$problems" | sed 's/^/  - /' >&2
        [ -t 0 ] || return 1
        read -r -p "Edit it again? (Y/n): " answer || answer=n
        [[ "${answer:-y}" =~ ^[Yy]$ ]] || return 1
    done
}

# Say which stale approvals were dropped (empty list: nothing to say).
# Usage: _profile_report_pruned <name> <keys newline-separated>
_profile_report_pruned() {
    [ -n "$2" ] || return 0
    config_info "Profile '$1': dropped approvals that no longer match their value: $(printf '%s' "$2" | paste -sd, -) (approve again with: profile set … --allow-loosen)"
}

# Problems of an overlay file, one per line, as `profile set` would report
# them: unknown lines, settings a profile cannot override, invalid values or
# mounts, and loosenings without approval. Prints nothing when it is clean.
# Usage: profile_overlay_problems <file>
profile_overlay_problems() {
    local file="$1" line key value lineno=0 reason item
    [ -f "$file" ] || return 0
    if reason=$(config_file_bad_bytes "$file"); then
        echo "$reason (only tabs and line endings are allowed): every run ignores the whole overlay"
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        config_split_line "$line"
        key="$_CFG_KEY"
        value="$_CFG_VALUE"
        case "$key" in
        "" | \#* | allow_loosen.*) ;;
        mount.*)
            reason=$(_profile_mount_value_error "${key#mount.}" "$value") || echo "line $lineno: $key: $reason"
            ;;
        setting.*)
            if ! profile_overlay_key_ok "${key#setting.}"; then
                echo "line $lineno: $key cannot be overridden per profile"
            elif ! reason=$(_profile_value_error "${key#setting.}" "$value"); then
                echo "line $lineno: $key: $reason"
            fi
            ;;
        *) echo "line $lineno: unknown line '$key' (use setting.<key>=… or mount.<name>=…)" ;;
        esac
    done <"$file"
    while IFS= read -r item; do
        [ -n "$item" ] && echo "$item loosens the global posture without approval (profile set … --allow-loosen)"
    done < <(profile_overlay_unapproved "$file")
    return 0
}

# Check a value the way the config loader would. Prints the reason on failure.
# Usage: _profile_value_error <key> <value>
_profile_value_error() {
    local key="$1" value="$2" out
    case "$key" in
    ssh_agent_support | gpg_agent_support | gpg_allow_main_socket | gpg_autostart_agent | gpg_relay | \
        docker_socket | integrity_check | share_skills | lsp | formatters)
        case "$value" in true | false) return 0 ;; esac
        echo "$key takes true or false"
        return 1
        ;;
    esac
    out=$( (config_reset_settings; _config_apply_setting "$key" "$value") 2>&1 >/dev/null)
    [ -z "$out" ] || {
        echo "$out"
        return 1
    }
    return 0
}

# Check a mount spec (host:container[:ro|rw]) the way the loader would. Prints
# the reason on failure. Usage: _profile_mount_value_error <name> <spec>
_profile_mount_value_error() {
    local name="$1" spec="$2" host container mode err
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "mount names use letters, digits, - and _"
        return 1
    fi
    # `-` drops the global mount of that name for this profile.
    [ "$spec" = - ] && return 0
    IFS=: read -r host container mode <<<"$spec"
    if ! err=$(validate_mount_spec "$host" "$container" "${mode:-ro}" 2>&1 >/dev/null); then
        echo "$err"
        return 1
    fi
}

# The overlay line a key lives on: setting.<key>, or mount.<name> as is.
# Usage: _profile_line_key <key>
_profile_line_key() {
    case "$1" in
    mount.*) echo "$1" ;;
    *) echo "setting.$1" ;;
    esac
}

# Usage: profile_cmd_set NAME KEY VALUE [--allow-loosen]   (KEY: a setting or mount.<name>)
# The candidate overlay is evaluated as a whole against the global config:
# when the new value would be dropped for lack of approval, --allow-loosen is
# required and the approval (naming that exact value) is written with it.
profile_cmd_set() {
    local name="${1:-}" key="${2:-}" value="${3:-}" allow=false cfg tmp line_key reason
    _profile_require "$name" || return 1
    shift 3 2>/dev/null || {
        config_error "Usage: claude-dockerized profile set NAME KEY VALUE [--allow-loosen]"
        return 1
    }
    [ "${1:-}" = --allow-loosen ] && allow=true
    # One value, one line: a line break would smuggle extra settings (and
    # approval lines) past the check below.
    case "$key$value" in
    *[[:cntrl:]]*)
        config_error "Refusing a key or value with control characters or line breaks."
        return 1
        ;;
    esac
    if [[ "$key" == mount.* ]]; then
        if ! reason=$(_profile_mount_value_error "${key#mount.}" "$value"); then
            config_error "Invalid mount: $reason"
            return 1
        fi
    else
        if ! profile_overlay_key_ok "$key"; then
            config_error "'$key' cannot be overridden per profile (allowed: ssh_agent_support gpg_agent_support gpg_allow_main_socket gpg_autostart_agent gpg_relay docker_socket network security_policy hardening integrity_check model claude_version cleanup_days lsp lsp_servers formatters memory cpus share_skills lsp_from, or mount.<name>)"
            return 1
        fi
        if ! reason=$(_profile_value_error "$key" "$value"); then
            config_error "Invalid value for $key: $reason"
            return 1
        fi
    fi
    line_key=$(_profile_line_key "$key")
    cfg="$(profile_dir_of "$name")/config"
    if reason=$(config_file_bad_bytes "$cfg"); then
        config_error "Refusing to change $cfg: $reason. Fix it with: claude-dockerized profile edit $name"
        return 1
    fi
    tmp=$(mktemp "$cfg.tmp.XXXXXX" 2>/dev/null) || return 1
    [ ! -f "$cfg" ] || cat "$cfg" >"$tmp"
    profile_file_unset "$tmp" "allow_loosen.$key"
    profile_file_set "$tmp" "$line_key" "$value" || {
        rm -f "$tmp"
        return 1
    }
    if profile_overlay_unapproved "$tmp" | grep -qxF -- "$key"; then
        if [ "$allow" = false ]; then
            rm -f "$tmp"
            config_error "$key=$value loosens the global security posture. Re-run with --allow-loosen to approve it for profile '$name'."
            return 1
        fi
        profile_file_set "$tmp" "allow_loosen.$key" "$value" || {
            rm -f "$tmp"
            return 1
        }
        config_warning "Profile '$name' now loosens $key; it is marked in 'profile list' and reported on every run."
    fi
    _profile_report_pruned "$name" "$(profile_prune_orphan_approvals "$tmp")"
    cat "$tmp" >"$cfg" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
    config_success "Profile '$name': $line_key=$value"
}

# Usage: profile_cmd_unset NAME KEY
profile_cmd_unset() {
    local name="${1:-}" key="${2:-}" cfg line_key reason
    _profile_require "$name" || return 1
    if [ -z "$key" ]; then
        config_error "Usage: claude-dockerized profile unset NAME KEY"
        return 1
    fi
    cfg="$(profile_dir_of "$name")/config"
    line_key=$(_profile_line_key "$key")
    if reason=$(config_file_bad_bytes "$cfg"); then
        config_error "Refusing to change $cfg: $reason. Fix it with: claude-dockerized profile edit $name"
        return 1
    fi
    profile_file_unset "$cfg" "$line_key"
    profile_file_unset "$cfg" "allow_loosen.$key"
    _profile_report_pruned "$name" "$(profile_prune_orphan_approvals "$cfg")"
    config_success "Profile '$name': $line_key now follows the global config"
}
