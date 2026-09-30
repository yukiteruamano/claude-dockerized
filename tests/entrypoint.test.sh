#!/bin/bash
# entrypoint.sh PATH contract (T-04): the session-writable ~/.local/bin is
# always LAST on PATH (it can never shadow claude/node/git/jq from the image),
# appears exactly once, and never leaves an empty entry (= current directory).
# The PATH block is extracted from entrypoint.sh and evaluated in isolation,
# since the full entrypoint needs the image (NVM).
#
# Usage: bash tests/entrypoint.test.sh
# shellcheck disable=SC2317  # helpers run via check

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="entrypoint"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

block="$(sed -n '/^user_bin=/,/^export PATH=.*user_bin"$/p' "$REPO_DIR/entrypoint.sh")"
check "PATH block found in entrypoint.sh" [ -n "$block" ]

path_after() {
    (
        PATH="$1"
        eval "$block"
        printf '%s' "$PATH"
    )
}

U=/home/coder/.local/bin
assert_eq "$(path_after "$U:/usr/local/bin:/usr/bin")" "/usr/local/bin:/usr/bin:$U" "user bin moved last"
assert_eq "$(path_after "/usr/bin:$U:$U:/bin")" "/usr/bin:/bin:$U" "duplicates collapse to one, last"
assert_eq "$(path_after "/usr/bin:/bin")" "/usr/bin:/bin:$U" "user bin appended when absent"
assert_eq "$(path_after "$U")" "$U" "no empty entry when it is the only one"
no_empty_entry() { [[ ":$(path_after "$1"):" != *::* ]]; }
check "no empty PATH entry (1)" no_empty_entry "$U:/usr/bin"
check "no empty PATH entry (2)" no_empty_entry "$U"

t_summary
