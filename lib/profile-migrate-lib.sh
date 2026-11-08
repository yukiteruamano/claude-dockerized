#!/bin/bash
# profile-migrate-lib.sh - migration of the single-account layout
# ($CONFIG_DIR/home) into profiles/default, with a verified backup, a
# migration lock, the MANIFEST record and --rollback; backup listing and
# pruning. Sourced by lib/config-lib.sh. Not executable directly; no
# `set -e`: callers own error handling (see AGENTS.md on the lock).

# The legacy layout keeps the one account in $CONFIG_DIR/home and the secrets
# file named by setting.env_file. Needed when that home exists and the default
# profile has none yet. Usage: profile_migration_needed
profile_migration_needed() {
    [ "$CCODE_HOME_PINNED" = false ] || return 1
    [ -d "$CONFIG_DIR/home" ] || [ -L "$CONFIG_DIR/home" ] || return 1
    [ ! -e "$PROFILES_DIR/default/home" ]
}

# Legacy setting.env_file resolved to an absolute path, when it names an
# existing file (anywhere: the secrets must reach the default profile).
# Usage: _profile_legacy_env_path
_profile_legacy_env_path() {
    local v p
    v=$(config_file_value "$CONFIG_FILE" setting.env_file) || return 0
    [ -n "$v" ] || return 0
    p=$(canonical_host_path "$v")
    [ -f "$p" ] && printf '%s' "$p"
    return 0
}

# Does the legacy env file live under $CONFIG_DIR (the wrapper's own file,
# moved by the migration) rather than elsewhere (the user's file, copied and
# left in place)? Usage: _profile_legacy_env_owned <path>
_profile_legacy_env_owned() {
    path_within "$1" "$(canonical_host_path "$CONFIG_DIR")"
}

# Copy a legacy env file that lives outside $CONFIG_DIR into <dst> (0600 from
# the start); the original is the user's and stays where it is.
# Usage: _profile_copy_legacy_env <src> <dst>
_profile_copy_legacy_env() {
    if (umask 077 && cat -- "$1" >"$2") && chmod 600 "$2"; then
        return 0
    fi
    rm -f -- "$2"
    return 1
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
        # A file outside $CONFIG_DIR is copied, not moved (see _profile_migrate_env).
        [ -z "$2" ] || _profile_legacy_env_owned "$2" || echo "env_mode=copy"
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
    local backup="$1" bdir env_src env_dst legacy_home env_moved=false env_copied=false
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
    # mounted into sessions, the env file never must be. One outside
    # $CONFIG_DIR is the user's own file: it is copied and stays in place.
    if [ -n "$env_src" ]; then
        if [ -e "$env_dst" ]; then
            if path_within "$env_src" "$legacy_home"; then
                config_error "$env_dst already exists and the legacy env file ($env_src) is inside the home; merge them by hand, then retry. Nothing was changed (backup: $bdir)."
                rmdir "$PROFILES_DIR/default" 2>/dev/null
                return 1
            fi
            config_warning "$env_dst already exists: the legacy env file ($env_src) is left where it is and setting.env_file stays in the config until you merge them by hand."
            env_src=""
        elif ! _profile_legacy_env_owned "$env_src"; then
            if ! _profile_copy_legacy_env "$env_src" "$env_dst"; then
                rmdir "$PROFILES_DIR/default" 2>/dev/null
                config_error "Could not copy the env file ($env_src); nothing was changed (backup: $bdir)."
                return 1
            fi
            env_copied=true
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
        [ "$env_copied" != true ] || rm -f -- "$env_dst"
        rmdir "$PROFILES_DIR/default" 2>/dev/null
        config_error "Could not move the home; nothing was changed (backup: $bdir)."
        return 1
    fi
    if { [ "$env_moved" = true ] || [ "$env_copied" = true ]; } && ! _profile_strip_legacy_env; then
        config_warning "Could not drop setting.env_file from $CONFIG_FILE; remove that line by hand."
    fi
    if [ "$env_copied" = true ]; then
        config_info "Copied the secrets of $env_src into $env_dst (mode 600); the original file remains where it was: delete it yourself once you no longer need it."
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
        if [ -n "$env_src" ] && _profile_legacy_env_owned "$env_src"; then
            config_info "Would move $env_src -> $PROFILES_DIR/default/env and drop setting.env_file from the config"
        elif [ -n "$env_src" ]; then
            config_info "Would copy $env_src -> $PROFILES_DIR/default/env (the original stays) and drop setting.env_file from the config"
        fi
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
    # A copied env file (the original stayed in place): point the config back
    # at the original, and drop the copy only while it is still identical.
    if grep -qx 'env_mode=copy' "$bdir/MANIFEST" && [ -n "$env_dst" ] && [ -f "$env_dst" ]; then
        profile_file_set "$CONFIG_FILE" setting.env_file "$env_dst"
        if cmp -s -- "$env_dst" "$PROFILES_DIR/default/env"; then
            rm -f -- "$PROFILES_DIR/default/env"
        fi
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
