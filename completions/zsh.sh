#compdef claude-dockerized
# shellcheck shell=bash disable=SC2034,SC2154,SC1087,SC2016

# Zsh completion for claude-dockerized
# Source this file in your ~/.zshrc or place in /usr/local/share/zsh/site-functions/

_claude_dockerized() {
    local -a commands
    commands=(
        'run:Run Claude Code on a project (ARGS after -- go to claude)'
        'exec:Run a non-interactive prompt (claude -p)'
        'auth:Log in (claude auth login)'
        'mcp:MCP servers (list|get|login|logout)'
        'plugin:Plugins (list|check)'
        'models:Show the default model'
        'install:First-time setup / repair PATH, config, completions, aliases'
        'build:Build the image'
        'update:Verified self-update (signed release, preview, sync, rebuild)'
        'upgrade:Alias of update'
        'rollback:Undo the last update (checkout + previous image)'
        'config:Wrapper config (show|edit|path|sync|credentials)'
        'clean:Remove the image'
        'uninstall:Show how to uninstall'
        'doctor:Check host, image, security layer and container'
        'version:Wrapper, guard, policy and Claude Code versions'
        'stats:Local session-storage statistics'
        'debug:Debugging helpers (paths|doctor)'
        'help:Show help (help COMMAND for details)'
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
                    _arguments '1:project directory:_files -/' '*::claude arguments:'
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
                help)
                    _describe -t commands 'command' commands
                    ;;
                config)
                    if (( CURRENT == 2 )); then
                        local -a config_cmds
                        config_cmds=(
                            'show:Show current configuration'
                            'edit:Edit wrapper config file in $EDITOR'
                            'path:Print wrapper config file path'
                            'sync:Refresh security layer from repo (--check for drift only)'
                            'claude:User Claude settings (path|edit) / managed policy path'
                            'credentials:Credentials file path (path only)'
                        )
                        _describe -t config_cmds 'config subcommand' config_cmds
                    else
                        case $words[2] in
                            sync) _values 'sync flag' --check ;;
                            claude) _values 'claude subcommand' path edit policy ;;
                            credentials) _values 'credentials subcommand' path ;;
                        esac
                    fi
                    ;;
                upgrade|update)
                    _arguments \
                        '--check[only report: 0 up to date, 100 update available]' \
                        '--dry-run[verify and preview, change nothing]' \
                        '--yes[apply without confirmation]' \
                        '--no-build[skip the image rebuild]' \
                        '--channel[release channel]:channel:(tags branch)' \
                        '--claude-version[pin a Claude Code release]:version (X.Y.Z):' \
                        '--allow-unsigned[accept unverified code (interactive)]' \
                        '--trust-key[pin a release-signing key]:key file:_files' \
                        '--help[show help]'
                    ;;
                rollback)
                    _values 'rollback flag' --yes --help
                    ;;
                build)
                    _values 'build flag' --no-cache --pull --help
                    ;;
                doctor|version)
                    _values 'output flag' --json --help
                    ;;
                install)
                    _arguments \
                        '--yes[non-interactive full setup]' \
                        '--only[setup steps]:steps:_values -s , step config completions aliases global path build'
                    ;;
            esac
            ;;
    esac
}

# compdef exists only after compinit; registering earlier must not error.
if (( $+functions[compdef] )); then
    compdef _claude_dockerized claude-dockerized
    compdef _claude_dockerized ccd
fi
