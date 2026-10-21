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
  unset NAME_PANES PANE_TOPICS TITLE_CONDENSE HERDR_MOCK_VERSION HERDR_MOCK_NO_VERSION HERDR_MOCK_FAIL_VERB
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
# PANE_TOPICS reads the same lists, so both are off.
setup
list_fixtures
export NAME_PANES=0 PANE_TOPICS=0
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

# ======================================================================
# Scenario 5: PANE_TOPICS. Each agent pane gets its own topic as the `topic`
#   token, so the sidebar can show what EACH agent works on, not only the one
#   its tab is named after (issue #32). `tokens` is what herdr shows now.
#   q1 a title with a trailing spinner      -> topic set, spinner gone
#   q2 a topic that already matches         -> left alone
#   q3 a title that says nothing, old topic -> topic cleared
#   q4 named, and titled                    -> one call carries both
#   q5 a herdr-mirror pane                  -> the remote's, left alone
# ======================================================================
topics_json() {
  cat <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[],
  "panes":[
    {"pane_id":"w1:q1","tab_id":"w1:t1","agent":"codex","cwd":"/home/u/api",
     "terminal_title_stripped":"Research upload tags ⠋"},
    {"pane_id":"w1:q2","tab_id":"w1:t1","agent":"opencode","cwd":"/home/u/api",
     "terminal_title_stripped":"Greeting and quick check-in",
     "tokens":{"topic":"Greeting and quick check-in"}},
    {"pane_id":"w1:q3","tab_id":"w1:t1","agent":"claude","cwd":"/home/u/api",
     "terminal_title_stripped":"Claude Code","tokens":{"topic":"old"}},
    {"pane_id":"w1:q4","tab_id":"w1:t1","agent":"claude","cwd":"/home/u/api",
     "terminal_title_stripped":"Investigate why the nightly ETL job drops rows"},
    {"pane_id":"w1:q5","tab_id":"w1:t1","agent":"claude","cwd":"/home/u/.mirror-pane",
     "terminal_title_stripped":"Remote work"}
  ],
  "agents":[
    {"pane_id":"w1:q4","agent":"claude","name":"etl"}
  ]
}}}
JSON
}

setup
topics_json | fixture snapshot.json
run_event pane.focused
check "each agent pane gets its own topic" \
"pane report-metadata w1:q1 $SRC --agent codex --token topic=Research upload tags
pane report-metadata w1:q3 $SRC --clear-token topic
pane report-metadata w1:q4 $SRC --agent claude --title etl --token topic=Investigate why the nightly ETL job drops rows" \
  "$(log)"
teardown

# herdr 0.7.4 added --token. Below it, herdr refuses the whole call, so the
# border title goes alone and no topic is asked for. Nor does it show tokens.
setup
topics_json | jq 'del(.result.snapshot.panes[].tokens)' | fixture snapshot.json
export HERDR_MOCK_VERSION=0.7.3
run_event pane.focused
check "below herdr 0.7.4 the title goes alone" \
  "pane report-metadata w1:q4 $SRC --agent claude --title etl" "$(log)"
teardown

# herdr keeps the first 80 characters of a token and drops the whitespace that
# leaves at the end, so a longer topic is sent as herdr will store it. Sent
# whole, it never matched what herdr showed and went out again on every event.
long=$(printf 'abcd %.0s' $(seq 1 20)); long=${long% }
stored=$(printf 'abcd %.0s' $(seq 1 16)); stored=${stored% }
setup
fixture snapshot.json <<JSON
{"result":{"snapshot":{"workspaces":[],"tabs":[],"panes":[
  {"pane_id":"w1:q1","tab_id":"w1:t1","agent":"codex","cwd":"/home/u/api",
   "terminal_title_stripped":"$long"},
  {"pane_id":"w1:q2","tab_id":"w1:t1","agent":"codex","cwd":"/home/u/api",
   "terminal_title_stripped":"$long","tokens":{"topic":"$stored"}}
],"agents":[]}}}
JSON
run_event pane.focused
check "a long topic is sent as herdr stores it, and not again" \
  "pane report-metadata w1:q1 $SRC --agent codex --token topic=$stored" "$(log)"
teardown

# TITLE_CONDENSE shortens the topic the same way it shortens a tab name.
setup
topics_json | fixture snapshot.json
export TITLE_CONDENSE=1
run_event pane.focused
check_contains "a condensed title is the topic" "$(log)" \
  "pane report-metadata w1:q4 $SRC --agent claude --title etl --token topic=nightly-ETL-job-drops-rows"
teardown

# The per-list path reads the same facts off the pane list.
setup
topics_json | jq '{result:{panes:.result.snapshot.panes}}' | fixture panes.json
topics_json | jq '{result:{agents:.result.snapshot.agents}}' | fixture agents.json
run_event pane.focused
check_contains "the per-list path sets topics too" "$(log)" \
  "pane report-metadata w1:q1 $SRC --agent codex --token topic=Research upload tags"
teardown

# Switched off, and with the clear action, the topics come back off. NAME_PANES
# is off here so only the topic writes are in the log.
setup
topics_json | fixture snapshot.json
export PANE_TOPICS=0 NAME_PANES=0
run_event pane.focused
check "off clears every topic, and sets none" \
"pane report-metadata w1:q2 $SRC --clear-token topic
pane report-metadata w1:q3 $SRC --clear-token topic" "$(log)"
teardown

setup
topics_json | fixture snapshot.json
export NAME_PANES=0
run_event --clear
out=$(log)
check_contains "the clear action clears topics too" "$out" \
  "pane report-metadata w1:q2 $SRC --clear-token topic"
check_absent "and sets none" "$out" "--token "
teardown

t_summary
