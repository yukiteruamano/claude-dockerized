#!/bin/bash
# ui-lib.sh - terminal output for claude-dockerized (colors, symbols, levels).
# Sourced by lib/config-lib.sh (and through it by every script). Not
# executable directly; no `set -e`.
#
# - info/success go to stdout; warnings/errors go to stderr, so piping the
#   output of a command never mixes diagnostics into the data.
# - Color only when the target stream is a terminal, never with NO_COLOR
#   (https://no-color.org), TERM=dumb or --no-color; CLICOLOR_FORCE=1 forces
#   it (e.g. for `less -R`).
# - ASCII symbols when the locale is not UTF-8.

# Refresh the color/symbol decision (call again after changing NO_COLOR).
# Usage: ui_init
ui_init() {
    UI_COLOR=auto
    if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ]; then
        UI_COLOR=never
    elif [ -n "${CLICOLOR_FORCE:-}" ] && [ "${CLICOLOR_FORCE}" != 0 ]; then
        UI_COLOR=always
    fi
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8* | *utf8* | *UTF8* | *utf-8*)
        UI_SYM_INFO="ℹ" UI_SYM_OK="✓" UI_SYM_WARN="⚠" UI_SYM_ERR="✗"
        ;;
    *)
        UI_SYM_INFO="i" UI_SYM_OK="+" UI_SYM_WARN="!" UI_SYM_ERR="x"
        ;;
    esac
}

# Should output on file descriptor <fd> be colored? Usage: _ui_color_on <fd>
_ui_color_on() {
    case "${UI_COLOR:-auto}" in
    always) return 0 ;;
    never) return 1 ;;
    esac
    [ -t "$1" ]
}

# Usage: _ui_line <fd> <ansi-color> <symbol> <message>
_ui_line() {
    local fd="$1" color="$2" sym="$3" msg="$4"
    if _ui_color_on "$fd"; then
        printf '%s%s\033[0m %s\n' "$color" "$sym" "$msg" >&"$fd"
    else
        printf '%s %s\n' "$sym" "$msg" >&"$fd"
    fi
}

print_info() { _ui_line 1 $'\033[0;34m' "$UI_SYM_INFO" "$1"; }
print_success() { _ui_line 1 $'\033[0;32m' "$UI_SYM_OK" "$1"; }
print_warning() { _ui_line 2 $'\033[1;33m' "$UI_SYM_WARN" "$1"; }
print_error() { _ui_line 2 $'\033[0;31m' "$UI_SYM_ERR" "$1"; }

ui_init
