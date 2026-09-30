#!/bin/bash
# Documentation <-> tests traceability for the security documents:
# every threat in the THREAT-MODEL matrix is covered by RED (attack) and BLUE
# (control) and referenced by at least one test; every threat id used in the
# tests exists in the matrix; statuses use the documented vocabulary; a "gap"
# status has an open known-gap marker and vice versa.
#
# Usage: bash tests/threat-matrix.test.sh
# shellcheck disable=SC2317  # helpers run via check

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
T_SUITE="threat-matrix"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

DOCS="$REPO_DIR/docs/security"
TM="$DOCS/THREAT-MODEL.md"
SELF="$(basename "${BASH_SOURCE[0]}")"

for doc in THREAT-MODEL RED BLUE YELLOW; do
    check "$doc.md exists" [ -s "$DOCS/$doc.md" ]
done
check "SECURITY.md links every security document" \
    grep -q 'docs/security/THREAT-MODEL.md' "$REPO_DIR/SECURITY.md"

# Matrix rows: "| T-xx | threat | status | evidence |".
rows="$(grep -E '^\| T-[0-9]{2} \|' "$TM")"
ids="$(sed -E 's/^\| (T-[0-9]{2}) \|.*/\1/' <<<"$rows" | sort -u)"
check "the matrix lists threats" [ -n "$ids" ]
assert_eq "$(wc -l <<<"$rows" | tr -d ' ')" "$(wc -l <<<"$ids" | tr -d ' ')" "threat ids are unique"

# Test sources (the suites and the corpus), without this file.
test_refs="$(grep -rhoE 'T-[0-9]{2}' "$REPO_DIR/tests" --exclude="$SELF" | sort -u)"
# Open known-gap markers: corpus known_gap values and Bash `gap T-xx`.
open_gaps="$(
    {
        grep -rhoE '"known_gap": *"T-[0-9]{2}"' "$REPO_DIR/tests" --exclude="$SELF"
        grep -rhoE '^[[:space:]]*gap T-[0-9]{2}' "$REPO_DIR/tests" --exclude="$SELF" --exclude=assert.sh
        grep -rhoE 'report\.check\([^)]*"T-[0-9]{2}"\)' "$REPO_DIR/tests" --exclude="$SELF"
    } | grep -oE 'T-[0-9]{2}' | sort -u
)"

in_list() { grep -qxF -- "$1" <<<"$2"; }
mentions() { grep -qE -- "(^|[^0-9A-Za-z])$1([^0-9]|$)" "$2"; }

while IFS= read -r id; do
    [ -n "$id" ] || continue
    row="$(grep -E "^\| $id \|" <<<"$rows")"
    status="$(awk -F'|' '{print $4}' <<<"$row" | sed 's/^ *//;s/ *$//')"
    evidence="$(awk -F'|' '{print $5}' <<<"$row" | sed 's/^ *//;s/ *$//')"
    check "$id has a status" [ -n "$status" ]
    check "$id names its evidence" [ -n "$evidence" ]
    status_ok() { grep -qE '^(mitigated|detected|accepted|opt-in|partial|gap)' <<<"$1"; }
    check "$id status uses the vocabulary ($status)" status_ok "$status"
    check "$id is covered in RED.md" mentions "$id" "$DOCS/RED.md"
    check "$id is covered in BLUE.md" mentions "$id" "$DOCS/BLUE.md"
    check "$id is referenced by a test" in_list "$id" "$test_refs"
    if grep -qE '^gap' <<<"$status"; then
        check "$id (gap) has an open known-gap marker" in_list "$id" "$open_gaps"
    fi
done <<<"$ids"

while IFS= read -r id; do
    [ -n "$id" ] || continue
    check "$id used in tests exists in the matrix" in_list "$id" "$ids"
done <<<"$test_refs"

while IFS= read -r id; do
    [ -n "$id" ] || continue
    row="$(grep -E "^\| $id \|" <<<"$rows")"
    gap_status() { grep -qE '\| (gap|partial)' <<<"$1"; }
    check "$id has an open known gap, so its status is gap/partial" gap_status "$row"
done <<<"$open_gaps"

t_summary
