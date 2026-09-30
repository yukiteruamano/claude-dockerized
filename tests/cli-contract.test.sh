#!/bin/bash
# CLI surface contract: every command dispatched by main() in
# bin/claude-dockerized is documented in `help` and offered by both shell
# completions, and nothing is advertised that main() does not handle.
#
# Usage: bash tests/cli-contract.test.sh
# shellcheck disable=SC2317  # helpers run via check/gap

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="cli-contract"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

BIN="$REPO_DIR/bin/claude-dockerized"

# Commands dispatched by main(): the labels of its LAST `case "$command" in`
# block (the dispatcher; an earlier one only routes --help), minus the help
# aliases and the catch-all.
dispatched="$(
    awk '/^main\(\) \{/ {in_main=1}
         in_main && /case "\$command" in/ {in_case=1; delete labels; n=0; next}
         in_case && /^    esac/ {in_case=0; next}
         in_case && /^    [a-z|* -]+\)$/ {labels[n++]=$0}
         in_main && /^\}/ {for (i = 0; i < n; i++) print labels[i]; exit}' "$BIN" |
        tr -d ' )' | tr '|' '\n' | grep -vE '^(\*|--help|-h)$' | sort -u
)"
check "main() dispatches commands" [ -n "$dispatched" ]

help_text="$(NO_COLOR=1 bash "$BIN" help 2>/dev/null)"
bash_opts="$(sed -n 's/^[[:space:]]*opts="\(.*\)"$/\1/p' "$REPO_DIR/completions/bash.sh" | tr ' ' '\n' | grep -v '^-' | sort -u)"
zsh_cmds="$(sed -n '/^[[:space:]]*commands=(/,/^[[:space:]]*)/p' "$REPO_DIR/completions/zsh.sh" | sed -n "s/^[[:space:]]*'\([a-z-]*\):.*/\1/p" | sort -u)"

in_help() { grep -qE "^[[:space:]]+$1([[:space:]]|$)" <<<"$help_text"; }
in_list() { grep -qxF -- "$1" <<<"$2"; }

while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    check "'$cmd' documented in help" in_help "$cmd"
    check "'$cmd' in bash completion" in_list "$cmd" "$bash_opts"
    check "'$cmd' in zsh completion" in_list "$cmd" "$zsh_cmds"
done <<<"$dispatched"

# Nothing advertised that main() would reject.
while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    check "bash completion '$cmd' is dispatched" in_list "$cmd" "$dispatched"
done <<<"$bash_opts"
while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    check "zsh completion '$cmd' is dispatched" in_list "$cmd" "$dispatched"
done <<<"$zsh_cmds"

# Both completion scripts parse.
check "bash completion syntax" bash -n "$REPO_DIR/completions/bash.sh"
check "zsh completion parses (bash -n, as in CI)" bash -n "$REPO_DIR/completions/zsh.sh"
check "zsh completion guards compdef (no error before compinit)" grep -q 'functions\[compdef\]' "$REPO_DIR/completions/zsh.sh"

# Every dispatched command has its own help page.
while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    has_command_help() { NO_COLOR=1 bash "$BIN" help "$1" >/dev/null 2>&1; }
    check "'$cmd' has a help page" has_command_help "$cmd"
done <<<"$dispatched"
check_not "help never prints the install path" has_text "$REPO_DIR/bin" "$help_text"

t_summary
