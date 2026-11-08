#!/bin/bash
# profile-cmd-lib.sh - the `claude-dockerized profile` command family
# (list, create, login, logout, show, current, use, bind, unbind, edit, set,
# unset, rename, delete, path, doctor, migrate). Core logic lives in
# lib/profile-lib.sh. Sourced by lib/config-lib.sh. Not executable directly;
# no `set -e`: callers own error handling.

# Is <line> an assignment of <key>? Same tolerance as the loader: leading
# whitespace and spaces around `=`. Usage: _profile_line_is_key <line> <key>
_profile_line_is_key() {
    local t="${1#"${1%%[![:space:]]*}"}"
    case "$t" in
    "$2"=*) return 0 ;;
    "$2"[[:space:]]*)
        t="${t#"$2"}"
        t="${t#"${t%%[![:space:]]*}"}"
        [[ "$t" == =* ]]
        return
        ;;
    esac
    return 1
}

# Write or replace one key=value line in an INI file, preserving the rest. A
# key or value with a line break is refused: it would write extra lines (an
# injected setting). Usage: profile_file_set <file> <key> <value>
profile_file_set() {
    local file="$1" key="$2" value="$3" tmp line replaced=false
    case "$key$value" in
    *$'\n'* | *$'\r'*)
        config_error "Refusing a value with a line break"
        return 1
        ;;
    esac
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
    tmp=$(mktemp "$file.tmp.XXXXXX" 2>/dev/null) || return 1
    if [ -f "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if _profile_line_is_key "$line" "$key"; then
                [ "$replaced" = true ] || printf '%s=%s\n' "$key" "$value" >>"$tmp"
                replaced=true
            else
                printf '%s\n' "$line" >>"$tmp"
            fi
        done <"$file"
    fi
    [ "$replaced" = true ] || printf '%s=%s\n' "$key" "$value" >>"$tmp"
    cat "$tmp" >"$file" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
}

# Drop the key=value line from an INI file. Usage: profile_file_unset <file> <key>
profile_file_unset() {
    local file="$1" key="$2" tmp line
    [ -f "$file" ] || return 0
    tmp=$(mktemp "$file.tmp.XXXXXX" 2>/dev/null) || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        _profile_line_is_key "$line" "$key" || printf '%s\n' "$line" >>"$tmp"
    done <"$file"
    cat "$tmp" >"$file" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
}

# Run <command...> once per profile (default first) in a subshell with that
# profile active; the status is the worst one. Usage: profile_foreach <command...>
profile_foreach() {
    local name rc=0 total
    total=$(profile_names | wc -l)
    for name in $(profile_names); do
        [ "$total" -le 1 ] || config_info "Profile: $name"
        (
            PROFILE_FLAG="$name"
            activate_profile
            parse_config || true
            "$@"
        ) || rc=1
    done
    return "$rc"
}

# Require an existing, valid profile name. Usage: _profile_require <name>
_profile_require() {
    if ! profile_name_valid "${1:-}"; then
        config_error "Invalid or missing profile name '${1:-}' (see: claude-dockerized profiles)"
        return 1
    fi
    if [ "$CCODE_HOME_PINNED" = true ] && [ "$1" != default ]; then
        config_error "CCODE_HOME is set in the environment and pins the state root; only 'default' exists."
        return 1
    fi
    if ! profile_exists "$1"; then
        config_error "Unknown profile '$1' (see: claude-dockerized profiles)"
        return 1
    fi
}

# Human-readable one-liner about the user's confirmation: type the name.
# Usage: _profile_confirm <name> <what>
_profile_confirm() {
    local name="$1" what="$2" answer=""
    if [ ! -t 0 ]; then
        config_error "Refusing to $what without a terminal; pass --yes."
        return 1
    fi
    read -r -p "Type '$name' to confirm: " answer || answer=""
    [ "$answer" = "$name" ] || {
        config_info "Cancelled."
        return 1
    }
}

# Model of a profile as set in its overlay ("" when inherited).
# Usage: _profile_overlay_value <name> <key>
_profile_overlay_value() {
    local cfg
    cfg="$(profile_dir_of "$1")/config"
    [ -f "$cfg" ] || return 0
    sed -n "s/^setting\\.$2=//p" "$cfg" 2>/dev/null | tail -n 1
}

# Keys a profile loosens on purpose and that are really in effect (an
# approval that no longer matches its value does not count).
# Usage: _profile_loosened_keys <name>
_profile_loosened_keys() {
    profile_overlay_state "$1" 2>/dev/null | sed -n 's/^approved://p'
}

# Keys the overlay of a profile tries to loosen without a valid approval
# (they are ignored). Usage: _profile_unapproved_keys <name>
_profile_unapproved_keys() {
    profile_overlay_state "$1" 2>/dev/null | sed -n 's/^unapproved://p'
}

# Date a profile was last used (YYYY-MM-DD) or "never". Usage: _profile_last_used <name>
_profile_last_used() {
    local f
    f="$(profile_dir_of "$1")/.last-used"
    [ -f "$f" ] || {
        echo never
        return 0
    }
    date -r "$f" +%F 2>/dev/null || stat -f %Sm -t %F "$f" 2>/dev/null || echo "?"
}

# ============================================
# list / current / show / path
# ============================================

# Usage: profile_cmd_list [--json]
profile_cmd_list() {
    local json=false
    case "${1:-}" in
    --json) json=true ;;
    "") ;;
    *)
        config_error "Usage: claude-dockerized profile list [--json]"
        return 1
        ;;
    esac
    local name home state email model used size binds loosened ignored ovl first=true note
    [ "$json" = true ] && printf '{"active":"%s","profiles":[' "$PROFILE_NAME"
    if [ "$json" = false ]; then
        printf '  %-16s %-9s %-28s %-12s %-11s %-6s %s\n' NAME LOGIN ACCOUNT MODEL USED SIZE NOTES
    fi
    for name in $(profile_names); do
        home=$(profile_home_of "$name")
        state=$(profile_login_state "$name")
        email=""
        [ "$state" = oauth ] && email=$(profile_account_email "$home")
        model=$(_profile_overlay_value "$name" model)
        used=$(_profile_last_used "$name")
        size=$(du -sh "$home" 2>/dev/null | cut -f1)
        binds=$(profile_map_dirs "$name" | wc -l)
        ovl=$(profile_overlay_state "$name" 2>/dev/null) || ovl=""
        loosened=$(printf '%s\n' "$ovl" | sed -n 's/^approved://p' | paste -sd, -)
        ignored=$(printf '%s\n' "$ovl" | sed -n 's/^unapproved://p' | paste -sd, -)
        if [ "$json" = true ]; then
            [ "$first" = true ] || printf ','
            first=false
            printf '{"name":"%s","active":%s,"login":"%s","account":%s,"model":%s,"last_used":"%s","size":%s,"binds":%s,"loosened":%s,"ignored":%s}' \
                "$name" "$([ "$name" = "$PROFILE_NAME" ] && echo true || echo false)" "$state" \
                "$(printf '%s' "$email" | _integrity_json_string)" "$(printf '%s' "$model" | _integrity_json_string)" "$used" \
                "$(printf '%s' "${size:--}" | _integrity_json_string)" "$binds" \
                "$(printf '%s' "$loosened" | tr ',' '\n' | _integrity_json_array)" \
                "$(printf '%s' "$ignored" | tr ',' '\n' | _integrity_json_array)"
            continue
        fi
        note=""
        [ -z "$loosened" ] || note="$UI_SYM_WARN loosens: $loosened"
        [ -z "$ignored" ] || note="${note:+$note; }$UI_SYM_WARN ignored (unapproved): $ignored"
        [ "$binds" -eq 0 ] || note="${note:+$note; }$binds project(s)"
        printf '%s %-16s %-9s %-28s %-12s %-11s %-6s %s\n' "$([ "$name" = "$PROFILE_NAME" ] && echo '*' || echo ' ')" \
            "$name" "$state" "${email:--}" "${model:--}" "$used" "${size:--}" "$note"
    done
    [ "$json" = true ] && printf ']}\n'
    return 0
}

# Usage: profile_cmd_current [--name]
profile_cmd_current() {
    case "${1:-}" in
    --name) echo "$PROFILE_NAME" ;;
    "") echo "$PROFILE_NAME ($PROFILE_SOURCE)" ;;
    *)
        config_error "Usage: claude-dockerized profile current [--name]"
        return 1
        ;;
    esac
}

# Usage: profile_cmd_path [NAME] [home|config|env]
profile_cmd_path() {
    local name="${1:-$PROFILE_NAME}" what="${2:-dir}"
    _profile_require "$name" || return 1
    case "$what" in
    dir) profile_dir_of "$name" ;;
    home) profile_home_of "$name" ;;
    config) echo "$(profile_dir_of "$name")/config" ;;
    env) echo "$(profile_dir_of "$name")/env" ;;
    *)
        config_error "Usage: claude-dockerized profile path [NAME] [home|config|env]"
        return 1
        ;;
    esac
}

# Usage: profile_cmd_show [NAME]
profile_cmd_show() {
    local name="${1:-$PROFILE_NAME}"
    _profile_require "$name" || return 1
    (
        PROFILE_FLAG="$name"
        activate_profile
        parse_config || true
        local state email keys
        state=$(profile_login_state "$name")
        email=$(profile_account_email "$CCODE_HOME")
        keys=0
        [ -f "$PROFILE_ENV_FILE" ] && keys=$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$PROFILE_ENV_FILE" 2>/dev/null || true)
        echo ""
        echo "Profile $name:"
        echo "  Directory: $PROFILE_DIR"
        echo "  Home: $CCODE_HOME"
        echo "  Overlay: $PROFILE_CONFIG_FILE$([ -f "$PROFILE_CONFIG_FILE" ] || echo ' (none)')"
        echo "  Secrets: $PROFILE_ENV_FILE ($keys keys)"
        echo "  Login: $state${email:+ ($email)}"
        echo "  Last used: $(_profile_last_used "$name")"
        local dir
        while IFS= read -r dir; do
            [ -n "$dir" ] && echo "  Bound project: $dir"
        done < <(profile_map_dirs "$name")
        print_config
    )
}

# ============================================
# create / login / logout
# ============================================

# Copy the non-secret preferences of <src> into <dst_home>: settings.json,
# agents, commands and (unless shared) skills. Credentials, sessions,
# .claude.json, plugins and the env file never travel.
# Usage: _profile_copy_prefs <src> <dst> <share_skills>
_profile_copy_prefs() {
    local src_home dst_home item
    src_home=$(profile_home_of "$1")
    dst_home="$(profile_dir_of "$2")/home"
    mkdir -p "$dst_home/.claude" 2>/dev/null || return 1
    if [ -f "$src_home/.claude/settings.json" ]; then
        cp -a "$src_home/.claude/settings.json" "$dst_home/.claude/settings.json" || return 1
    fi
    for item in agents commands skills; do
        [ "$item" = skills ] && [ "$3" = true ] && continue
        if [ -d "$src_home/.claude/$item" ]; then
            cp -a "$src_home/.claude/$item" "$dst_home/.claude/$item" || return 1
        fi
    done
    # The overlay comes along without its loosening approvals: a copy must
    # earn its own --allow-loosen.
    if [ -f "$(profile_dir_of "$1")/config" ]; then
        grep -v '^allow_loosen\.' "$(profile_dir_of "$1")/config" >"$(profile_dir_of "$2")/config" || true
    fi
    return 0
}

# Fill the new profile's directory: copied preferences, overlay settings and
# the imported env file (0600). Usage:
# _profile_create_seed <name> <from> <share> <model> <lsp_from> <envsrc>
_profile_create_seed() {
    local name="$1" from="$2" share="$3" model="$4" lsp_from="$5" envsrc="$6" dir cfg
    dir=$(profile_dir_of "$name")
    cfg="$dir/config"
    if [ -n "$from" ]; then
        _profile_copy_prefs "$from" "$name" "$share" || return 1
    fi
    if [ -n "$model" ]; then
        profile_file_set "$cfg" setting.model "$model" || return 1
    fi
    # --share-skills / --lsp-from are the explicit request for those read-only
    # exceptions to isolation, so the approval they need is written with them.
    if [ "$share" = true ]; then
        profile_file_set "$cfg" setting.share_skills true || return 1
        profile_file_set "$cfg" allow_loosen.share_skills true || return 1
    fi
    if [ -n "$lsp_from" ]; then
        profile_file_set "$cfg" setting.lsp_from "$lsp_from" || return 1
        profile_file_set "$cfg" allow_loosen.lsp_from "$lsp_from" || return 1
    fi
    if [ -n "$envsrc" ]; then
        (umask 077 && cat "$envsrc" >"$dir/env") && chmod 600 "$dir/env" || return 1
    fi
    return 0
}

# Usage: profile_cmd_create NAME [--from SRC] [--login] [--model M] [--env-file FILE] [--share-skills] [--lsp-from default]
profile_cmd_create() {
    local name="${1:-}" from="" login=false model="" envsrc="" share=false lsp_from=""
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
        --from) from="${2:-}"; shift 2 || shift ;;
        --login)
            login=true
            shift
            ;;
        --model) model="${2:-}"; shift 2 || shift ;;
        --env-file) envsrc="${2:-}"; shift 2 || shift ;;
        --share-skills)
            share=true
            shift
            ;;
        --lsp-from) lsp_from="${2:-}"; shift 2 || shift ;;
        *)
            config_error "Unknown create option: $1"
            return 1
            ;;
        esac
    done
    if [ -z "$name" ]; then
        config_error "Usage: claude-dockerized profile create NAME [--from SRC] [--login] [--model M] [--env-file FILE] [--share-skills] [--lsp-from default]"
        return 1
    fi
    if [ "$CCODE_HOME_PINNED" = true ]; then
        config_error "CCODE_HOME is set in the environment and pins the state root; profiles are disabled."
        return 1
    fi
    if ! profile_name_valid "$name" || profile_name_reserved "$name"; then
        config_error "Invalid profile name '$name' (lowercase letters, digits, - and _; max 32; not default/all/none/current)"
        return 1
    fi
    if [ -e "$(profile_dir_of "$name")" ]; then
        config_error "Profile '$name' already exists"
        return 1
    fi
    [ -z "$from" ] || _profile_require "$from" || return 1
    if [ -n "$envsrc" ] && [ ! -f "$envsrc" ]; then
        config_error "env file not found: $envsrc"
        return 1
    fi
    if [ -n "$model" ]; then
        case "$model" in *[!A-Za-z0-9._-]*)
            config_error "Invalid model '$model' (letters, digits, . - or _)"
            return 1
            ;;
        esac
    fi
    case "$lsp_from" in "" | default) ;; *)
        config_error "--lsp-from only accepts 'default'"
        return 1
        ;;
    esac

    local dir
    dir=$(profile_dir_of "$name")
    # mkdir without -p: of two concurrent creates of one name exactly one wins,
    # and only the winner ever removes the directory below.
    mkdir -p "$PROFILES_DIR" 2>/dev/null && chmod 700 "$PROFILES_DIR" 2>/dev/null
    if ! mkdir "$dir" 2>/dev/null; then
        config_error "Cannot create $dir (it exists already, or the directory is not writable)"
        return 1
    fi
    chmod 700 "$dir" 2>/dev/null || true
    # From here a failure removes the half-built profile, so a retry works.
    if ! _profile_create_seed "$name" "$from" "$share" "$model" "$lsp_from" "$envsrc"; then
        rm -rf -- "$dir"
        config_error "Could not create profile '$name'; nothing was kept."
        return 1
    fi

    # Build the home skeleton and security layer for the new profile now, in a
    # subshell whose steps are chained with && (errexit does not apply inside an
    # `if` condition): any failure, including an activate_profile `exit`, ends
    # up in the cleanup instead of leaving a half-built profile.
    if ! (
        # shellcheck disable=SC2034 # read by activate_profile
        PROFILE_FLAG="$name"
        activate_profile && parse_config && ensure_claude_dirs && [ -d "$CCODE_HOME/.claude" ]
    ); then
        rm -rf -- "$dir"
        config_error "Could not build the home of profile '$name'; nothing was kept."
        return 1
    fi
    PROFILE_FLAG="$name"
    activate_profile
    parse_config
    if [ ! -d "$CCODE_HOME/.claude" ]; then
        rm -rf -- "$dir"
        config_error "Could not build the home of profile '$name'; nothing was kept."
        return 1
    fi
    config_success "Created profile '$name' ($PROFILE_DIR)"
    if [ "$login" = true ]; then
        profile_cmd_login "$name"
        return $?
    fi
    config_info "Next: claude-dockerized profile login $name   (or put API keys in: claude-dockerized profile edit $name env)"
}

# Usage: profile_cmd_login NAME
profile_cmd_login() {
    _profile_require "${1:-}" || return 1
    PROFILE_FLAG="$1"
    activate_profile
    parse_config
    ensure_claude_dirs
    check_docker
    run_auth
    local email
    email=$(profile_account_email "$CCODE_HOME")
    config_success "Profile '$PROFILE_NAME' logged in${email:+ as $email}"
}

# Usage: profile_cmd_logout NAME [--yes]
profile_cmd_logout() {
    local name="${1:-}" yes=false
    shift || true
    [ "${1:-}" = --yes ] && yes=true
    _profile_require "$name" || return 1
    local cred
    cred="$(profile_home_of "$name")/.claude/.credentials.json"
    if [ ! -s "$cred" ]; then
        config_info "Profile '$name' has no login to remove."
        return 0
    fi
    [ "$yes" = true ] || _profile_confirm "$name" "log out profile '$name'" || return 1
    : >"$cred" && chmod 600 "$cred"
    config_success "Logged out profile '$name' (API keys in its env file are untouched: profile edit $name env)"
    [ "$name" != default ] || profile_warn_backups
}

# ============================================
# use / bind / unbind
# ============================================

# Usage: profile_cmd_use NAME
profile_cmd_use() {
    _profile_require "${1:-}" || return 1
    config_exists || init_config_file
    profile_file_set "$CONFIG_FILE" setting.profile "$1" || return 1
    config_success "Default profile is now '$1' (override per run with --profile or CLAUDE_DOCKERIZED_PROFILE)"
}

# Usage: profile_cmd_bind NAME [DIR]
profile_cmd_bind() {
    local name="${1:-}" dir="${2:-$(pwd)}"
    _profile_require "$name" || return 1
    if [ ! -d "$dir" ]; then
        config_error "Project directory does not exist: $dir"
        return 1
    fi
    dir="$(cd "$dir" && pwd -P)"
    validate_project_dir "$dir" || return 1
    profile_map_set "$dir" "$name" || return 1
    config_success "Project $dir now runs with profile '$name' (pinned in $PROFILE_MAP_FILE, outside the project)"
}

# Usage: profile_cmd_unbind [DIR]
profile_cmd_unbind() {
    local dir="${1:-$(pwd)}"
    [ -d "$dir" ] && dir="$(cd "$dir" && pwd -P)"
    if [ -z "$(profile_bound_name "$dir")" ]; then
        config_info "No profile is bound to $dir"
        return 0
    fi
    profile_map_unset "$dir" || return 1
    config_success "Removed the profile bound to $dir"
}

# ============================================
# edit / set / unset
# ============================================

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
    *)
        config_error "Usage: claude-dockerized profile edit NAME [config|env]"
        return 1
        ;;
    esac
}

# Edit an overlay and check it on save the way `profile set` would; on a TTY
# offer to reopen it while problems remain. Returns 1 when problems are left.
# Usage: _profile_edit_overlay <name> <editor> <file>
_profile_edit_overlay() {
    local name="$1" editor="$2" file="$3" problems answer
    while :; do
        "$editor" "$file"
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

# Problems of an overlay file, one per line, as `profile set` would report
# them: unknown lines, settings a profile cannot override, invalid values or
# mounts, and loosenings without approval. Prints nothing when it is clean.
# Usage: profile_overlay_problems <file>
profile_overlay_problems() {
    local file="$1" key value lineno=0 reason item
    [ -f "$file" ] || return 0
    while IFS='=' read -r key value || [ -n "$key" ]; do
        lineno=$((lineno + 1))
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
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
            config_error "'$key' cannot be overridden per profile (allowed: ssh_agent_support gpg_agent_support gpg_allow_main_socket gpg_autostart_agent gpg_relay docker_socket network security_policy hardening integrity_check model cleanup_days lsp lsp_servers formatters memory cpus share_skills lsp_from, or mount.<name>)"
            return 1
        fi
        if ! reason=$(_profile_value_error "$key" "$value"); then
            config_error "Invalid value for $key: $reason"
            return 1
        fi
    fi
    line_key=$(_profile_line_key "$key")
    cfg="$(profile_dir_of "$name")/config"
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
    cat "$tmp" >"$cfg" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
    config_success "Profile '$name': $line_key=$value"
}

# Usage: profile_cmd_unset NAME KEY
profile_cmd_unset() {
    local name="${1:-}" key="${2:-}" cfg line_key
    _profile_require "$name" || return 1
    if [ -z "$key" ]; then
        config_error "Usage: claude-dockerized profile unset NAME KEY"
        return 1
    fi
    cfg="$(profile_dir_of "$name")/config"
    line_key=$(_profile_line_key "$key")
    profile_file_unset "$cfg" "$line_key"
    profile_file_unset "$cfg" "allow_loosen.$key"
    config_success "Profile '$name': $line_key now follows the global config"
}

# ============================================
# rename / delete
# ============================================

# Usage: profile_cmd_rename OLD NEW
profile_cmd_rename() {
    local old="${1:-}" new="${2:-}"
    _profile_require "$old" || return 1
    if [ "$old" = default ]; then
        config_error "The default profile cannot be renamed."
        return 1
    fi
    if ! profile_name_valid "$new" || profile_name_reserved "$new"; then
        config_error "Invalid profile name '$new'"
        return 1
    fi
    if [ -e "$(profile_dir_of "$new")" ]; then
        config_error "Profile '$new' already exists"
        return 1
    fi
    if profile_running "$old"; then
        config_error "Profile '$old' has a running session; close it first."
        return 1
    fi
    mv "$(profile_dir_of "$old")" "$(profile_dir_of "$new")" || return 1
    profile_map_rename "$old" "$new"
    [ "$(profile_config_default)" != "$old" ] || profile_file_set "$CONFIG_FILE" setting.profile "$new"
    config_success "Renamed profile '$old' to '$new'"
}

# Usage: profile_cmd_delete NAME [--yes] [--force]
profile_cmd_delete() {
    local name="${1:-}" yes=false force=false arg
    shift || true
    for arg in "$@"; do
        case "$arg" in
        --yes) yes=true ;;
        --force) force=true ;;
        esac
    done
    _profile_require "$name" || return 1
    if [ "$name" = default ] && [ "$force" = false ]; then
        config_error "The default profile is the fallback; delete it only with --force (it is recreated empty on next use)."
        return 1
    fi
    local dir
    dir=$(profile_dir_of "$name")
    if [ -L "$dir" ]; then
        config_error "$dir is a symlink; remove it by hand."
        return 1
    fi
    if profile_running "$name"; then
        config_error "Profile '$name' has a running session; close it first."
        return 1
    fi
    local state email
    state=$(profile_login_state "$name")
    email=$(profile_account_email "$(profile_home_of "$name")")
    config_warning "Deleting profile '$name' removes for good: login ($state${email:+, $email}), sessions, plugins, settings and its env file ($(du -sh "$dir" 2>/dev/null | cut -f1))."
    [ "$yes" = true ] || _profile_confirm "$name" "delete profile '$name'" || return 1
    rm -rf -- "$dir" || return 1
    profile_map_drop "$name"
    [ "$(profile_config_default)" != "$name" ] || profile_file_unset "$CONFIG_FILE" setting.profile
    config_success "Deleted profile '$name'"
    [ "$name" != default ] || profile_warn_backups
}

# ============================================
# doctor / migrate
# ============================================

# Checks of one profile in the current (sub)shell. Usage: _profile_doctor_one <name>
_profile_doctor_one() {
    local name="$1" rc=0 mode dir key
    dir=$(profile_dir_of "$name")
    mode=$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir" 2>/dev/null || true)
    if [ -n "$mode" ] && [ $((8#$mode & 8#077)) -ne 0 ]; then
        config_warning "$name: $dir is accessible by group/others (chmod 700)"
        rc=1
    fi
    if [ -f "$dir/env" ]; then
        mode=$(stat -c '%a' "$dir/env" 2>/dev/null || stat -f '%Lp' "$dir/env" 2>/dev/null || true)
        if [ -n "$mode" ] && [ $((8#$mode & 8#044)) -ne 0 ]; then
            config_warning "$name: env file is readable by group/others (chmod 600)"
            rc=1
        fi
    fi
    [ "$(profile_login_state "$name")" != none ] || config_warning "$name: no login and no API key (profile login $name)"
    for key in $(_profile_loosened_keys "$name"); do
        config_warning "$name: loosens $key on purpose (--allow-loosen)"
    done
    for key in $(_profile_unapproved_keys "$name"); do
        config_warning "$name: its overlay tries to loosen $key without approval, so it is ignored (profile set $name $key VALUE --allow-loosen)"
        rc=1
    done
    if ! (
        # shellcheck disable=SC2034 # read by activate_profile
        PROFILE_FLAG="$name"
        activate_profile
        parse_config >/dev/null 2>&1 || true
        check_security_layer >/dev/null 2>&1
    ); then
        config_error "$name: security layer drift (run: claude-dockerized config sync)"
        rc=1
    fi
    [ "$rc" -ne 0 ] || config_success "$name: ok"
    return "$rc"
}

# Usage: profile_cmd_doctor [NAME|--all]
profile_cmd_doctor() {
    local target="${1:---all}" name rc=0
    if [ "$target" = --all ]; then
        for name in $(profile_names); do
            _profile_doctor_one "$name" || rc=1
        done
    else
        _profile_require "$target" || return 1
        _profile_doctor_one "$target" || rc=1
    fi
    if [ -d "$CONFIG_DIR/home" ] && [ "$CCODE_HOME_PINNED" = false ] && [ -e "$PROFILES_DIR/default/home" ]; then
        config_warning "Legacy $CONFIG_DIR/home is ignored (the default profile lives in $PROFILES_DIR/default/home)"
    fi
    return "$rc"
}

# Usage: profile_cmd_migrate [--dry-run|--no-backup|--rollback|--prune-backups [--yes]]
profile_cmd_migrate() {
    local action="" yes=false arg
    local -a mflags=()
    for arg in "$@"; do
        case "$arg" in
        --yes) yes=true ;;
        --dry-run | --no-backup) mflags+=("$arg") ;;
        --rollback | --prune-backups)
            if [ -n "$action" ]; then
                config_error "Use one of --rollback or --prune-backups."
                return 1
            fi
            action="$arg"
            ;;
        *)
            config_error "Usage: claude-dockerized profile migrate [--dry-run|--no-backup|--rollback|--prune-backups [--yes]]"
            return 1
            ;;
        esac
    done
    # --dry-run and --no-backup describe a migration; with --rollback or
    # --prune-backups they would be silently ignored while the action is real.
    if [ -n "$action" ] && [ "${#mflags[@]}" -gt 0 ]; then
        config_error "${mflags[0]} only applies to a migration, not to $action."
        return 1
    fi
    case "$action" in
    --rollback)
        profile_migrate_rollback || return 1
        config_info "Use the previous wrapper version now; the next run of this one migrates again."
        ;;
    --prune-backups) profile_prune_backups "$yes" ;;
    *) profile_migrate_legacy "${mflags[@]}" ;;
    esac
}

# ============================================
# dispatcher
# ============================================

# `claude-dockerized profile <subcommand>` (and `profiles` = `profile list`).
# Usage: manage_profiles [SUBCOMMAND] [ARGS...]
manage_profiles() {
    local sub="${1:-list}"
    shift || true
    case "$sub" in
    list | ls) profile_cmd_list "$@" ;;
    current) profile_cmd_current "$@" ;;
    show) profile_cmd_show "$@" ;;
    path) profile_cmd_path "$@" ;;
    create | new | add) profile_cmd_create "$@" ;;
    login) profile_cmd_login "$@" ;;
    logout) profile_cmd_logout "$@" ;;
    use) profile_cmd_use "$@" ;;
    bind) profile_cmd_bind "$@" ;;
    unbind) profile_cmd_unbind "$@" ;;
    edit) profile_cmd_edit "$@" ;;
    set) profile_cmd_set "$@" ;;
    unset) profile_cmd_unset "$@" ;;
    rename | mv) profile_cmd_rename "$@" ;;
    delete | rm) profile_cmd_delete "$@" ;;
    doctor) profile_cmd_doctor "$@" ;;
    migrate) profile_cmd_migrate "$@" ;;
    -h | --help | help) command_help profile ;;
    *)
        config_error "Unknown profile subcommand: $sub"
        command_help profile >&2
        return 1
        ;;
    esac
}
