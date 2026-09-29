#!/bin/bash

# Bash completion for claude-dockerized
# Source this file in your ~/.bashrc or install system-wide

_claude_dockerized() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="run auth models exec mcp plugin stats debug doctor install upgrade build update version config clean help --help -h"

    case "${prev}" in
        run)
            # Complete directory paths for run command
            mapfile -t COMPREPLY < <(compgen -d -- "${cur}")
            return 0
            ;;
        config)
            # Complete config subcommands
            mapfile -t COMPREPLY < <(compgen -W "show edit path claude credentials sync" -- "${cur}")
            return 0
            ;;
        sync)
            # Second-level flag for `config sync`
            if [ "${COMP_WORDS[1]}" = "config" ]; then
                mapfile -t COMPREPLY < <(compgen -W "--check" -- "${cur}")
                return 0
            fi
            ;;
        mcp)
            mapfile -t COMPREPLY < <(compgen -W "list get login logout" -- "${cur}")
            return 0
            ;;
        plugin)
            mapfile -t COMPREPLY < <(compgen -W "list check" -- "${cur}")
            return 0
            ;;
        debug)
            mapfile -t COMPREPLY < <(compgen -W "paths doctor" -- "${cur}")
            return 0
            ;;
        upgrade|update)
            mapfile -t COMPREPLY < <(compgen -W "--check --yes --no-build --claude-version" -- "${cur}")
            return 0
            ;;
        install)
            mapfile -t COMPREPLY < <(compgen -W "--yes --only" -- "${cur}")
            return 0
            ;;
        *)
            ;;
    esac

    mapfile -t COMPREPLY < <(compgen -W "${opts}" -- "${cur}")
    return 0
}

complete -F _claude_dockerized claude-dockerized
complete -F _claude_dockerized ccd
