#!/usr/bin/env bash
# Integration tests for NAME_PANES: each named agent's name on its pane border,
# reported as the pane's title through `pane report-metadata`. Same fake-herdr
# harness as tests/test_reconcile.sh. Tab naming and numbering are off in every
# scenario, so the log holds only what this feature wrote.

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

SRC="--source herdr-automatic-rename"

setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-panes.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"
  export HERDR_CONFIG_FILE="$SB/herdr.toml"
  export HERDR_SOCKET_PATH="$SB/herdr.sock"
  export NAME_TABS=0 AUTO_INDEX=0
  unset NAME_PANES HERDR_MOCK_VERSION HERDR_MOCK_NO_VERSION HERDR_MOCK_FAIL_VERB
  unset AUTO_INDEX_WORKSPACES AUTO_INDEX_TABS AUTO_INDEX_AGENTS
  unset HERDR_TAB_ID HERDR_PANE_ID HERDR_PLUGIN_CONTEXT_JSON
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }
run_event() { /usr/bin/env bash "$ENGINE" "$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# One snapshot with a pane for every rule. A pane's `title` is what herdr shows
# on its border now, from whichever source reported it.
#   p1 named reviewer, untitled             -> titled
#   p2 named after its own kind             -> left alone
#   p3 named, with a label the user typed   -> left alone, the label shows
#   p4 named, already titled with the name  -> left alone
#   p5 no agent, a title of its own         -> never asked about
#   p6 a herdr-mirror pane                  -> the remote's, left alone
#   p7 titled, its agent's name since gone  -> cleared
#   p8 titled, then given a label           -> cleared, so the label shows
snapshot_json() {
  cat <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[{"tab_id":"w1:t1","label":"1","pane_count":8,"focused":true,"workspace_id":"w1"}],
  "panes":[
    {"pane_id":"w1:p1","tab_id":"w1:t1","agent":"claude","cwd":"/home/u/api"},
    {"pane_id":"w1:p2","tab_id":"w1:t1","agent":"claude","cwd":"/home/u/api"},
    {"pane_id":"w1:p3","tab_id":"w1:t1","agent":"codex","label":"notes","cwd":"/home/u/api"},
    {"pane_id":"w1:p4","tab_id":"w1:t1","agent":"codex","title":"fixer","cwd":"/home/u/api"},
    {"pane_id":"w1:p5","tab_id":"w1:t1","title":"build","cwd":"/home/u/api"},
    {"pane_id":"w1:p6","tab_id":"w1:t1","agent":"claude","cwd":"/home/u/.mirror-pane"},
    {"pane_id":"w1:p7","tab_id":"w1:t1","agent":"claude","title":"old","cwd":"/home/u/api"},
    {"pane_id":"w1:p8","tab_id":"w1:t1","agent":"claude","label":"typed","title":"beta","cwd":"/home/u/api"}
  ],
  "agents":[
    {"pane_id":"w1:p1","agent":"claude","name":"reviewer"},
    {"pane_id":"w1:p2","agent":"claude","name":"claude"},
    {"pane_id":"w1:p3","agent":"codex","name":"api"},
    {"pane_id":"w1:p4","agent":"codex","name":"fixer"},
    {"pane_id":"w1:p6","agent":"claude","name":"remote"},
    {"pane_id":"w1:p7","agent":"claude","name":null},
    {"pane_id":"w1:p8","agent":"claude","name":"beta"}
  ]
}}}
JSON
}
snapshot_fixture() { snapshot_json | fixture snapshot.json; }
# The same panes and agents as the two lists a herdr without `api snapshot`
# serves, so the per-list path meets every rule too.
list_fixtures() {
  snapshot_json | jq '{result:{panes:.result.snapshot.panes}}' | fixture panes.json
  snapshot_json | jq '{result:{agents:.result.snapshot.agents}}' | fixture agents.json
}

# ======================================================================
# Scenario 1: on by default, every rule on the snapshot path.
# ======================================================================
setup
snapshot_fixture
run_event pane.agent_detected
out=$(log)
check "the only writes are the title and the two clears" \
"pane report-metadata w1:p1 $SRC --agent claude --title reviewer
pane report-metadata w1:p7 $SRC --clear-title
pane report-metadata w1:p8 $SRC --clear-title" "$out"
check_absent "a name that repeats the kind is not shown" "$out" "w1:p2 "
check_absent "a labelled pane is not titled" "$out" "w1:p3 "
check_absent "a title that already matches is not resent" "$out" "w1:p4 "
check_absent "a pane with no agent is not asked about" "$out" "w1:p5 "
check_absent "a mirror pane is the remote's" "$out" "w1:p6 "
teardown

# ======================================================================
# Scenario 2: the per-list path (no snapshot) reads the same two lists.
# ======================================================================
setup
list_fixtures
run_event pane.focused
check "per-list path applies every rule the same way" \
"pane report-metadata w1:p1 $SRC --agent claude --title reviewer
pane report-metadata w1:p7 $SRC --clear-title
pane report-metadata w1:p8 $SRC --clear-title" "$(log)"
teardown

# Switched off, the per-list path reads nothing at all, so it cannot clear: the
# titles go as their agents exit. The clear action still reads and clears.
setup
list_fixtures
export NAME_PANES=0
run_event pane.focused
check "off on the per-list path makes no call" "" "$(log)"
teardown

setup
list_fixtures
export NAME_PANES=0
run_event --clear
check_contains "the clear action still clears on the per-list path" "$(log)" \
  "pane report-metadata w1:p4 $SRC --clear-title"
teardown

# A list that cannot be read is not a list with no agents in it: clearing on it
# would take every title down on a socket blip.
setup
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"w1:p1","tab_id":"w1:t1","agent":"claude","title":"reviewer","cwd":"/home/u/api"}
]}}
JSON
export HERDR_MOCK_FAIL_VERB="agent list"
run_event pane.focused
check "an unreadable agent list writes nothing" "" "$(log)"
teardown

# ======================================================================
# Scenario 3: NAME_PANES=0 and the clear action take the titles back off.
# ======================================================================
setup
snapshot_fixture
export NAME_PANES=0
run_event pane.focused
check "off clears every title on an agent pane, and sets none" \
"pane report-metadata w1:p4 $SRC --clear-title
pane report-metadata w1:p7 $SRC --clear-title
pane report-metadata w1:p8 $SRC --clear-title" "$(log)"
teardown

setup
snapshot_fixture
run_event --clear
out=$(log)
check_contains "the clear action clears titles too" "$out" "pane report-metadata w1:p4 $SRC --clear-title"
check_absent "and sets none" "$out" "--title "
teardown

# ======================================================================
# Scenario 4: an older herdr numbers agents ("[1] reviewer"). The border shows
#   the name without the number, and "[2] claude" is still only the kind.
# ======================================================================
setup
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[],
  "panes":[
    {"pane_id":"w1:p1","tab_id":"w1:t1","agent":"claude","cwd":"/home/u/api"},
    {"pane_id":"w1:p2","tab_id":"w1:t1","agent":"claude","cwd":"/home/u/api"}
  ],
  "agents":[
    {"pane_id":"w1:p1","agent":"claude","name":"[1] reviewer"},
    {"pane_id":"w1:p2","agent":"claude","name":"[2] claude"}
  ]
}}}
JSON
run_event pane.focused
check "a numbered name shows without its number" \
"pane report-metadata w1:p1 $SRC --agent claude --title reviewer" "$(log)"
teardown

t_summary
