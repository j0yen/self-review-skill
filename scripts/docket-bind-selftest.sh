#!/usr/bin/env bash
# docket-bind-selftest.sh — AC6 dry-run walkthrough for docket-self-review-bind.
#
# Exercises the bind contract end-to-end against the real docket binary using an
# isolated temporary database (via XDG_DATA_HOME override) so it does not pollute
# the live ledger.
#
# Expected outcome:
#   - After r1+r2+r3, agorabus-stale-binary is ESCALATED (reported every run,
#     escalate-threshold=3)
#   - A finding reported only at r1 becomes resolved(stale) after sweep at r4
#     with --stale-after 2 (the sweep counts runs recorded between last_run and
#     current_run, exclusive; r2 and r3 are between seq(r1) and seq(r4), so
#     elapsed=2 >= stale_after=2 at r4).
#
# Note on run counts: with --stale-after 2, a finding absent since r1 is NOT
# stale at r3 (elapsed=1), but IS stale at r4 (elapsed=2). This is because
# docket sweep counts only *intermediate* run ledger entries, not the current run.
#
# Usage: bash scripts/docket-bind-selftest.sh
# Exit 0 = all assertions pass. Exit 1 = failure (check stderr).

set -uo pipefail

if ! command -v docket >/dev/null 2>&1; then
    echo "SKIP: docket not on PATH (expected on this box; check install)" >&2
    exit 0
fi

# Isolated environment: override XDG_DATA_HOME so docket uses a tmp dir.
TMPDIR_TEST=$(mktemp -d /tmp/docket-selftest-XXXXXX)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export XDG_DATA_HOME="$TMPDIR_TEST"
mkdir -p "$TMPDIR_TEST/docket"

FAIL=0
assert_contains() {
    local label="$1" expected="$2" actual="$3"
    if printf '%s' "$actual" | grep -qF "$expected"; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label — expected to find: $expected" >&2
        printf '        actual output: %s\n' "$actual" >&2
        FAIL=1
    fi
}
assert_not_contains() {
    local label="$1" unexpected="$2" actual="$3"
    if printf '%s' "$actual" | grep -qF "$unexpected"; then
        echo "  FAIL: $label — should NOT contain: $unexpected" >&2
        FAIL=1
    else
        echo "  PASS: $label"
    fi
}

echo "=== docket-bind-selftest: AC6 dry-run walkthrough ==="

# --- Run r1: report all 4 seeded findings ---
echo ""
echo "--- r1: report 4 seeded findings ---"
docket report --run "test.r1" --key agorabus-stale-binary \
    --title "agorabus daemon binary is stale vs source" \
    --escalate-threshold 3 >/dev/null
docket report --run "test.r1" --key agentns-session-zeros \
    --title "agentns session counter stuck at zero" \
    --escalate-threshold 3 >/dev/null
docket report --run "test.r1" --key ctrace-sessionend-flake \
    --title "ctrace session-end event missing" \
    --escalate-threshold 3 >/dev/null
docket report --run "test.r1" --key wm-anthropic-key-empty \
    --title "WM_ANTHROPIC_KEY / API key is empty or missing" \
    --escalate-threshold 3 >/dev/null
r1_sweep=$(docket sweep --run "test.r1" --stale-after 2 2>&1)
echo "  sweep r1: $r1_sweep"

# --- Run r2: report only agorabus ---
echo ""
echo "--- r2: report agorabus only (others absent run 1) ---"
docket report --run "test.r2" --key agorabus-stale-binary \
    --title "agorabus daemon binary is stale vs source" \
    --escalate-threshold 3 >/dev/null
r2_sweep=$(docket sweep --run "test.r2" --stale-after 2 2>&1)
echo "  sweep r2: $r2_sweep"

# --- Run r3: report only agorabus ---
echo ""
echo "--- r3: report agorabus only (others absent run 2) ---"
docket report --run "test.r3" --key agorabus-stale-binary \
    --title "agorabus daemon binary is stale vs source" \
    --escalate-threshold 3 >/dev/null
r3_sweep=$(docket sweep --run "test.r3" --stale-after 2 2>&1)
echo "  sweep r3: $r3_sweep"

# After r3: agorabus should now be escalated (3 consecutive runs)
# The other 3 findings should still be open (elapsed=1 at r3, not yet stale)
echo ""
echo "--- State after r3 ---"
escalated_r3=$(docket list --escalated 2>&1)
assert_contains "agorabus-stale-binary escalated after r3" \
    "[escalated] agorabus-stale-binary" "$escalated_r3"

agentns_r3=$(docket show agentns-session-zeros 2>&1)
assert_contains "agentns-session-zeros still open after r3 (elapsed=1, not stale yet)" \
    "[open] agentns-session-zeros" "$agentns_r3"

# --- Run r4: report only agorabus (others now absent for 2 runs: elapsed >= stale_after) ---
echo ""
echo "--- r4: report agorabus only (others absent run 3, stale at elapsed=2) ---"
docket report --run "test.r4" --key agorabus-stale-binary \
    --title "agorabus daemon binary is stale vs source" \
    --escalate-threshold 3 >/dev/null
r4_sweep=$(docket sweep --run "test.r4" --stale-after 2 2>&1)
echo "  sweep r4: $r4_sweep"

# --- Final assertions ---
echo ""
echo "--- Final assertions ---"

all_out=$(docket list 2>&1)
escalated_out=$(docket list --escalated 2>&1)
agentns_out=$(docket show agentns-session-zeros 2>&1 || true)

# agorabus should be escalated (4 consecutive runs reported)
assert_contains "agorabus-stale-binary is escalated after r4" \
    "[escalated] agorabus-stale-binary" "$escalated_out"

# The 3 findings reported only at r1 should be resolved(stale) after r4 sweep
# (stale-after 2: they were absent at r2 and r3, so elapsed=2 at r4)
assert_not_contains "agentns-session-zeros not in open list after r4" \
    "[open] agentns-session-zeros" "$all_out"
assert_not_contains "ctrace-sessionend-flake not in open list after r4" \
    "[open] ctrace-sessionend-flake" "$all_out"
assert_not_contains "wm-anthropic-key-empty not in open list after r4" \
    "[open] wm-anthropic-key-empty" "$all_out"

# Verify r4 sweep reported resolutions
assert_contains "r4 sweep resolved stale findings (resolved=3)" \
    "resolved=3" "$r4_sweep"

# Verify agentns is resolved(stale)
assert_contains "agentns-session-zeros is resolved" \
    "[resolved] agentns-session-zeros" "$agentns_out"
assert_contains "agentns-session-zeros reason contains stale" \
    "stale" "$agentns_out"

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "=== ALL ASSERTIONS PASSED — AC6 VERIFIED ==="
    exit 0
else
    echo "=== SOME ASSERTIONS FAILED — see above ==="
    exit 1
fi
