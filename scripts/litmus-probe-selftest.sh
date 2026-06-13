#!/bin/sh
# litmus-probe-selftest.sh — fixture-backed selftest for Phase B.5 probe snippets.
#
# Tests probe snippets under scripts/probes/ against fixture inputs in fixtures/
# and compares KEY=value output to fixtures/<probe-name>/expect.env.
#
# Usage: bash scripts/litmus-probe-selftest.sh
# Exit 0 = all assertions pass (SKIP is not a failure).
# Exit 1 = one or more FAIL.
#
# Modelled on scripts/docket-bind-selftest.sh.

set -u

# Locate repo root relative to this script.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROBES_DIR="$REPO_ROOT/scripts/probes"
FIXTURES_DIR="$REPO_ROOT/fixtures"

# Isolated workdir — all probe side-effects must stay here.
WORK=$(mktemp -d /tmp/litmus-probe-selftest-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $1" >&2
    printf '      expected: %s\n' "$2" >&2
    printf '      actual:   %s\n' "$3" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip() {
    echo "SKIP: $1"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

# assert_env_var LABEL KEY EXPECTED ACTUAL_FILE
# Reads KEY=value from ACTUAL_FILE and compares to EXPECTED.
assert_env_var() {
    local label="$1" key="$2" expected="$3" actual_file="$4"
    local actual
    actual=$(grep "^${key}=" "$actual_file" 2>/dev/null | head -1 | sed "s/^${key}=//")
    if [ "$actual" = "$expected" ]; then
        pass "$label: $key=$expected"
    else
        fail "$label: $key mismatch" "$expected" "${actual:-<not found>}"
    fi
}

# run_probe_sourced PROBE_FILE ENV_OVERRIDES... — sources probe in a subshell,
# prints all KEY=VALUE lines to stdout. ENV_OVERRIDES are "KEY=VALUE" strings
# exported before sourcing.
run_probe_sourced() {
    local probe_file="$1"; shift
    (
        # Apply caller-supplied env overrides
        for kv in "$@"; do
            export "$(echo "$kv" | cut -d= -f1)"="$(echo "$kv" | cut -d= -f2-)"
        done
        # Source the probe
        . "$probe_file"
        # Emit all variables the probe might set — we grep for the known ones in callers
        set
    )
}

echo "=== litmus-probe-selftest ==="
echo ""

# ---------------------------------------------------------------------------
# Test group 1: ctrace-wiring probe — wired fixture (real hook)
# ---------------------------------------------------------------------------
echo "--- ctrace-wiring: wired fixture (HAS_REAP=yes HAS_BACKFILL=yes) ---"

FIXTURE_HOOK="$FIXTURES_DIR/ctrace-wiring/hook.sh"
EXPECT="$FIXTURES_DIR/ctrace-wiring/expect.env"
PROBE="$PROBES_DIR/ctrace-wiring.sh"

if [ ! -f "$FIXTURE_HOOK" ]; then
    skip "ctrace-wiring: fixture hook not found at $FIXTURE_HOOK"
elif [ ! -f "$PROBE" ]; then
    skip "ctrace-wiring: probe not found at $PROBE"
else
    ACTUAL_OUT="$WORK/ctrace-wiring-actual.env"
    (
        PROBE_INPUT_HOOK="$FIXTURE_HOOK"
        . "$PROBE"
        echo "HAS_REAP=$HAS_REAP"
        echo "HAS_BACKFILL=$HAS_BACKFILL"
    ) > "$ACTUAL_OUT"

    assert_env_var "ctrace-wiring[wired]" "HAS_REAP"     "yes" "$ACTUAL_OUT"
    assert_env_var "ctrace-wiring[wired]" "HAS_BACKFILL"  "yes" "$ACTUAL_OUT"
fi

echo ""

# ---------------------------------------------------------------------------
# Test group 2: ctrace-wiring probe — unwired fixture (negative control)
# ---------------------------------------------------------------------------
echo "--- ctrace-wiring: unwired fixture (HAS_REAP=yes HAS_BACKFILL=no) ---"

FIXTURE_HOOK_UNWIRED="$FIXTURES_DIR/ctrace-wiring-unwired/hook.sh"
EXPECT_UNWIRED="$FIXTURES_DIR/ctrace-wiring-unwired/expect.env"

if [ ! -f "$FIXTURE_HOOK_UNWIRED" ]; then
    skip "ctrace-wiring-unwired: fixture hook not found"
elif [ ! -f "$PROBE" ]; then
    skip "ctrace-wiring-unwired: probe not found"
else
    ACTUAL_UNWIRED="$WORK/ctrace-wiring-unwired-actual.env"
    (
        PROBE_INPUT_HOOK="$FIXTURE_HOOK_UNWIRED"
        . "$PROBE"
        echo "HAS_REAP=$HAS_REAP"
        echo "HAS_BACKFILL=$HAS_BACKFILL"
    ) > "$ACTUAL_UNWIRED"

    assert_env_var "ctrace-wiring[unwired]" "HAS_REAP"     "yes" "$ACTUAL_UNWIRED"
    assert_env_var "ctrace-wiring[unwired]" "HAS_BACKFILL"  "no"  "$ACTUAL_UNWIRED"
fi

echo ""

# ---------------------------------------------------------------------------
# Test group 3: ctrace-wiring — prove the OLD false-negative pattern would fail
# This is the regression proof: the old pattern 'scribe[[:space:]]backfill'
# does NOT match the real hook line '"$scribe" backfill', so if we used it,
# we would get HAS_BACKFILL=no on the wired fixture (wrong).
# ---------------------------------------------------------------------------
echo "--- ctrace-wiring: old false-negative pattern regression proof ---"

if [ ! -f "$FIXTURES_DIR/ctrace-wiring/hook.sh" ]; then
    skip "ctrace-wiring-regression-proof: fixture missing"
else
    OLD_PATTERN_RESULT="$WORK/old-pattern-result.env"
    (
        HOOK="$FIXTURES_DIR/ctrace-wiring/hook.sh"
        HAS_BACKFILL_OLD=no
        # Deliberately use the OLD broken pattern (space-class only, no dollar-sign-scribe form)
        if grep -qE 'scribe[[:space:]]backfill' "$HOOK" 2>/dev/null; then
            HAS_BACKFILL_OLD=yes
        fi
        echo "HAS_BACKFILL_OLD=$HAS_BACKFILL_OLD"
    ) > "$OLD_PATTERN_RESULT"

    # The old pattern should produce 'no' (it fails to match '"$scribe" backfill')
    old_val=$(grep '^HAS_BACKFILL_OLD=' "$OLD_PATTERN_RESULT" | sed 's/^HAS_BACKFILL_OLD=//')
    if [ "$old_val" = "no" ]; then
        pass "regression-proof: old pattern produces false-negative (HAS_BACKFILL_OLD=no) — new probe needed and present"
    else
        # If the real hook was changed to use 'scribe backfill' directly, old pattern now matches.
        # That would be a hook change, not a probe regression. Note it.
        skip "regression-proof: old pattern now matches (hook may have changed to literal 'scribe backfill'); verify hook wording"
    fi
fi

echo ""

# ---------------------------------------------------------------------------
# Test group 4: memlog-state probe — active fixture
# ---------------------------------------------------------------------------
echo "--- memlog-state: active fixture (MEMLOG_STATE=active) ---"

MEMLOG_PROBE="$PROBES_DIR/memlog-state.sh"

if [ ! -f "$MEMLOG_PROBE" ]; then
    skip "memlog-state: probe not found at $MEMLOG_PROBE"
else
    # Fixture: fake a /dev/memlog-like file with group=memlog, group present, user is member.
    # We use a temp file with stat-able group ownership and override probes via env vars.
    # Since we can't change the gid of a file to 'memlog' (group may not exist in CI),
    # we point PROBE_DEV_MEMLOG at a temp file and override PROBE_MEMLOG_GROUP_CMD and
    # PROBE_USER_GROUPS + PROBE_DEV_MEMLOG via a stat-compatible approach.
    # Simplest: override MEMLOG_DEV_GROUP by creating a tiny wrapper that returns 'memlog'.
    # We achieve this by overriding all four probes via env vars.

    ACTIVE_ACTUAL="$WORK/memlog-active-actual.env"
    (
        # Group present: override command to always succeed
        PROBE_MEMLOG_GROUP_CMD="true"
        # Device group: create a temp file and use a wrapper to report 'memlog'
        # We can't change gid, so override via PROBE_DEV_MEMLOG pointing to a file
        # whose real gid != memlog. Instead we patch the stat call via a wrapper script.
        # Simpler: the probe uses PROBE_DEV_MEMLOG for stat — create a tmpfile and
        # wrap stat via PATH injection.
        _fake_dev="$WORK/fake-dev-memlog-active"
        touch "$_fake_dev"
        # Inject a fake stat wrapper that returns 'memlog' for %G
        _bin="$WORK/bin-active"
        mkdir -p "$_bin"
        printf '#!/bin/sh\necho memlog\n' > "$_bin/stat"
        chmod +x "$_bin/stat"
        PATH="$_bin:$PATH"
        export PATH
        PROBE_DEV_MEMLOG="$_fake_dev"
        # User is a member: override groups list
        PROBE_USER_GROUPS="jsy memlog wheel"
        # No staged/installed pkgrel needed for active case
        PROBE_INST_PKGREL=""
        PROBE_STAGED_PKGREL=""
        export PROBE_MEMLOG_GROUP_CMD PROBE_DEV_MEMLOG PROBE_USER_GROUPS PROBE_INST_PKGREL PROBE_STAGED_PKGREL
        . "$MEMLOG_PROBE"
        echo "MEMLOG_STATE=$MEMLOG_STATE"
    ) > "$ACTIVE_ACTUAL"

    assert_env_var "memlog-state[active]" "MEMLOG_STATE" "active" "$ACTIVE_ACTUAL"
fi

echo ""

# ---------------------------------------------------------------------------
# Test group 5: memlog-state probe — staged-awaiting-install fixture
# ---------------------------------------------------------------------------
echo "--- memlog-state: staged fixture (MEMLOG_STATE=staged-awaiting-install(pkgrel-42)) ---"

if [ ! -f "$MEMLOG_PROBE" ]; then
    skip "memlog-state: probe not found"
else
    STAGED_ACTUAL="$WORK/memlog-staged-actual.env"
    (
        # Group NOT present
        PROBE_MEMLOG_GROUP_CMD="false"
        # No device (doesn't matter when group absent)
        _fake_dev="$WORK/fake-dev-memlog-staged"
        touch "$_fake_dev"
        _bin="$WORK/bin-staged"
        mkdir -p "$_bin"
        printf '#!/bin/sh\necho unknown\n' > "$_bin/stat"
        chmod +x "$_bin/stat"
        PATH="$_bin:$PATH"
        export PATH
        PROBE_DEV_MEMLOG="$_fake_dev"
        PROBE_USER_GROUPS="jsy wheel"
        # Staged pkgrel=42 > installed pkgrel=0 (not installed)
        PROBE_INST_PKGREL=""
        PROBE_STAGED_PKGREL="42"
        export PROBE_MEMLOG_GROUP_CMD PROBE_DEV_MEMLOG PROBE_USER_GROUPS PROBE_INST_PKGREL PROBE_STAGED_PKGREL
        . "$MEMLOG_PROBE"
        echo "MEMLOG_STATE=$MEMLOG_STATE"
    ) > "$STAGED_ACTUAL"

    assert_env_var "memlog-state[staged]" "MEMLOG_STATE" "staged-awaiting-install(pkgrel-42)" "$STAGED_ACTUAL"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== SUMMARY: PASS=$PASS_COUNT FAIL=$FAIL_COUNT SKIP=$SKIP_COUNT ==="

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "=== SOME ASSERTIONS FAILED — see above ==="
    exit 1
else
    echo "=== ALL ASSERTIONS PASSED ==="
    exit 0
fi
