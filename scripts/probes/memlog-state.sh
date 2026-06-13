#!/bin/sh
# memlog-state.sh — probe snippet: classify memlog activation state.
#
# Input variables (override for testing):
#   PROBE_MEMLOG_GROUP_CMD  — command to test group existence (default: getent group memlog)
#   PROBE_DEV_MEMLOG        — path to /dev/memlog substitute (default: /dev/memlog)
#   PROBE_STAGED_PKGREL     — override STAGED_PKGREL directly (skip pkg scan)
#   PROBE_INST_PKGREL       — override INST_PKGREL directly (skip pacman -Q)
#   PROBE_USER_GROUPS       — space-separated group list for membership check (default: run id -nG)
#
# Output variable set in caller's environment (source this file):
#   MEMLOG_STATE — one of: active | staged-awaiting-install | installed-awaiting-relogin |
#                          unstaged | staged-awaiting-install(pkgrel-N)

# Probe 1: group present?
if [ -n "${PROBE_MEMLOG_GROUP_CMD+x}" ]; then
    eval "$PROBE_MEMLOG_GROUP_CMD" >/dev/null 2>&1 && MEMLOG_GROUP=yes || MEMLOG_GROUP=no
else
    getent group memlog >/dev/null 2>&1 && MEMLOG_GROUP=yes || MEMLOG_GROUP=no
fi

# Probe 2: device group = memlog?
_dev="${PROBE_DEV_MEMLOG:-/dev/memlog}"
MEMLOG_DEV_GROUP=$(stat -c '%G' "$_dev" 2>/dev/null || echo unknown)

# Probe 3: current user a member?
if [ -n "${PROBE_USER_GROUPS+x}" ]; then
    echo "$PROBE_USER_GROUPS" | tr ' ' '\n' | grep -qx memlog && MEMLOG_MEMBER=yes || MEMLOG_MEMBER=no
else
    MEMLOG_MEMBER=$(id -nG 2>/dev/null | tr ' ' '\n' | grep -qx memlog && echo yes || echo no)
fi

# Probe 4: pkgrel comparison (overridable for fixtures)
if [ -n "${PROBE_INST_PKGREL+x}" ]; then
    INST_PKGREL="$PROBE_INST_PKGREL"
else
    INST_PKGREL=$(pacman -Q linux-wintermute 2>/dev/null | grep -oE '[0-9]+$')
fi

if [ -n "${PROBE_STAGED_PKGREL+x}" ]; then
    STAGED_PKGREL="$PROBE_STAGED_PKGREL"
else
    STAGED_PKGREL=$(
        for f in "$HOME"/wintermute/wintermute-kernel/pkg/linux-wintermute-*-x86_64.pkg.tar.zst; do
            pr=$(basename "$f" | sed -n 's/.*arch1-\([0-9][0-9]*\)-x86_64.*/\1/p')
            [ -n "$pr" ] && bsdtar -tf "$f" 2>/dev/null | grep -q 'sysusers.d.*memlog' && echo "$pr"
        done | sort -n | tail -1
    )
fi

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
