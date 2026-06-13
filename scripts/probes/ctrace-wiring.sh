#!/bin/sh
# ctrace-wiring.sh — probe snippet: check ctrace-session-start.sh for reap and backfill wiring.
#
# Input variable:
#   PROBE_INPUT_HOOK  — path to the hook file to inspect (default: ~/.claude/scripts/ctrace-session-start.sh)
#
# Output variables set in caller's environment (source this file):
#   HAS_REAP     — yes/no: orphan-reap invocation found
#   HAS_BACKFILL — yes/no: scribe backfill invocation found
#
# The correct grep for backfill matches: "$scribe" backfill
# (The old false-negative pattern was: scribe[[:space:]]backfill — this silently missed
#  the real hook line `"$scribe" backfill` because [[:space:]] doesn't match between
#  a quoted variable expansion and the backfill argument in the same word run.)

PROBE_INPUT_HOOK="${PROBE_INPUT_HOOK:-$HOME/.claude/scripts/ctrace-session-start.sh}"

HAS_REAP=no
HAS_BACKFILL=no

if grep -q 'orphan-reap' "$PROBE_INPUT_HOOK" 2>/dev/null; then
    HAS_REAP=yes
fi

# Match "$scribe" backfill — the actual pattern in the real hook.
# Also match the literal string scribe backfill (space-separated, no variable) as
# a forward-compat pattern in case the hook is rewritten to inline the path.
if grep -qF '"$scribe" backfill' "$PROBE_INPUT_HOOK" 2>/dev/null || \
   grep -qE 'scribe backfill' "$PROBE_INPUT_HOOK" 2>/dev/null; then
    HAS_BACKFILL=yes
fi
