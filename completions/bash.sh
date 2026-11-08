#!/bin/bash

# Bash completion for claude-dockerized
# Source this file in your ~/.bashrc or install system-wide

_claude_dockerized() {
    local cur prev opts cmd
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmd="${COMP_WORDS[1]:-}"
    opts="run auth models exec mcp plugin profile profiles stats debug doctor install upgrade build update rollback version config clean uninstall help --help -h --version -V --no-color"

    # First word: the command.
    if [ "$COMP_CWORD" -eq 1 ]; then
        mapfile -t COMPREPLY < <(compgen -W "${opts}" -- "${cur}")
        return 0
    fi

    # Profile names come from the profiles directory (no wrapper call).
    local pdir="${CONFIG_DIR:-$HOME/.config/claude-dockerized}/profiles" pnames
    pnames="default"
    local pd
    for pd in "$pdir"/*/; do
        [ -d "$pd" ] || continue
        pd="${pd%/}"
        pd="${pd##*/}"
        # real profile names only (default is already listed)
        [[ "$pd" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] && [ "$pd" != default ] || continue
        pnames="$pnames $pd"
    done

    # Flags that take a value.
    case "${prev}" in
        -p | --profile)
            mapfile -t COMPREPLY < <(compgen -W "${pnames}" -- "${cur}")
            return 0
            ;;
        --channel)
            mapfile -t COMPREPLY < <(compgen -W "tags branch" -- "${cur}")
            return 0
            ;;
        --trust-key)
            mapfile -t COMPREPLY < <(compgen -f -- "${cur}")
            return 0
            ;;
        --claude-version)
            return 0
            ;;
        --only)
            local steps="config completions aliases global path build" prefix=""
            case "$cur" in *,*) prefix="${cur%,*}," ;; esac
            mapfile -t COMPREPLY < <(compgen -P "$prefix" -W "$steps" -- "${cur##*,}")
            return 0
            ;;
    esac

    # Later words: completed per command (flags keep completing after the first).
    case "${cmd}" in
        run)
            if [ "$COMP_CWORD" -eq 2 ]; then
                mapfile -t COMPREPLY < <(compgen -d -- "${cur}")
            else
                mapfile -t COMPREPLY < <(compgen -W "--profile -p" -- "${cur}")
            fi
            ;;
        profile)
            if [ "$COMP_CWORD" -eq 2 ]; then
                mapfile -t COMPREPLY < <(compgen -W "list current show path create login logout use bind unbind edit set unset approve rename delete doctor migrate" -- "${cur}")
            else
                case "${COMP_WORDS[2]}" in
                    list) mapfile -t COMPREPLY < <(compgen -W "--json" -- "${cur}") ;;
                    delete) mapfile -t COMPREPLY < <(compgen -W "${pnames} --yes --force" -- "${cur}") ;;
                    migrate) mapfile -t COMPREPLY < <(compgen -W "--dry-run --rollback" -- "${cur}") ;;
                    create) [ "$COMP_CWORD" -gt 3 ] && mapfile -t COMPREPLY < <(compgen -W "--from --login --model --env-file --share-skills --lsp-from" -- "${cur}") ;;
                    set) [ "$COMP_CWORD" -gt 3 ] && mapfile -t COMPREPLY < <(compgen -W "--allow-loosen" -- "${cur}") ;;
                    show | path | login | logout | use | bind | unset | rename | doctor)
                        [ "$COMP_CWORD" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "${pnames}" -- "${cur}")
                        ;;
                    edit)
                        if [ "$COMP_CWORD" -eq 3 ]; then
                            mapfile -t COMPREPLY < <(compgen -W "${pnames}" -- "${cur}")
                        elif [ "$COMP_CWORD" -eq 4 ]; then
                            mapfile -t COMPREPLY < <(compgen -W "config env rules permissions allow-patterns" -- "${cur}")
                        fi
                        ;;
                    approve)
                        if [ "$COMP_CWORD" -eq 3 ]; then
                            mapfile -t COMPREPLY < <(compgen -W "${pnames}" -- "${cur}")
                        else
                            mapfile -t COMPREPLY < <(compgen -W "allow-patterns --yes" -- "${cur}")
                        fi
                        ;;
                esac
            fi
            ;;
        profiles)
            mapfile -t COMPREPLY < <(compgen -W "--json" -- "${cur}")
            ;;
        config)
            if [ "$COMP_CWORD" -eq 2 ]; then
                mapfile -t COMPREPLY < <(compgen -W "show edit path sync credentials claude" -- "${cur}")
            else
                case "${COMP_WORDS[2]}" in
                    sync) mapfile -t COMPREPLY < <(compgen -W "--check" -- "${cur}") ;;
                    claude) mapfile -t COMPREPLY < <(compgen -W "path edit policy" -- "${cur}") ;;
                    credentials) mapfile -t COMPREPLY < <(compgen -W "path" -- "${cur}") ;;
                esac
            fi
            ;;
        mcp)
            [ "$COMP_CWORD" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "list get login logout" -- "${cur}")
            ;;
        plugin)
            [ "$COMP_CWORD" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "list check" -- "${cur}")
            ;;
        debug)
            [ "$COMP_CWORD" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "paths doctor" -- "${cur}")
            ;;
        help)
            [ "$COMP_CWORD" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "${opts}" -- "${cur}")
            ;;
        upgrade | update)
            mapfile -t COMPREPLY < <(compgen -W "--check --dry-run --yes --no-build --trust-first-use --channel --claude-version --allow-unsigned --trust-key --help" -- "${cur}")
            ;;
        rollback)
            mapfile -t COMPREPLY < <(compgen -W "--yes --help" -- "${cur}")
            ;;
        build)
            mapfile -t COMPREPLY < <(compgen -W "--no-cache --pull --trust-first-use --help" -- "${cur}")
            ;;
        doctor | version)
            mapfile -t COMPREPLY < <(compgen -W "--json --help" -- "${cur}")
            ;;
        install)
            mapfile -t COMPREPLY < <(compgen -W "--yes --only --help" -- "${cur}")
            ;;
    esac
    return 0
}

complete -F _claude_dockerized claude-dockerized
complete -F _claude_dockerized ccd
