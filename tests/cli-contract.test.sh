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

# Commands dispatched by main(): the case labels between `case "$command"` and
# its esac, minus the help aliases and the catch-all.
dispatched="$(
    awk '/^main\(\) \{/ {in_main=1} in_main && /case "\$command" in/ {in_case=1; next}
         in_case && /^    esac/ {exit}
         in_case && /^    [a-z|* -]+\)$/ {print}' "$BIN" |
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
    if [ "$cmd" = uninstall ]; then
        gap UX-08 "'$cmd' documented in help" in_help "$cmd"
        gap UX-08 "'$cmd' in bash completion" in_list "$cmd" "$bash_opts"
        gap UX-08 "'$cmd' in zsh completion" in_list "$cmd" "$zsh_cmds"
        continue
    fi
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

t_summary
