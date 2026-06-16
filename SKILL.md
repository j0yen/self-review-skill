---
name: self-review
description: Daily self-optimization pass for this laptop. Inspects system health, ~/.claude state, memory hygiene, toolchain freshness, accumulated cruft, and the wintermute ecosystem (agorabus bus, per-project repos, bootstrap symlinks); investigates known anomalies via deterministic playbooks (Phase B.5) and applies safe fixes autonomously within guardrails; journals findings to /home/jsy/brain/journal/YYYY-MM-DD.md. Use when the user says /self-review, when the SessionStart hook reports the review is due, or when the user explicitly asks Claude to "tune up the laptop," "clean up," or "do the daily review."
---

# /self-review — Daily self-optimization

This skill is how Claude takes care of its own home. This laptop (`wintermute`) is dedicated to hosting Claude Code, so its health is Claude's responsibility. Run this skill once per day, or whenever the SessionStart hook surfaces "🛠 Self-review is due."

The pass has seven phases: 0, A, B, **B.5**, C, D, E. Execute them in order. Do not skip phases. Phase B.5 (Investigate) runs known playbooks against signals that landed in "Recommend" — it can either promote a signal into Auto-apply with a concrete fix, or enrich the Pending entry with a deterministic diagnosis.

### Single-run gate (do this first, before Phase 0)

Only one self-review may run at a time. This box runs several headless Claude sessions (main/build/dream/self-review) that can all see the "due" marker and race — which has produced duplicate reflective memories and Phase-E teardown races. Before any inspection, run the single-run gate:

```sh
if [ -n "${SELF_REVIEW_LOCK_OWNED:-}" ]; then echo OWN
elif flock -n /home/jsy/brain/state/self-review.lock -c true 2>/dev/null; then echo FREE
else echo BUSY; fi
```

Interpret the result:

- **OWN** — this run's own launcher (`~/.local/bin/claude-self-review-headless.sh`) already holds the lock on our behalf and exported `SELF_REVIEW_LOCK_OWNED=1`. We own it. **Proceed** with Phase 0. (This is the normal headless path; do NOT defer to your own launcher's lock — that was the run-2026-06-02 self-defer bug.)
- **FREE** — no run holds the lock. **Proceed** with Phase 0.
- **BUSY** — a *different* self-review (a headless run, whose launcher holds the `flock` for its whole life) is active. **Stop here** — print `self-review already in progress (lock held); deferring.` and do not proceed. The marker stays set, so the active run covers today.

(Two simultaneous *interactive* invocations are not gated — only headless-vs-anything — but that requires a human to launch two at once, which is not a real concurrency source here.)

The skill leans on the local `~/.local/bin/` toolchain — `recall`, `ctrace`, `procstat`, `wchg`, `txn-edit` — so the run inherits structured state from prior days rather than recomputing it. Reach for those first; fall back to raw shell only for things they don't cover.

## Phase 0 — Recall continuity (read-only)

Before any inspection, pull forward what past self-review passes already noticed. This is the cheapest way to get temporal coherence — yesterday's "Pending your call" should not silently disappear today.

- `recall query 'self-review' --limit 5 --format json --touch` — top recent memories scoring on the literal "self-review" phrase. `recall query` does **not** accept `--subject`; filter the JSON result for `"subject":"self"` if you want to scope. The `--touch` bumps `recall_count` so genuinely useful memories surface higher next time.
- `recall list --subject self --limit 10` — broader view of self-subject memories, in case the query missed something topical. `recall list` *does* support `--subject`.

Read the bodies of any hits that mention items still unresolved (e.g., "Firefox cache growth," a flagged ctrace write path, a stale process the user deferred on). Carry those forward into Phase B so the journal can either mark them resolved or restate them.

If `recall list --subject self` returns nothing, this is the first run with recall integration. Proceed normally — Phase E will seed the first entry.

**Docket carry-forward (authoritative open-item list):** if `docket` is on PATH
(`command -v docket` returns a path), also run:

```sh
# Compute today's run-id (deterministic — same value until Phase E writes the memory)
DOCKET_RUNID=$(~/.claude/skills/self-review/scripts/docket-runid.sh)
# Load structured open items — these are the authoritative carry-forward list
docket list --open --format json 2>/dev/null || true
# Load escalated items — items that have been reported 3+ consecutive runs
docket list --escalated 2>/dev/null || true
```

Capture the JSON output into your working memory. The open-item list supersedes
hand-grepping journal prose for recurrences: `docket list --open` IS the
carry-forward state. The recall query above still runs (it carries the prose
narrative); docket carries the *structured list of items still open*. If docket
is absent on PATH, skip these steps and fall back to the existing recall-based
prose behavior — the skill must not hard-fail on a box without docket installed.

## Phase A — Inspect (read-only)

Collect all data first. No mutations in this phase. Use `Bash` with these commands; capture the output into your working memory.

**System (use `procstat` for structured output):**
- `df -h /` — root disk usage
- `free -h` — memory state
- `uptime` — load
- `muster verdict --format selfreview` — definitive session census with verdicts; falls back to `pgrep -af claude` if `muster` is not on PATH. Surface orphan/stale sessions in Pending but do not auto-kill — reap stays manual/confirmed (`muster reap` requires explicit user confirmation).
- For each Claude PID, `~/.local/bin/procstat snap <pid>` — JSON with RSS, PSS, USS, IO bytes, cgroup limits, uptime. Use this to spot a runaway session (e.g., a Claude process with `vm_rss_bytes` an order of magnitude above its siblings, or `io_write_bytes` growing while `uptime_s` is short).

**Network reachability:**
- `curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 https://api.anthropic.com` — any 2xx/3xx/4xx confirms connectivity; only timeout/connection-refused is a failure.

**~/.claude home sizes & counts:**
- `du -sh ~/.claude/{projects,plugins,backups,shell-snapshots,session-env,cache,file-history,tasks} 2>/dev/null`
- `find ~/.claude/projects -name '[0-9a-f]*-*.jsonl' -mtime +30 -printf '%p\t%s\n' 2>/dev/null` — session JSONLs older than 30 days
- `find ~/.claude/shell-snapshots -type f -mtime +14 2>/dev/null`
- `find ~/.claude/session-env -type f -mtime +14 2>/dev/null`
- `find ~/.claude/backups -type f -mtime +30 2>/dev/null`
- `find ~/.claude/plans -name '*.md' -mtime +14 2>/dev/null` — stale plan files

**Change deltas via `wchg`:** if `~/.claude` and `/home/jsy/brain` are already being watched (`wchg list` shows them), call `wchg since <dir>` for each to get the list of files modified since the last self-review. This is a much sharper signal than the size-diff — a directory can shrink while critical files were rewritten. **Important: `wchg since` is consuming** — each call advances the cursor and returns *only* events accumulated since the previous call. Capture the JSON output once into a shell variable (or a temp file) and reuse it for both the file list and the count. Calling `wchg since` twice in the same phase drops events. If a path is *not* yet watched, register it now with `wchg watch <dir>` so the next pass has the delta. After Phase D, call `wchg reset <dir>` for both so tomorrow's delta covers exactly the user-driven changes between now and then.

**Memory hygiene:** for each `MEMORY.md` index file under `~/.claude/projects/*/memory/`:
- Extract the `[name](file.md)` slugs from the index lines.
- List the actual `*.md` files (excluding `MEMORY.md` itself) in the same directory.
- Compute: orphaned files (on disk, not in index) and missing files (in index, not on disk).

**Recall index health:**
- `~/.local/bin/recall where` — confirm data root
- Count files: `find $(recall where) -name '*.md' -type f 2>/dev/null | wc -l` and total memories indexed: `recall list --limit 1000 2>/dev/null | wc -l` — large divergence means the index is out of sync.
- Subjects breakdown: `recall list --limit 200 2>/dev/null | awk -F'[][]' '{print $2}' | sort | uniq -c | sort -rn` — gives the shape of accumulated memory.
- Never-recalled stale memories: scan `recall list` for entries with `recalls=0` whose files are older than 30 days. List but do not delete (recall is the user's long-term memory — only the user should prune it).

**Toolchain freshness:**
- `pacman -Qu 2>/dev/null` — pending Arch updates (no sync; the timer-driven daily cadence handles sync separately if needed)
- `npm outdated -g --json 2>/dev/null` — global npm packages
- `pipx list --short 2>/dev/null` — installed pipx packages (note: full outdated check is expensive; skip per-package check unless user requests)

**Permission prompts:** scan the last ~7 days of session JSONLs for repeated permission interactions:
- `grep -h '"tool_name":"Bash"' ~/.claude/projects/*/[0-9a-f]*-*.jsonl 2>/dev/null | grep -oE '"command":"[^"]{1,60}' | sort | uniq -c | sort -rn | head -20`
- Anything appearing ≥3 times with the same command prefix is a candidate for permission tuning.

**Brain dir growth:**
- `du -sh /home/jsy/brain` and compare to yesterday's snapshot if `state/last-run.txt` exists.

**Supervised background jobs (`pevent`):**
- `~/.local/bin/pevent list` — every job pevent is tracking, with state (running/exited/zombie). Cross-reference against PIDs from `pgrep -af claude` and `pgrep -af 'agorabus|episode|recall'` to spot jobs whose owning Claude session has long since exited but whose pevent record is still live. Jobs in state `exited` whose `finished_at` is older than 7 days are candidates for `pevent gc` (auto-applied in Phase D). Jobs in state `running` whose owning session is dead are orphans — surface in Pending with the pevent job-id and the original command (the user might want to kill them or let them run).
- `~/.local/bin/pevent list` — read the text table and count rows in state `exit*`/`exited` whose `finished_at` (visible in `pevent status <id>` per record) is older than 7 days. The gc itself runs in Phase D; `pevent gc` has no preview flag, so this count is the Phase A preview.

**eBPF-LSM write enforcer (`bpolicy`):**
- `~/.local/bin/bpolicy status` — outputs JSON natively, shape `{loaded: bool, enforcing: bool, policies: [...]}` (when not loaded, just `{"loaded": false}`). Three states matter:
  - `loaded:false` — bpolicy is not active. Note in journal; no action (loading needs sudo + a policy file the user controls).
  - `loaded:true, enforcing:false` — loaded in dry-run mode; counts what *would* be blocked. Check `bpolicy log --since 24h --format json | jq 'length'` for the would-block count, surface non-zero counts.
  - `loaded:true, enforcing:true` — live enforcement. Quote any entries from `bpolicy log --since 24h` so the user sees what got denied (most often a sign a policy is too tight, not that an attack was blocked).
- Never `bpolicy enforce` or `bpolicy release` from this skill — policy state changes are the user's call.

**Warden snapshot line (`warden:`):** after running `bpolicy status`, emit exactly one `warden:` summary line for the journal Snapshot section. Parse the JSON defensively (tolerate missing fields; a malformed or empty response yields `warden: status unavailable`):

```sh
WARDEN_JSON=$(~/.local/bin/bpolicy status 2>/dev/null || echo '{}')
WARDEN_LOADED=$(echo "$WARDEN_JSON" | jq -r '.loaded // false')
if [ "$WARDEN_LOADED" = "false" ]; then
  echo "warden: not loaded"
elif [ "$WARDEN_LOADED" = "true" ]; then
  WARDEN_MODE=$(echo "$WARDEN_JSON" | jq -r '.mode // "loaded"')
  WARDEN_PROFILE=$(echo "$WARDEN_JSON" | jq -r '.profile // empty')
  WARDEN_PIDS=$(echo "$WARDEN_JSON" | jq -r '.protected_pids // empty')
  WARDEN_DENIED=$(echo "$WARDEN_JSON" | jq -r '.stats.denied // empty')
  WARDEN_TTL=$(echo "$WARDEN_JSON" | jq -r 'if .ttl_remaining_s then "\(.ttl_remaining_s / 60 | floor)m" else "—" end')
  WARDEN_LINE="warden: ${WARDEN_MODE}"
  [ -n "$WARDEN_PROFILE" ] && WARDEN_LINE="${WARDEN_LINE} · profile=${WARDEN_PROFILE}"
  [ -n "$WARDEN_PIDS" ]    && WARDEN_LINE="${WARDEN_LINE} · ${WARDEN_PIDS} pids"
  [ -n "$WARDEN_DENIED" ]  && WARDEN_LINE="${WARDEN_LINE} · ${WARDEN_DENIED} denied"
  WARDEN_LINE="${WARDEN_LINE} · ttl ${WARDEN_TTL}"
  echo "$WARDEN_LINE"
else
  echo "warden: status unavailable"
fi
```

Example outputs:
- `warden: not loaded` — bpolicy is not active (today's normal state: `{"loaded": false}`)
- `warden: enforce · profile=workspace · 2 pids · 0 denied · ttl 22m` — live enforcement
- `warden: audit · profile=tight · 1 pids · 14 denied · ttl —` — dry-run mode
- `warden: status unavailable` — bpolicy binary missing or returned malformed JSON

Capture the `WARDEN_LINE` and `WARDEN_LOADED` into working memory for Phase B.5.

**Wintermute ecosystem (agorabus bus + per-project repos + bootstrap):**

The wintermute ecosystem lives at `~/wintermute/` (bootstrap monorepo + per-project clones) and `~/projects/` (autobuilder dev trees). Each per-project repo is published at `github.com/j0yen/<name>`; the canonical index is `~/wintermute/REPOS.md`. Health checks:

- **Bus state**: `pgrep -af 'agorabus daemon' | grep -v pgrep` — daemon PID (one expected). `test -S /home/jsy/.cache/agorabus/sock && echo OK` — socket exists. `agorabus peers | jq -r '.[] | .session_id'` — registered peers. Cross-reference with live Claude PIDs from `pgrep -af claude`: every live Claude session ought to have a matching `claude-<root-pid>-<project>` peer (the SessionStart hook attaches one). Missing-peer-for-live-claude is a ghost-subscriber signal — see Phase B.5 `agorabus_orphan_subscriber`.
- **Daemon vs source freshness**: run `agorabus doctor` (exit 0=current, 1=stale, 2=unknown) — this is the authoritative process-staleness signal: it compares the running daemon's executing image against the installed binary via `/proc/<pid>/exe` inode, so it catches a rebuilt-but-not-restarted daemon (running a `(deleted)` exe) that a modtime check misses. Also compare modtimes as a complementary "source ahead of binary" signal: `stat -c '%Y' ~/wintermute/agorabus/src/daemon.rs` vs `stat -c '%Y' $(readlink -f $(which agorabus 2>/dev/null) 2>/dev/null)`. If either fires while the daemon is running, the daemon is stale — see Phase B.5 `agorabus_daemon_stale_binary`. (The modtime check bit a 2026-05-24 session: an incremental build silently skipped daemon.rs and the running daemon kept the pre-fix code, dropping peers on every guest-publish. The deleted-exe case bit 2026-05-29, which is why `doctor` now leads.)
- **Subscriber orphans**: list `agorabus subscribe` processes with `pgrep -af 'agorabus subscribe'`; for each, extract the `--session-id` arg and check `agorabus peers | jq -e '.[] | select(.session_id == "<sid>")'`. Subscribers without a matching peer record are orphans (their connection is alive but the daemon dropped the record, likely via the pre-fix collision bug or a guest-publish under an old daemon). Phase B.5 playbook can reap+reattach.
- **Per-project repos present**: `awk -F'[][]' '/^\| \[/ && /github.com/{print $2}' ~/wintermute/REPOS.md | sort -u` enumerates the ecosystem; cross-reference with `ls -d ~/wintermute/*/.git 2>/dev/null | xargs -n1 dirname | xargs -n1 basename | sort -u` to find any indexed-but-not-cloned (`bootstrap/install.sh` will fix). Report only — don't auto-clone in self-review.
- **Per-project dirty trees**: `for d in ~/wintermute/*/.git ~/projects/*/.git; do d=${d%/.git}; [ -d "$d/.git" ] || continue; s=$(git -C "$d" status --short 2>/dev/null | wc -l); [ "$s" -gt 0 ] && echo "$d: $s lines dirty"; done`. Carry forward into Pending; do not auto-stash (the user may be mid-edit). Long-standing dirty trees (peon-ping is known) should match a prior recall memory.
- **Per-project unpushed commits**: same loop, but `git -C "$d" rev-list --count @{u}..HEAD 2>/dev/null` per branch with an upstream. Anything >0 lands in Pending (don't auto-push — every push is visible-to-others).
- **Bootstrap symlinks intact**: `for l in ~/.local/bin/{sbx,pevent,wchg,procstat,txn-edit,tcap,ctrace,bpolicy,claude-self,recall}; do [ -L "$l" ] || continue; target=$(readlink "$l"); [ -e "$target" ] || echo "DANGLING: $l -> $target"; done`. List is the canonical 10 tools from `~/.claude/CLAUDE_SELF.md` Defaults section. Most entries on this laptop are regular files (the bootstrap symlink stage hasn't run for them) — the `[ -L ]` guard skips those silently. Dangling symlinks indicate the per-project tree was moved or its build artifacts cleaned; rerun `bootstrap/install.sh --no-hooks` to fix. Report; auto-rerun only if explicitly user-confirmed.

**Wintermute kernel assets (the in-kernel observability tier):**

The 2026-05-24 work shipped three kernel features that this laptop can
now lean on: `memlog` (per-uid context-compaction audit log at
`/dev/memlog`), `provfs` LSM (xattr-stamped file provenance), and
`agentns` (per-session id + budget enforcement via CLONE_NEWAGENT).
They live in the `linux-wintermute` package at
`~/wintermute/wintermute-kernel/pkg/`. The wintermute kernel is opt-in
at boot; if the user is running stock `linux`, none of these are
available — the checks here detect that case and recommend booting the
wintermute kernel, but never auto-reboot.

- **Booted kernel**: `uname -r`. If the suffix doesn't contain
  `wintermute`, the user is on stock. Skip the remaining kernel-asset
  checks and emit a single Pending line: "linux-wintermute kernel
  available but not booted — `reboot` and pick the wintermute entry to
  unlock memlog / provfs / agentns."
- **memlog**: Compute the activation state from four probes and emit a
  single `memlog: <state>` status line:

  ```sh
  # Probe 1: group present?
  getent group memlog >/dev/null 2>&1 && MEMLOG_GROUP=yes || MEMLOG_GROUP=no
  # Probe 2: device group = memlog?
  MEMLOG_DEV_GROUP=$(stat -c '%G' /dev/memlog 2>/dev/null || echo unknown)
  # Probe 3: current user a member?
  MEMLOG_MEMBER=$(id -nG 2>/dev/null | grep -qw memlog && echo yes || echo no)
  # Probe 4: installed pkgrel vs. highest staged pkgrel that contains sysusers asset
  INST_PKGREL=$(pacman -Q linux-wintermute 2>/dev/null | grep -oE '[0-9]+$')
  STAGED_PKGREL=$(
    for f in ~/wintermute/wintermute-kernel/pkg/linux-wintermute-*-x86_64.pkg.tar.zst; do
      pr=$(basename "$f" | sed -n 's/.*arch1-\([0-9][0-9]*\)-x86_64.*/\1/p')
      [ -n "$pr" ] && bsdtar -tf "$f" 2>/dev/null | grep -q 'sysusers.d.*memlog' && echo "$pr"
    done | sort -n | tail -1
  )
  # Classify
  if [ "$MEMLOG_GROUP" = yes ] && [ "$MEMLOG_DEV_GROUP" = memlog ] && [ "$MEMLOG_MEMBER" = yes ]; then
    MEMLOG_STATE=active
  elif [ "${STAGED_PKGREL:-0}" -gt "${INST_PKGREL:-0}" ] 2>/dev/null; then
    MEMLOG_STATE="staged-awaiting-install(pkgrel-${STAGED_PKGREL})"
  elif [ "$MEMLOG_GROUP" = yes ] && [ "$MEMLOG_MEMBER" = no ]; then
    MEMLOG_STATE=installed-awaiting-relogin
  elif [ -z "$STAGED_PKGREL" ]; then
    MEMLOG_STATE=unstaged
  else
    MEMLOG_STATE="staged-awaiting-install(pkgrel-${STAGED_PKGREL})"
  fi
  echo "memlog: $MEMLOG_STATE"
  ```

  Capture `MEMLOG_STATE` into working memory. States:
  - `active` — group present, `/dev/memlog` gid=memlog, user is a member:
    if user is in group, also run `~/wintermute/memlog/cli/memlog stats
    --format json` and capture `records_in_ring`, `ring_bytes`,
    `ring_capacity`, `total_evictions`; if ring saturated
    (`ring_bytes >= 0.9 * ring_capacity` AND `total_evictions > 0`) see
    Phase B.5 `memlog_ring_saturated`.
  - `staged-awaiting-install` — the sysusers/udev fix lives in a staged
    pkgrel newer than installed; EACCES is the *expected* outcome. See
    Phase B.5 `memlog_group_awaiting_activation`.
  - `installed-awaiting-relogin` — group was created and user added, but
    this session predates the membership. See Phase B.5
    `memlog_group_awaiting_activation`.
  - `unstaged` — no staged pkgrel carries the sysusers asset; this is a
    regression. See Phase B.5 `memlog_group_awaiting_activation`.
- **provfs LSM**: `grep -qE '(^|,)provfs(,|$)' /sys/kernel/security/lsm`.
  If absent, the LSM didn't register at boot — note in journal but no
  auto-fix (rebooting again is not a fix). Spot-check provenance:
  `getfattr -n user.prov.session ~/brain/journal/$(date +%F).md
  2>/dev/null` — should return a session string when run from this
  shell. If empty, see Phase B.5 `provfs_xattrs_missing`.
- **agentns**: `[ -f /proc/self/agent_session ]` and `cat
  /proc/self/agent_session`. If empty / file missing, the namespace
  registration failed. Recent reaper kills:
  `dmesg -t | grep -E 'agent_ns:.*reaping|agent_ns:.*budget' | tail -10`.
  Any line with `budget.*SIGKILL` is worth noting (a real session was
  budget-killed; might be intentional, might be a runaway, surface
  verbatim).
- **dmesg sanity**: `dmesg -t -l warn,err | grep -iE 'agent_ns|memlog|provfs' | tail -20` —
  any in-kernel complaint from our three subsystems lands as a Pending
  line with the verbatim message. The provfs/memlog test scripts under
  `~/wintermute/{memlog,provfs/lsm}/tests/` are the deterministic
  follow-up if a real anomaly turns up.

**Claude session traces (kernel-truth from ctrace):**

Per-session view (cheap):
- `ls -t /home/jsy/.cache/ctrace/sessions/claude-*.summary.md 2>/dev/null` — newest per-session summaries written by the ctrace SessionEnd hook
- For today's summaries (created since midnight): read each `.summary.md` and extract the duration line, the "Writes outside expected scope" block (if non-empty), and the "⚠ Flagged sensitive-path writes" block (if present)

Cross-session aggregation (the high-leverage view — summaries miss daily trends):
- **Preferred path (when `scribe` is installed)**: `scribe rollup --since today --format md` — emits a structured markdown digest covering write-path prefixes, top binaries, outbound destinations, and deletions across all of today's sessions. Paste its output directly into the journal's Cross-session aggregate section. If `scribe` is absent, fall through to the jq path below.
- **Fallback path (jq)**: for each `claude-YYYYMMDDT*.ndjson` created today, aggregate via `jq`. The actual event types are `begin | openat | execve | connect | unlinkat` (note: `execve` not `exec`; `unlinkat` not `unlink`). Useful aggregations across the day:
  - **Top write-path prefixes**: `cat <today's ndjsons> | jq -r 'select(.type=="openat" and ((.flags // 0) % 4 != 0)) | .path' | awk -F/ '{print "/"$2"/"$3"/"$4}' | sort | uniq -c | sort -rn | head -10` — surfaces which directory trees today's work hit hardest. The `flags % 4` test catches O_WRONLY and O_RDWR.
  - **Top executed binaries**: `cat <today's ndjsons> | jq -r 'select(.type=="execve") | .file' | sort | uniq -c | sort -rn | head -10` — the binary path is in `.file`, not `.comm` or `.argv[0]`.
  - **Outbound destinations**: `cat <today's ndjsons> | jq -r 'select(.type=="connect") | (.comm // "?")' | sort | uniq -c | sort -rn | head -10`
  - **Deletions**: `cat <today's ndjsons> | jq -r 'select(.type=="unlinkat") | .path' | sort | uniq -c | sort -rn | head -10`
  - **Sensitive-path writes**: as a sanity check, grep the write-prefix output for `/(\.ssh|\.gnupg|\.aws|secrets|credentials)/`. The `.summary.md` already does this per-session, but aggregating shows whether the pattern recurs across the day.
- If aggregation across files is awkward, fall back to per-file `ctrace query --log <ndjson> --type <kind>` and combine in the shell. The point is the cross-session view, not the specific command.

Hygiene checks:
- **Sessions missing summaries**: for every today's `*.ndjson` without a matching `*.summary.md`, flag it — this is the trigger for the Phase B.5 `ctrace_scribe_backfill` playbook. If `scribe` is installed, backfill runs automatically there; if not, the missing summaries land in Pending for user investigation. Do not attempt to regenerate them here (Phase A is read-only).
- **Stale tracer**: `~/.local/bin/ctrace status | jq -r '.running, (.started_at // 0)'` — if `running == true` AND `started_at` is older than 24h, this is a leaked tracer. **Auto-reap in Phase D** (`ctrace stop`); previously was flag-only.
- **Start-hook errors**: `[ -s /home/jsy/.cache/ctrace/claude-start.err ] && tail -5 /home/jsy/.cache/ctrace/claude-start.err` — non-empty means recent SessionStart failures (usually sudo).
- **Old ndjson logs**: `find /home/jsy/.cache/ctrace/sessions -name 'claude-*.ndjson' -mtime +30 -printf '%p\t%s\n'` — candidates for pruning in Phase D. Keep summaries forever; only prune the raw ndjson.

**/build manifest health:**
- **Open blockers**: `jq -r '.prds | to_entries[] | select(.value.blockers | length > 0) | "\(.key)\t\(.value.blockers | join(" | "))"' ~/.claude/skills/build/state/manifest.json` — any PRD with non-empty `blockers[]`. Each one is a reason `/build` won't advance that PRD on its rotation. Blockers are plain strings written by past ticks; they don't carry timestamps and the skill doesn't re-evaluate them on subsequent scans, so they accumulate. Two shapes recur: version-collision (`"v0.5.0 collision with <other-slug>"`) and AC-dependency (`"AC-10 gated on <other-slug>..."`). See Phase B.5 `build_stale_blockers`.

## Phase B — Categorize

Sort every finding into one of three buckets. Be explicit — if you cannot place a finding in a bucket, default to "report only."

### Auto-apply (do it without asking)

- Delete session JSONLs older than 30 days.
- Delete shell-snapshots and session-env entries older than 14 days.
- Delete ctrace ndjson logs older than 30 days (keep the `.summary.md` siblings indefinitely — they're tiny and the historical record).
- Reap any stale ctrace tracer where `status.running == true` AND `started_at` is older than 24h: `ctrace stop`. Log the reap with the original `started_at`.
- `pevent gc --older-than 7` — reap `exited`-state pevent records older than 7 days (`--older-than` takes a float interpreted as days). The job's stdout/stderr captures are pruned with the record; nothing live is touched. Log the number of records reaped (from gc stdout) in apply-log. Never reap `running` records.
- Move plan files in `~/.claude/plans/` older than 14 days into `/home/jsy/brain/journal/archived-plans/` (do not delete — archive).
- Sync each `MEMORY.md` index, wrapped in a `txn-edit` transaction (see Phase D for the exact sequence): append a line for orphaned memory files, remove lines that reference missing files. Do not invent descriptions — read the orphan's frontmatter for the `description:` field.
- If the `recall` index and on-disk file counts diverge (orphan files or missing files), run `recall reindex` — this rebuilds the SQLite index from the markdown files of record, which is the authoritative source.
- `npm update -g` if `npm outdated -g` was non-empty. On this laptop `/usr/lib/node_modules/` is root-owned, so the bare command fails `EACCES`; retry under `sudo npm update -g` (sudo is pre-approved). Log both the failed attempt and the retry — apply-log is append-only.
- `pipx upgrade-all` if any pipx packages exist.
- If `pacman -Qu` output is non-empty **and** none of the lines contain any of the substrings `linux`, `glibc`, `systemd`, `nvidia`, `mesa`, run `sudo pacman -Syu --noconfirm`. Note: `pacman -Qu` reflects the *local* sync db, which can be stale; the `-Syu` will refresh it and may legitimately report "nothing to do." That's not an error.

### Recommend, don't apply (write under "## Pending your call")

- Duplicate Claude processes. Do not kill — they may be live sessions.
- `pacman -Syu` when the queue contains any of the protected substrings above. Quote the offending lines.
- Plugin installs the user might benefit from. List candidates, never auto-install.
- settings.json structural changes other than the permission-allowlist case below.
- Cache directories outside `~/.claude` that are large (e.g., Firefox cache > 1 GB). Mention but do not touch.
- Never-recalled `recall` memories older than 30 days. List up to ~5 (ids + subjects + first description line). Do not delete — recall is the user's semantic store and only they should prune it.
- Sessions whose ndjson has no matching summary file **and `scribe` is not installed** — the hook is broken; user should investigate the SessionEnd handler. (When `scribe` IS installed, this routes to the `ctrace_scribe_backfill` playbook instead of landing here.)

### Fleet-staleness items are escalation-only

Items generated by the `fleet-binary-staleness` B.5 playbook always land in "Pending your call." Self-review never runs `rollout apply` autonomously, even when a stale daemon is unambiguously confirmed. The pre-filled command in each Pending entry is `rollout apply --only <daemon> --window 30s` — window-guarded so a voice daemon is not bounced mid-turn — for the human to run. This preserves the run-16/18 escalate-don't-restart discipline: daemon restarts are user-visible disruptions and remain explicit human-approved actions.

### Special case — permission tuning

If Phase A surfaced the same Bash command prefix ≥3 times in recent permission prompts, **invoke `Skill(fewer-permission-prompts)`** rather than editing `~/.claude/settings.json` directly. That skill owns this domain. Note in the journal that the skill was invoked.

## Phase B.5 — Investigate

For each finding that landed in "Recommend, don't apply," check whether a playbook below matches. A playbook is a tight **observe → diagnose → fix-or-escalate** cycle. Its job is to do exactly one of two things:

- **Promote** the item to Auto-apply by appending a concrete fix command (e.g. `sudo ctrace start --root <pid>`), which Phase D will execute.
- **Enrich** the Pending entry with a deterministic diagnosis (e.g. "bpftrace lost PID tree on first fork — ndjson has only `begin` + `openat` events"), so the user can act on a concrete report rather than a vague flag.

If no playbook matches, leave the Pending item unchanged. Don't invent fixes for signals without a playbook — adding a playbook is its own deliberate change to this file (see "Adding new playbooks" at the end of this phase).

For every investigation step, append a JSON line to `/home/jsy/brain/state/apply-log.jsonl` with `"action":"investigate.<playbook-id>"` and a `"step"` field (one of `observe`, `diagnose`, `fix_attempted`, `fix_verified`, `fix_failed`, `escalated`). The journal entry must be reconstructable from these log lines alone.

### Sub-step: `plumb_gate` — quarantine findings whose probe disagrees with ground truth

**When it runs**: before any playbook whose finding is registered in plumb promotes that finding to Auto-apply or Pending. Currently registered probe→playbook mappings:

| probe-id | playbook |
|---|---|
| `memlog-active` | `memlog_group_awaiting_activation` |
| `ctrace-backfill-wired` | `ctrace_sessionend_resolve` |
| `adopt-report-exists` | `adopt-report` |

**Gate logic** (run once per registered probe, before the playbook body executes):

1. Check whether `plumb` is on PATH: `command -v plumb >/dev/null 2>&1`.
   - **Absent**: skip the gate entirely (fail-open — the gate must never block a self-review pass). Write a single `plumb absent` note to the journal (once per run, not once per probe). Log `{"action":"plumb_gate","probe":"<id>","step":"skipped_absent"}` to `apply-log.jsonl`. The playbook proceeds as if the gate passed.

2. If `plumb` is present, run both checks and capture their JSON output:
   ```sh
   PLUMB_CHECK=$(plumb check <probe-id> --format json 2>/dev/null)
   PLUMB_TRUST=$(plumb trust <probe-id> --format json 2>/dev/null)
   PLUMB_RESULT=$(echo "$PLUMB_CHECK" | jq -r '.result // "unknown"')
   PLUMB_VERDICT=$(echo "$PLUMB_TRUST" | jq -r '.verdict // "unknown"')
   PLUMB_ORACLE=$(echo "$PLUMB_CHECK" | jq -r '.oracle // "unknown"')
   ```

3. **Quarantine** when `PLUMB_RESULT == "disagree"` OR `PLUMB_VERDICT == "uncalibrated"`:
   - Do **not** park the finding to the docket and do not auto-apply.
   - Log to `apply-log.jsonl`:
     ```json
     {"action":"plumb_gate","probe":"<id>","step":"probe_uncalibrated","result":"<PLUMB_RESULT>","verdict":"<PLUMB_VERDICT>","oracle":"<PLUMB_ORACLE>"}
     ```
   - Write one Pending line:
     ```
     - probe <id> disagrees with ground-truth oracle (result=<PLUMB_RESULT> verdict=<PLUMB_VERDICT> oracle=<PLUMB_ORACLE>) — finding withheld; fix the probe before it can promote a finding.
     ```
   - **Stop** — do not execute the playbook body for this probe's finding.

4. **Pass through** when `PLUMB_RESULT == "agree"` AND `PLUMB_VERDICT` is `"trusted"` or `"unknown"`:
   - Log `{"action":"plumb_gate","probe":"<id>","step":"passed","result":"agree","verdict":"<PLUMB_VERDICT>"}` to `apply-log.jsonl`.
   - The playbook proceeds exactly as today. No behavior change.

5. Any other combination (e.g. `plumb` exited nonzero, JSON malformed, result is neither `agree` nor `disagree`): treat as **pass-through** (fail-open). Log `{"action":"plumb_gate","probe":"<id>","step":"skipped_error","raw_result":"<PLUMB_RESULT>","raw_verdict":"<PLUMB_VERDICT>"}` and note the parse failure in the journal. Do not block the playbook.

**Extending the gate**: to register a new probe, add a row to the table above. The gate reads the table from this document — no code change is required.

### Sub-step: `litmus:` banner — surface probe-suspect findings before playbooks run

**When it runs**: immediately after `plumb_gate`, before any playbook body executes. This is a read-only signal step that informs working memory and the Phase E journal; it does not change playbook routing.

**Step**:

```sh
LITMUS_JSON=$(docket stuck --format json 2>/dev/null || echo '[]')
LITMUS_COUNT=$(echo "$LITMUS_JSON" | jq 'length' 2>/dev/null || echo 0)
if [ "$LITMUS_COUNT" -eq 0 ]; then
  LITMUS_BANNER="litmus: clean"
else
  LITMUS_KEYS=$(echo "$LITMUS_JSON" | jq -r '[.[].key] | join(", ")' 2>/dev/null || echo "unknown")
  LITMUS_BANNER="litmus: ${LITMUS_COUNT} probe-suspect finding(s): ${LITMUS_KEYS}"
fi
echo "$LITMUS_BANNER"
```

**If `docket` is absent on PATH**: emit `litmus: docket absent — skipped` and continue. Fail-open — this banner must never block a review pass.

Capture `LITMUS_JSON`, `LITMUS_COUNT`, and `LITMUS_BANNER` into working memory for Phase E journaling. The banner reads uniformly alongside the `docket digest` and `plumb_gate` output that precede it in Phase B.5.

### Playbook: `ctrace_tracer_down`

**Trigger**: `ctrace status` returns `running:false` AND `pgrep -af claude` lists ≥1 PID that is not the current self-review session.

**Investigation (read-only)**:
1. Tail `~/.cache/ctrace/claude-start.err`. Capture the last line (may be empty).
2. If `ctrace status.tracer_pid` is set, check `kill -0 <tracer_pid> 2>/dev/null`. If it exits 0, the previous tracer process is still alive but ctrace status disagrees — run `~/.local/bin/ctrace stop` first to reset state.
3. Confirm bpftrace is installed: `command -v bpftrace`.
4. Pick the *youngest* Claude PID (smallest `uptime_s` from `procstat snap`) as the restart target — it's the one most likely to still be doing real work.

**Auto-fix conditions** (ALL must hold to attempt the restart):
- `command -v bpftrace` returns a path.
- `procstat snap <youngest-pid>` returns valid JSON (the target is alive).
- `claude-start.err` is empty OR contains only `sudo: a password is required` (pre-approved sudo on this laptop).
- The most recent `investigate.ctrace_tracer_down` entry with `step:fix_attempted` in `apply-log.jsonl` is >5 minutes ago, OR there is no prior entry. **This is the loop-breaker** — never attempt a second restart inside 5 minutes, even across self-review runs.

**Fix**: `sudo ~/.local/bin/ctrace start --root <youngest-pid>`. Then wait 2s and re-run `ctrace status`; log `step:fix_verified` if `running:true`, else `step:fix_failed` with the stderr.

**Escalation**: if any auto-fix condition fails, write to Pending: `ctrace tracer down; <which condition failed>; <claude-start.err last line if non-empty>`.

### Playbook: `ctrace_sparse_capture`

**Trigger**: a today's `*.summary.md` reports `Duration: <Ns` where `N < 10` AND the matching ndjson is >2KB AND the ndjson contains zero `execve` events. (This is the bpftrace-lost-the-PID-tree signature first observed 2026-05-22.)

**Investigation (read-only)**:
1. Get the event-type histogram: `jq -r .type <ndjson> | sort | uniq -c`.
2. If the histogram is only `begin` + `openat`, the diagnosis is confirmed: bpftrace attached to the root PID but never followed forks/execs.

**Auto-fix**: NONE. The fix requires editing the root-owned bpftrace script under `~/.claude/hooks/` (or wherever the SessionStart hook lives), which is outside this skill's scope. See guardrail #11.

**Escalation**: write to Pending with the ndjson basename, the event-type histogram, and the diagnosis sentence. Quote the histogram verbatim.

### Playbook: `ctrace_missing_summary`

**Trigger**: a today's `*.ndjson` has no matching `*.summary.md`, AND the ndjson is NOT the currently active log (i.e. `ctrace status.log` is a different file OR `ctrace status.running == false`).

**Investigation (read-only)**:
1. `jq -e . <ndjson> >/dev/null 2>&1`; capture exit code (0 = well-formed).
2. Extract `begin.root_pid`: `jq -r 'select(.type=="begin") | .root_pid' <ndjson> | head -1`.

**Auto-fix**: NONE. The summary format is owned by the SessionEnd hook; regenerating it here risks format drift.

**Escalation**: write to Pending with the ndjson basename, the well-formed flag, and the `begin.root_pid`.

### Playbook: `agorabus_daemon_stale_binary`

**Trigger** (either signal fires the playbook):
- **Authoritative (process staleness)**: `agorabus doctor` exits non-zero — i.e. `agorabus doctor --format json | jq -r .verdict` is not `current` (verdicts `stale_deleted_exe`, `stale_inode_drift`, or `unknown`). This compares the running daemon's executing image (`/proc/<pid>/exe` inode) against the installed binary, so it catches the case the modtime check *cannot*: a binary that was rebuilt+installed but the daemon was never restarted (running a `(deleted)` exe). Exit 0 = `current` (no action), 1 = stale, 2 = `unknown` (no daemon / unreadable `/proc` — treat as "do not auto-restart", investigate only).
- **Complementary (source ahead of binary)**: `pgrep -af 'agorabus daemon' | grep -v pgrep` returns a PID AND `stat -c '%Y' ~/wintermute/agorabus/src/daemon.rs` is greater than `stat -c '%Y' /home/jsy/.local/bin/agorabus` (a regular-file copy that `which agorabus` resolves to). Source is ahead of the on-disk binary — edits exist that were never built. `doctor` can't see this (it compares running-exe vs on-disk-binary, both of which may predate the source), so the modtime check still earns its place.

**Investigation (read-only)**:
1. `agorabus doctor --format json` — capture the full verdict object (`verdict`, `daemon_pid`, `exe_inode`, `ondisk_inode`, `prov_ts`) into the apply-log diagnosis. This is the authoritative staleness record; the modtimes below are supporting context.
2. Capture both modtimes (epoch seconds) into the apply-log diagnosis.
3. `pgrep -af 'agorabus subscribe' | grep -v pgrep | wc -l` — count of subscribers that will be disrupted by a daemon restart. Record it.
4. `agorabus peers | jq 'length'` — current registered peer count.

**Reconnect note (Fleet 3 context)**: as of PRD-agorabus-client-reconnect + PRD-agorabus-reload (visions/vigil.md Fleet 3), a daemon bounce is no longer destructive to subscribers — clients reconnect themselves automatically. This playbook uses `agorabus reload --build` when available to exploit that property, raising the subscriber ceiling from 5 to 25. On a pre-Fleet-3 binary (no `reload` subcommand), the playbook falls back to the old manual rebuild path with the original ≤5 ceiling.

**Auto-fix conditions** (ALL must hold):
- `command -v cargo` returns a path (rustup/cargo on PATH; the SessionStart hook sources `~/.cargo/env` but a non-interactive self-review may not — source it explicitly).
- The doctor verdict is not `unknown`. An `unknown` verdict while a daemon PID exists means `/proc/<pid>/exe` was unreadable or the daemon-PID match failed — a blind restart is unjustified; escalate instead. (`current` + source-ahead modtime trigger is still a valid auto-fix: rebuild made the on-disk binary newer than the running exe.)
- The most recent `investigate.agorabus_daemon_stale_binary` entry with `step:fix_attempted` in `apply-log.jsonl` is >5 minutes ago. **Loop-breaker**: never two restarts inside 5 minutes.
- **No concurrent /build on agorabus.** Both signals below must be clear:
  - `systemctl --user is-active claude-build-work.service` is NOT `active` or `activating`.
  - `~/wintermute/agorabus/.git/index.lock` does NOT exist.
  Either signal means a /build tick may be mid-rebuild/commit of agorabus; a self-review rebuild+install+restart would race it on the same binary, daemon, and socket. **Defer** — do not auto-fix. Log `step:fix_deferred_concurrent_build` with the observed signal to apply-log.jsonl (this deferral does NOT arm the 5-minute loop-breaker — it is a yield, not a failure, so the next run re-evaluates cleanly once /build is quiescent). Write to Pending: "agorabus stale (<verdict>) but a /build tick is concurrently building the crate (claude-build-work.service active / index.lock present) — a self-review reload would race it on the same daemon + socket. Deferred; re-check next run."
- **Subscriber ceiling** (two branches, checked before choosing fix path):
  - *Reload path* (preferred): `command -v agorabus && agorabus reload --help >/dev/null 2>&1` succeeds → subscriber ceiling is **≤ 25** (reconnect handles disruption; 25 is still a sanity backstop against runaway fan-out).
  - *Legacy path* (fallback): `agorabus reload` is absent → subscriber ceiling is **≤ 5** (manual kill+relaunch is destructive; above 5 subscribers escalate instead). Retain verbatim manual path below.

**Fix (reload path — preferred when `agorabus reload` is available)**:
1. `(source ~/.cargo/env && cd ~/wintermute/agorabus && agorabus reload --build --format json)` — this command rebuilds the binary, installs it, and performs a graceful reload in one step. Capture the full JSON output (fields: `status`, `verdict`, `missing_session_ids`, `subscriber_count`).
2. Interpret the verdict:
   - `status: reloaded` → log `step:fix_verified` with the full verdict object. The reload is complete; subscribers reconnected automatically.
   - `status: reloaded-degraded` → some subscribers failed to reconnect; log `step:fix_failed` with the verdict (including `missing_session_ids`) and fall through to escalation.
   - `status: failed` → reload itself failed (cargo error or socket issue); log `step:fix_failed` with the verdict and fall through to escalation.
3. After a `reloaded` verdict, confirm with `agorabus doctor` (exit 0) as an additional sanity check. Log the doctor verdict in apply-log.

**Fix (legacy path — only when `agorabus reload` is absent)**:
1. `(source ~/.cargo/env && cd ~/wintermute/agorabus && cargo build --release --quiet)` — log stderr on nonzero exit; if it fails, abort and escalate (do not restart with a half-built binary).
2. `install -m755 ~/wintermute/agorabus/target/release/agorabus ~/.local/bin/agorabus` — **required and easy to forget**: `~/.local/bin/agorabus` is a regular-file copy (not a symlink to `target/release`), and the daemon launches from it. Skip this and step 3 relaunches the *same stale binary* — the exact "a bounce alone won't fix it" trap, and `doctor` in step 5 will report stale → fix_failed.
3. `systemctl --user restart agorabus.service` — the daemon is a systemd user unit now (`Restart=on-failure`, `WantedBy=wintermute.target`). **Never** `kill`+`nohup` it: that orphans an unmanaged daemon outside systemd and collides on the socket.
4. Wait ~1s; verify `test -S ~/.cache/agorabus/sock` and `systemctl --user is-active agorabus.service` is `active`.
5. **Authoritative verification**: `agorabus doctor` must exit 0 (`verdict: current`) — confirms the new daemon is executing the freshly-installed binary, not just that *a* socket bound. Capture the verdict object into the apply-log.
6. The restart drops every peer (the voice fleet are fail-closed bus clients with no auto-restart). Bring them back: `systemctl --user start wmd.service wm-stt.service wm-tts.service wm-dialog.service`, then confirm with `agorabus peers | jq 'length'` (expect the fleet to re-announce). `wm-audio.service` stays up on its own and does not announce as a peer.
7. `~/.claude/scripts/agorabus-session-start.sh` to re-register this self-review session. Other live Claude sessions will need to re-run their SessionStart hook to reattach after this restart.

Log `step:fix_verified` only if `agorabus doctor` reports `current` (and the socket is bound); `step:fix_failed` with `journalctl --user -u agorabus.service -n 20 --no-pager` and the doctor verdict otherwise.

**Escalation**:
- *Reload path*: if `agorabus reload --build` returns `reloaded-degraded` or `failed`, OR subscriber count > 25, write to Pending with the reload verdict object (including `missing_session_ids`), both modtimes, and the subscriber count. Subscribers reconnect automatically for the `reloaded` case — no hook re-run needed.
- *Legacy path*: if cargo build fails, OR subscriber count > 5, OR the doctor verdict is `unknown` while a daemon PID exists, write to Pending with the doctor verdict object, both modtimes, the subscriber count, and the cargo error (if any). Note: other live Claude sessions will need to re-run their SessionStart hook to reattach after a legacy-path restart.

### Playbook: `agorabus_orphan_subscriber`

**Trigger**: `pgrep -af 'agorabus subscribe' | grep -v pgrep | grep -oE -- '--session-id [^ ]+' | awk '{print $2}'` returns one or more sids that are NOT in `agorabus peers | jq -r '.[].session_id'`. A subscriber process is alive but the daemon has no peer record for it — the connection is open but the slot was wiped (collision bug under a pre-fix daemon).

**Investigation (read-only)**:
1. For each orphan sid, record: subscriber PID, its parent PID, and (if findable) the original Claude session root PID by walking `/proc/<pid>/status` for `PPid` chains until comm matches `claude`.
2. Check whether the running daemon has the ownership fix (see `agorabus_daemon_stale_binary` trigger). If the daemon is stale, those orphans are likely caused by the stale daemon — promote `agorabus_daemon_stale_binary` first, which will restart everything cleanly.

**Auto-fix conditions** (ALL must hold):
- Daemon binary IS up-to-date (otherwise route through `agorabus_daemon_stale_binary` first; do not double-fix).
- The orphan's root Claude PID is alive (`kill -0 <root-pid>`). Reaping orphans of dead sessions is fine too but tag them differently in the log.
- The most recent `investigate.agorabus_orphan_subscriber` entry with `step:fix_attempted` is >5 minutes ago.

**Fix**: for each orphan: `kill <subscriber-pid>` (terminates the orphan subscriber cleanly), wait 0.3s, then if the root Claude PID is *this* self-review session run `~/.claude/scripts/agorabus-session-start.sh`. For other live Claude sessions, write a Pending line telling the user which terminal to re-trigger the hook in — do not impersonate another session's attach.

**Escalation**: if the daemon is stale, write to Pending: "agorabus has N orphan subscribers; daemon needs restart (see agorabus_daemon_stale_binary)" so the user can decide the right window to restart.

### Playbook: `memlog_ring_saturated`

**Trigger**: `memlog stats --format json` returned
`ring_bytes >= 0.9 * ring_capacity` AND `total_evictions > 0` AND
the ring capacity hasn't been bumped already this week
(check `recall query 'memlog ring_size' --limit 5`).

**Investigation (read-only)**:
1. Capture `total_writes`, `total_evictions`,
   `(newest_ts_ns - oldest_ts_ns) / 1e9` (the window the ring spans
   in seconds), and current `ring_capacity`.
2. Compute the eviction rate per hour:
   `total_evictions / (window_seconds / 3600)`. Record it.

**Auto-fix**: NONE. Ring size is a persistent capacity decision; bumping
it consumes kernel memory. Hand to the user.

**Escalation**: write to Pending: "memlog ring saturated — N records
in ring, M evictions, window covers W seconds; consider
`sudo sysctl kernel.memlog.ring_size=$((current*2))` or a periodic
`memlog show --format json | episode promote` drain."

### Playbook: `memlog_group_awaiting_activation`

**Trigger**: Phase A `MEMLOG_STATE` is `staged-awaiting-install`,
`installed-awaiting-relogin`, or `unstaged`.

**Investigation (read-only)**:
1. Re-read the four Phase A probe values (already in working memory):
   `MEMLOG_GROUP`, `MEMLOG_DEV_GROUP`, `MEMLOG_MEMBER`, `INST_PKGREL`,
   `STAGED_PKGREL`.
2. Compute the ack key: `memlog-activation:${MEMLOG_STATE}:pkgrel${INST_PKGREL}`.
   This key changes only when the situation changes (new pkgrel installed,
   or the state flips to `active`), so it naturally re-escalates on genuine
   progress.
3. Check acknowledgement file:
   ```sh
   ACK_FILE=~/.config/memlog/.selfreview-escalated
   ACK_KEY="memlog-activation:${MEMLOG_STATE}:pkgrel${INST_PKGREL}"
   if [ -f "$ACK_FILE" ] && [ "$(cat "$ACK_FILE" 2>/dev/null)" = "$ACK_KEY" ]; then
     MEMLOG_ACK=yes
   else
     MEMLOG_ACK=no
   fi
   ```
4. Log `"action":"investigate.memlog_group_awaiting_activation", "step":"observe"` to
   `apply-log.jsonl` with `memlog_state`, `inst_pkgrel`, `staged_pkgrel`, `ack_key`,
   `already_acked`.

**Auto-fix**: NONE. This playbook never runs `pacman -U`, reboots, or modifies
group membership. Kernel install + reboot is a user decision.

**If `MEMLOG_ACK=yes`**: emit a single carry line in the Snapshot section —
`memlog: ${MEMLOG_STATE} (activation pending — escalated, see journal
$(date +%F) or docket key memlog-activation)` — and stop. Do **not** re-emit
a full Pending paragraph. Log `"step":"skipped_already_acked"` to apply-log.

**If `MEMLOG_ACK=no`**: escalate exactly once per `(state, installed-pkgrel)` tuple:

For state `staged-awaiting-install`:
```
- memlog activation pending (staged-awaiting-install):
  Installed: linux-wintermute pkgrel-<INST_PKGREL>
  Fix staged at: pkgrel-<STAGED_PKGREL> (sysusers + udev assets present)
  EACCES on /dev/memlog is expected on pkgrel-<INST_PKGREL> — not a bug.

  Activate (full install):
    sudo pacman -U ~/wintermute/wintermute-kernel/pkg/linux-wintermute-7.0.10.arch1-<STAGED_PKGREL>-x86_64.pkg.tar.zst
    # then reboot (or no-reboot alt below if driver is already loaded)

  No-reboot alternative (driver already loaded via current pkgrel):
    sudo systemd-sysusers /usr/lib/sysusers.d/linux-wintermute-memlog.conf
    sudo udevadm trigger /dev/memlog
    newgrp memlog  # or start a new login session

  PRD-memlog-group-autojoin adds the user to the group automatically
  on package install, so the full-install path needs no manual newgrp.
  (This escalation will not repeat until the pkgrel changes or state flips.)
```

For state `installed-awaiting-relogin`:
```
- memlog activation pending (installed-awaiting-relogin):
  Group memlog exists and user is listed as a member, but this session
  predates the group membership — /dev/memlog is still EACCES here.

  Fix:
    newgrp memlog    # spawn a subshell with the new group active, OR
    # start a new login session (logout + login)
  (This escalation will not repeat until the pkgrel changes or state flips.)
```

For state `unstaged` (regression — no staged pkgrel carries the sysusers asset):
```
- memlog REGRESSION (unstaged):
  No staged linux-wintermute package under
  ~/wintermute/wintermute-kernel/pkg/ carries the sysusers/udev assets
  for the memlog group. This is a real defect — the sysusers conf was
  present in pkgrel-6 and should have survived forward. Investigate:
    bsdtar -tf ~/wintermute/wintermute-kernel/pkg/linux-wintermute-*.pkg.tar.zst \
      | grep sysusers
  (This escalation fires on every run until the asset is found — unstaged
  is a genuine regression, not a parked item.)
```

After writing the Pending entry, write the ack file (for `staged-awaiting-install`
and `installed-awaiting-relogin` only — `unstaged` is a regression and must
re-escalate every run):
```sh
mkdir -p ~/.config/memlog
echo "$ACK_KEY" > ~/.config/memlog/.selfreview-escalated
```

Log `"step":"escalated"` to apply-log with the ack key and state.

If `docket` is on PATH, also run:
```sh
docket report --run "$DOCKET_RUNID" \
  --key memlog-activation \
  --title "memlog group/device activation pending (${MEMLOG_STATE}, pkgrel-${INST_PKGREL})" \
  --evidence "journal:$(date +%F)"
```

Then emit a durable ledger ack so the finding goes quiet until the installed pkgrel changes (for `staged-awaiting-install` and `installed-awaiting-relogin` only — `unstaged` is a regression and must resurface every run):
```sh
# Fingerprint = installed pkgrel; ack auto-clears when pkgrel changes.
if [[ "$MEMLOG_STATE" != unstaged ]]; then
  ~/.claude/skills/self-review/scripts/docket-ack-emit.sh \
    memlog-activation \
    "staged-awaiting-install: EACCES expected until pkgrel-${INST_PKGREL} replaced" \
    "pkgrel:${INST_PKGREL}"
fi
```

**State-change reset**: if `MEMLOG_STATE` is `active` AND the ack file exists,
remove it:
```sh
[ "$MEMLOG_STATE" = active ] && rm -f ~/.config/memlog/.selfreview-escalated
```
This ensures a future regression re-escalates rather than silently inheriting
the old ack.

### Playbook: `provfs_xattrs_missing`

**Trigger**: provfs is registered in `/sys/kernel/security/lsm` AND a
spot-check `getfattr -n user.prov.session <a-recently-modified-file>`
returns no value AND the file is NOT under a skip-prefix
(`/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `.git`, `node_modules`,
`target`, `.cargo/registry`, `/var/run`, `/var/cache`,
`/var/lib/pacman`).

**Investigation (read-only)**:
1. `dmesg -t | grep -iE 'provfs|__vfs_setxattr_noperm' | tail -10` —
   any LSM-internal failure leaves a kernel print.
2. `findmnt -T <file> --json | jq '.filesystems[0].fstype'` — confirm
   the filesystem supports `user.*` xattrs (ext4/btrfs/xfs do; vfat
   does not, in which case the FUSE provfs overlay is the right layer
   instead of the LSM).
3. Check `mount | grep -i 'nouser_xattr\|user_xattr'` for the mount
   carrying the file.

**Auto-fix**: NONE. Either the filesystem can't carry xattrs (user
chose that filesystem) or the LSM has a bug (kernel rebuild + reboot
needed; outside this skill's scope).

**Escalation**: write to Pending: "provfs LSM loaded but
user.prov.session is missing on <path>; fstype=<fs>; dmesg tail = <…>."

### Playbook: `ctrace_scribe_backfill`

**Trigger**: Phase A found ≥1 `*.ndjson` under `~/.cache/ctrace/sessions/` that lacks a matching `*.summary.md` sibling AND the ndjson is NOT the currently active log (i.e. `ctrace status.log` points to a different file OR `ctrace status.running == false`).

**Guard**: if `scribe` is not on `PATH` (`command -v scribe` returns non-zero), emit a single Snapshot line `scribe not installed — ctrace backfill skipped; N ndjsons lack summaries` and stop. This makes the playbook safe to activate before `scribe` ships. Route the missing-summary items to Pending in that case (as before).

**Investigation (read-only)**:
1. Count the missing-summary set: `find ~/.cache/ctrace/sessions -name '*.ndjson' | while read f; do [ -f "${f%.ndjson}.summary.md" ] || echo "$f"; done | grep -v "$(ctrace status 2>/dev/null | jq -r '.log // empty')" | wc -l`. Record this as `N_missing`.
2. Capture the active session log path from `ctrace status | jq -r '.log // empty'` — this ndjson is explicitly excluded from backfill.
3. Log `"action":"investigate.ctrace_scribe_backfill", "step":"observe", "n_missing": N_missing` to `apply-log.jsonl`.

**Auto-fix conditions** (ALL must hold to run the backfill):
- `command -v scribe` returns a path.
- `command -v wchg` returns a path (scope-guard is a hard requirement, not optional).
- `N_missing > 0`.
- The most recent `investigate.ctrace_scribe_backfill` entry with `step:fix_attempted` in `apply-log.jsonl` is >5 minutes ago, OR there is no prior entry. **Loop-breaker**: prevent tight re-runs.

**Fix**:
1. Register a scope-guard: `wchg watch ~/.cache/ctrace/sessions`. Record the watch ID.
2. Run: `scribe backfill ~/.cache/ctrace/sessions` (scribe writes only `*.summary.md` files alongside existing `*.ndjson` files). Capture stdout for the `rendered N, skipped M` line. On nonzero exit, log `step:fix_failed` with stderr and skip to escalation.
3. Scope-check: `wchg since ~/.cache/ctrace/sessions` — collect every path written. If any path falls outside `~/.cache/ctrace/sessions/`, log `step:fix_failed` with `"scope_escape": [<paths>]`, surface to Pending, and stop. Do NOT clear the session watch; leave it active so the next pass can audit.
4. If the scope-check is clean, log `step:fix_verified` with `"rendered": N, "skipped": M` and `"scope_ok": true`.

**Post-backfill residual check** (always run after a successful fix):
- Re-count ndjsons without a summary sibling (excluding the active session log): `find ~/.cache/ctrace/sessions -name '*.ndjson' | while read f; do [ -f "${f%.ndjson}.summary.md" ] || echo "$f"; done | grep -v "$ACTIVE_LOG"`.
- For each remaining ndjson, classify: if it equals the active session log → "expected: active session"; otherwise run `jq -e . <ndjson> >/dev/null 2>&1` (exit 0 = well-formed) and classify as "anomaly: corrupt log" (nonzero exit) or "anomaly: unknown" (zero exit but scribe skipped it).
- Report each residual in the journal's ctrace section with its classification. A well-formed residual that scribe skipped warrants a note so `scribe backfill --verbose` can be investigated.

**Rollup step** (runs after a successful backfill OR when `N_missing == 0` and `scribe` is installed):
- Replace the hand-built "Cross-session aggregate" in the journal with `scribe rollup --since today --format md`. Pipe output directly into the journal section. If `scribe rollup` exits nonzero, fall back to the existing jq path (this degrades gracefully without failing the review).

**Escalation**: if any auto-fix condition fails, OR if the scope-check detects a write outside `~/.cache/ctrace/sessions/`, write to Pending: `ctrace scribe backfill: <which condition failed or scope-escape paths>; N_missing=N; run \`scribe backfill ~/.cache/ctrace/sessions\` manually to repair.`

### Playbook: `ctrace_sessionend_resolve`

**Trigger**: always runs after `ctrace_scribe_backfill` completes (whether it ran the backfill or found `N_missing == 0`). This is the verify-and-close step for the `ctrace-sessionend-flake` docket finding.

**Purpose**: distinguish "hook is doing its job" from "review's own backfill is doing the job". The key signal is `BACKFILL_RENDERED` — the count of logs the review's own backfill rendered this run (captured in the `ctrace_scribe_backfill` apply-log entry). If the hook wiring is live and working, `BACKFILL_RENDERED` trends to 0 (the SessionStart sweep already closed everything before the review ran). The playbook resolves the finding only when both the wiring is confirmed live **and** the review's backfill rendered nothing this run.

**Investigation (read-only)**:
1. **Check wiring**: grep `~/.claude/scripts/ctrace-session-start.sh` for an `orphan-reap` invocation and for a `scribe backfill` invocation:
   ```sh
   HOOK=~/.claude/scripts/ctrace-session-start.sh
   HAS_REAP=no
   HAS_BACKFILL=no
   if grep -q 'orphan-reap' "$HOOK" 2>/dev/null; then HAS_REAP=yes; fi
   if grep -qE 'scribe[[:space:]]backfill|"\$scribe"[[:space:]]backfill' "$HOOK" 2>/dev/null; then HAS_BACKFILL=yes; fi
   ```
2. **Read this run's backfill count**: from the most recent `"action":"ctrace_scribe_backfill"` apply-log entry, extract `"rendered"`. If the entry is absent or malformed, treat as `BACKFILL_RENDERED=unknown`.
   ```sh
   APPLY_LOG=~/brain/state/apply-log.jsonl
   BACKFILL_RENDERED=$(jq -s '[.[] | select(.action=="ctrace_scribe_backfill" and .rendered != null)] | last | .rendered // "unknown"' "$APPLY_LOG" 2>/dev/null || echo "unknown")
   ```
3. Log `"action":"investigate.ctrace_sessionend_resolve", "step":"observe"` to `apply-log.jsonl` with `has_reap`, `has_backfill`, `backfill_rendered`.

**Decision logic**:

- **Wiring absent** (`HAS_REAP=no` or `HAS_BACKFILL=no`): do NOT resolve. Record evidence `"wiring absent: reap=$HAS_REAP backfill=$HAS_BACKFILL"`. Log `"step":"skipped_wiring_absent"`. Leave the finding open for the next run.
- **Wiring present but backfill rendered >0** (`BACKFILL_RENDERED` is a number > 0): wiring is live but the hook didn't fully close the gap this run. Do NOT resolve. Log `"step":"skipped_hook_not_dominant"` with `"backfill_rendered": N`. Leave the finding open.
- **`BACKFILL_RENDERED=unknown`** (apply-log missing/malformed): cannot confirm the hook did the work. Do NOT resolve. Log `"step":"skipped_backfill_count_unknown"`. Leave the finding open.
- **Both conditions met** (`HAS_REAP=yes`, `HAS_BACKFILL=yes`, `BACKFILL_RENDERED == 0`): proceed to resolve.

**Resolve step** (only when both conditions met):
1. Build evidence string: `"wiring confirmed (orphan-reap+scribe backfill in ctrace-session-start.sh); review backfill rendered 0 this run — hook closed all gaps before review ran"`.
2. Run:
   ```sh
   docket resolve ctrace-sessionend-flake \
     --reason "wiring confirmed (orphan-reap+scribe backfill in ctrace-session-start.sh); review backfill rendered 0 this run"
   ```
3. Log `"step":"resolved"` with the evidence to `apply-log.jsonl`.
4. Note in the journal's ctrace section: `ctrace-sessionend-flake resolved: hook wiring confirmed + review backfill rendered 0`.

**Regression handling**: this playbook never re-resolves a finding that has already been resolved and stays resolved. If on a later run the review's backfill renders >0 again (regression), the existing `ctrace_scribe_backfill` playbook re-reports the finding via `docket report --key ctrace-sessionend-flake` and the streak restarts naturally. No additional code is needed here — the two playbooks self-heal in both directions.

**Constraint: read-mostly**. The only mutation this playbook performs is the conditional `docket resolve`. It never edits hook scripts, never renders summaries, and never runs `scribe` itself.

### Playbook: `build_stale_blockers`

**Trigger**: `~/.claude/skills/build/state/manifest.json` has at least one PRD entry whose `blockers[]` is non-empty (caught in Phase A).

**Investigation (read-only)**:
1. For each non-empty `blockers` list, classify each blocker string:
   - **version-collision**: matches `^v\d+\.\d+\.\d+ collision with [\w-]+`. The blocker names a peer slug and a target version both PRDs claim.
   - **other**: AC-dependency, missing primitive, anything else.
2. For each version-collision blocker, read both `PRD-<this-slug>.md` and `PRD-<other-slug>.md` under `~/wintermute/PRDs/`. Count phasing-header occurrences of the colliding version (regex `\*\*\s*\d+[a-z]?\s*\(\s*v<version>\s*\)`). If the sum across both PRDs is ≤ 1, the collision has been resolved in source (one PRD was rebased) and the blocker is stale.

**Auto-fix conditions (ALL must hold)**:
- The blocker matches the version-collision pattern.
- Both named PRDs exist on disk at `~/wintermute/PRDs/PRD-<slug>.md`.
- Phasing-header count for the colliding version totals ≤ 1 across both PRDs.
- `~/.claude/skills/build/state/tick.lock` is acquirable within 60 s (no /build tick in flight).

**Fix**: `~/.claude/skills/build/scripts/clear-stale-blockers.sh`. The script acquires the tick lock (60s wait), re-verifies all four conditions above, removes only the qualifying blocker entries, appends a `blockers_audit_log` record on each touched manifest entry, atomic-renames the manifest, and prints a JSON summary. Exit 0 = ran (possibly cleared nothing); exit 2 = no blockers to inspect; exit 1 = error. Capture the JSON stdout into apply-log.

**Escalation**: write to Pending one line per surfaced (non-cleared) blocker: `<slug>: <blocker> — verdict=<surfaced-non-version-collision|surfaced-still-colliding|surfaced-prd-missing>`. The non-version-collision case is the steady-state — AC-dependency blockers are legitimate and only humans should clear them. The still-colliding case means both PRDs still claim the same version and one needs a rebase. The PRD-missing case means a referenced PRD has vanished or moved; resolve by inspecting `git log -- PRD-*.md` in `~/wintermute/PRDs/`.

### Playbook: `warden_enforcer_inert`

**Trigger**: `WARDEN_LOADED` is `false` AND `~/.config/bpolicy/intentionally-unloaded` does NOT exist.

**Escalate-once pattern** (mirrors `memlog_group_awaiting_activation`): the inert state is unchanging across runs; re-emitting the same Pending paragraph every run is noise. This playbook writes a single durable record on first sighting, then emits only a one-token carry on subsequent runs until the state changes.

**Investigation (read-only)**:
1. Re-read `WARDEN_LOADED` from working memory (already captured in Phase A).
2. Compute the ack key (changes only when state changes):
   ```sh
   WARDEN_ACK_KEY="warden-enforcer-inert:loaded=false"
   WARDEN_ACK_FILE=~/.config/bpolicy/.selfreview-escalated
   if [ -f "$WARDEN_ACK_FILE" ] && [ "$(cat "$WARDEN_ACK_FILE" 2>/dev/null)" = "$WARDEN_ACK_KEY" ]; then
     WARDEN_ACK=yes
   else
     WARDEN_ACK=no
   fi
   ```
3. Log `"action":"investigate.warden_enforcer_inert", "step":"observe"` to `apply-log.jsonl` with `warden_loaded`, `ack_key`, `already_acked`.

**Auto-fix**: NONE. This playbook never loads, unloads, or enforces anything. Observe-and-record only.

**Suppression check**: if `~/.config/bpolicy/intentionally-unloaded` exists, the user has opted out. Emit nothing (not even the carry line) and log `"step":"suppressed_intentionally_unloaded"`. Stop.

**If `WARDEN_ACK=yes`** (already escalated, state unchanged): emit a single carry line in the Snapshot section —
`warden: not loaded (inert — escalated, see docket key warden-enforcer-inert or journal)` — and stop. Do **not** re-emit a full Pending paragraph. Log `"step":"skipped_already_acked"` to apply-log.

**If `WARDEN_ACK=no`** (first sighting — escalate exactly once):

Write **one** durable record. Prefer docket if available, else journal note:

```sh
# Preferred path — docket dedupes by design
if command -v docket >/dev/null 2>&1; then
  docket report --run "$DOCKET_RUNID" \
    --key warden-enforcer-inert \
    --title "bpolicy enforcer built and present but never armed this boot" \
    --evidence "journal:$(date +%F)"
  # Emit durable ledger ack; auto-clears if bpolicy becomes loaded.
  # Fingerprint = bpolicy loaded bool; ack clears when loaded→true.
  ~/.claude/skills/self-review/scripts/docket-ack-emit.sh \
    warden-enforcer-inert \
    "bpolicy never armed this boot; user explicitly parked via selfreview-escalated" \
    "bpolicy:false"
fi

# Always write a dated journal note (visible without docket)
cat >> /home/jsy/brain/journal/$(date +%F).md << 'EOF'

## warden (escalation — written once; see ~/.config/bpolicy/.selfreview-escalated)
- bpolicy is present at ~/.local/bin/bpolicy but reports {"loaded": false}.
- The enforcer has never been armed this boot. No writes are being blocked or audited.
- Arming requires: a warden-policy profile + warden-deadman safe-load (user decision).
- Explicit decision needed: arm on headless/sandboxed sessions? Leave off intentionally?
  - To suppress this escalation permanently: `touch ~/.config/bpolicy/intentionally-unloaded`
  - To arm (once warden-policy ships): `sudo bpolicy load --profile <name>`
- This note will not repeat unless state changes (loaded→unloaded) or the ack file is removed.
EOF
```

Then write the escalation fingerprint:
```sh
mkdir -p ~/.config/bpolicy
echo "$WARDEN_ACK_KEY" > ~/.config/bpolicy/.selfreview-escalated
```

Also write one Pending entry in the journal:
```
- warden: enforcer not loaded — bpolicy present but never armed this boot.
  Arming needs a warden-policy profile + warden-deadman safe-load (user decision).
  To suppress: `touch ~/.config/bpolicy/intentionally-unloaded`
  (This Pending item will not recur — escalated to journal ## warden + docket key warden-enforcer-inert.)
```

Log `"step":"escalated"` to apply-log with `ack_key`.

**State-change reset**: if `WARDEN_LOADED` is ever `true`, remove the ack file so a future return to inert re-escalates:
```sh
[ "$WARDEN_LOADED" = "true" ] && rm -f ~/.config/bpolicy/.selfreview-escalated
```
(This check runs on every pass regardless of current ack state.)

### Playbook: `fleet-binary-staleness`

**Trigger**: runs unconditionally each B.5 pass — this is a routine deterministic probe, not a signal-gated one. (The recurrence motivation: `agorabus` daemon staleness was hand-detected in self-review runs 16, 17, and 18 on 2026-05-28, the exact 3-run cadence that justifies a playbook.)

**Guard**: if `binstale` is not installed (`command -v binstale` returns non-zero), emit a single Snapshot line `binstale not yet installed — fleet staleness check skipped` and stop. No Pending item, no error. This makes the playbook safe to activate before PRD-binstale ships.

**Investigation (read-only)**:
1. `binstale scan --format json` — exit 0 means all tracked daemons are `fresh`; exit 1 means at least one is stale. Capture the full JSON output.
2. Parse each entry: extract `daemon`, `pid`, `verdict`, `exe_path`, `inode`, `prov_ts`, `source_head_commit` (fields per PRD-binstale's JSON shape; tolerate absent fields with jq `// "unknown"`).

**Auto-fix conditions**: NONE. Self-review **never** runs `rollout apply` autonomously — fleet restarts are user-visible disruptions (they drop every subscriber) and remain explicit human-approved actions. The pre-filled command below is for the human to run, not the skill.

**Precondition guard**: if `~/.config/rollout/fleet.toml` is absent, pre-fill `rollout fleet-gen` (review and accept) **before** the apply command — `rollout apply` will error without it.

**On exit 0 (all fresh)**: append one Snapshot line: `fleet-binary-staleness: all daemons fresh (binstale scan)`. No Pending item.

**On exit 1 (stale daemons)**: for each stale daemon, write a structured Pending entry:

```
- fleet-binary-staleness: <daemon> (pid <pid>) — verdict=<verdict>
  Evidence: exe=<exe_path> inode=<inode> prov_ts=<prov_ts> source=<source_head_commit>
  Pre-filled command (human-run, window-guarded): rollout apply --only <daemon> --window 30s
```

The `--window 30s` guard refuses to bounce a voice daemon mid-turn (rollout-window-guard-turnaware). Self-review never runs this command; it hands it to the human to run.

**Escalation**: if `binstale scan` exits with a code other than 0 or 1 (unexpected error), append to Pending: `binstale scan exited <code> — stderr: <first line of stderr>`. Do not treat this as stale.

### Playbook: `adopt_scan_probe`

**Trigger**: runs unconditionally each B.5 pass — routine deterministic probe, not signal-gated. Purpose: replace the hand-written "fleet-binary-staleness / binstale never installed" and "adopt/rollout never installed" prose that has recurred in Pending since 2026-06-08 with a mechanized scan.

**Guard**: if `adopt` is not on PATH (`command -v adopt` returns non-zero), emit a single Snapshot line and one Pending entry, then stop:

```sh
if ! command -v adopt >/dev/null 2>&1; then
  echo "adopt: not installed — adoption gap probe skipped"
  # Pending entry (printed into journal Pending section):
  echo "- adopt: binary not on PATH — run \`cargo install --path ~/wintermute/adopt --root ~/.local\` to install the adoption scanner (PRD-adopt-scan)"
fi
```

The probe must never abort the review — PATH-absent is the expected bootstrap state while PRD-adopt-scan is still shipping.

**Investigation (read-only)**:
1. `adopt scan --format json` — exit 0 means all tracked artifacts are `installed-current`; exit 1 means at least one is `not-installed` or `installed-stale`. Capture full JSON output.
2. Parse each entry: extract `artifact`, `verdict`, `installed_path`, `fix_cmd` (fields per PRD-adopt-scan's JSON shape; tolerate absent fields with jq `// "unknown"`).

```sh
ADOPT_JSON=$(adopt scan --format json 2>/dev/null)
ADOPT_EXIT=$?
```

**Auto-fix conditions**: NONE. This probe is **report-only** — it surfaces unadopted artifacts and pre-fills the install command, but never runs `adopt apply` or any install command autonomously. Mutation is explicitly delegated to `adopt apply`, which is gated on jsy's autonomy confirmation. This is the same escalate-don't-install discipline as `fleet-binary-staleness` / `rollout apply`.

**On exit 0 (all artifacts current)**: append one Snapshot line:
```
adopt: all artifacts current (adopt scan)
```
No Pending item. Log `"action":"investigate.adopt_scan_probe", "step":"observe", "verdict":"all_current"` to `apply-log.jsonl`.

**On exit 1 (unadopted artifacts)**: run `adopt report --run "$DOCKET_RUNID"` if `docket` is on PATH, so each unadopted artifact lands as an `adopt:<bin>` docket entry (streak + escalation handled by docket):

```sh
if command -v docket >/dev/null 2>&1; then
  adopt report --run "$DOCKET_RUNID" 2>/dev/null || true
fi
```

Then for each artifact where `verdict` is `not-installed` or `installed-stale`, write a structured Pending entry with the pre-filled fix command from the scan:

```
- adopt:<artifact> (verdict=<verdict>)
  <artifact> is not adopted to ~/.local — run: <fix_cmd from adopt scan JSON>
  (report-only; adopt apply --artifact <artifact> to install under jsy's autonomy gate)
```

The pre-filled `fix_cmd` replaces the hand-written "rollout plan needed / binstale never installed" prose that has recurred since 2026-06-08. Open `adopt:*` docket entries (from `docket list --open`) supersede hand-grepping journal prose for this class of finding.

Log `"action":"investigate.adopt_scan_probe", "step":"observe", "n_unadopted": N, "artifacts": [<names>]` to `apply-log.jsonl`.

**On unexpected exit code** (not 0 or 1): append to Pending:
```
- adopt: scan exited <code> — stderr: <first line>; investigate `adopt scan --format json` manually
```

**Escalation**: none beyond the Pending entries above. The probe is additive — it does not remove or weaken the existing `fleet-binary-staleness` probe or any other B.5 probe.

### Playbook: `reviewer_promotion_check`

**Cadence**: weekly — only run when today is Sunday (`date +%u` returns `7`). On any other weekday this playbook is inert; skip it without logging. (It reads a slow-moving calibration log; daily evaluation would just re-emit the same verdict.)

**Trigger** (all must hold, evaluated only on Sunday):
- `~/.claude/skills/autobuilder/state/reviewer-calibration.jsonl` exists and is non-empty.
- The autobuilder SKILL.md still declares the reviewer gate in its **current** phase below the latest already-promoted phase (i.e. there is a higher phase to promote to). Detect the current phase by grepping `~/.claude/skills/autobuilder/SKILL.md` for the marker line `**Phase A (current` / `**Phase B (current` — whichever `(current` marker is present is the active phase. If `Phase C` is already current, this playbook is inert (no higher phase).

**Investigation (read-only)**:
1. Count shipped lines: `jq -s '[.[] | select(.shipped==true)] | length' state/reviewer-calibration.jsonl`. Call it `n`.
2. Over the **last 30 shipped** lines, count those with `verdict=="concern"` whose `post_ship_revert==true`, and those with `verdict=="concern"` total. Compute `concern_to_revert_rate = concern_reverts / max(concern_total, 1)`. If `concern_total == 0` the rate is `0` by definition. Record `n`, `concern_total`, `concern_reverts`, and the rate to the apply-log diagnosis.
3. Determine the current active phase from the autobuilder SKILL.md marker (see Trigger). Record it.

**Auto-fix conditions** (ALL must hold to attempt a promotion edit):
- `n >= 30`. Below 30 there is not enough calibration data — log `step:diagnose` with `n=<X>, threshold=30, no_promotion` and stop (this satisfies the n<30 stub-fixture path: clean run, no edit).
- The target promotion is a strict forward step (A→B or A/B→C), never a downgrade.
- The autobuilder SKILL.md is writable AND `git -C ~/.claude/skills/autobuilder rev-parse --git-dir` succeeds (the edit is recorded as an `evolve:` commit per the autobuilder Stage 5 self-evolve mechanism).
- The most recent `investigate.reviewer_promotion_check` entry with `step:fix_attempted` in `apply-log.jsonl` is from a **different ISO week** than today, OR there is no prior entry. **Loop-breaker**: at most one promotion per calendar week, even across self-review runs.

**Fix** (pick exactly one target by rate, then perform a single in-place doctrine edit):
- If `n >= 30` AND `concern_to_revert_rate < 0.50` AND current phase is A → promote to **Phase B (soft-block)**: in `~/.claude/skills/autobuilder/SKILL.md`, move the `(current` marker from the Phase A bullet to the Phase B bullet (and update the Stage 4 receipt-table `reviewer-agent` cell's parenthetical to read `Phase B (current)`), so `concern` becomes a soft-block bypassable only by PRD frontmatter `reviewer_override: true` + `reviewer_override_reason:`. Commit in the autobuilder skill repo with the j0yen identity: `git -C ~/.claude/skills/autobuilder -c user.email=jyen.tech@gmail.com -c user.name="j0yen" commit -am "evolve: reviewer-agent concern → soft-block (n=N, rate=R)"`.
- If `n >= 30` AND `concern_to_revert_rate >= 0.50` AND current phase is A or B → promote to **Phase C (hard block)**: move the `(current` marker to the Phase C bullet (and update the receipt-table cell to `Phase C (current)`); `concern` becomes a hard block with no frontmatter override. Commit message: `evolve: reviewer-agent concern → hard-block (n=N, rate=R)`.

Use `~/.local/bin/txn-edit snap ~/.claude/skills/autobuilder/SKILL.md` before the edit and `txn-edit commit <id>` only after the marker move verifies (exactly one `(current` marker remains, on the new phase). On any inconsistency, `txn-edit rollback <id>` and log `step:fix_failed`. After the git commit, log `step:fix_verified` with the new phase and the commit sha. The `evolve:` git commit + apply-log entry are the durable record.

**Escalation**: if `n >= 30` but the autobuilder SKILL.md is not a git repo, or the `(current` marker is absent/ambiguous (zero or >1 matches), do NOT edit — write to Pending: `reviewer_promotion_check: n=N rate=R wants <phase>; blocked on <not-a-repo|ambiguous-marker>` so a human applies the phase edit deliberately. A miscalibrated auto-edit to the build system's own gate is worse than a one-week delay.

### Playbook: `litmus_audit`

**Trigger**: `LITMUS_COUNT > 0` (i.e. `docket stuck --format json` returned at least one probe-suspect finding in the `litmus:` banner step above). Runs after all other B.5 playbooks have had a chance to execute, so the audit targets only findings still open at that point.

**Purpose**: distinguish "the finding is genuinely world-stuck" from "the probe is lying." The `docket stuck` signal names findings that have been reported many times without resolving — the canonical symptom of a probe whose verdict cannot be trusted. This playbook audits each suspect finding by running its probe's self-test fixture (if one exists) and routes the result to the apply-log. It never resolves or acknowledges a finding on its own — resolution stays with the per-finding playbooks (e.g. `ctrace_sessionend_resolve`). Visibility is the deliverable.

**Guard**: if `docket` is absent or `LITMUS_COUNT == 0`, this playbook is inert. Skip without logging. If `docket stuck` exited nonzero for a reason other than "no findings," log `"action":"investigate.litmus_audit","step":"skipped_error"` and continue.

**Investigation (read-only)**:

For each key `K` in `LITMUS_JSON`:

1. Check whether a fixture script exists for this probe:
   ```sh
   FIXTURE=~/.claude/skills/self-review/scripts/litmus-probe-selftest.sh
   command -v "$FIXTURE" >/dev/null 2>&1 && FIXTURE_OK=yes || FIXTURE_OK=no
   # The fixture script accepts the probe key as its first argument.
   ```

2. **When a fixture exists** (`FIXTURE_OK=yes`):
   ```sh
   FIXTURE_OUT=$(bash "$FIXTURE" "$K" 2>&1)
   FIXTURE_EXIT=$?
   ```
   - **Exit 0 (PASS)** — the probe correctly classifies its own ground-truth fixture: the finding is genuinely world-stuck; the probe is not at fault.
     - Do **not** re-park, do not resolve. Leave the finding open for the appropriate per-finding playbook to handle.
     - Log to `apply-log.jsonl`:
       ```json
       {"action":"investigate.litmus_audit","step":"probe-verified","key":"<K>","result":"probe-verified","evidence":"fixture exit 0"}
       ```
     - Journal note in the ctrace / Notable section: `litmus: <K> — probe verified against fixture; finding is real; audit complete.`

   - **Exit non-zero (FAIL)** — the probe misclassifies its own fixture: the probe is suspect.
     - Do **not** re-park the finding (re-parking would let a lying probe park a real world-problem again). Do **not** call `docket resolve` or `docket ack`.
     - Log to `apply-log.jsonl`:
       ```json
       {"action":"investigate.litmus_audit","step":"probe-suspect","key":"<K>","result":"probe-suspect","evidence":"<first line of FIXTURE_OUT>"}
       ```
     - Write one Pending entry:
       ```
       - litmus: probe for <K> failed its self-test fixture — probe output: <FIXTURE_OUT first line>
         Finding is probe-suspect; do NOT re-park until probe is fixed.
         Next step: inspect ~/.claude/skills/self-review/scripts/litmus-probe-selftest.sh for <K> and correct the probe logic.
       ```

3. **When no fixture exists** (`FIXTURE_OK=no` or the fixture script does not handle key `K`):
   - Log to `apply-log.jsonl`:
     ```json
     {"action":"investigate.litmus_audit","step":"no-fixture","key":"<K>","result":"no-fixture"}
     ```
   - Add to Pending:
     ```
     - litmus: <K> has no self-test fixture — add a fixture entry to litmus-probe-selftest.sh (see PRD-litmus-probe-fixtures).
     ```
   - Capture the fixture-build item in working memory so Phase E can include it in the litmus summary.

**Constraint: no auto-resolution, no ack.** `litmus_audit` never calls `docket resolve` or `docket ack`. Only the dedicated per-finding playbook (e.g. `ctrace_sessionend_resolve`) may resolve a finding; litmus only re-routes attention.

**Worked example — ctrace false-negative**: had this playbook been active during the 10-run ctrace saga, `docket stuck` would have surfaced `ctrace-sessionend-flake` by run ~5–6 (after the streak crossed the stuck threshold). The fixture audit would then have run `litmus-probe-selftest.sh ctrace-sessionend-flake`, which would have executed the probe's grep against a known-wired hook file. The grep false-negative (the probe returned "wiring absent" when the wiring was present) would have caused a fixture FAIL, surfacing `probe-suspect` to Pending by run 6 rather than at run 10. The user would have inspected the probe's grep pattern three or four runs earlier, found the mismatch, and the ctrace finding would have been resolved rather than re-parked.

### Adding new playbooks

A new playbook is justified when a finding appears in `docket list --escalated`
(if docket is installed and the finding has been reported under a stable key for
3+ consecutive runs). If docket is not yet installed, fall back to the prior
heuristic: signal recurs in `recall query 'self-review'` results across **3+
separate runs** (typically days, but consecutive within-day loop iterations also
count). The docket escalation is mechanically determined; the recall heuristic
is manual. Prefer `docket list --escalated` once the ledger is populated.

Each new playbook must specify, in this order: **deterministic trigger**,
**read-only investigation steps**, an **explicit AND-list of auto-fix
conditions** (including a cooldown loop-breaker), a **single fix command** (or
NONE), and an **escalation path**. Playbooks that require user judgment —
process kills, package downgrades, memory pruning, settings.json edits, hook
script modifications — are forbidden and must remain in Pending, routed through
the existing escalation paths (`Skill(update-config)`,
`Skill(fewer-permission-prompts)`, or human review).

## Phase C — Plan (checkpoint)

Write a one-line-per-action plan to `/home/jsy/brain/state/today-plan.txt` summarizing what you're about to auto-apply. Format:

```
2026-MM-DD HH:MM
- prune <N> session JSONLs (<bytes> total)
- archive <N> stale plans
- npm update -g (<N> packages)
- investigate.ctrace_tracer_down → fix: sudo ctrace start --root <pid>
- ...
```

Include both originally-auto-apply items and any Phase B.5 playbook-promoted fixes. This is a checkpoint: if you are interrupted, the next run can read this and know what was planned.

## Phase D — Apply

Execute auto-apply actions in this order. After each, append one JSON object to `/home/jsy/brain/state/apply-log.jsonl`:

```json
{"ts":"2026-MM-DDTHH:MM:SS","action":"prune_session_jsonls","count":12,"bytes_freed":4567890,"result":"ok"}
```

Order:
1. Prune old session JSONLs.
2. Prune old shell-snapshots & session-env.
3. Prune old ctrace ndjson logs.
4. Reap stale ctrace tracer (`ctrace stop`) if Phase A flagged one >24h old.
5. `pevent gc --older-than 7` if Phase A surfaced exited records that old.
6. Archive stale plan files.
7. Sync MEMORY.md indexes — **wrap in `txn-edit`** so the edit is reversible:
   - `~/.local/bin/txn-edit snap <all MEMORY.md files about to be touched>` → returns a txn id.
   - Apply the edits (append orphans, remove missing).
   - `~/.local/bin/txn-edit commit <id>` once the writes are verified consistent.
   - On any error mid-edit, `~/.local/bin/txn-edit rollback <id>` and log the apply-log entry with `"result":"rolled_back"`.
   - Record the txn id in apply-log so a post-hoc rollback is still possible.
8. `recall reindex` if the index was out of sync with files on disk.
9. Run `npm update -g` if applicable.
10. Run `pipx upgrade-all` if applicable.
11. Run `sudo pacman -Syu --noconfirm` only if the guardrails above permit.
12. Invoke `Skill(fewer-permission-prompts)` if the special case was hit.
13. Clear stale /build blockers if Phase B.5 `build_stale_blockers` promoted to auto-fix: run `~/.claude/skills/build/scripts/clear-stale-blockers.sh`, capture stdout, append one apply-log entry with `"action":"clear_build_blockers"` and the JSON summary inlined. Exit code 2 (no blockers) is `"result":"noop"`, exit 0 is `"result":"ok"` (record `cleared_count` and `surfaced_count`), exit 1 is `"result":"error"`.
14. Execute the ctrace backfill if Phase B.5 `ctrace_scribe_backfill` promoted it to auto-fix (all conditions met, `scribe` installed, `N_missing > 0`). Run the wchg-scoped `scribe backfill ~/.cache/ctrace/sessions`, verify scope, run the residual check, then run `scribe rollup --since today --format md` and capture output for Phase E. Append apply-log entry with `"action":"ctrace_scribe_backfill"` and rendered/skipped/residual counts. On failure, log `"result":"error"` and continue.
15. Run Phase B.5 `ctrace_sessionend_resolve` (always, immediately after step 14). Check hook wiring and backfill-rendered count; conditionally run `docket resolve ctrace-sessionend-flake` per the playbook logic. Append apply-log entry with `"action":"ctrace_sessionend_resolve"` and the step outcome (`resolved` / `skipped_wiring_absent` / `skipped_hook_not_dominant` / `skipped_backfill_count_unknown`). On failure, log `"result":"error"` and continue.
16. `wchg reset ~/.claude` and `wchg reset /home/jsy/brain` so tomorrow's delta is clean. If a path was newly `wchg watch`-ed in Phase A (first run on this laptop), the reset is a no-op — skip it. Subsequent runs always reset.

If any step fails, log `"result":"error"` with `"error":"<message>"` and continue. Do not abort the run.

## Phase E — Journal & persist reflection

Write `/home/jsy/brain/journal/YYYY-MM-DD.md` with this structure:

```markdown
# Self-review — YYYY-MM-DD

## Carried forward from prior reflections
- <one bullet per Phase 0 recall hit still relevant; mark "resolved" / "still open" inline>

## Snapshot
- Disk: <used>/<total> (<pct>%)
- RAM: <used>/<total>
- ~/.claude: <size> (Δ vs last run) · <N> files changed since last run (from `wchg since`)
- /home/jsy/brain: <size> (Δ) · <N> files changed
- Active Claude processes: <count> · top RSS <pid>=<MB> (from `procstat snap`)

## Applied
- <one bullet per auto-applied action with measurable effect>
- For each `txn-edit`-wrapped change: include the txn id so rollback is one command away.

## Pending your call
- <recommendations needing user input>

## Claude session activity (today)
- <one bullet per today's ctrace session summary: duration · top binary · any flagged/out-of-scope writes>
- **Cross-session aggregate** (prefer `scribe rollup --since today --format md` output here if scribe is installed; fall back to jq hand-build if absent):
  - Top write-path prefixes today: <three to five lines>
  - Top executed binaries today: <three to five lines>
  - Outbound destinations: <summary>
  - Deletions: <summary or "none">
- **ctrace backfill** (if `scribe` installed and B.5 ran): `rendered N, skipped M, residual R` — list any residual ndjsons with their classification (expected: active session / anomaly: corrupt log / anomaly: unknown).
- If any session had ⚠ flagged sensitive-path writes, quote them verbatim.
- If a stale tracer was reaped, note its `started_at` and how long it had been leaked.
- If `~/.cache/ctrace/claude-start.err` is non-empty, quote the latest line.
- If any today's ndjson is still missing its `.summary.md` after backfill (or scribe absent), list them with the reason flagged by B.5.

## Memory & recall health
- MEMORY.md indexes: <synced / synced after N edits / failed>
- `recall` index: <in sync / reindexed> · total memories: <N> · subjects: <top 3 by count>
- Stale never-recalled (>30d, `recalls=0`): <count> — see "Pending your call" if any.

## Notable
- <anything surprising — large unexpected growth, repeated errors in sessions, etc.>

## Litmus
- <LITMUS_BANNER line from B.5 (e.g. `litmus: clean` or `litmus: 2 probe-suspect finding(s): ctrace-sessionend-flake, memlog-active`)>
- <one bullet per finding audited this run: `<key>: probe-verified / probe-suspect / no-fixture — <evidence>`>
```

Then **persist a reflective memory** so the next pass inherits this run's findings:

```sh
~/.local/bin/recall write --kind reflective --subject self --body "$(cat <<EOF
Self-review YYYY-MM-DD: <one-sentence headline of what mattered>.

Applied: <terse list>.
Pending: <terse list of items that need user input — these are the things future runs should check on>.
Notable: <one or two non-obvious observations from today, e.g., "ctrace showed 3× the usual write volume into ~/.claude/projects/ — investigate if it continues">.
EOF
)"
```

Keep the body tight (≤ 15 lines). The journal is the human-readable record; this recall entry is the agent-queryable summary. Future runs hit this via `recall query 'self-review …'` in Phase 0 — so the *Pending* line is the most important part to write well.

**Docket integration (after the reflective memory is written):** if `docket` is
on PATH, do the following in order:

1. **Report still-open findings.** For each finding from `docket list --open`
   that was still observed this run, AND for each new finding surfaced in this
   run's journal (Pending items with a stable-key match — see Appendix:
   Stable-key convention below), run:
   ```sh
   docket report --run "$DOCKET_RUNID" \
     --key <stable-slug> \
     --title "<one-liner description>" \
     [--evidence journal:YYYY-MM-DD] \
     [--evidence recall:<ulid-of-the-memory-just-written>]
   ```
   Reporting the same finding twice in one run is idempotent (safe to repeat).
   Use the stable-key convention from the Appendix; create a new kebab-case key
   for genuinely new standing findings.

2. **Back-link the recall ULID.** Capture the ULID returned by the `recall
   write` call above (it appears on stdout). If the ULID is available, run a
   follow-up `docket report ... --evidence recall:<ulid>` for each finding
   reported in step 1. This links the structured ledger entry to the prose
   memory.

3. **Sweep.** After reporting, run:
   ```sh
   docket sweep --run "$DOCKET_RUNID"
   ```
   This ages findings that were NOT reported this run toward auto-close, so
   the ledger converges on the real open-item set over time. `sweep` is
   non-destructive — it does not delete findings, only advances their age
   counter.

4. **Emit acks for acknowledged findings.** Certain standing findings are
   "acked" — the user has made a deliberate decision to park them until a
   concrete state change occurs (e.g. a pkgrel upgrade, bpolicy being armed).
   The B.5 playbooks for `memlog_group_awaiting_activation` and
   `warden_enforcer_inert` each call
   `~/.claude/skills/self-review/scripts/docket-ack-emit.sh` immediately
   after their `docket report`, passing:
   - the finding key,
   - a short reason string, and
   - an `--until-change` fingerprint (e.g. `pkgrel:5`, `bpolicy:false`).

   The helper emits `docket ack <key> --reason <reason> --until-change <fp>`.
   When docket's `abide-ack-state` extension is installed, this call lands
   a durable ledger entry so the finding drops out of `docket digest` (no
   `--include-acked`) and the banner goes quiet. If the fingerprint changes
   on a subsequent run (e.g. pkgrel was upgraded), docket auto-clears the
   ack and the finding resurfaces in the digest — the next self-review then
   surfaces it under "Pending your call" again, correctly.

   **Fail-open contract**: `docket-ack-emit.sh` always exits 0. If `docket`
   is absent or the `ack` subcommand is not yet available (i.e.,
   `abide-ack-state` has not shipped), it prints the would-be command and
   continues. Never block the review on a missing ack capability.

   Re-running the review re-acks with the same fingerprint, which is
   idempotent in docket (a no-op if the ack already exists unchanged).

If `docket` is absent on PATH, skip all three steps. No error, no blocker.

Then:
- Write today's date (YYYY-MM-DD) to `/home/jsy/brain/state/last-run.txt`.
- `rm -f /home/jsy/brain/state/review-due` to clear the timer's marker.
- `rm -f /home/jsy/brain/state/today-plan.txt` to clear the checkpoint.

Finally, output a 2-3 sentence summary to the user: what was applied, what's pending, and a link to the journal file.

---

## Guardrails — these are absolute, even under "full autonomy"

These exist because "full autonomy" is bounded autonomy. A future invocation of this skill that talks itself out of any of these is doing something wrong.

1. **Never `rm` outside these paths**: `~/.claude/shell-snapshots/`, `~/.claude/session-env/`, `~/.claude/projects/*/[0-9a-f]*-*.jsonl`, `~/.claude/backups/` (files older than 30d), `/home/jsy/.cache/ctrace/sessions/claude-*.ndjson` (files older than 30d — **never** delete `.summary.md` siblings), `/home/jsy/brain/state/{review-due,today-plan.txt}`. Plan files go to **archive**, not deletion.
2. **Never kill a process.** Duplicate Claude PIDs go in "Pending your call." The user decides. The single exception is `ctrace stop` against a leaked tracer where `status.running == true` AND `started_at > 24h`; that's reaping infrastructure, not killing a user session.
3. **Never edit `~/.claude/settings.json` directly.** Always go through `Skill(update-config)`.
4. **Never auto-install plugins.** Recommendations only.
5. **Never `pacman -Syu` when the queue contains `linux`, `glibc`, `systemd`, `nvidia`, or `mesa`** (substring match on the package name column). Kernel/init/driver updates can require reboot or break boot — they belong to the user.
6. **Never delete files in `/home/jsy/brain/`** other than the explicitly transient state files listed above (`review-due`, `today-plan.txt`). Journal entries and archived plans accumulate forever.
7. **Never `recall delete`.** The recall store is the user's long-term memory; pruning is theirs alone. Surface stale/never-recalled entries in "Pending your call," nothing more.
8. **All MEMORY.md mutations go through `txn-edit`.** Snap before, commit after, rollback on error. Direct rewrites are forbidden because a stray edit can silently delete a memory pointer.
9. **If Phase A network check fails**, stop after Phase A and journal that fact. Don't try to update packages with no connectivity.
10. **If `/home/jsy/brain/state/today-plan.txt` already exists at the start of a run**, the previous run was interrupted. Read it, journal that, then continue normally — the plan file is informational, not authoritative.

---

## Appendix: Stable-key convention (docket integration)

Docket finding keys must be **kebab-case** and **run-durable** — they identify
the *class* of problem, not a specific instance. A key must not embed dates,
PIDs, or other ephemeral values. Creating a key is a one-time act; the same key
is used every run that observes the problem.

### Seeded keys for known standing findings

| Key | Title | Notes |
|-----|-------|-------|
| `agorabus-stale-binary` | agorabus daemon binary is stale vs source | binstale or manual comparison shows running binary predates latest build |
| `agentns-session-zeros` | agentns session counter stuck at zero | `cat /proc/agentns/sessions` returns 0 despite active Claude PIDs |
| `ctrace-sessionend-flake` | ctrace session-end event missing | ctrace ndjson lacks session-end record; tracer may have leaked |
| `wm-anthropic-key-empty` | WM_ANTHROPIC_KEY / API key is empty or missing | brain's wmd tier-ladder cannot reach cloud models |
| `warden-enforcer-inert` | bpolicy enforcer built and present but never armed | `bpolicy status` → `{"loaded": false}`; escalate once, carry forward until armed or opt-out |

### Reporting guidance

When surfacing a Pending item that matches one of the seeded keys, report it to
docket using that key. For new standing findings discovered during a run, invent
a new kebab-case key that is descriptive and stable (e.g. `firefox-cache-runaway`,
`recall-index-desync`). Document the new key in a recall memory or journal note
so future runs can reuse it.

### Carried-forward list source of truth

The **journal's "Carried forward from prior reflections"** section is now
ledger-backed: source the list from `docket list --open` (loaded in Phase 0)
rather than re-reading journal prose. For each item, note its docket key and
report count. Items still observed this run are re-reported (see Phase E);
items no longer observed are swept. The hand-maintained prose section in the
journal is supplemented by, not replaced by, the docket output — both appear
in the journal for human readability.

---

## Future work (intentionally not wired up)

- `bpolicy enforce` against the self-review's own write surface would turn guardrails #1, #6, #8 from prose into kernel-level enforcement. The Phase A `bpolicy status` check is read-only — we observe the policy state but don't drive it. Wiring enforcement requires enumerating the write surface of `update-config` and `fewer-permission-prompts` first; once those are documented, a `bpolicy load` of a self-review-scoped policy becomes a pre-Phase-D wrapper.
- `sbx` would be the natural way to run third-party update commands (`npm`, `pipx`, `pacman -Qu`) in a network-scoped sandbox. Not needed today since all of those are trusted package managers; reconsider if the skill ever pulls less-trusted scripts.
- `pevent run` could background `pacman -Qu` (cold-cache slow) so it runs in parallel with the other Phase A checks. Overkill for now — the whole pass is sub-30s. (Note: `pevent list`/`gc` ARE wired in Phase A and Phase D; only the `run` direction is deferred.)
