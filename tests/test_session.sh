#!/usr/bin/env bash
# Unit tests for where the state store lives: one per herdr session.
#
# herdr numbers every session's tabs from w1:t1, so two servers on one state
# file were each other's corruption. Each full pass prunes the tab ids it did not
# see, which in another session's store is every tab there, and a tab whose
# record is gone reads as renamed by hand on the next pass and opts out for good.
# The socket path is the one variable both the herdr-invoked pass and the shell
# hooks receive, and a named session keeps its socket under `sessions/NAME/`.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-session.XXXXXX")
export XDG_STATE_HOME="$SB/xdg"
ENGINE="$here/../automatic-rename.sh"
LEGACY="$XDG_STATE_HOME/herdr-automatic-rename"

# state_dir_for <socket path or empty> -> the STATE_DIR the engine resolves.
# A fresh bash per case, so the socket path of one never leaks into the next.
state_dir_for() {
  # shellcheck disable=SC2016  # the $STATE_DIR is the child bash's, read after it sourced the engine
  env -u HERDR_SOCKET_PATH ${1:+HERDR_SOCKET_PATH="$1"} \
    bash -c '. "$1"; printf %s "$STATE_DIR"' _ "$ENGINE"
}

# ---- resolution ----
check "no socket path: the store stays where it was" \
  "$LEGACY" "$(state_dir_for "")"
check "default session: socket beside config, store unchanged" \
  "$LEGACY" "$(state_dir_for "$SB/config/herdr/herdr.sock")"
check "named session: its own store under sessions/" \
  "$LEGACY/sessions/work" "$(state_dir_for "$SB/config/herdr/sessions/work/herdr.sock")"
check "another named session: another store" \
  "$LEGACY/sessions/home" "$(state_dir_for "$SB/config/herdr/sessions/home/herdr.sock")"
# A directory merely called sessions is not a session inside it.
check "a socket directly under sessions/ is not a session" \
  "$LEGACY" "$(state_dir_for "$SB/config/herdr/sessions/herdr.sock")"
# The lock and the rerun flag follow the store, or two sessions would still
# refuse each other's passes.
check "the lock follows the store" \
  "$LEGACY/sessions/work/lock" \
  "$(HERDR_SOCKET_PATH="$SB/config/herdr/sessions/work/herdr.sock" \
       bash -c '. "$1"; printf %s "$LOCK_DIR"' _ "$ENGINE")"

# ---- the regression: one session's prune leaves the other's records alone ----
# Session work names w1:t1 and records it. Session home then runs a pass that sees
# only its own w1:t1, which is a different tab, and prunes everything else. The
# record work wrote has to survive, or work's next pass finds an owned tab with no
# record, reads its label as typed by hand, and stops naming it.
in_session() { # <name> <commands...>
  local name=$1; shift
  HERDR_SOCKET_PATH="$SB/config/herdr/sessions/$name/herdr.sock" \
    bash -c '. "$1"; mkdir -p "$STATE_DIR"; eval "$2"' _ "$ENGINE" "$*"
}
in_session work 'ar_state_set w1:t1 nvim true'
in_session home 'ar_state_set w1:t1 claude true; ar_state_prune w1:t1'
check "work keeps its record after home prunes" \
  "nvim" "$(in_session work 'ar_state_get w1:t1 auto')"
check "home sees only its own tab" \
  "claude" "$(in_session home 'ar_state_get w1:t1 auto')"
in_session home 'ar_state_prune w9:t9'
check "home pruning every tab it knows still leaves work alone" \
  "nvim" "$(in_session work 'ar_state_get w1:t1 auto')"
check "and work still owns it" \
  "0" "$(in_session work 'ar_name_eligible w1:t1 nvim; echo $?')"

rm -rf "$SB" 2>/dev/null || true
t_summary
