#!/usr/bin/env bash
# docket-runid.sh — compute a stable docket run-id for the current self-review invocation.
#
# Output: a single run-id string on stdout of the form YYYY-MM-DD.<n>
# where <n> is the run number of the day (1-indexed).
#
# The run number is derived by counting today's self-review reflective memories
# (via `recall list --subject self --limit 50`) that contain today's date, then
# adding 1. This is deterministic: calling this script twice within the same
# logical run (before a new reflective memory is written) produces the same id.
#
# If an override is desired, set DOCKET_RUNID in the environment; the script
# will echo it unchanged and exit 0.
#
# Safety: uses `set -uo pipefail` but explicitly guards against a missing
# recall binary or an empty memory dir without aborting the caller.

set -uo pipefail

# --- override path ---
if [[ -n "${DOCKET_RUNID:-}" ]]; then
    printf '%s\n' "$DOCKET_RUNID"
    exit 0
fi

TODAY=$(date +%F)

# Count today's self-review reflective memories.
# recall list may not exist yet on some machines; fall back to 0.
N=0
if command -v recall >/dev/null 2>&1; then
    # recall list outputs one JSON object per line (ndjson) or a JSON array.
    # We count lines whose "body" field contains today's date and "Self-review" prefix.
    recall_out=$(recall list --subject self --limit 50 --format json 2>/dev/null || true)
    if [[ -n "$recall_out" ]]; then
        # Handle both ndjson and JSON array output from recall.
        N=$(printf '%s' "$recall_out" \
            | python3 -c "
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    print(0)
    sys.exit(0)
# Try array first, then ndjson
try:
    items = json.loads(raw)
except json.JSONDecodeError:
    items = []
    for line in raw.splitlines():
        line = line.strip()
        if line:
            try:
                items.append(json.loads(line))
            except json.JSONDecodeError:
                pass
today = sys.argv[1]
count = sum(
    1 for item in items
    if isinstance(item, dict)
    and today in item.get('body', '')
    and 'Self-review' in item.get('body', '')
)
print(count)
" "$TODAY" 2>/dev/null || echo 0)
    fi
fi

# Run number = memories written today + 1 (the current, in-progress run)
RUN_N=$(( N + 1 ))

printf '%s.%d\n' "$TODAY" "$RUN_N"
