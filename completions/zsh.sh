#compdef claude-dockerized
# shellcheck shell=bash disable=SC2034,SC2154,SC1087,SC2016

# Zsh completion for claude-dockerized
# Source this file in your ~/.zshrc or place in /usr/local/share/zsh/site-functions/

_claude_dockerized() {
    local -a commands
    commands=(
        'run:Run Claude Code in Docker (default: current directory)'
        'auth:Run Claude Code authentication (claude auth login)'
        'models:Show the effective default model'
        'exec:Run a non-interactive prompt (claude -p)'
        'mcp:Manage MCP servers'
        'plugin:Manage plugins'
        'stats:Show local session-storage statistics'
        'debug:Debugging helpers'
        'doctor:Diagnose install, guard, SSH/GPG, settings, LSP and env file'
        'install:First-time install / repair PATH, config, completions, aliases'
        'upgrade:Alias of update'
        'build:Build the Docker image'
        'update:Verified self-update (signed release, preview, sync, rebuild)'
        'rollback:Undo the last update (checkout + previous image)'
        'version:Show Claude Code version in the container'
        'config:Show, edit, or print config file path'
        'clean:Remove the Docker image'
        'help:Show help message'
    )

    _arguments -C \
        '1: :->cmds' \
        '*:: :->args'

    case $state in
        cmds)
            _describe -t commands 'claude-dockerized command' commands
            ;;
        args)
            case $words[1] in
                run)
                    _files -/
                    ;;
                mcp)
                    _values 'mcp subcommand' list get login logout
                    ;;
                plugin)
                    _values 'plugin subcommand' list check
                    ;;
                debug)
                    _values 'debug subcommand' paths doctor
                    ;;
                config)
                    local -a config_cmds
                    config_cmds=(
                        'show:Show current configuration'
                        'edit:Edit wrapper config file in $EDITOR'
                        'path:Print wrapper config file path'
                        'sync:Refresh security layer from repo (--check for drift only)'
                        'claude:Claude settings (path|edit|policy)'
                        'credentials:Credentials file path (path only)'
                    )
                    _describe -t config_cmds 'config subcommand' config_cmds
                    ;;
                upgrade|update)
                    _values 'self-update flag' --check --yes --no-build --claude-version
                    ;;
                install)
                    _values 'install flag' --yes --only
                    ;;
            esac
            ;;
    esac
}

compdef _claude_dockerized claude-dockerized
compdef _claude_dockerized ccd
