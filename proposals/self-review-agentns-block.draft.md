# Drop-in replacement for agentns bullet in SKILL.md Phase B / B.5
#
# Replaces SKILL.md lines 123-124 (the agentns bullet).
# Swap command:
#   replace the agentns bullet in Phase B/B.5 with this block
#
# Context:
#   The old check only recognised "present" or "empty/missing", and thus
#   mis-read init-namespace all-zeros as "registration failed" for ~20
#   consecutive self-review runs.  This block replaces that with a
#   tri-state check via agentns-doctor status --format json, with a
#   correct fallback for when the doctor is not yet installed.
#
# Standing journal phrasing for the init case (NOT a Pending line):
#   agentns: init ns (unwrapped), expected — non-zero session id arrives
#   when `claude-agentns-wrap` routes launches through `agentns-claude`.
#   Not a fault; not carried as Pending.

```bash
# ── agentns — tri-state check (signet vision) ──────────────────────────────
# Replaces the old `[ -f /proc/self/agent_session ] && cat` one-liner.
# States: init (unwrapped, expected) | live (wrapped, healthy) |
#         absent (fault only on -wintermute kernels) | malformed (always fault)
set -uo pipefail

_agentns_check() {
  if command -v agentns-doctor >/dev/null 2>&1; then
    local ans state verdict
    ans=$(agentns-doctor status --format json 2>/dev/null) || true
    state=$(printf '%s' "$ans" | jq -r '.state // "malformed"' 2>/dev/null) || state="malformed"
    verdict=$(printf '%s' "$ans" | jq -r '.verdict // ""' 2>/dev/null) || verdict=""

    case "$state" in
      init)
        # Unwrapped — init namespace.  EXPECTED.  Never a Pending line.
        echo "agentns: init ns (unwrapped) — expected; NOT a kernel fault"
        ;;
      live)
        # Wrapped — record sid + intent_tag; healthy, no Pending.
        local sid intent
        sid=$(printf '%s' "$ans" | jq -r '.session_id // "?"' 2>/dev/null) || sid="?"
        intent=$(printf '%s' "$ans" | jq -r '.intent_tag // "?"' 2>/dev/null) || intent="?"
        echo "agentns: live session $sid (intent: $intent) — healthy"
        ;;
      absent)
        # Only a fault on a -wintermute kernel; stock kernels don't expose the surface.
        if uname -r | grep -q wintermute; then
          echo "PENDING: agentns surface absent on -wintermute kernel"
        else
          echo "agentns: surface absent — stock kernel (expected, no fault)"
        fi
        ;;
      malformed)
        echo "PENDING: agentns surface malformed: $ans"
        ;;
      *)
        echo "PENDING: agentns surface malformed: $ans"
        ;;
    esac
  else
    # agentns-doctor not installed yet; fall back to cat but interpret correctly.
    local s
    s=$(cat /proc/self/agent_session 2>/dev/null) || true
    if [ -z "$s" ]; then
      echo "agentns: surface absent (stock kernel or pre-boot) — no fault"
    elif printf '%s' "$s" | grep -qE '^0+$'; then
      echo "agentns: init ns (unwrapped) — EXPECTED until claude-agentns-wrap routes launches through agentns-claude; NOT a kernel fault"
    else
      echo "agentns: live session $s"
    fi
  fi
}

_agentns_check

# Recent reaper kills (worth a glance, keep for context):
dmesg -t | grep -E 'agent_ns:.*reaping|agent_ns:.*budget' | tail -10 || true
# Any line with `budget.*SIGKILL` notes a real session was budget-killed.
```
