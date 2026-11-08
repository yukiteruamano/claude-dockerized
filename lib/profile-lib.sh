#!/bin/bash
# profile-lib.sh - accounts as profiles: name rules, resolution, activation,
# account info and project binds. Sourced by lib/config-lib.sh; the overlay
# lives in profile-overlay-lib.sh, the layout migration in
# profile-migrate-lib.sh and the user-facing `profile` commands in
# profile-cmd-lib.sh / profile-edit-lib.sh. Not executable directly; no
# `set -e`: callers own error handling.
#
# Layout (see docs/security/THREAT-MODEL.md, T-31..T-36):
#   $CONFIG_DIR/profiles/<name>/home    CCODE_HOME of the profile (the only home mounted)
#   $CONFIG_DIR/profiles/<name>/config  overlay (setting.* / mount.* / allow_loosen.<key>=<value>)
#   $CONFIG_DIR/profiles/<name>/env     dotenv secrets of the profile (0600, never mounted)
#   $CONFIG_DIR/profiles/<name>/CLAUDE.md, permissions, allow-patterns.json
#                                       session rules, deny/ask rules, guard allow rules
#   $CONFIG_DIR/profiles.map            project path <TAB> profile (host-side pin)
#   $CONFIG_DIR/backups/                taken before the layout migration

# shellcheck disable=SC2034 # PROFILE_* and ENV_FILE are consumed by bin/claude-dockerized and the other libs

PROFILE_NAME="default"
PROFILE_SOURCE="default" # flag | env | bind | config | default | pinned
PROFILE_DIR="$PROFILES_DIR/default"
PROFILE_CONFIG_FILE="$PROFILE_DIR/config"
PROFILE_ENV_FILE="$PROFILE_DIR/env"
PROFILE_MAP_FILE="${PROFILE_MAP_FILE:-$CONFIG_DIR/profiles.map}"
PROFILE_FLAG=""
declare -a PROFILE_ARGS=()
declare -a PROFILE_LOOSENED=() # "key=value" pairs the active profile loosened on purpose
declare -a PROFILE_UNAPPROVED=() # settings the overlay tried to loosen without approval (dropped)
declare -a PROFILE_SET_KEYS=()   # settings and mount.<name> keys the overlay applied (config show sources)
declare -a PROFILE_DROPPED_MOUNTS=() # global mounts the overlay removed (mount.<name>=-)
declare -a PROFILE_APPROVALS=()  # allow_loosen.<key>=<value> of the overlay, as "key=value" (read by the loader)
declare -a PROFILE_RAW_KEYS=() PROFILE_RAW_VALUES=() # setting keys/values the loader applied from the overlay
PROFILE_REJECTED=""              # the overlay file when it was refused as a whole (control bytes)
PROFILE_BOUND_PATH=""            # set by profile_bound_entry: the map entry that applies...
PROFILE_BOUND_NAME=""            # ...and its profile
PROFILE_ALLOW_PATTERNS=""        # the profile's approved allow-patterns.json (T-36), or empty
_PROFILE_WARNED=""               # ids of warnings already printed by this process

# ============================================
# NAMES AND PATHS
# ============================================

# Profile names become directory and container-name components: lowercase
# letters, digits, - and _, starting alphanumeric, at most 32 characters.
# Usage: profile_name_valid <name>
profile_name_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]
}

# Names that cannot be created (default exists implicitly; the rest would read
# as keywords in `profile` output). Usage: profile_name_reserved <name>
profile_name_reserved() {
    case "$1" in
    default | all | none | current) return 0 ;;
    esac
    return 1
}

# Usage: profile_dir_of <name>
profile_dir_of() {
    printf '%s/%s' "$PROFILES_DIR" "$1"
}

# CCODE_HOME of a profile (a pinned CCODE_HOME stands for `default`).
# Usage: profile_home_of <name>
profile_home_of() {
    if [ "$CCODE_HOME_PINNED" = true ] && [ "$1" = default ]; then
        printf '%s' "$CCODE_HOME"
    else
        printf '%s/home' "$(profile_dir_of "$1")"
    fi
}

# Does the profile exist? `default` always does (created on first use).
# Usage: profile_exists <name>
profile_exists() {
    [ "$1" = default ] || [ -d "$(profile_dir_of "$1")" ]
}

# Names of every profile, default first, the rest sorted. Usage: profile_names
profile_names() {
    local d name
    echo default
    # A pinned CCODE_HOME turns profiles off: only the default one is in use.
    [ "$CCODE_HOME_PINNED" = false ] || return 0
    [ -d "$PROFILES_DIR" ] || return 0
    for d in "$PROFILES_DIR"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        [ "$name" = default ] && continue
        profile_name_valid "$name" || continue
        echo "$name"
    done | sort
}

# Create the 0700 directory of a profile. Usage: profile_dir_init <name>
profile_dir_init() {
    local dir
    dir=$(profile_dir_of "$1")
    mkdir -p "$PROFILES_DIR" "$dir" 2>/dev/null || return 1
    chmod 700 "$PROFILES_DIR" "$dir" 2>/dev/null || true
}

# ============================================
# SELECTION: --profile, env, project bind, setting.profile
# ============================================

# Pull --profile NAME / --profile=NAME (and -p NAME when <short_ok>=true) out
# of the arguments before the first `--`. Sets PROFILE_FLAG and PROFILE_ARGS
# (the remaining arguments). Usage: profile_extract_flag <short_ok> <args...>
profile_extract_flag() {
    local short_ok="$1" stop=false
    shift
    PROFILE_ARGS=()
    while [ $# -gt 0 ]; do
        if [ "$stop" = false ]; then
            case "$1" in
            --) stop=true ;;
            --profile | -p)
                if [ "$1" = -p ] && [ "$short_ok" != true ]; then
                    PROFILE_ARGS+=("$1")
                    shift
                    continue
                fi
                if [ $# -lt 2 ] || [ -z "$2" ]; then
                    print_error "$1 needs a profile name (see: claude-dockerized profiles)"
                    exit 1
                fi
                PROFILE_FLAG="$2"
                shift 2
                continue
                ;;
            --profile=*)
                if [ -z "${1#--profile=}" ]; then
                    print_error "--profile needs a profile name (see: claude-dockerized profiles)"
                    exit 1
                fi
                PROFILE_FLAG="${1#--profile=}"
                shift
                continue
                ;;
            esac
        fi
        PROFILE_ARGS+=("$1")
        shift
    done
}

# Is profiles.map safe to parse? A NUL or control byte would make bash and
# awk read different lines; the map is then ignored (no bind applies) with one
# error. Usage: profile_map_ok
profile_map_ok() {
    local reason
    reason=$(config_file_bad_bytes "$PROFILE_MAP_FILE") || return 0
    config_error_once "bad-bytes:$PROFILE_MAP_FILE" "Ignoring $PROFILE_MAP_FILE: $reason (only tabs and line endings are allowed); no project bind applies until it is fixed by hand."
    return 1
}

# The bind that applies to <dir>: the entry for <dir> or its closest
# ancestor (the longest match wins). Sets PROFILE_BOUND_PATH and
# PROFILE_BOUND_NAME (both empty when nothing is bound). The map lives next to
# the config, never inside a project: the agent can write to the project but
# not to $CONFIG_DIR (T-32). Usage: profile_bound_entry <dir>
profile_bound_entry() {
    local dir="$1" p n best_len=0
    PROFILE_BOUND_PATH=""
    PROFILE_BOUND_NAME=""
    [ -n "$dir" ] && [ -f "$PROFILE_MAP_FILE" ] || return 0
    profile_map_ok || return 0
    dir=$(canonical_host_path "$dir")
    while IFS=$'\t' read -r p n || [ -n "$p" ]; do
        [ -n "$p" ] && [ -n "$n" ] || continue
        if path_within "$dir" "$p" && [ "${#p}" -gt "$best_len" ]; then
            PROFILE_BOUND_PATH="$p"
            PROFILE_BOUND_NAME="$n"
            best_len=${#p}
        fi
    done <"$PROFILE_MAP_FILE"
}

# The profile pinned to <dir> (or an ancestor), or nothing.
# Usage: profile_bound_name <dir>
profile_bound_name() {
    profile_bound_entry "$1"
    printf '%s' "$PROFILE_BOUND_NAME"
}

# setting.profile from the global config, read before the full parse because
# the selected profile decides which files get parsed. Usage: profile_config_default
profile_config_default() {
    local v
    v=$(config_file_value "$CONFIG_FILE" setting.profile) || return 0
    profile_name_valid "$v" && printf '%s' "$v"
    return 0
}

# Resolve which profile is active: --profile, then CLAUDE_DOCKERIZED_PROFILE,
# then the bind of the project, then setting.profile, then default. Sets
# PROFILE_NAME and PROFILE_SOURCE. Usage: profile_resolve [project_dir]
profile_resolve() {
    local project="${1:-}" name="" src="" bound=""
    if [ -n "$PROFILE_FLAG" ]; then
        name="$PROFILE_FLAG" src=flag
    elif [ -n "${CLAUDE_DOCKERIZED_PROFILE:-}" ]; then
        name="$CLAUDE_DOCKERIZED_PROFILE" src=env
    else
        profile_bound_entry "$project"
        bound="$PROFILE_BOUND_NAME"
        if [ -n "$bound" ] && profile_name_valid "$bound" && { profile_exists "$bound" || [ "$CCODE_HOME_PINNED" = true ]; }; then
            name="$bound" src=bind
        else
            [ -z "$bound" ] || print_warning "Ignoring the profile bound to this project ('$bound' no longer exists); see: claude-dockerized profile unbind"
            name=$(profile_config_default)
            src=config
            # A stale setting.profile must not lock the user out of every
            # command (including the ones that fix it): fall back to default.
            if [ -n "$name" ] && [ "$CCODE_HOME_PINNED" = false ] && ! profile_exists "$name"; then
                print_warning "setting.profile names '$name', which no longer exists; using default (fix it with: claude-dockerized profile use default)"
                name=""
            fi
            [ -n "$name" ] || {
                name=default
                src=default
            }
        fi
    fi
    if ! profile_name_valid "$name"; then
        print_error "Invalid profile name '$name' (lowercase letters, digits, - and _; max 32; start alphanumeric)"
        exit 1
    fi
    PROFILE_NAME="$name"
    PROFILE_SOURCE="$src"
}

# Select the profile and point CCODE_HOME at its home. Migrates the
# single-account layout first (with a backup). Exits when the profile does not
# exist. Usage: activate_profile [project_dir]
activate_profile() {
    profile_resolve "${1:-}"
    if [ "$CCODE_HOME_PINNED" = true ]; then
        # Asking for a profile is an error here; a configured default or a
        # project bind is just not applicable while profiles are off.
        if [ "$PROFILE_NAME" != default ]; then
            case "$PROFILE_SOURCE" in
            flag | env)
                print_error "CCODE_HOME is set in the environment and pins the state root; profiles are disabled (unset it to use '$PROFILE_NAME')."
                exit 1
                ;;
            esac
            PROFILE_NAME=default
        fi
        PROFILE_SOURCE=pinned
    else
        # `profile migrate` runs the migration itself (dry-run, rollback).
        if [ -z "${PROFILE_SKIP_AUTO_MIGRATE:-}" ]; then
            profile_migrate_legacy_auto || exit 1
        fi
        if ! profile_exists "$PROFILE_NAME"; then
            print_error "Unknown profile '$PROFILE_NAME' (create it with: claude-dockerized profile create $PROFILE_NAME)"
            exit 1
        fi
        if [ ! -d "$(profile_dir_of "$PROFILE_NAME")" ] && [ -z "${PROFILE_SKIP_AUTO_MIGRATE:-}" ]; then
            profile_dir_init "$PROFILE_NAME" || {
                print_error "Cannot create $(profile_dir_of "$PROFILE_NAME")"
                exit 1
            }
        fi
        CCODE_HOME="$(profile_dir_of "$PROFILE_NAME")/home"
    fi
    PROFILE_DIR="$(profile_dir_of "$PROFILE_NAME")"
    PROFILE_CONFIG_FILE="$PROFILE_DIR/config"
    PROFILE_ENV_FILE="$PROFILE_DIR/env"
}

# ============================================
# ACCOUNT INFO (read-only, no secrets printed)
# ============================================

# Account e-mail of a profile home from .claude.json (oauthAccount.emailAddress,
# an identity, not a secret): node when present, grep otherwise. Prints nothing
# when unknown. Usage: profile_account_email <home>
profile_account_email() {
    local file="$1/.claude.json" email=""
    [ -r "$file" ] || return 0
    if command -v node >/dev/null 2>&1; then
        email=$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const e=j.oauthAccount&&j.oauthAccount.emailAddress;if(typeof e==="string")process.stdout.write(e)}catch(e){}' "$file" 2>/dev/null || true)
    else
        # Without node: the emailAddress inside the oauthAccount object only (any
        # other "emailAddress" in the file belongs to something else).
        # `{` right after the key excludes `"oauthAccount": null`; `[^{}]*` keeps
        # the match inside that one flat object (a nested one gives nothing).
        email=$(tr -d '\n' <"$file" 2>/dev/null | grep -o '"oauthAccount"[[:space:]]*:[[:space:]]*{[^{}]*"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"\([^"]*\)"$/\1/')
    fi
    case "$email" in "" | *[!A-Za-z0-9._%+@-]*) return 0 ;; esac
    printf '%s' "$email"
}

# How a profile authenticates: oauth (login), api-key / token (env file key
# names only), provider (Bedrock/Vertex/Foundry flags) or none.
# Usage: profile_login_state <name>
profile_login_state() {
    local home env
    home=$(profile_home_of "$1")
    env="$(profile_dir_of "$1")/env"
    if [ -s "$home/.claude/.credentials.json" ]; then
        echo oauth
    elif [ -f "$env" ] && grep -qE '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)=' "$env" 2>/dev/null; then
        echo api-key
    elif [ -f "$env" ] && grep -qE '^CLAUDE_CODE_USE_(BEDROCK|VERTEX|FOUNDRY)=' "$env" 2>/dev/null; then
        echo provider
    else
        echo none
    fi
}

# Is a session of the profile running? Needs a reachable Docker; without one
# nothing can be running. Usage: profile_running <name>
profile_running() {
    command -v docker >/dev/null 2>&1 || return 1
    [ -n "$(docker ps -q --filter "label=claude-dockerized.profile=$1" 2>/dev/null)" ]
}

# Record that the profile was used (shown by `profile list`).
# Usage: profile_touch_used
profile_touch_used() {
    : >"$PROFILE_DIR/.last-used" 2>/dev/null || true
}

# ============================================
# profiles.map (project -> profile pins)
# ============================================

# Usage: profile_map_rewrite <awk-program> [awk -v args...]
_profile_map_rewrite() {
    local prog="$1" tmp
    shift
    mkdir -p "$CONFIG_DIR" 2>/dev/null || return 1
    tmp=$(mktemp "$PROFILE_MAP_FILE.tmp.XXXXXX" 2>/dev/null) || return 1
    if [ -f "$PROFILE_MAP_FILE" ]; then
        awk -F'\t' -v OFS='\t' "$@" "$prog" "$PROFILE_MAP_FILE" >"$tmp" || {
            rm -f "$tmp"
            return 1
        }
    fi
    if [ -s "$tmp" ]; then
        chmod 600 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$PROFILE_MAP_FILE"
    else
        rm -f "$tmp" "$PROFILE_MAP_FILE"
    fi
}

# Pin <dir> to <name>. Usage: profile_map_set <dir> <name>
profile_map_set() {
    local dir="$1" name="$2"
    case "$dir" in
    *$'\t'* | *$'\n'*)
        config_error "Refusing a project path with tabs or newlines"
        return 1
        ;;
    esac
    _profile_map_rewrite '$1 != d' -v d="$dir" || return 1
    printf '%s\t%s\n' "$dir" "$name" >>"$PROFILE_MAP_FILE" || return 1
    chmod 600 "$PROFILE_MAP_FILE" 2>/dev/null || true
}

# Usage: profile_map_unset <dir>
profile_map_unset() {
    _profile_map_rewrite '$1 != d' -v d="$1"
}

# Drop every pin of a profile. Usage: profile_map_drop <name>
profile_map_drop() {
    _profile_map_rewrite '$2 != n' -v n="$1"
}

# Repoint every pin of <old> to <new>. Usage: profile_map_rename <old> <new>
profile_map_rename() {
    _profile_map_rewrite '{ if ($2 == o) $2 = n; print }' -v o="$1" -v n="$2"
}

# Directories pinned to a profile. Usage: profile_map_dirs <name>
profile_map_dirs() {
    [ -f "$PROFILE_MAP_FILE" ] || return 0
    awk -F'\t' -v n="$1" '$2 == n { print $1 }' "$PROFILE_MAP_FILE"
}

# ============================================
# CLI HELPERS
# ============================================

# Directory that decides the project bind: the DIR of `run`, else the cwd.
# Usage: profile_project_hint <command> [args...]
profile_project_hint() {
    local command="$1" a
    shift
    if [ "$command" = run ]; then
        for a in "$@"; do
            case "$a" in
            --) break ;;
            -*) ;;
            *)
                printf '%s' "$a"
                return 0
                ;;
            esac
        done
    fi
    pwd -P
}

# Say which account a session uses when it is not the only one.
# Usage: profile_banner
profile_banner() {
    [ "$PROFILE_NAME" != default ] || [ "$(profile_names | wc -l)" -gt 1 ] || return 0
    local email
    email=$(profile_account_email "$CCODE_HOME")
    print_info "Profile: $PROFILE_NAME${email:+ ($email)}"
}
