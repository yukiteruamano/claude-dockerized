#!/bin/bash
# profile-lib.sh - accounts as profiles: name rules, resolution, activation,
# per-profile config overlay and the migration of the single-account layout.
# Sourced by lib/config-lib.sh (the user-facing `profile` commands live in
# lib/profile-cmd-lib.sh). Not executable directly; no `set -e`: callers own
# error handling.
#
# Layout (see docs/security/THREAT-MODEL.md, T-31..T-34):
#   $CONFIG_DIR/profiles/<name>/home    CCODE_HOME of the profile (the only home mounted)
#   $CONFIG_DIR/profiles/<name>/config  overlay (setting.* / mount.* / allow_loosen.<key>=true)
#   $CONFIG_DIR/profiles/<name>/env     dotenv secrets of the profile (0600, never mounted)
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

# The profile pinned to <dir> (or an ancestor; the longest match wins) in
# profiles.map, or nothing. The map lives next to the config, never inside a
# project: the agent can write to the project but not to $CONFIG_DIR (T-32).
# Usage: profile_bound_name <dir>
profile_bound_name() {
    local dir="$1" p n best="" best_len=0
    [ -n "$dir" ] && [ -f "$PROFILE_MAP_FILE" ] || return 0
    dir=$(canonical_host_path "$dir")
    while IFS=$'\t' read -r p n || [ -n "$p" ]; do
        [ -n "$p" ] && [ -n "$n" ] || continue
        if path_within "$dir" "$p" && [ "${#p}" -gt "$best_len" ]; then
            best="$n"
            best_len=${#p}
        fi
    done <"$PROFILE_MAP_FILE"
    printf '%s' "$best"
}

# setting.profile from the global config, read before the full parse because
# the selected profile decides which files get parsed. Usage: profile_config_default
profile_config_default() {
    [ -f "$CONFIG_FILE" ] || return 0
    local v
    v=$(sed -n 's/^[[:space:]]*setting\.profile[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" 2>/dev/null | tail -n 1)
    v="${v%"${v##*[![:space:]]}"}"
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
        bound=$(profile_bound_name "$project")
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
# CONFIG OVERLAY
# ============================================

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
        docker_socket | network | security_policy | hardening | integrity_check | model | cleanup_days | \
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

# The network a session really gets: hardening=strict turns an implicit host
# network into bridge (see append_hardening_args).
# Usage: _profile_effective_network <hardening> <network> <explicit>
_profile_effective_network() {
    if [ "$1" = strict ] && [ "$3" != true ] && [ "$2" = host ]; then
        echo bridge
    else
        echo "$2"
    fi
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

# Checks that need the whole overlay: the effective network (an overlay
# network=host escapes the bridge that global hardening=strict implies) and the
# resource limits (dropping or raising a global memory/cpus limit). A loosening
# without approval is reverted to the global value.
# Usage: _profile_overlay_post_checks <file> <g_hardening> <g_network> <g_explicit> <g_memory> <g_cpus>
_profile_overlay_post_checks() {
    local file="$1" raw old_eff new_eff kind var old new
    old_eff=$(_profile_effective_network "$2" "$3" "$4")
    if raw=$(_profile_overlay_raw "$file" network); then
        new_eff=$(_profile_effective_network "$HARDENING" "$NETWORK" "$NETWORK_EXPLICIT")
        if [ "$old_eff" = bridge ] && [ "$new_eff" = host ]; then
            if profile_loosen_approved "$file" network "$raw"; then
                PROFILE_LOOSENED+=("network=host")
            else
                NETWORK="$3"
                NETWORK_EXPLICIT="$4"
                PROFILE_UNAPPROVED+=("network")
                # Say what the session really gets (an approved hardening change
                # can still make it host).
                new_eff=$(_profile_effective_network "$HARDENING" "$NETWORK" "$NETWORK_EXPLICIT")
                _profile_warn_once "$PROFILE_NAME:network" "Profile '$PROFILE_NAME' loosens network ($old_eff -> host) without approval; the session gets $new_eff (approve with: claude-dockerized profile set $PROFILE_NAME network \"$raw\" --allow-loosen)"
            fi
        fi
    fi
    # An approved hardening change can turn the implied bridge into host on its
    # own: make that visible next to it.
    new_eff=$(_profile_effective_network "$HARDENING" "$NETWORK" "$NETWORK_EXPLICIT")
    if [ "$old_eff" = bridge ] && [ "$new_eff" = host ] && [[ " ${PROFILE_LOOSENED[*]} " != *" network=host "* ]]; then
        PROFILE_LOOSENED+=("network=host")
    fi
    for kind in memory cpus; do
        raw=$(_profile_overlay_raw "$file" "$kind") || continue
        if [ "$kind" = memory ]; then
            var=MEMORY old="$5"
        else
            var=CPUS old="$6"
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

# Layer an overlay file on top of the settings loaded so far. Fills
# PROFILE_LOOSENED (approved loosenings) and PROFILE_UNAPPROVED (dropped ones).
# Usage: profile_apply_overlay_file <file>
profile_apply_overlay_file() {
    local file="$1" g_h="$HARDENING" g_n="$NETWORK" g_e="$NETWORK_EXPLICIT" g_m="$MEMORY" g_c="$CPUS"
    PROFILE_LOOSENED=()
    PROFILE_UNAPPROVED=()
    [ -f "$file" ] || return 0
    _load_config_file "$file" overlay
    _profile_overlay_post_checks "$file" "$g_h" "$g_n" "$g_e" "$g_m" "$g_c"
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

# One warning per run when the profile weakens the global posture on purpose.
# Usage: profile_report_loosened
profile_report_loosened() {
    local item
    for item in "${PROFILE_LOOSENED[@]}"; do
        config_warning "Profile '$PROFILE_NAME' loosens the global security posture: $item (approved with --allow-loosen)"
    done
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
# MIGRATION of the single-account layout ($CONFIG_DIR/home)
# ============================================

# The legacy layout keeps the one account in $CONFIG_DIR/home and the secrets
# file named by setting.env_file. Needed when that home exists and the default
# profile has none yet. Usage: profile_migration_needed
profile_migration_needed() {
    [ "$CCODE_HOME_PINNED" = false ] || return 1
    [ -d "$CONFIG_DIR/home" ] || [ -L "$CONFIG_DIR/home" ] || return 1
    [ ! -e "$PROFILES_DIR/default/home" ]
}

# Legacy setting.env_file resolved to an absolute path, only when it is an
# existing file under $CONFIG_DIR. Usage: _profile_legacy_env_path
_profile_legacy_env_path() {
    [ -f "$CONFIG_FILE" ] || return 0
    local v p
    v=$(sed -n 's/^[[:space:]]*setting\.env_file[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" 2>/dev/null | tail -n 1)
    v="${v%"${v##*[![:space:]]}"}"
    [ -n "$v" ] || return 0
    p=$(canonical_host_path "$v")
    path_within "$p" "$(canonical_host_path "$CONFIG_DIR")" && [ -f "$p" ] && printf '%s' "$p"
    return 0
}

# Sorted names of the top-level entries of <dir>, hidden ones included, minus
# the re-creatable .cache. Usage: _profile_top_entries <dir>
_profile_top_entries() {
    local e
    for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        [ "${e##*/}" = .cache ] || printf '%s\n' "${e##*/}"
    done | sort
}

# Number of entries below <dir>, .cache excluded. Usage: _profile_entry_count <dir>
_profile_entry_count() {
    find "$1" -path "$1/.cache" -prune -o -print 2>/dev/null | wc -l | tr -d ' '
}

# Is there room for a copy of the home (without its .cache, which the backup
# skips)? Explains and returns 1 when not; when the sizes cannot be read it
# lets cp decide. Usage: _profile_backup_space_ok
_profile_backup_space_ok() {
    local total cache need avail
    total=$(du -sk "$CONFIG_DIR/home" 2>/dev/null | cut -f1)
    cache=$(du -sk "$CONFIG_DIR/home/.cache" 2>/dev/null | cut -f1)
    [[ "$cache" =~ ^[0-9]+$ ]] || cache=0
    avail=$(df -Pk "$CONFIG_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "$total" =~ ^[0-9]+$ ]] && [[ "$avail" =~ ^[0-9]+$ ]] || return 0
    need=$((total - cache))
    if [ "$avail" -lt $((need + need / 10 + 1024)) ]; then
        config_error "Not enough free space for the backup: it needs about $((need / 1024)) MB and $((avail / 1024)) MB are free under $CONFIG_DIR."
        return 1
    fi
}

# Record how to revert the layout. `--rollback` needs only this record, not the
# copies. Written last, so a backup interrupted halfway has no record and is
# never used. Usage: _profile_write_manifest <dir> <env_src|empty>
_profile_write_manifest() {
    {
        echo "layout=1"
        echo "home=$CONFIG_DIR/home"
        [ -z "$2" ] || echo "env=$2"
    } >"$1/MANIFEST"
}

# Name of a fresh private backup/record directory (unique per process, so two
# migrations in the same second never collide). Usage: _profile_new_backup_dir
_profile_new_backup_dir() {
    local bdir
    bdir="$CONFIG_DIR/backups/pre-profiles-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$CONFIG_DIR/backups" 2>/dev/null && chmod 700 "$CONFIG_DIR/backups" 2>/dev/null
    if ! { mkdir "$bdir" 2>/dev/null && chmod 700 "$bdir"; }; then
        config_error "Cannot create the backup directory $bdir"
        return 1
    fi
    printf '%s' "$bdir"
}

# Drop a partial backup and explain. Usage: _profile_backup_fail <dir> <message>
_profile_backup_fail() {
    rm -rf -- "$1"
    config_error "$2"
}

# Copy what the migration touches into backups/pre-profiles-<utc>-<pid>/ (0700):
# the home (minus the re-creatable .cache), the config and the legacy env
# file, then verify the copies. Prints the directory on success; on any
# failure it says why (stderr), removes the partial backup and has touched
# nothing else. Usage: bdir=$(_profile_migration_backup)
_profile_migration_backup() {
    local bdir env_src err
    _profile_backup_space_ok || return 1
    bdir=$(_profile_new_backup_dir) || return 1
    # Entry by entry, so the re-creatable .cache is never copied (it could be
    # large enough to fill the disk even though the space check passed).
    if ! mkdir "$bdir/home" 2>/dev/null; then
        _profile_backup_fail "$bdir" "Cannot create $bdir/home"
        return 1
    fi
    local e
    for e in "$CONFIG_DIR/home"/* "$CONFIG_DIR/home"/.[!.]* "$CONFIG_DIR/home"/..?*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        [ "${e##*/}" != .cache ] || continue
        if ! err=$(cp -a -- "$e" "$bdir/home/" 2>&1); then
            _profile_backup_fail "$bdir" "Backup failed: $(printf '%s' "$err" | head -n 1)"
            return 1
        fi
    done
    if ! diff <(_profile_top_entries "$CONFIG_DIR/home") <(_profile_top_entries "$bdir/home") >/dev/null 2>&1 ||
        [ "$(_profile_entry_count "$CONFIG_DIR/home")" != "$(_profile_entry_count "$bdir/home")" ]; then
        _profile_backup_fail "$bdir" "Backup verification failed: the copy differs from the home."
        return 1
    fi
    if [ -f "$CONFIG_FILE" ] && ! err=$(cp -a "$CONFIG_FILE" "$bdir/config" 2>&1); then
        _profile_backup_fail "$bdir" "Backup of the config failed: $(printf '%s' "$err" | head -n 1)"
        return 1
    fi
    env_src=$(_profile_legacy_env_path)
    if [ -n "$env_src" ]; then
        if ! err=$(cp -a "$env_src" "$bdir/env" 2>&1); then
            _profile_backup_fail "$bdir" "Backup of the env file failed: $(printf '%s' "$err" | head -n 1)"
            return 1
        fi
        chmod 600 "$bdir/env" 2>/dev/null || true
    fi
    if ! _profile_write_manifest "$bdir" "$env_src"; then
        _profile_backup_fail "$bdir" "Cannot write the migration record in $bdir"
        return 1
    fi
    printf '%s' "$bdir"
}

# A migration without a data copy (--no-backup) still leaves the record that
# `--rollback` needs. Usage: bdir=$(_profile_manifest_only)
_profile_manifest_only() {
    local bdir
    bdir=$(_profile_new_backup_dir) || return 1
    if ! _profile_write_manifest "$bdir" "$(_profile_legacy_env_path)"; then
        _profile_backup_fail "$bdir" "Cannot write the migration record in $bdir"
        return 1
    fi
    printf '%s' "$bdir"
}

# Remove the setting.env_file line from the global config (the secrets moved
# into the default profile). Usage: _profile_strip_legacy_env
_profile_strip_legacy_env() {
    [ -f "$CONFIG_FILE" ] || return 0
    local tmp
    tmp=$(mktemp "$CONFIG_FILE.tmp.XXXXXX" 2>/dev/null) || return 1
    grep -v '^[[:space:]]*setting\.env_file[[:space:]]*=' "$CONFIG_FILE" >"$tmp" || true
    cat "$tmp" >"$CONFIG_FILE" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
}

# --- migration lock: a directory holding the owner's pid ---------------------

# Usage: _profile_lock_dir
_profile_lock_dir() {
    printf '%s/.profiles-migrate.lock' "$CONFIG_DIR"
}

# A lock is stale when its owner is gone; with no pid recorded yet (the owner
# may sit between mkdir and writing it) only after 10 seconds.
# Usage: _profile_lock_stale
_profile_lock_stale() {
    local lock pid mtime
    lock=$(_profile_lock_dir)
    [ -d "$lock" ] || return 1
    pid=$(cat "$lock/pid" 2>/dev/null)
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill -0 "$pid" 2>/dev/null && return 1
        return 0
    fi
    mtime=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null) || return 1
    [ $(($(date +%s) - mtime)) -gt 10 ]
}

# Clear a lock found stale. The directory is moved aside first (an atomic
# rename that only one process can win), and the pid inside the moved copy
# must still be the one that was judged stale: if another process cleared and
# retook the lock in between, what was moved is its live lock and it is handed
# back instead of destroyed. Usage: _profile_lock_clear_stale
_profile_lock_clear_stale() {
    local lock seen moved
    lock=$(_profile_lock_dir)
    seen=$(cat "$lock/pid" 2>/dev/null)
    moved="$lock.stale.$$"
    mv -- "$lock" "$moved" 2>/dev/null || return 0 # somebody else cleared or retook it
    if [ "$(cat "$moved/pid" 2>/dev/null)" = "$seen" ]; then
        rm -rf -- "$moved"
    else
        mv -- "$moved" "$lock" 2>/dev/null || rm -rf -- "$moved"
    fi
    return 0
}

# Take the lock, waiting for a live holder (migrating a big home takes a
# while) and clearing a stale one. Usage: _profile_lock_acquire
_profile_lock_acquire() {
    local lock waited=0
    lock=$(_profile_lock_dir)
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    until mkdir "$lock" 2>/dev/null; do
        if _profile_lock_stale; then
            _profile_lock_clear_stale
            continue
        fi
        waited=$((waited + 1))
        if [ "$waited" -gt 1200 ]; then
            config_error "Another migration has held $lock for 10 minutes; remove it if you are sure no claude-dockerized process is migrating."
            return 1
        fi
        sleep 0.5
    done
    printf '%s\n' "$$" >"$lock/pid"
}

# Release the lock, but only if it is still ours (the pid inside is this
# process): never remove somebody else's. Usage: _profile_lock_release
_profile_lock_release() {
    local lock
    lock=$(_profile_lock_dir)
    [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -rf -- "$lock"
}

# Block while another process is migrating, so nobody runs on a half-moved
# layout; a stale lock is cleared. Usage: _profile_wait_migration_lock
_profile_wait_migration_lock() {
    local lock waited=0
    lock=$(_profile_lock_dir)
    while [ -d "$lock" ]; do
        if _profile_lock_stale; then
            _profile_lock_clear_stale
            return 0
        fi
        waited=$((waited + 1))
        if [ "$waited" -gt 1200 ]; then
            config_error "Another migration has held $lock for 10 minutes; remove it if you are sure no claude-dockerized process is migrating."
            return 1
        fi
        sleep 0.5
    done
}

# The steps that run under the lock. Every failure is explicit and leaves the
# old layout as it was (the caller releases the lock whatever happens, so this
# must not rely on `set -e`). Usage: _profile_migrate_locked <backup:true|false>
_profile_migrate_locked() {
    local backup="$1" bdir env_src env_dst legacy_home env_moved=false
    profile_migration_needed || return 0 # another process finished it meanwhile
    if [ "$backup" = true ]; then
        if ! bdir=$(_profile_migration_backup); then
            config_error "Nothing was changed. Fix the cause above and retry; without room for a backup you can run (not recommended): claude-dockerized profile migrate --no-backup"
            return 1
        fi
    else
        config_warning "Migrating without a backup copy: only the record that --rollback needs is kept."
        if ! bdir=$(_profile_manifest_only); then
            config_error "Nothing was changed."
            return 1
        fi
    fi
    profile_dir_init default || {
        config_error "Cannot create $PROFILES_DIR/default; nothing was changed (backup: $bdir)."
        return 1
    }
    env_src=$(_profile_legacy_env_path)
    env_dst="$PROFILES_DIR/default/env"
    legacy_home=$(canonical_host_path "$CONFIG_DIR/home")
    # The env file moves first and out of any path the home covers: the home is
    # mounted into sessions, the env file never must be.
    if [ -n "$env_src" ]; then
        if [ -e "$env_dst" ]; then
            if path_within "$env_src" "$legacy_home"; then
                config_error "$env_dst already exists and the legacy env file ($env_src) is inside the home; merge them by hand, then retry. Nothing was changed (backup: $bdir)."
                rmdir "$PROFILES_DIR/default" 2>/dev/null
                return 1
            fi
            config_warning "$env_dst already exists: the legacy env file ($env_src) is left where it is and setting.env_file stays in the config until you merge them by hand."
            env_src=""
        elif mv -- "$env_src" "$env_dst" && chmod 600 "$env_dst"; then
            env_moved=true
        else
            [ ! -e "$env_dst" ] || [ -e "$env_src" ] || mv -- "$env_dst" "$env_src"
            rmdir "$PROFILES_DIR/default" 2>/dev/null
            config_error "Could not move the env file ($env_src); nothing was changed (backup: $bdir)."
            return 1
        fi
    fi
    if ! mv -- "$CONFIG_DIR/home" "$PROFILES_DIR/default/home"; then
        [ "$env_moved" != true ] || mv -- "$env_dst" "$env_src"
        rmdir "$PROFILES_DIR/default" 2>/dev/null
        config_error "Could not move the home; nothing was changed (backup: $bdir)."
        return 1
    fi
    if [ "$env_moved" = true ] && ! _profile_strip_legacy_env; then
        config_warning "Could not drop setting.env_file from $CONFIG_FILE; remove that line by hand."
    fi
    if [ "$backup" = true ]; then
        config_info "Migrated the existing account to profile 'default' (backup: $bdir)"
    else
        config_info "Migrated the existing account to profile 'default' (no data backup; rollback record: $bdir)"
    fi
    return 0
}

# Move the single-account layout into profiles/default, backup first.
# --dry-run only prints the plan; --quiet prints one line (the automatic run);
# --no-backup (manual runs only, e.g. when the disk is too full) skips the
# data copy but still records how to revert.
# Usage: profile_migrate_legacy [--dry-run] [--quiet] [--no-backup]
profile_migrate_legacy() {
    local dry=false quiet=false backup=true arg
    for arg in "$@"; do
        case "$arg" in
        --dry-run) dry=true ;;
        --quiet) quiet=true ;;
        --no-backup) backup=false ;;
        esac
    done
    if [ "$CCODE_HOME_PINNED" = true ]; then
        config_error "CCODE_HOME is set in the environment and pins the state root; nothing to migrate."
        return 1
    fi
    if ! profile_migration_needed; then
        [ "$quiet" = true ] || config_info "Nothing to migrate: the default profile already follows the profile layout."
        return 0
    fi
    if [ -L "$CONFIG_DIR/home" ]; then
        config_error "$CONFIG_DIR/home is a symlink; move its target into $PROFILES_DIR/default/home by hand."
        return 1
    fi
    if [ "$dry" = true ]; then
        local env_src
        env_src=$(_profile_legacy_env_path)
        config_info "Would back up $CONFIG_DIR/home (minus .cache), the config and the env file to $CONFIG_DIR/backups/pre-profiles-<time>/"
        config_info "Would move $CONFIG_DIR/home -> $PROFILES_DIR/default/home"
        [ -z "$env_src" ] || config_info "Would move $env_src -> $PROFILES_DIR/default/env and drop setting.env_file from the config"
        return 0
    fi

    # One migrator at a time; the lock is released on every path (the steps
    # run in a function called with `||`, so no failure skips the release).
    local rc=0
    _profile_lock_acquire || return 1
    _profile_migrate_locked "$backup" || rc=$?
    _profile_lock_release
    return "$rc"
}

# Run the migration on first use, without prompts. Usage: profile_migrate_legacy_auto
profile_migrate_legacy_auto() {
    _profile_wait_migration_lock || return 1
    profile_migration_needed || return 0
    profile_migrate_legacy --quiet
}

# Directories of the migration backups/records, oldest first. Usage: profile_backup_dirs
profile_backup_dirs() {
    find "$CONFIG_DIR/backups" -maxdepth 1 -type d -name 'pre-profiles-*' 2>/dev/null | sort
}

# The newest backup that carries a complete record (a backup interrupted
# halfway has none). Usage: profile_manifest_backup
profile_manifest_backup() {
    local d last=""
    while IFS= read -r d; do
        [ ! -f "$d/MANIFEST" ] || last="$d"
    done < <(profile_backup_dirs)
    printf '%s' "$last"
}

# Delete the migration backups and records: they keep the credentials,
# sessions and env file as they were before the migration.
# Usage: profile_prune_backups <yes:true|false>
profile_prune_backups() {
    local yes="$1" list dir
    list=$(profile_backup_dirs)
    if [ -z "$list" ]; then
        config_info "No migration backups to remove."
        return 0
    fi
    printf '%s\n' "$list" | sed 's/^/  /'
    config_warning "These backups hold the credentials, sessions and env file as they were before the migration; removing them also removes the rollback."
    [ "$yes" = true ] || _profile_confirm prune "remove the migration backups" || return 1
    while IFS= read -r dir; do
        [ -n "$dir" ] && rm -rf -- "$dir"
    done <<<"$list"
    rmdir "$CONFIG_DIR/backups" 2>/dev/null
    config_success "Removed the migration backups."
}

# After a logout or delete: say that old backups still hold the token.
# Usage: profile_warn_backups
profile_warn_backups() {
    [ -n "$(profile_backup_dirs)" ] || return 0
    config_warning "Migration backups in $CONFIG_DIR/backups still hold the credentials from before the migration; remove them with: claude-dockerized profile migrate --prune-backups"
}

# Can the profile layout be reverted right now? Shared by `--rollback` and by
# the wrapper rollback's precheck, so both agree. Explains (stderr) and returns
# 1 when not; on success PROFILE_ROLLBACK_BACKUP names the record to use.
# Usage: profile_rollback_check
profile_rollback_check() {
    PROFILE_ROLLBACK_BACKUP=""
    if [ "$CCODE_HOME_PINNED" = true ]; then
        config_error "CCODE_HOME is set in the environment; nothing to roll back."
        return 1
    fi
    local bdir others
    bdir=$(profile_manifest_backup)
    if [ -z "$bdir" ]; then
        config_error "No migration record found under $CONFIG_DIR/backups (every migration writes one; --prune-backups removes them)."
        return 1
    fi
    if [ -e "$CONFIG_DIR/home" ]; then
        config_error "$CONFIG_DIR/home already exists; resolve it by hand (is the old layout still in use?)."
        return 1
    fi
    if [ ! -d "$PROFILES_DIR/default/home" ]; then
        config_error "The default profile has no home ($PROFILES_DIR/default/home) to move back."
        return 1
    fi
    others=$(profile_names | grep -vx default | paste -sd' ' -)
    if [ -n "$others" ]; then
        config_error "Other profiles exist ($others); delete them first (profile delete NAME) or keep the profile layout."
        return 1
    fi
    PROFILE_ROLLBACK_BACKUP="$bdir"
}

# Undo the migration (for going back to a wrapper version that predates
# profiles): move the live default home and env back to where the old layout
# keeps them. The current config is kept: only its setting.env_file line is
# restored and setting.profile dropped, so edits made since the migration
# survive. Files the old layout cannot use (an overlay or an env file created
# since) are left in place with a warning, never deleted or overwritten.
# Usage: profile_migrate_rollback
profile_migrate_rollback() {
    profile_rollback_check || return 1
    local bdir="$PROFILE_ROLLBACK_BACKUP" env_dst
    env_dst=$(sed -n 's/^env=//p' "$bdir/MANIFEST")
    if ! mv -- "$PROFILES_DIR/default/home" "$CONFIG_DIR/home"; then
        config_error "Could not move the home back; nothing was changed."
        return 1
    fi
    if [ -f "$PROFILES_DIR/default/env" ]; then
        if [ -n "$env_dst" ] && [ ! -e "$env_dst" ] && mv -- "$PROFILES_DIR/default/env" "$env_dst"; then
            chmod 600 "$env_dst" 2>/dev/null || true
            profile_file_set "$CONFIG_FILE" setting.env_file "$env_dst"
        else
            config_warning "$PROFILES_DIR/default/env was left in place: the old layout has no per-profile secrets (copy the keys you need into a file and point setting.env_file at it)."
        fi
    fi
    profile_file_unset "$CONFIG_FILE" setting.profile
    if [ -s "$PROFILES_DIR/default/config" ]; then
        config_warning "The default profile's overlay stays in $PROFILES_DIR/default/config; the old layout ignores it."
    else
        rm -f "$PROFILES_DIR/default/config"
    fi
    rm -f "$PROFILES_DIR/default/.last-used"
    rmdir "$PROFILES_DIR/default" "$PROFILES_DIR" 2>/dev/null
    config_success "Restored the single-account layout (record kept at $bdir)."
    return 0
}

# Before a wrapper rollback (`rollback`): a target that predates profiles
# would not find the account (it looks in $CONFIG_DIR/home and would start
# from an empty one). Runs the same check `--rollback` will run, before the
# checkout is touched, and flags the layout to be reverted right after it.
# Sets PROFILE_ROLLBACK_LAYOUT. Usage: profile_rollback_precheck
profile_rollback_precheck() {
    PROFILE_ROLLBACK_LAYOUT=false
    [ "$CCODE_HOME_PINNED" = false ] && [ -d "$PROFILES_DIR/default/home" ] || return 0
    local target
    target=$(head -n 1 "$UPDATE_STATE_DIR/last-good" 2>/dev/null)
    [ -n "$target" ] || return 0
    if _update_git cat-file -e "$target:lib/profile-lib.sh" 2>/dev/null; then
        return 0
    fi
    if ! profile_rollback_check; then
        config_error "The rollback target predates account profiles, so the account layout has to be reverted first, and it cannot be (see above). Nothing was changed."
        return 1
    fi
    # shellcheck disable=SC2034 # read by rollback_update
    PROFILE_ROLLBACK_LAYOUT=true
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
