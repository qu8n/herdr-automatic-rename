#!/usr/bin/env bash
# Integration tests for the preexec/precmd fast path against the fake herdr.
#
# The bug that motivated the "shell" marker: zsh expands aliases in preexec's
# $2 but never expands functions, so calling a function `l` handed the engine
# the literal word "l". No program list can match a function name, so the tab
# flashed "l" and precmd snapped it back -- a flicker on every instant function.
# The hooks now classify the command word; anything that is not an external
# command gets a "shell" third argument, and the engine names the tab by the
# pane's REAL foreground process (sampled after a short settle) instead of by
# the typed word.

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

# Sandbox mirroring test_reconcile.sh, plus the tab/pane identity the fast path
# reads from the environment (HERDR_TAB_ID / HERDR_PANE_ID) and a seeded state
# file that marks tab t1 as owned with base "zsh" (so it is rename-eligible).
setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-fast.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"
  export SHELL_NAME=zsh
  export NAME_TABS=1 AUTO_INDEX=1
  export HERDR_TAB_ID=t1 HERDR_PANE_ID=p1
  mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
  printf '{"t1":{"auto":"zsh","enabled":true}}\n' \
    >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
  fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"[1] zsh"}}}
JSON
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# ======================================================================
# Scenario 1: instant shell function (the flicker bug).
#   preexec "l" shell; by sample time the function has exited, so the pane's
#   foreground leader is the shell again. The tab must NOT be renamed -- the
#   old behavior renamed it to "[1] l" and precmd flapped it back.
# ======================================================================
setup
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
/bin/bash "$ENGINE" preexec "l" shell
check "instant function: no rename" "" "$(log)"
teardown

# ======================================================================
# Scenario 2: function wrapping a long-running program.
#   preexec "v" shell; at sample time nvim holds the foreground, so the tab is
#   named after the real program, not the function word.
# ======================================================================
setup
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
/bin/bash "$ENGINE" preexec "v" shell
check "wrapped program: named by foreground" "tab rename t1 [1] nvim" "$(log)"
teardown

# ======================================================================
# Scenario 3: sampling fails (no process-info) -> rename nothing, never guess.
# ======================================================================
setup
# NOTE: no procinfo_p1.json -> the mock serves "{}" -> no resolvable process.
/bin/bash "$ENGINE" preexec "l" shell
check "sample failure: no rename" "" "$(log)"
teardown

# ======================================================================
# Scenario 4: external command without the marker -- the pre-existing instant
# path must be untouched (renames from the typed word, no process-info call).
# ======================================================================
setup
/bin/bash "$ENGINE" preexec "nvim README.md"
check "external command: instant rename" "tab rename t1 [1] nvim" "$(log)"
teardown

# ======================================================================
# Scenario 5: precmd back at the prompt reverts to the shell name.
# ======================================================================
setup
fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"[1] nvim"}}}
JSON
printf '{"t1":{"auto":"nvim","enabled":true}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
/bin/bash "$ENGINE" precmd zsh
check "precmd: back to shell name" "tab rename t1 [1] zsh" "$(log)"
teardown

t_summary
