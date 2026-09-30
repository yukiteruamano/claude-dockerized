#!/bin/bash
# Run every test suite: Node (tests/*.test.mjs) and Bash (tests/*.test.sh).
# The Docker integration suite runs with --integration (it skips by itself
# when no daemon is reachable). Exits non-zero when any suite fails.
#
# Usage: bash tests/run-all.sh [--integration] [--verbose]
#   --verbose  also list every known gap (GUARD_TEST_VERBOSE=1)
set -e

TESTS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

integration=false
for arg in "$@"; do
    case "$arg" in
    --integration) integration=true ;;
    --verbose) export GUARD_TEST_VERBOSE=1 ;;
    -h | --help)
        sed -n '2,8p' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    *)
        echo "Unknown option: $arg" >&2
        exit 1
        ;;
    esac
done

suites=()
for f in "$TESTS_DIR"/*.test.mjs "$TESTS_DIR"/*.test.sh; do
    [ -f "$f" ] && suites+=("$f")
done
[ "$integration" = true ] && suites+=("$TESTS_DIR/integration/container.test.sh")

failed=()
for suite in "${suites[@]}"; do
    name="${suite#"$TESTS_DIR"/}"
    printf '==> %s\n' "$name"
    case "$suite" in
    *.mjs) runner=(node "$suite") ;;
    *) runner=(bash "$suite") ;;
    esac
    if ! "${runner[@]}"; then
        failed+=("$name")
    fi
done

echo
if [ "${#failed[@]}" -gt 0 ]; then
    printf 'FAILED suites (%d/%d):\n' "${#failed[@]}" "${#suites[@]}"
    printf '  %s\n' "${failed[@]}"
    exit 1
fi
printf 'All %d suites passed.\n' "${#suites[@]}"
