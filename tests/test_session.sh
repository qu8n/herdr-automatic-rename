#!/usr/bin/env bash
# Unit tests for where the state store lives: one per herdr session, resolved
# the way the herdr CLI picks its server (docs/ARCHITECTURE.md, "Why config and
# state sit at fixed paths"), and seeded once from the shared store it replaces.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-session.XXXXXX")
export XDG_STATE_HOME="$SB/xdg"
export XDG_CONFIG_HOME="$SB/config"
# The runner's own pane would otherwise name a session for every case below.
unset HERDR_SOCKET_PATH HERDR_SESSION
ENGINE="$here/../automatic-rename.sh"
LEGACY="$XDG_STATE_HOME/herdr-automatic-rename"
CFG="$SB/config/herdr"

# in_env <socket path> <session name> <command string> -> runs the command in a
# fresh bash that sourced the engine under exactly those two variables (an
# empty value is what an unset one resolves to). One process per case, so no
# case sees another's resolution.
in_env() {
  HERDR_SOCKET_PATH="$1" HERDR_SESSION="$2" \
    bash -c '. "$1"; mkdir -p "$STATE_DIR"; eval "$2"' _ "$ENGINE" "$3"
}
# resolve <socket path> <session name> <VAR> -> that engine variable's value.
resolve() { in_env "$1" "$2" "printf %s \"\$$3\""; }
state_dir_for() { resolve "$1" "${2:-}" STATE_DIR; }

# ---- resolution off the socket path ----
check "no socket path: the store stays where it was" \
  "$LEGACY" "$(state_dir_for "")"
check "default session: socket beside config, store unchanged" \
  "$LEGACY" "$(state_dir_for "$CFG/herdr.sock")"
check "named session: its own store under sessions/" \
  "$LEGACY/sessions/work" "$(state_dir_for "$CFG/sessions/work/herdr.sock")"
check "another named session: another store" \
  "$LEGACY/sessions/home" "$(state_dir_for "$CFG/sessions/home/herdr.sock")"
check "a socket directly under sessions/ is not a session" \
  "$LEGACY" "$(state_dir_for "$CFG/sessions/herdr.sock")"
check "a relative path with no parent is not a session" \
  "$LEGACY" "$(state_dir_for "sessions/herdr.sock")"
check "a doubled slash names no session" \
  "$LEGACY" "$(state_dir_for "$CFG/sessions//herdr.sock")"
check "a dot segment cannot alias the store" \
  "$LEGACY" "$(state_dir_for "$CFG/sessions/./herdr.sock")"
check "nor a dot-dot segment" \
  "$LEGACY" "$(state_dir_for "$CFG/sessions/../herdr.sock")"

# ---- resolution off the session name ----
check "a session name alone names the store" \
  "$LEGACY/sessions/work" "$(state_dir_for "" work)"
check "the default session's name is the root store" \
  "$LEGACY" "$(state_dir_for "" default)"
check "the socket path wins over the name, as it does for the CLI" \
  "$LEGACY/sessions/home" "$(state_dir_for "$CFG/sessions/home/herdr.sock" work)"
check "a default-shaped socket is not overridden by the name" \
  "$LEGACY" "$(state_dir_for "$CFG/herdr.sock" work)"

# The files the engine reads beside the socket follow the same rule, or a hand
# run with only the name set would talk to one server and read another's
# session.json.
check "the session dir follows the socket path" \
  "$CFG/sessions/home" "$(in_env "$CFG/sessions/home/herdr.sock" work 'ar_herdr_session_dir')"
check "and the name when there is no socket path" \
  "$CFG/sessions/work" "$(in_env "" work 'ar_herdr_session_dir')"
check "and the default session's name means the config dir" \
  "$CFG" "$(in_env "" default 'ar_herdr_session_dir')"

# The lock and the rerun flag follow the store, or two sessions would still
# refuse each other's passes and raise each other's flags.
check "the lock follows the store" \
  "$LEGACY/sessions/work/lock" \
  "$(resolve "$CFG/sessions/work/herdr.sock" "" LOCK_DIR)"
check "so does the rerun flag" \
  "$LEGACY/sessions/work/rerun" \
  "$(resolve "$CFG/sessions/work/herdr.sock" "" RERUN_FLAG)"

# ---- the regression: one session's prune leaves the other's records alone ----
# Session work names w1:t1 and records it. Session home then runs a pass that
# sees only its own w1:t1, a different tab, and prunes everything else. The
# record work wrote has to survive, or work's next pass finds an owned tab with
# no record, reads its label as typed by hand, and stops naming it.
in_session() { in_env "$CFG/sessions/$1/herdr.sock" "" "$2"; }
in_session work 'ar_state_set w1:t1 nvim true'
in_session home 'ar_state_set w1:t1 claude true; ar_state_prune w1:t1'
check "work keeps its record after home prunes" \
  "nvim" "$(in_session work 'ar_state_get w1:t1 auto')"
check "home sees only its own tab" \
  "claude" "$(in_session home 'ar_state_get w1:t1 auto')"
in_session home 'ar_state_prune w9:t9'
check "home pruning every tab it knows still leaves work alone" \
  "nvim" "$(in_session work 'ar_state_get w1:t1 auto')"
check_rc "and work still owns it" 0 \
  "$(in_session work 'ar_name_eligible w1:t1 nvim; echo $?')"

# ---- seeding: a session's first store starts from the shared one ----
# An empty store reads every label as typed by hand and opts the tab out, so
# an upgrade would freeze every tab a named session already had named. The
# shared store's owned records come across; opted-out ones do not, so a tab at
# a placeholder label is adopted as it would be from nothing.
rm -rf "$LEGACY"
mkdir -p "$LEGACY"
printf '{"w1:t1":{"auto":"nvim","enabled":true},"w1:t2":{"auto":"","enabled":false},"ws:w1":{"auto":"proj","enabled":true}}' \
  >"$LEGACY/state.json"
in_session work 'ar_state_seed'
check "an owned tab record is seeded"        "nvim" "$(in_session work 'ar_state_get w1:t1 auto')"
check "and so is an owned workspace record"  "proj" "$(in_session work 'ar_state_get ws:w1 auto')"
check "an opted-out record is not"           ""     "$(in_session work 'ar_state_get w1:t2 enabled')"
check_rc "so the seeded tab is still owned"  0 \
  "$(in_session work 'ar_name_eligible w1:t1 nvim; echo $?')"
check_rc "and the unseeded one adopts a placeholder" 0 \
  "$(in_session work 'ar_name_eligible w1:t2 3; echo $?')"

# A store that exists is never seeded over, whatever the shared one holds.
in_session work 'ar_state_set w1:t1 htop true'
in_session work 'ar_state_seed'
check "an existing store is left alone"      "htop" "$(in_session work 'ar_state_get w1:t1 auto')"

# A shared store jq cannot use seeds nothing, and the session starts empty.
printf '{"w1:t1": {"auto": "nvim", "enab' >"$LEGACY/state.json"
in_session home 'ar_state_seed'
check "an unreadable shared store seeds nothing" "" "$(in_session home 'ar_state_get w1:t1 auto')"
check "and leaves no file behind" "no" \
  "$([ -e "$LEGACY/sessions/home/state.json" ] && printf yes || printf no)"

# The default session is the shared store itself, so it has nothing to seed from.
printf '{"w1:t1":{"auto":"nvim","enabled":true}}' >"$LEGACY/state.json"
in_env "$CFG/herdr.sock" "" 'ar_state_seed'
check "the root store is never seeded onto itself" "nvim" \
  "$(in_env "$CFG/herdr.sock" "" 'ar_state_get w1:t1 auto')"

# ---- end to end: two sessions through the real reconcile ----
# The same regression through ar_main against tests/mocks/herdr, so the steps
# only an executed pass takes (the mkdir of the nested store, the lock, the
# prune at the end of the pass) are pinned too. Each session has its own
# fixtures, as each server answers for its own tabs, and both number from w1:t1.
MOCK="$here/mocks/herdr"
export HERDR_BIN_PATH="$MOCK" HERDR_MOCK_LOG="$SB/renames.log"
export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"   # absent -> env toggles win
export HERDR_CONFIG_FILE="$SB/herdr.toml"
printf 'agent_panel_sort = "spaces"\n' >"$HERDR_CONFIG_FILE"
export NAME_TABS=1 AUTO_INDEX=0 SHELL_NAME=zsh
unset HIDE_SHELL HERDR_TAB_ID HERDR_PLUGIN_CONTEXT_JSON
rm -rf "$LEGACY"

# session_fixtures <name> <label> <program> -> one workspace, one tab, one pane.
session_fixtures() {
  local d="$SB/fixtures-$1"
  mkdir -p "$d"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}' >"$d/workspaces.json"
  printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"%s","pane_count":1,"focused":true}]}}' "$2" >"$d/tabs_w1.json"
  printf '{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}' >"$d/panes.json"
  printf '{"result":{"process_info":{"foreground_process_group_id":100,"foreground_processes":[{"pid":100,"argv0":"%s","cmdline":"%s"}]}}}' "$3" "$3" >"$d/procinfo_p1.json"
}
# run_in <name> <event> -> a full pass under that session's socket and fixtures.
run_in() {
  : >"$HERDR_MOCK_LOG"
  HERDR_SOCKET_PATH="$CFG/sessions/$1/herdr.sock" HERDR_MOCK_DIR="$SB/fixtures-$1" \
    /usr/bin/env bash "$ENGINE" "$2"
  cat "$HERDR_MOCK_LOG"
}

session_fixtures work 1 nvim
check_contains "work names its tab" "$(run_in work tab.focused)" "tab rename w1:t1 nvim"
check "and records it in its own store" "nvim" \
  "$(jq -r '."w1:t1".auto' "$LEGACY/sessions/work/state.json" 2>/dev/null)"

session_fixtures home 1 claude
check_contains "home names its own w1:t1" "$(run_in home tab.focused)" "tab rename w1:t1 claude"
check "without touching work's record" "nvim" \
  "$(jq -r '."w1:t1".auto' "$LEGACY/sessions/work/state.json" 2>/dev/null)"

# The label now carries work's own name and the program has changed: the tab is
# still work's to rename. Under one shared store, home's prune had dropped the
# record, the label read as typed by hand, and this pass renamed nothing.
session_fixtures work nvim htop
check_contains "work goes on naming it after home's pass" "$(run_in work tab.focused)" "tab rename w1:t1 htop"
check "and no store was left at the root" "no" \
  "$([ -e "$LEGACY/state.json" ] && printf yes || printf no)"

rm -rf "$SB" 2>/dev/null || true
t_summary
