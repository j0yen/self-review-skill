#!/usr/bin/env bash
# docket-ack-emit.sh — emit a docket ack for an acknowledged finding.
#
# Usage:
#   docket-ack-emit.sh <key> <reason> <fingerprint>
#
# Arguments:
#   key         — docket finding key (kebab-case, e.g. memlog-activation)
#   reason      — short prose explaining why this is acked (no newlines)
#   fingerprint — until-change sentinel; when docket sees a different value
#                 on the next report, the ack is cleared and the finding
#                 resurfaces (e.g. "pkgrel:5", "bpolicy:false")
#
# Behaviour:
#   - If `docket` is on PATH and supports the `ack` subcommand:
#       docket ack "$key" --reason "$reason" --until-change "$fingerprint"
#   - If `docket` is absent, or `ack` is not yet a subcommand (abide-ack-state
#     not yet shipped), print the would-be command and exit 0. Never block the
#     review (fail-open discipline per self_build_jq_escape_reads_absent /
#     self_delegate_run_300s_cap notes).
#   - All errors are non-fatal: the helper always exits 0.
#
# Idempotent: re-acking with the same fingerprint is a no-op in docket.
# If the fingerprint changes between runs, docket auto-clears the ack and the
# finding resurfaces in `docket list --open` / `docket digest`.
#
# This script is sourced or called directly by the review's docket-bind step.
# The current DOCKET_RUNID need not be set here — ack is a standalone ledger
# operation, separate from the per-run report/sweep cycle.

set -uo pipefail

# --- argument validation ---
if [[ $# -ne 3 ]]; then
    printf 'usage: docket-ack-emit.sh <key> <reason> <fingerprint>\n' >&2
    exit 0  # fail-open
fi

KEY="$1"
REASON="$2"
FINGERPRINT="$3"

if [[ -z "$KEY" || -z "$REASON" || -z "$FINGERPRINT" ]]; then
    printf 'docket-ack-emit: empty argument (key=%q reason=%q fp=%q) — skipping\n' \
        "$KEY" "$REASON" "$FINGERPRINT" >&2
    exit 0  # fail-open
fi

# --- docket presence check ---
if ! command -v docket >/dev/null 2>&1; then
    printf 'docket-ack-emit: docket not on PATH — would-be: docket ack %q --reason %q --until-change %q\n' \
        "$KEY" "$REASON" "$FINGERPRINT"
    exit 0
fi

# --- ack subcommand availability check ---
# abide-ack-state may not be shipped yet; probe via `docket help` output.
if ! docket help 2>&1 | grep -qw '^  ack\b'; then
    # Check the full help output more permissively
    if ! docket --help 2>&1 | grep -qE '^\s+ack\b'; then
        printf 'docket-ack-emit: docket ack subcommand not available (abide-ack-state pending) — would-be: docket ack %q --reason %q --until-change %q\n' \
            "$KEY" "$REASON" "$FINGERPRINT"
        exit 0
    fi
fi

# --- emit the ack ---
if docket ack "$KEY" --reason "$REASON" --until-change "$FINGERPRINT" 2>/dev/null; then
    printf 'docket-ack-emit: acked %s (until-change=%s)\n' "$KEY" "$FINGERPRINT"
else
    # Non-zero exit from docket ack — still fail-open
    printf 'docket-ack-emit: docket ack %q exited non-zero — would-be: docket ack %q --reason %q --until-change %q\n' \
        "$KEY" "$KEY" "$REASON" "$FINGERPRINT" >&2
fi
exit 0
