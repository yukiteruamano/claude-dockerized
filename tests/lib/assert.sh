#!/bin/bash
# assert.sh - tiny assertion helpers for the Bash test suites. Sourced, never
# executed. Failures are counted (not fatal) so one broken case never hides
# the rest; t_summary prints the tally and sets the exit status.
#
# Known gaps: `gap <threat> <description> <cmd...>` runs a check that must
# still FAIL (a documented weakness, see docs/security/THREAT-MODEL.md). When
# the fix lands the check passes and the suite goes red until the call is
# turned into a regular `check`.

T_PASS=0
T_FAIL=0
T_GAPS=0
T_SUITE="${T_SUITE:-$(basename "${BASH_SOURCE[1]:-test}")}"

t_fail() {
    T_FAIL=$((T_FAIL + 1))
    printf 'FAIL: %s\n' "$*"
}

t_pass() {
    T_PASS=$((T_PASS + 1))
}

# check <description> <cmd...> — passes when the command succeeds.
check() {
    local desc="$1"
    shift
    if "$@"; then t_pass; else t_fail "$desc"; fi
}

# check_not <description> <cmd...> — passes when the command fails.
check_not() {
    local desc="$1"
    shift
    if "$@"; then t_fail "$desc"; else t_pass; fi
}

# gap <threat-id> <description> <cmd...> — documented weakness (see header).
gap() {
    local threat="$1" desc="$2"
    shift 2
    if "$@"; then
        t_fail "XPASS $threat $desc: the gap is fixed, turn this gap into a check"
    else
        T_GAPS=$((T_GAPS + 1))
        [ -n "${GUARD_TEST_VERBOSE:-}" ] && printf 'XFAIL %s %s\n' "$threat" "$desc"
    fi
    return 0
}

# assert_eq <got> <want> <description>
assert_eq() {
    if [ "$1" = "$2" ]; then t_pass; else t_fail "$3: got '$1', want '$2'"; fi
}

# has_line <exact-line> <text> — exact whole-line match (fixed string).
has_line() {
    grep -qxF -- "$1" <<<"$2"
}

# has_text <substring> <text> — fixed-string substring match.
has_text() {
    grep -qF -- "$1" <<<"$2"
}

# rc_of <cmd...> — prints the exit status of the command (stdout/stderr dropped).
rc_of() {
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# t_tmpdir — private temp dir under $TMPDIR (removed by the caller's trap).
t_tmpdir() {
    local base="${TMPDIR:-/tmp}"
    mkdir -p "$base" 2>/dev/null || base=/tmp
    mktemp -d -p "$base"
}

t_summary() {
    printf '%s: %d passed, %d failed, %d known gap(s)\n' "$T_SUITE" "$T_PASS" "$T_FAIL" "$T_GAPS"
    [ "$T_FAIL" -eq 0 ]
}

# lacks_text <substring> <text> — the substring is absent.
lacks_text() {
    ! has_text "$1" "$2"
}
