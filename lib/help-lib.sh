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

Setup and maintenance:
    install [OPTS]       First-time setup / repair: PATH, config, completions, aliases
    build [OPTS]         Build the image (--no-cache, --pull)
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
    --no-color           Plain output (also: NO_COLOR=1); CLICOLOR_FORCE=1 forces color
    -V, --version        Same as 'version'
    -h, --help           This help
    DRY_RUN=true         (env) print the docker command instead of running it

Getting started:
    1. $CCD_NAME install          # PATH, config, completions (once)
    2. $CCD_NAME build            # build the image
    3. $CCD_NAME auth             # log in
    4. $CCD_NAME run ~/src/app    # work on a project

Security: non-root container (host UID, no capabilities, no new privileges),
read-only managed policy and guard hooks, secrets only via setting.env_file,
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
Usage: $CCD_NAME run [DIR] [-- CLAUDE_ARGS...]

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
Usage: $CCD_NAME build [--no-cache] [--pull]

Build $IMAGE_NAME from the checkout. Honors setting.image_strip_setuid,
setting.image_docker_cli and a Claude Code version pinned with
'update --claude-version'. --pull refreshes the (digest-pinned) base layers.
EOF
        ;;
    update | upgrade) update_usage "$1" ;;
    rollback) echo "Usage: $CCD_NAME rollback [--yes]   (restore the checkout and image from before the last update)" ;;
    config)
        cat <<EOF
Usage: $CCD_NAME config [show|edit|path|sync [--check]|credentials path]

    show               parsed configuration
    edit               open the config in \$EDITOR (created if missing)
    path               config file path
    sync [--check]     refresh (or only verify) the security layer from the repo
    credentials path   credentials file path (values are never printed)
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
