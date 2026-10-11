#!/bin/bash
# Run every test suite: Node (tests/*.test.mjs) and Bash (tests/*.test.sh).
# The Docker integration suite runs with --integration (it skips by itself
# when no daemon is reachable). Exits non-zero when any suite fails.
#
# A suite that skips itself (missing gpg or Docker) is counted and listed, so a
# green run never hides coverage that did not execute.
#
# Usage: bash tests/run-all.sh [--integration] [--verbose] [--no-skip]
#   --verbose  also list every known gap (GUARD_TEST_VERBOSE=1)
#   --no-skip  fail when any suite skipped itself
set -e

TESTS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

integration=false
no_skip=false
for arg in "$@"; do
    case "$arg" in
    --integration) integration=true ;;
    --verbose) export GUARD_TEST_VERBOSE=1 ;;
    --no-skip) no_skip=true ;;
    -h | --help)
        sed -n '2,12p' "${BASH_SOURCE[0]}"
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

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
failed=()
skipped=()
for suite in "${suites[@]}"; do
    name="${suite#"$TESTS_DIR"/}"
    printf '==> %s\n' "$name"
    case "$suite" in
    *.mjs) runner=(node "$suite") ;;
    *) runner=(bash "$suite") ;;
    esac
    rc=0
    "${runner[@]}" 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || failed+=("$name")
    if grep -Eq '^[A-Za-z0-9_-]+: skipped' "$out"; then
        skipped+=("$name")
    fi
done

echo
if [ "${#failed[@]}" -gt 0 ]; then
    printf 'FAILED suites (%d/%d):\n' "${#failed[@]}" "${#suites[@]}"
    printf '  %s\n' "${failed[@]}"
    exit 1
fi
if [ "${#skipped[@]}" -gt 0 ]; then
    printf 'SKIPPED suites (%d/%d), their checks did not run:\n' "${#skipped[@]}" "${#suites[@]}"
    printf '  %s\n' "${skipped[@]}"
    if [ "$no_skip" = true ]; then
        exit 1
    fi
fi
printf 'All %d suites passed (%d skipped).\n' "${#suites[@]}" "${#skipped[@]}"
