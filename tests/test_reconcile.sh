#!/usr/bin/env bash
# Integration test: drive the real engine (automatic-rename.sh) against a fake herdr
# and assert the exact rename commands it issues. This exercises the full
# reconcile -- workspace grouping/numbering, tab naming + numbering, the
# placeholder-defer rule, agent numbering, and the --clear strip -- with no live
# herdr and no live shell.

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

# A fresh sandbox per scenario: isolated fixtures, rename log, state, and config.
setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-test.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"   # absent -> env toggles win
  export HERDR_CONFIG_FILE="$SB/herdr.toml"
  printf 'agent_panel_sort = "spaces"\n' >"$HERDR_CONFIG_FILE"
  export SHELL_NAME=zsh
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }   # fixture <name>  (JSON on stdin)
run_event() { /bin/bash "$ENGINE" "$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# ======================================================================
# Scenario 1: both features on. Grouped agent sort.
#   - two singleton workspaces -> [1]/[2]
#   - tab t1 at a zsh prompt, t2 running nvim -> named + numbered in one rename
#   - a background multi-pane tab (no resolvable pane) with a placeholder label
#     -> DEFERRED (no throwaway "[N] 3" flash)
#   - one agent -> [1]
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[
  {"workspace_id":"w1","label":"api"},
  {"workspace_id":"w2","label":"web"}
]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false}
]}}
JSON
fixture tabs_w2.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w2:t1","label":"3","pane_count":2,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false},
  {"pane_id":"p3","tab_id":"w2:t1","focused":false},
  {"pane_id":"p4","tab_id":"w2:t1","focused":false}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[
  {"terminal_id":"term_a","name":"claude","agent_session":{"agent":"claude"}}
]}}
JSON
run_event tab.focused
out=$(log)
check_contains "ws1 numbered"          "$out" "workspace rename w1 [1] api"
check_contains "ws2 numbered"          "$out" "workspace rename w2 [2] web"
check_contains "tab1 named+numbered"   "$out" "tab rename w1:t1 [1] zsh"
check_contains "tab2 named+numbered"   "$out" "tab rename w1:t2 [2] nvim"
check_absent   "placeholder deferred"  "$out" "tab rename w2:t1"
check_contains "agent numbered"        "$out" "agent rename term_a [1] claude"
teardown

# ======================================================================
# Scenario 2: NAME_TABS on, AUTO_INDEX off.
#   Tabs are named with NO prefix; workspaces and agents are left untouched.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[{"terminal_id":"term_a","name":"claude","agent_session":{"agent":"claude"}}]}}
JSON
run_event tab.focused
out=$(log)
check_contains "tab named without prefix" "$out" "tab rename w1:t1 zsh"
check_absent   "no workspace numbering"   "$out" "workspace rename"
check_absent   "no agent numbering"       "$out" "agent rename"
teardown

# ======================================================================
# Scenario 3: --clear strips every prefix and reverts the agent to detection.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] zsh","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[{"terminal_id":"term_a","name":"[1] claude","agent_session":{"agent":"claude"}}]}}
JSON
run_event --clear
out=$(log)
check_contains "ws prefix stripped"    "$out" "workspace rename w1 api"
check_contains "tab prefix stripped"   "$out" "tab rename w1:t1 zsh"
check_contains "agent reverted"        "$out" "agent rename term_a --clear"
teardown

# ======================================================================
# Scenario 4: a process-info blip must NOT clobber a named tab.
#   We already own w1:t1 as "nvim" (seeded state). process-info fails (no
#   fixture -> empty foreground process), so the base must stay "nvim" and the
#   already-correct "[1] nvim" label must not be rewritten to "[1] zsh".
#   Guards engine finding #1 (ar_tab_name must return "" on failure, not $SHELL).
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"nvim","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"code"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
# NOTE: no procinfo_p1.json -> the mock serves "{}" -> no resolvable foreground process.
run_event tab.focused
out=$(log)
check_absent "no clobber to shell name on blip" "$out" "zsh"
check_absent "owned tab left untouched on blip" "$out" "tab rename w1:t1"
teardown

# ======================================================================
# Scenario 5: the api-snapshot path. Same inputs and expected renames as
#   Scenario 1, but the engine's whole picture comes from ONE snapshot.json
#   (no workspaces.json / tabs_*.json / panes.json / agents.json). If the
#   snapshot path were skipped, the fallback would hit the mock's empty list
#   defaults and rename NOTHING -- so these renames appearing proves the
#   snapshot slices are parsed, ordered, and grouped-by-workspace correctly.
#   procinfo fixtures are still required: naming samples the foreground process
#   per tab, which the snapshot does not carry.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[
    {"workspace_id":"w1","label":"api"},
    {"workspace_id":"w2","label":"web"}
  ],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w2:t1","label":"3","pane_count":2,"focused":false,"workspace_id":"w2"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true},
    {"pane_id":"p2","tab_id":"w1:t2","focused":false},
    {"pane_id":"p3","tab_id":"w2:t1","focused":false},
    {"pane_id":"p4","tab_id":"w2:t1","focused":false}
  ],
  "agents":[
    {"terminal_id":"term_a","name":"claude","agent_session":{"agent":"claude"}}
  ]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "snapshot: ws1 numbered"        "$out" "workspace rename w1 [1] api"
check_contains "snapshot: ws2 numbered"        "$out" "workspace rename w2 [2] web"
check_contains "snapshot: tab1 named+numbered" "$out" "tab rename w1:t1 [1] zsh"
check_contains "snapshot: tab2 named+numbered" "$out" "tab rename w1:t2 [2] nvim"
check_absent   "snapshot: placeholder deferred" "$out" "tab rename w2:t1"
check_contains "snapshot: agent numbered"      "$out" "agent rename term_a [1] claude"
teardown

t_summary
