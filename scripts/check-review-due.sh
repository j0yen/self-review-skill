#!/bin/sh
# SessionStart hook: if /home/jsy/brain/state/review-due exists, OR last-run.txt is
# missing/older than today, prepend a one-line reminder to Claude's context.
# Output the hook JSON to stdout and exit 0. Stay silent if nothing is due.

state_dir="/home/jsy/brain/state"
marker="$state_dir/review-due"
last_run="$state_dir/last-run.txt"
today=$(date +%Y-%m-%d)

due=0
if [ -e "$marker" ]; then
    due=1
elif [ ! -e "$last_run" ]; then
    due=1
else
    recorded=$(head -n1 "$last_run" 2>/dev/null | tr -d '[:space:]')
    [ "$recorded" != "$today" ] && due=1
fi

msg=""
if [ "$due" -eq 1 ]; then
    msg="🛠 Self-review is due. Run /self-review when you have a moment — it inspects this laptop, cleans up cruft, and journals to /home/jsy/brain/journal/."
fi

# fleet-sync drift (written hourly by fleet-sync.timer; empty file = every
# canonical skill source on this node is at origin and correctly linked).
drift_file="$state_dir/fleet-drift.txt"
if [ -s "$drift_file" ]; then
    drift=$(grep -E '^[a-zA-Z-]+ +(missing|wrong-remote|wrong-branch|dirty|ahead|behind|wrong-link|unreachable) ' "$drift_file" | tr '\n' ';' | sed 's/;$//; s/"/\\"/g; s/  */ /g')
    [ -n "$drift" ] && msg="${msg:+$msg }⚠ fleet-sync drift on $(hostname): $drift — run \`fleet-sync apply\` (dirty/ahead need a commit or push)."
fi

if [ -n "$msg" ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
fi

exit 0
