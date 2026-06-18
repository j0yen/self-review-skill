#!/usr/bin/env bash
# SessionStart hook: start a ctrace session rooted at the Claude process tree
# unless another ctrace is already running. Silent on success. Never blocks
# Claude startup — always exits 0.

set -u

# Never trace the ephemeral headless /build sessions. ctrace launches a
# root-owned `sudo bpftrace`; when it runs inside claude-build-work.service it
# lingers in that cgroup as root, and user-systemd can't kill it ("Operation
# not permitted") -> stop-sigterm timeout -> the unit fails and knocks
# claude-build.timer offline, and the teardown SIGKILL storm can hang
# terminals. Skip any session whose cgroup is a claude-build* unit. (2026-06-05)
if grep -q 'claude-build' /proc/self/cgroup 2>/dev/null; then
    exit 0
fi

ctrace=/home/jsy/.local/bin/ctrace
cache=/home/jsy/.cache/ctrace
sessions="$cache/sessions"
marker="$cache/claude-owns.json"
err="$cache/claude-start.err"

mkdir -p "$sessions" 2>/dev/null || exit 0

# Reap orphaned tracers from prior SIGKILL'd sessions before starting a new one.
reap=/home/jsy/.local/bin/ctrace-orphan-reap
if [ -x "$reap" ]; then
    "$reap" --apply >/dev/null 2>>"$err" || true
fi

# Sweep any un-summarized session logs left by prior SIGKILLed sessions.

# Find Claude's PID. The hook may be invoked directly by claude (PPID=claude)
# or wrapped in a shell (PPID=sh, grandparent=claude). Walk up one if needed.
root="$PPID"
if [ -r "/proc/$PPID/comm" ]; then
    parent_comm=$(cat "/proc/$PPID/comm" 2>/dev/null || true)
    if [ "$parent_comm" != "claude" ]; then
        grand=$(awk '{print $4}' "/proc/$PPID/stat" 2>/dev/null || true)
        if [ -n "$grand" ] && [ "$grand" != "1" ]; then
            root="$grand"
        fi
    fi
fi

# Reap stale marker: tracer exited but marker file remains.
if [ -f "$marker" ]; then
    if ! "$ctrace" status 2>/dev/null | jq -e '.running == true' >/dev/null 2>&1; then
        rm -f "$marker"
    fi
fi

# Honor any running tracer (foreign or already-owned). Do not fight —
# unless it's orphaned (tracer alive but root_pid dead), in which case
# no new events will ever be captured. Stop and replace.
status=$("$ctrace" status 2>/dev/null)
if echo "$status" | jq -e '.running == true' >/dev/null 2>&1; then
    cur_root=$(echo "$status" | jq -r '.root_pid // empty')
    if [ -n "$cur_root" ] && ! kill -0 "$cur_root" 2>/dev/null; then
        "$ctrace" stop >/dev/null 2>&1 || true
        rm -f "$marker"
    else
        exit 0
    fi
fi

iso=$(date +%Y%m%dT%H%M%S)
log="$sessions/claude-$iso.ndjson"

if "$ctrace" doctor --fix --root "$root" --log "$log" >/dev/null 2>"$err"; then
    printf '{"claude_pid":%s,"started_at":"%s","log":"%s"}\n' \
        "$root" "$iso" "$log" > "$marker"
fi

exit 0
