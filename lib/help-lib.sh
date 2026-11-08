#!/bin/bash
# help-lib.sh - `claude-dockerized help [COMMAND]` and `<command> --help`.
# Sourced by bin/claude-dockerized. Not executable directly; no `set -e`.
# Always prints the command name (never the install path).

CCD_NAME="claude-dockerized"

show_help() {
    cat <<EOF
Claude Code in a rootless, hardened Docker container.

Usage: $CCD_NAME [--no-color] <command> [options]
       $CCD_NAME help <command>     (or: $CCD_NAME <command> --help)

Everyday:
    run [DIR] [-- ARGS]  Run Claude Code on DIR (default: current dir); ARGS go to claude
    exec MSG [ARGS]      Non-interactive prompt (claude -p)
    auth                 Log in (claude auth login)
    mcp [ARGS]           MCP servers: list|get|login|logout (add/remove are host-only)
    plugin [ARGS]        Plugins: list|check (install/update/remove are host-only)
    models               Show the default model (/model switches per session)
    profile [SUB]        Account profiles: list|create|login|use|bind|set|delete|... (help profile)
    profiles             Alias of 'profile list' (name, login, account, model, last use)

Setup and maintenance:
    install [OPTS]       First-time setup / repair: PATH, config, completions, aliases
    build [OPTS]         Build the image (--no-cache, --pull, --trust-first-use)
    update [OPTS]        Verified self-update: signed release, preview, sync, rebuild
    upgrade [OPTS]       Alias of update
    rollback [--yes]     Undo the last update (checkout + previous image)
    config [SUB]         Wrapper config: show|edit|path|sync [--check]|credentials
    clean                Remove the image
    uninstall            Show how to uninstall

Diagnostics:
    doctor [--json]      Check host, image, security layer and container (exit 1 on failure)
    version [--json]     Wrapper, guard, policy and Claude Code versions
    stats                Local session-storage statistics
    debug [paths|doctor] Resolved paths, or the native claude doctor
    help [COMMAND]       This overview, or one command's details

Global options:
    -p, --profile NAME   Use this account profile (also: CLAUDE_DOCKERIZED_PROFILE; after 'run' or anywhere before --)
    --no-color           Plain output (also: NO_COLOR=1); CLICOLOR_FORCE=1 forces color
    -V, --version        Same as 'version'
    -h, --help           This help
    DRY_RUN=true         (env) print the docker command instead of running it

Getting started:
    1. $CCD_NAME install          # PATH, config, completions (once)
    2. $CCD_NAME build            # build the image
    3. $CCD_NAME auth             # log in (the 'default' profile)
    4. $CCD_NAME run ~/src/app    # work on a project
    More accounts: $CCD_NAME profile create work --login; $CCD_NAME run --profile work

Security: non-root container (host UID, no capabilities, no new privileges),
read-only managed policy and guard hooks, secrets only in each profile's env file,
Docker socket off by default, session integrity report after each run,
opt-in hardening profiles (setting.hardening). See SECURITY.md and
docs/security/ for the threat model and the Red/Blue/Yellow playbooks.
EOF
}

# Detailed help for one command; returns 1 for an unknown command.
# Usage: command_help <command>
command_help() {
    case "$1" in
    run)
        cat <<EOF
Usage: $CCD_NAME run [DIR] [-p|--profile NAME] [-- CLAUDE_ARGS...]

Start an interactive Claude Code session with DIR (default: the current
directory) mounted read-write. Everything after -- goes to claude, e.g.:
    $CCD_NAME run ~/src/app -- --resume
    $CCD_NAME run -- --continue

DIR must not be /, your home, an ancestor of it, ~/.ssh, ~/.gnupg, ~/.config
or the wrapper's config dir. The exit status is Claude Code's own. After the
session, changes to persistent paths (git hooks/config, ~/.local/bin,
plugins, MCP servers, ...) are reported (setting.integrity_check).
DRY_RUN=true prints the docker command instead of running it.
EOF
        ;;
    exec)
        cat <<EOF
Usage: $CCD_NAME exec MSG [CLAUDE_ARGS...]

Run one non-interactive prompt (claude -p MSG) against the current directory
and print the result, e.g.: $CCD_NAME exec "Summarize the open TODOs"
EOF
        ;;
    auth) echo "Usage: $CCD_NAME auth   (claude auth login; credentials persist in the generated home)" ;;
    mcp)
        cat <<EOF
Usage: $CCD_NAME mcp [list|get NAME|login NAME|logout NAME]

MCP servers are configured on the host (the managed config is read-only in
the container): add/remove/reset are refused here.
EOF
        ;;
    plugin) echo "Usage: $CCD_NAME plugin [list|check]   (install/update/remove are host-only)" ;;
    models) echo "Usage: $CCD_NAME models   (the default comes from setting.model; /model switches per session)" ;;
    install) echo "Usage: $CCD_NAME install [--yes] [--only config,completions,aliases,global[,path][,build]]" ;;
    build)
        cat <<EOF
Usage: $CCD_NAME build [--no-cache] [--pull] [--trust-first-use]

Build $IMAGE_NAME from the checkout. Honors setting.image_strip_setuid,
setting.image_docker_cli and a Claude Code version pinned with
'update --claude-version'. --pull refreshes the (digest-pinned) base layers.
The Claude Code binary's sha256 is recorded on the first build of a version
and enforced on later ones; with setting.require_claude_sha=true a version
with no record is refused unless --trust-first-use accepts it once.
EOF
        ;;
    update | upgrade) update_usage "$1" ;;
    rollback) echo "Usage: $CCD_NAME rollback [--yes]   (restore the checkout and image from before the last update)" ;;
    config)
        cat <<EOF
Usage: $CCD_NAME config [show|edit|path|sync [--check]|claude [path|edit|policy]|credentials path]

    show               parsed configuration
    edit               open the config in \$EDITOR (created if missing)
    path               config file path
    sync [--check]     refresh (or only verify) the security layer from the repo
    claude [path|edit|policy]
                       user settings.json (writable preferences) / managed policy path
    credentials path   credentials file path (values are never printed)
EOF
        ;;
    profile | profiles)
        cat <<EOF
Usage: $CCD_NAME profile [SUBCOMMAND]        (profiles = profile list)

Each account is a profile with its own home (login, sessions, plugins, MCP),
overlay config and env file. Only the active profile's home is mounted.
Selection: --profile NAME, then CLAUDE_DOCKERIZED_PROFILE, the project bind,
setting.profile, default.

    list [--json]               name, login, account, model, last use, size, notes
    current [--name]            active profile and why
    show [NAME]                 paths, login and the effective config
    path [NAME] [home|config|env]
    create NAME [--from SRC] [--login] [--model M] [--env-file FILE]
                [--share-skills] [--lsp-from default]
    login NAME | logout NAME [--yes]
    use NAME                    default profile (setting.profile)
    bind NAME [DIR] | unbind [DIR]   pin a project to a profile (kept outside the project)
    edit NAME [config|env|rules|permissions|allow-patterns]
                                overlay config / secrets / session rules / extra
                                deny|ask permission rules / guard allow rules in
                                \$EDITOR (rules and permissions add to the global
                                ones, never replace them)
    approve NAME allow-patterns [--yes]
                                review and approve the profile's guard allow rules
                                (pinned by sha256: editing the file voids it)
    set NAME KEY VALUE [--allow-loosen] | unset NAME KEY    (KEY: a setting or mount.<name>;
                                mount.<name> - drops that global mount for the profile)
    rename OLD NEW | delete NAME [--yes] [--force]
    doctor [NAME|--all]         permissions, login, loosened settings, security layer
    migrate [--dry-run|--no-backup|--rollback|--prune-backups [--yes]]
                                move the single-account layout (automatic, with backup);
                                the backups keep old credentials until pruned

A profile can tighten any setting freely. Loosening the global posture
(security_policy, hardening, docker_socket, ssh/gpg agents, integrity_check,
share_skills, lsp_from, a host network where the global one is bridge, a
memory/cpus limit removed, zeroed or raised, any :rw mount) needs --allow-loosen, which approves that exact value;
it is flagged in list and on every run, and an unapproved one is ignored.
Secrets live only in <config>/profiles/<name>/env; there is no global env file.
EOF
        ;;
    clean) echo "Usage: $CCD_NAME clean   (remove the image; config and sessions are kept)" ;;
    uninstall) echo "Usage: $CCD_NAME uninstall   (prints the uninstall steps; nothing is deleted)" ;;
    doctor)
        cat <<EOF
Usage: $CCD_NAME doctor [--json]

Host checks (Docker access, image, pinned vs installed Claude Code, security
layer drift, hardening profile, last integrity report) followed by the
in-container checks (guard, managed policy, SSH/GnuPG, LSP, env file).
Exit status 1 when any check fails. --json prints the host checks as JSON.
EOF
        ;;
    version) echo "Usage: $CCD_NAME version [--json]   (works without Docker; the image version needs it)" ;;
    stats) echo "Usage: $CCD_NAME stats   (local session storage; no secrets)" ;;
    debug) echo "Usage: $CCD_NAME debug [paths|doctor]   (paths: resolved locations; doctor: native claude doctor)" ;;
    help) echo "Usage: $CCD_NAME help [COMMAND]" ;;
    *) return 1 ;;
    esac
}
