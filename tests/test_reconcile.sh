#!/usr/bin/env bash
# Integration test: drive the real engine (automatic-rename.sh) against a fake herdr
# and assert the exact rename commands it issues. This exercises the full
# reconcile -- workspace grouping/numbering, tab naming + numbering, the
# placeholder-defer rule, agent numbering, and the --clear strip -- with no live
# herdr and no live shell.

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

# The glyphs an agent puts in its terminal title, built from their UTF-8 bytes
# rather than pasted: a literal one is what an editor or a copy-paste eats without
# saying so, and these are the needles of check_absent assertions -- a needle that
# cannot appear is a check that cannot fail. Defined once here because a second
# copy is a second chance to mistype one into a silently green check.
SPINNER=$(printf '\342\234\263')   # U+2733, claude's working glyph
PI_BRAND=$(printf '\317\200')       # U+03C0, the brand oh-my-pi leads with
PI_SPINNER=$(printf '\342\240\213') # U+280B, one of its ten working frames

# A fresh sandbox per scenario: isolated fixtures, rename log, state, and config.
setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-test.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"; rm -f "$HERDR_MOCK_LOG.tabget"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"   # absent -> env toggles win
  export HERDR_CONFIG_FILE="$SB/herdr.toml"
  printf 'agent_panel_sort = "spaces"\n' >"$HERDR_CONFIG_FILE"
  export HERDR_SOCKET_PATH="$SB/herdr.sock"   # keeps herdr state reads (session.json) in the sandbox
  export SHELL_NAME=zsh
  unset HERDR_MOCK_VERSION HERDR_MOCK_NO_VERSION HERDR_MOCK_RERUN_ONCE   # per-scenario opt-in; mock default is current herdr
  unset HERDR_MOCK_FAIL_RENAME                     # per-scenario opt-in; renames succeed by default
  unset HERDR_MOCK_FAIL_VERB                       # per-scenario opt-in; every query answers by default
  unset HERDR_MOCK_TAB_GONE_AFTER                  # per-scenario opt-in; a tab stays until its fixture goes
  unset HIDE_SHELL                                 # per-scenario opt-in; default is off
  unset AUTO_INDEX_WORKSPACES AUTO_INDEX_TABS AUTO_INDEX_AGENTS   # per-kind opt-in; inherit AUTO_INDEX
  unset AGENT_TITLES SHOW_PROGRAM_ARGS TITLE_STYLE # per-scenario opt-in; naming.sh defaults apply
  # The reset action reads these from herdr. They are also set in every pane of a
  # live herdr, so a suite run from inside one would otherwise inherit a tab id
  # that no fixture describes -- and the "nothing to reset" arm could never happen.
  unset HERDR_TAB_ID HERDR_PLUGIN_CONTEXT_JSON
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }   # fixture <name>  (JSON on stdin)
run_event() { /usr/bin/env bash "$ENGINE" "$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# ======================================================================
# Scenario 1: both features on. Grouped agent sort.
#   - two singleton workspaces -> [1]/[2]
#   - tab t1 at a zsh prompt, t2 running nvim -> named + numbered in one rename
#   - a background multi-pane tab with a placeholder label -> DEFERRED (no
#     throwaway "[N] 3" flash). This is also the no-layouts FALLBACK in
#     ar_resolve_pane: the per-list path carries no layout to ask, so none of the
#     tab's panes is .focused and no pane resolves at all. Scenario 20 pins the
#     same tab naming itself once a snapshot supplies its layout.
#   - one agent -> [1], on the last herdr that accepts a bracketed agent name
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
export HERDR_MOCK_VERSION=0.7.4   # < 0.7.5: agent numbering is still possible
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
  {"terminal_id":"term_a","pane_id":"w1:pA","name":"claude","agent_session":{"agent":"claude"}}
]}}
JSON
run_event tab.focused
out=$(log)
check_contains "ws1 numbered"          "$out" "workspace rename w1 [1] api"
check_contains "ws2 numbered"          "$out" "workspace rename w2 [2] web"
check_contains "tab1 named+numbered"   "$out" "tab rename w1:t1 [1] zsh"
check_contains "tab2 named+numbered"   "$out" "tab rename w1:t2 [2] nvim"
check_absent   "placeholder deferred"  "$out" "tab rename w2:t1"
check_contains "agent numbered by pane id" "$out" "agent rename w1:pA [1] claude"
check_absent   "agent never targeted by terminal id" "$out" "agent rename term_a"
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
{"result":{"agents":[{"terminal_id":"term_a","pane_id":"w1:pA","name":"claude","agent_session":{"agent":"claude"}}]}}
JSON
run_event tab.focused
out=$(log)
check_contains "tab named without prefix" "$out" "tab rename w1:t1 zsh"
check_absent   "no workspace numbering"   "$out" "workspace rename"
check_absent   "no agent numbering"       "$out" "agent rename"
teardown

# ======================================================================
# Scenario 3: --clear strips every prefix and reverts the agent to detection, and
#   says so. The action is meant for a keybinding, where a tab bar that quietly
#   redraws is the only other sign anything happened -- and on a session whose
#   labels were already bare, nothing redraws at all.
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
{"result":{"agents":[{"terminal_id":"term_a","pane_id":"w1:pA","name":"[1] claude","agent_session":{"agent":"claude"}}]}}
JSON
run_event --clear
out=$(log)
check_contains "ws prefix stripped"    "$out" "workspace rename w1 api"
check_contains "tab prefix stripped"   "$out" "tab rename w1:t1 zsh"
check_contains "agent reverted"        "$out" "agent rename w1:pA --clear"
check_contains "the clear action notifies" "$out" \
  "notification show Number prefixes cleared --body Base names restored"
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
export HERDR_MOCK_VERSION=0.7.4   # < 0.7.5: agent numbering is still possible
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
    {"terminal_id":"term_a","pane_id":"w1:pA","name":"claude","agent_session":{"agent":"claude"}}
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
check_contains "snapshot: agent numbered"      "$out" "agent rename w1:pA [1] claude"
teardown

# ======================================================================
# Scenario 6: process-info without an argv0 field (issue #6).
#   herdr's Linux builds report no argv0 at all -- only argv/cmdline/name. On
#   NixOS `name` is the on-disk executable, which for a wrapped program is the
#   internal `.<prog>-wrapped` binary, while argv[0] still carries what the user
#   typed. Naming must follow argv[0], not the wrapper.
#   p1: the reporter's payload -- `nh os switch` must read "nh", not ".nh-wrapped".
#   p2: a login shell, where argv[0] keeps the leading "-" that argv0 lacks.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":75757,
  "foreground_processes":[
    {"pid":75757,"argv":["nh","os","switch"],"cmdline":"nh os switch","name":".nh-wrapped"},
    {"pid":75998,"argv":["nix","build","x"],"cmdline":"nix build x","name":"nix"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv":["-zsh"],"cmdline":"-zsh","name":".zsh-wrapped"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "argv[0] names the tab, not the wrapper" "$out" "tab rename w1:t1 nh"
check_absent   "wrapper name never shown"               "$out" "wrapped"
check_contains "login shell argv[0] strips the dash"    "$out" "tab rename w1:t2 zsh"
teardown

# ======================================================================
# Scenario 7: herdr >= 0.7.5 restricts agent names to ^[a-z][a-z0-9_-]{0,31}$,
#   so "[N] claude" can never be set. Numbering must be skipped even though the
#   panel is grouped-sorted, and an "[1] claude" left behind by an older
#   herdr + older plugin must be reverted to detection (the upgrade path: that
#   name is otherwise stuck, including through the uninstall --clear).
#   Workspaces and tabs are unaffected -- their labels stay free-form.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
export HERDR_MOCK_VERSION=0.8.0
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
{"result":{"agents":[
  {"terminal_id":"term_a","pane_id":"w1:pA","name":"[1] claude","agent_session":{"agent":"claude"}},
  {"terminal_id":"term_b","pane_id":"w1:pB","name":"my-session","agent_session":{"agent":"codex"}}
]}}
JSON
run_event tab.focused
out=$(log)
check_absent   "no bracketed agent name attempted" "$out" "[1] claude"
check_contains "legacy agent prefix reverted"      "$out" "agent rename w1:pA --clear"
check_absent   "user-named agent left alone"       "$out" "agent rename w1:pB"
check_contains "workspaces still numbered"         "$out" "workspace rename w1 [1] api"
check_contains "tabs still named and numbered"     "$out" "tab rename w1:t1 [1] zsh"
teardown

# ======================================================================
# Scenario 8: an unreadable herdr version must NOT unlock agent numbering.
#   The mock serves no version at all, so ar_herdr_version fails and the engine
#   has to assume the restrictive herdr rather than issuing a rename that a real
#   herdr would reject.
# ======================================================================
setup
export NAME_TABS=0 AUTO_INDEX=1
export HERDR_MOCK_NO_VERSION=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[{"terminal_id":"term_a","pane_id":"w1:pA","name":"claude","agent_session":{"agent":"claude"}}]}}
JSON
run_event tab.focused
out=$(log)
check_absent   "unknown version does not number agents" "$out" "agent rename w1:pA [1]"
check_contains "workspaces unaffected"                  "$out" "workspace rename w1 [1] api"
teardown

# ======================================================================
# Scenario 9: HIDE_SHELL=1 with AUTO_INDEX=0 (issue #5).
#   A shell tab is renamed to the EMPTY label so herdr renders its own number;
#   an nvim tab is named as usual. The state file must record the empty name as
#   ours, or the next pass would read herdr's number back as a hand rename.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0 HIDE_SHELL=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"fish","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-fish","cmdline":"-fish"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
# t1 is ours, named "fish" by an earlier pass, so the knob has a label to undo.
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"fish","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
run_event tab.focused
out=$(log)
check "shell tab renamed to nothing" "tab rename w1:t1 " "$(printf '%s\n' "$out" | grep 'w1:t1')"
check_contains "nvim tab still named"  "$out" "tab rename w1:t2 nvim"
check "empty name recorded as ours" "true" \
  "$(jq -r '."w1:t1" | (.auto == "") and .enabled' "$XDG_STATE_HOME/herdr-automatic-rename/state.json")"
teardown

# ======================================================================
# Scenario 10: HIDE_SHELL=1 with AUTO_INDEX=1.
#   The jump number is the one thing numbering exists for, so a hidden shell tab
#   keeps "[N]" alone. The next pass must read that back as OUR label (empty base,
#   still owned) and leave it alone rather than opting the tab out.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 HIDE_SHELL=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] zsh","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"zsh","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
run_event tab.focused
check_contains "numbered shell tab keeps the number only" "$(log)" "tab rename w1:t1 [1]"
# Second pass over the settled "[1]" label: no further rename, still ours.
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1]","pane_count":1,"focused":true}]}}
JSON
: >"$HERDR_MOCK_LOG"
run_event tab.focused
check "settled [N] label is stable" "" "$(printf '%s\n' "$(log)" | grep 'tab rename')"
check "still owned after settling" "true" \
  "$(jq -r '."w1:t1".enabled' "$XDG_STATE_HOME/herdr-automatic-rename/state.json")"
teardown

# ======================================================================
# Scenario 11: HIDE_SHELL and the two ways an empty label must NOT be touched.
#   a) --clear strips a leftover "[1]" off a hidden tab (the uninstall path).
#   b) A process-info blip on a hidden tab leaves the label alone: the old
#      "empty base -> skip" guard now runs on HIDE_SHELL, so nothing may make it
#      guess "[1]" for a tab whose program it could not read.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 HIDE_SHELL=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1]","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
run_event --clear
check "clear strips a number-only label" "tab rename w1:t1 " "$(printf '%s\n' "$(log)" | grep 'w1:t1')"
teardown

setup
export NAME_TABS=1 AUTO_INDEX=1 HIDE_SHELL=1
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
# NOTE: no procinfo_p1.json -> process-info resolves nothing.
run_event tab.focused
check_absent "blip does not hide a named tab" "$(log)" "tab rename w1:t1"
teardown

# ======================================================================
# Scenario 12: a hidden tab whose program can't be sampled must still be
#   renumbered. A background multi-pane tab exposes no active pane at all, so its
#   name is never computable -- but its jump number still has to follow the tab
#   order, which is exactly what the "[i]"-only label has to keep working for.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 HIDE_SHELL=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t9","label":"[2]","pane_count":2,"focused":false}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t9","focused":false},
  {"pane_id":"p2","tab_id":"w1:t9","focused":false}
]}}
JSON
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t9":{"auto":"","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
run_event tab.moved
check_contains "hidden tab follows its number" "$(log)" "tab rename w1:t9 [1]"
teardown

# ======================================================================
# Scenario 13: with HIDE_SHELL off, a name the config erased is not a name.
#   MAX_NAME_LEN=0 stands in for any rule that computes a name and then leaves
#   nothing of it (a catch-all SUBSTITUTE_SETS does the same). Only HIDE_SHELL
#   licenses blanking a tab, so this must leave the label alone.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 MAX_NAME_LEN=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"nvim","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
run_event tab.focused
check_absent "erased name does not blank a tab" "$(log)" "tab rename w1:t1"
unset MAX_NAME_LEN
teardown

# ======================================================================
# Scenario 14: issue #8 -- numbered tabs, plain workspaces, from one knob.
#   AUTO_INDEX_WORKSPACES=0 alone. Tabs and agents keep numbering (they inherit
#   AUTO_INDEX), and the workspace prefix already on the row is STRIPPED rather
#   than left for the next `clear`: the pass runs whether the scope is on or off.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 AUTO_INDEX_WORKSPACES=0
export HERDR_MOCK_VERSION=0.7.4   # < 0.7.5: agent numbering is still possible
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[
  {"workspace_id":"w1","label":"[1] api"},
  {"workspace_id":"w2","label":"web"}
]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture tabs_w2.json <<'JSON'
{"result":{"tabs":[]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[{"terminal_id":"term_a","pane_id":"w1:pA","name":"claude","agent_session":{"agent":"claude"}}]}}
JSON
run_event tab.focused
out=$(log)
check_contains "stale ws prefix stripped"  "$out" "workspace rename w1 api"
check_absent   "ws never renumbered"       "$out" "workspace rename w1 [1]"
check_absent   "unprefixed ws left alone"  "$out" "workspace rename w2"
check_contains "tabs still numbered"       "$out" "tab rename w1:t1 [1] nvim"
check_contains "agents still numbered"     "$out" "agent rename w1:pA [1] claude"
teardown

# ======================================================================
# Scenario 15: the mirror image -- AUTO_INDEX_TABS=0 with the rest on. The tab
#   keeps its NAME but loses its number, while the workspace keeps both.
#   Guards against a scope leaking into its neighbours through ar_index_on.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 AUTO_INDEX_TABS=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "tab keeps name, loses number" "$out" "tab rename w1:t1 nvim"
check_contains "workspace still numbered"     "$out" "workspace rename w1 [1] api"
teardown

# ======================================================================
# Scenario 16: AUTO_INDEX_AGENTS=0 strips an agent prefix on a herdr that would
#   otherwise accept one, and does it without consulting the version or the
#   panel sort -- the toggle is tested before both probes. Workspaces and tabs,
#   inheriting AUTO_INDEX=1, are unaffected.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 AUTO_INDEX_AGENTS=0
export HERDR_MOCK_VERSION=0.7.4   # < 0.7.5: numbering would be allowed
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[]}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[{"terminal_id":"term_a","pane_id":"w1:pA","name":"[1] claude","agent_session":{"agent":"claude"}}]}}
JSON
run_event tab.focused
out=$(log)
check_contains "agent prefix stripped"    "$out" "agent rename w1:pA --clear"
check_contains "workspace still numbered" "$out" "workspace rename w1 [1] api"
teardown

# ======================================================================
# Scenario 17: a config that predates these settings must not be touched.
#   Only AUTO_INDEX=0 is set, so every kind INHERITS off and nothing was named.
#   The passes are skipped exactly as they were before per-kind settings existed,
#   which is what keeps a hand-typed "[1] incident" that has sat there for
#   months from being stripped by an upgrade the user did not ask for.
# ======================================================================
setup
export NAME_TABS=0 AUTO_INDEX=0
export HERDR_MOCK_VERSION=0.7.4   # < 0.7.5: agents would be eligible
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] incident"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[2] notes","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[]}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[{"terminal_id":"term_a","pane_id":"w1:pA","name":"[3] triage","agent_session":{"agent":"claude"}}]}}
JSON
run_event tab.focused
check "legacy AUTO_INDEX=0 renames nothing" "" "$(log)"
teardown

# ======================================================================
# Scenario 18: name the kind and the strip arms, including the cost of it.
#   Scenario 17's config plus an explicit AUTO_INDEX_WORKSPACES=0, so the pair
#   isolates naming as the thing that arms it. The stale prefix goes, and so
#   does a hand-typed one -- nothing tells them apart, which is what the docs
#   warn about. "[wip] ..." is spared by the all-digits rule, and agents, still
#   only inheriting, stay untouched.
# ======================================================================
setup
export NAME_TABS=0 AUTO_INDEX=0 AUTO_INDEX_WORKSPACES=0
export HERDR_MOCK_VERSION=0.7.4
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[
  {"workspace_id":"w1","label":"[1] incident"},
  {"workspace_id":"w2","label":"[wip] deploy"}
]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[]}}
JSON
fixture tabs_w2.json <<'JSON'
{"result":{"tabs":[]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[]}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[{"terminal_id":"term_a","pane_id":"w1:pA","name":"[3] triage","agent_session":{"agent":"claude"}}]}}
JSON
run_event tab.focused
out=$(log)
check_contains "named kind strips its prefix"  "$out" "workspace rename w1 incident"
check_absent   "non-digit bracket survives"    "$out" "workspace rename w2"
check_absent   "unnamed kind still untouched"  "$out" "agent rename"
teardown

# ======================================================================
# Scenario 19: an agent behind a language runtime.
#
# An agent installed through npm or npx runs as its runtime (its bin shim is a
# JS file behind a node shebang), so a codex pane was named "node". herdr
# detects the agent regardless and publishes it on the pane object, and where
# the foreground program is a runtime that answer wins. No agents.json fixture:
# the name must come from the pane fields alone, with no `agent list` call.
#
# Both halves are required, and the scenario pins each: t2 is an ordinary node
# program with no agent in the pane and keeps its name, t3 is an agent that
# reports itself and is unaffected. t4 pins the gate itself: its pane carries
# only an agent_session (a resume ref -- herdr#803's half-wired state, where
# detection reports nothing and agent list excludes the pane), which must NOT
# name the tab.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false},
  {"tab_id":"w1:t3","label":"3","pane_count":1,"focused":false},
  {"tab_id":"w1:t4","label":"4","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"codex","agent_status":"idle",
   "agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"019f"}},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false,"agent_status":"unknown"},
  {"pane_id":"p3","tab_id":"w1:t3","focused":false,"agent":"claude","agent_status":"idle",
   "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"ce04"}},
  {"pane_id":"p4","tab_id":"w1:t4","focused":false,"agent_status":"unknown",
   "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"dead"}}
]}}
JSON
# p1: codex through npx -- argv0 absent, argv[0] is the runtime, name is a thread.
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv":["node","/home/u/.npm/_npx/x/node_modules/.bin/codex"],
  "name":"MainThread","cmdline":"node /home/u/.npm/_npx/x/node_modules/.bin/codex"}]}}}
JSON
# p2: an ordinary node program, no agent in the pane.
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"node","cmdline":"node server.js"}]}}}
JSON
# p3: an agent that reports its own name.
fixture procinfo_p3.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":300,
  "foreground_processes":[{"pid":300,"argv0":"claude","cmdline":"claude"}]}}}
JSON
# p4: node again, but the pane holds only a session ref -- no detected agent.
fixture procinfo_p4.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":400,
  "foreground_processes":[{"pid":400,"argv0":"node","cmdline":"node worker.js"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "runtime + detected agent -> the agent" "$out" "tab rename w1:t1 [1] codex"
check_absent   "the runtime never names that tab"      "$out" "[1] node"
check_contains "an ordinary node program is untouched" "$out" "tab rename w1:t2 [2] node"
check_contains "a self-reporting agent is unchanged"   "$out" "tab rename w1:t3 [3] claude"
check_contains "a session ref alone never names"       "$out" "tab rename w1:t4 [4] node"
check_absent   "no rename from the stale session ref"  "$out" "[4] claude"
teardown

# ======================================================================
# Scenario 20: the snapshot's per-tab layouts decide which pane a tab is named
#   after. herdr publishes one layout per tab, and its .focused_pane_id is where
#   focus sits (or returns to) INSIDE that tab, which the pane list alone cannot
#   say -- so both tabs here were unnameable or misnamed before.
#   t1 is the case that was simply unreachable: a BACKGROUND multi-pane tab, whose
#   panes carry no .focused at all, so it kept whatever name it had from when it
#   last held a single pane (scenario 1 pins that fallback).
#   t2 pins the preference: it is the focused tab, but the global .focused flag
#   sits on p1 -- a pane of ANOTHER tab, which is what a second client or a remote
#   attach leaves behind. The old rule read that flag and would have named t2
#   "git" after a pane it does not own; its own layout says p4.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":2,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":2,"focused":true,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true},
    {"pane_id":"p2","tab_id":"w1:t1","focused":false},
    {"pane_id":"p3","tab_id":"w1:t2","focused":false},
    {"pane_id":"p4","tab_id":"w1:t2","focused":false}
  ],
  "layouts":[
    {"tab_id":"w1:t1","focused_pane_id":"p2"},
    {"tab_id":"w1:t2","focused_pane_id":"p4"}
  ],
  "agents":[]
}}}
JSON
# p1 is reachable only through the stale global focus flag, so its program is the
# name a regression would produce.
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"git","cmdline":"git status"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
fixture procinfo_p4.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":400,
  "foreground_processes":[{"pid":400,"argv0":"htop","cmdline":"htop -d 5"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "background multi-pane tab named from its layout" "$out" "tab rename w1:t1 nvim"
check_contains "focused tab named from its layout"               "$out" "tab rename w1:t2 htop"
check_absent   "another tab's focused pane never names a tab"    "$out" "git"
teardown

# ======================================================================
# Scenario 21: process-info with no foreground group to match against. herdr
#   reports a null group where it cannot read one at all (some Linux container
#   and sandbox setups) while still listing processes. t1: exactly ONE process
#   reported is not a choice, so naming the tab after it is not a guess and beats
#   leaving it on herdr's "1".
#   The other three shapes all keep the no-guess contract. t2: two processes with
#   no named group IS a choice -- herdr does not order this list and says a
#   background job can look like the foreground one there -- so the tab keeps its
#   own label rather than being named after either. t3: a group herdr DID name
#   whose process is absent is a group racing its own exit, so the name the tab
#   already has stays. t4: an empty list is no process to fall back to (same
#   outcome as the process-info blip in scenario 4).
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false},
  {"tab_id":"w1:t3","label":"3","pane_count":1,"focused":false},
  {"tab_id":"w1:t4","label":"4","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false},
  {"pane_id":"p3","tab_id":"w1:t3","focused":false},
  {"pane_id":"p4","tab_id":"w1:t4","focused":false}
]}}
JSON
# No group named, one process reported: nothing to choose between.
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":null,
  "foreground_processes":[{"pid":4242,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
# No group named, two processes: naming the tab after either one is a guess.
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":null,
  "foreground_processes":[
    {"pid":4243,"argv0":"git","cmdline":"git status"},
    {"pid":4242,"argv0":"htop","cmdline":"htop"}]}}}
JSON
fixture procinfo_p3.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":999,
  "foreground_processes":[{"pid":4242,"argv0":"lazygit","cmdline":"lazygit"}]}}}
JSON
fixture procinfo_p4.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":null,
  "foreground_processes":[]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "no group, one process -> it names the tab"   "$out" "tab rename w1:t1 nvim"
check_absent   "no group, two processes -> no name"          "$out" "tab rename w1:t2"
check_absent   "neither ambiguous process is picked"         "$out" "htop"
check_absent   "a named group with no process names nothing" "$out" "tab rename w1:t3"
check_absent   "an empty process list still names nothing"   "$out" "tab rename w1:t4"
teardown

# ======================================================================
# Scenario 22: ownership follows the rename, not the intent.
#   Pass 1 issues the rename and herdr REJECTS it. Recording ownership anyway
#   left state claiming a base the tab does not carry, and pass 2 read that
#   mismatch as a hand rename: the tab was opted out of auto-naming for good
#   (state {"auto":"","enabled":false}, recoverable only through `reset`) and
#   never renamed again. So pass 1 must leave no claim, and pass 2 -- same
#   fixtures, label still herdr's "1", healthy herdr -- must retry and adopt it.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
export HERDR_MOCK_FAIL_RENAME=1
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
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
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_event tab.focused
check_contains "rejected rename is still attempted" "$(log)" "tab rename w1:t1 [1] nvim"
check "a rejected rename claims nothing" "" "$(jq -rc '."w1:t1" // empty' "$STATE" 2>/dev/null)"
# Pass 2 against a herdr that accepts it.
unset HERDR_MOCK_FAIL_RENAME
: >"$HERDR_MOCK_LOG"
run_event tab.focused
check_contains "the next pass retries the rename" "$(log)" "tab rename w1:t1 [1] nvim"
check "a landed rename is recorded as ours" "nvim true" \
  "$(jq -r '."w1:t1" | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Scenario 23: the no-layouts fallback, where pane focus is all there is.
#   No snapshot.json here, so ar_resolve_pane gets no _layout_pane and takes the
#   pane-list rule -- the path an older herdr is stuck on, and the only one where
#   the session-wide focus flag could still steal a name.
#   w1:t1 is focused with two panes, and pB is its own focused pane. The pane
#   carrying .focused FIRST in the list is pX, which belongs to another tab
#   entirely: that is what a second client or a remote attach looks like, and
#   reading it would name w1:t1 "htop". Naming by the tab's OWN panes reads "nvim".
#   w2:t1 is the other half: focused, two panes, NEITHER of them focused, so there
#   is no answer to give. Its first pane runs lazygit, so a rename to "lazygit" is
#   what falling back to an arbitrary pane would look like -- any rename of w2:t1
#   fails this scenario.
#   w2:t2 keeps the single-pane arm honest: one pane, unfocused tab, still named.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[
  {"workspace_id":"w1","label":"api"},
  {"workspace_id":"w2","label":"web"}
]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":2,"focused":true}]}}
JSON
fixture tabs_w2.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w2:t1","label":"2","pane_count":2,"focused":true},
  {"tab_id":"w2:t2","label":"3","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"pX","tab_id":"w2:t2","focused":true},
  {"pane_id":"pA","tab_id":"w1:t1","focused":false},
  {"pane_id":"pB","tab_id":"w1:t1","focused":true},
  {"pane_id":"pC","tab_id":"w2:t1","focused":false},
  {"pane_id":"pD","tab_id":"w2:t1","focused":false}
]}}
JSON
fixture procinfo_pX.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":700,
  "foreground_processes":[{"pid":700,"argv0":"htop","cmdline":"htop"}]}}}
JSON
fixture procinfo_pA.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":701,
  "foreground_processes":[{"pid":701,"argv0":"psql","cmdline":"psql"}]}}}
JSON
fixture procinfo_pB.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":702,
  "foreground_processes":[{"pid":702,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
fixture procinfo_pC.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":703,
  "foreground_processes":[{"pid":703,"argv0":"lazygit","cmdline":"lazygit"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "own focused pane names the focused tab"     "$out" "tab rename w1:t1 nvim"
check_absent   "another tab's focused pane never names it"  "$out" "tab rename w1:t1 htop"
check_absent   "no focused pane of its own -> no name"      "$out" "tab rename w2:t1"
check_absent   "and no arbitrary first pane either"         "$out" "lazygit"
check_contains "a single-pane tab is still named"           "$out" "tab rename w2:t2 htop"
teardown

# ======================================================================
# Scenario 24: control characters out of argv, through the real path.
#   argv can hold a tab or a newline, and SHOW_PROGRAM_ARGS=1 puts argv in the
#   label. tests/test_naming.sh covers what ar_format does with one, but that is
#   not where they arrive: they come out of `pane process-info` as JSON, and the
#   jq that reads it used to hand them on as the printable sequences \t and \n --
#   past every scrub, into the tab bar, indistinguishable from typed text. This
#   drives the whole reconcile so the transport is what is under test.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0 SHOW_PROGRAM_ARGS=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
# A real tab and a real newline in the command line, plus a run of spaces.
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"psql","cmdline":"psql -c a\tb\nc   d"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "control characters land as single spaces" "$out" "tab rename w1:t1 psql -c a b c d"
check_absent   "no escaped tab survives into the label"   "$out" 'a\tb'
check_absent   "no escaped newline either"                "$out" 'b\nc'
teardown

# ======================================================================
# Scenario 25: the transport carries one value per LINE, which only holds
#   because the jq that reads process-info replaces control characters first.
#   A newline inside argv0 is what tests that: without the replacement, jq emits
#   three lines for two values, the split takes "ps" as the whole program name,
#   and the tab is named after a program nothing is running. With it, the name
#   arrives whole. SHOW_PROGRAM_ARGS=0 so the label IS the program name.
#   (Scenario 24 cannot pin this: a control character in the COMMAND LINE lands
#   in the last field, where ar_format scrubs it either way.)
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0 SHOW_PROGRAM_ARGS=0
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
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"ps\nql","cmdline":"ps\nql -h db"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "a newline in argv0 does not split the value" "$out" "tab rename w1:t1 ps ql"
teardown

# ======================================================================
# Scenario 26: a label survives the round trip through jq unchanged.
#   Rows used to come back through @tsv, which escapes rather than removes what
#   would break a row -- and its escapes are visible. w1:t1 is a tab named by
#   hand, so only numbering touches it: through @tsv its backslash came back
#   doubled and numbering wrote "C:\\temp" over the name the user chose.
#   w1:t2 is the ownership side. Its state says this plugin last set the base
#   "a b", and its label carries the raw control character an older fast path
#   could leave there. Escaped to "a\tb" it matched nothing, so the tab read as
#   renamed by hand and opted out of naming for good; cleaned to "a b" it is
#   still ours and gets named.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t2":{"auto":"a b","enabled":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"C:\\temp","pane_count":1,"focused":false},
  {"tab_id":"w1:t2","label":"[2] a\tb","pane_count":1,"focused":true}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":false},
  {"pane_id":"p2","tab_id":"w1:t2","focused":true}
]}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "numbering leaves a backslash alone" "$out" 'tab rename w1:t1 [1] C:\temp'
check_absent   "and does not double it"             "$out" 'C:\\temp'
check_contains "a control character in the label does not lose the tab" "$out" "tab rename w1:t2 [2] nvim"
check "the tab is still ours" "nvim true" \
  "$(jq -r '."w1:t2" | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Scenario 27: rows with an empty field, and a label that has to be rewritten.
#   w1:t1 carries NO label, which is what HIDE_SHELL leaves and what herdr shows
#   its own number for. Its row therefore has an empty field in the middle, and a
#   tab-delimited row loses those: bash counts a tab as IFS whitespace, collapses
#   the run, and every field after it shifts, so this tab used to read its pane
#   count as its label and was never named again.
#   w1:t2 is owned at the base "a b" and its label carries the raw control
#   character an older fast path could leave there. Rows arrive cleaned, so the
#   label reads as equal to the name computed for it and no rename looks needed --
#   which would leave that character in place for good. A name this plugin owns is
#   written until herdr holds exactly it.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0 SHOW_PROGRAM_ARGS=1
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t2":{"auto":"a b","enabled":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"a\tb","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":300,
  "foreground_processes":[{"pid":300,"argv0":"psql","cmdline":"a b"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "a tab with no label is still named" "$out" "tab rename w1:t1 nvim"
check_contains "a name we own is written until herdr holds it" "$out" "tab rename w1:t2 a b"
check "and it stays ours" "a b true" \
  "$(jq -r '."w1:t2" | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Scenario 28: an agent tab is named after the work the agent reports.
#   Five claude tabs all read "claude", and no amount of program detection fixes
#   that -- the agent's own terminal title is the only thing that tells them
#   apart, and herdr publishes it on the pane, so it costs no call. This drives
#   the whole engine because the title arrives through ar_pane_facts, which is
#   where the pane's fields (and the directory it sits in) come from. That is one
#   of the engine's two title lifts -- this scenario ships no snapshot, so it takes
#   the per-list one; scenario 32 makes the same claims through the other.
#   t1 is the ordinary case, spinner glyph included: herdr's stripped copy is
#   ANSI-free but the glyph is text, and an agent changes it as its status
#   changes, so the tab would rename itself for no reason.
#   t2 is a refusal reaching the fallback: "Claude Code" is what an agent shows
#   before it has a task, and the tab is better off reading "claude".
#   t3 is the claim that a title needs no process lookup: no procinfo fixture
#   exists for its pane at all, so the mock serves "{}" and the program path can
#   produce nothing. A name here can only have come from the title.
#   t4 is the directory refusal, which only this level can pin: the name is
#   compared against the basename of the pane's own cwd.
#   t5 reads herdr's unstripped title, the only field an older herdr may fill.
#   t6 is the gate: a pane with no detected agent has a title too (a shell, an
#   editor, anything that writes one), and it is not a task report.
#   t7 and t8 are the agent that brands its own titles: oh-my-pi writes
#   "<brand> <spinner> <label>", brand first, so nothing the leading strip does
#   reaches the glyph and every status change renamed the tab (issue #12). t7 keeps
#   its label and loses both, and it ships no procinfo fixture, so that label can
#   only have come from the title. t8 is the reported case whole: with no session
#   title yet the label IS the pane's directory, and the brand has to come off
#   before the directory refusal can see it and hand the tab to the program name.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false},
  {"tab_id":"w1:t3","label":"3","pane_count":1,"focused":false},
  {"tab_id":"w1:t4","label":"4","pane_count":1,"focused":false},
  {"tab_id":"w1:t5","label":"5","pane_count":1,"focused":false},
  {"tab_id":"w1:t6","label":"6","pane_count":1,"focused":false},
  {"tab_id":"w1:t7","label":"7","pane_count":1,"focused":false},
  {"tab_id":"w1:t8","label":"8","pane_count":1,"focused":false}
]}}
JSON
# ✳ is the spinner glyph claude parks on the front of its title (jq decodes
# the escape, so the fixture stays readable and no editor can eat the character).
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"claude","agent_status":"working",
   "terminal_title_stripped":"✳ Squash merge command","foreground_cwd":"/home/u/dev/api"},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false,"agent":"claude","agent_status":"idle",
   "terminal_title_stripped":"Claude Code","foreground_cwd":"/home/u/dev/api"},
  {"pane_id":"p3","tab_id":"w1:t3","focused":false,"agent":"claude","agent_status":"working",
   "terminal_title_stripped":"Reticulating splines","foreground_cwd":"/home/u/dev/api"},
  {"pane_id":"p4","tab_id":"w1:t4","focused":false,"agent":"claude","agent_status":"idle",
   "terminal_title_stripped":"api","foreground_cwd":"/home/u/dev/api"},
  {"pane_id":"p5","tab_id":"w1:t5","focused":false,"agent":"codex","agent_status":"working",
   "terminal_title":"Draft the changelog","cwd":"/home/u/dev/api"},
  {"pane_id":"p6","tab_id":"w1:t6","focused":false,
   "terminal_title_stripped":"Downloading the internet","cwd":"/home/u/dev/api"},
  {"pane_id":"p7","tab_id":"w1:t7","focused":false,"agent":"omp","agent_status":"working",
   "terminal_title_stripped":"\u03c0 \u280b Squash the fixups","foreground_cwd":"/home/u/dev/api"},
  {"pane_id":"p8","tab_id":"w1:t8","focused":false,"agent":"omp","agent_status":"working",
   "terminal_title_stripped":"\u03c0 \u280b api","foreground_cwd":"/home/u/dev/api"}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"claude","cmdline":"claude"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"claude","cmdline":"claude"}]}}}
JSON
# NOTE: no procinfo_p3.json on purpose -- t3 must be named from its title alone.
fixture procinfo_p4.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":400,
  "foreground_processes":[{"pid":400,"argv0":"claude","cmdline":"claude"}]}}}
JSON
fixture procinfo_p6.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":600,
  "foreground_processes":[{"pid":600,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
# NOTE: no procinfo_p7.json either -- t7 must be named from its branded title alone.
# t8's fallback: its title is refused once the brand is off, so this is the name it
# has to land on.
fixture procinfo_p8.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":800,
  "foreground_processes":[{"pid":800,"argv0":"omp","cmdline":"omp"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "an agent tab is named after its task"  "$out" "tab rename w1:t1 Squash merge command"
check_absent   "the spinner never reaches the label"   "$out" "$SPINNER"
check_absent   "and the program name is not used"      "$out" "tab rename w1:t1 claude"
check_contains "a refused title falls back to program" "$out" "tab rename w1:t2 claude"
check_absent   "the refused title is never a label"    "$out" "Claude Code"
check_contains "a title needs no process lookup"       "$out" "tab rename w1:t3 Reticulating splines"
check_contains "a title that is just the cwd is refused" "$out" "tab rename w1:t4 claude"
check_absent   "the directory is never the label"      "$out" "tab rename w1:t4 api"
check_contains "the unstripped title is read too"      "$out" "tab rename w1:t5 Draft the changelog"
check_contains "a pane with no agent is named by program" "$out" "tab rename w1:t6 nvim"
check_absent   "a non-agent title never names a tab"   "$out" "Downloading the internet"
# The branded agent (the fixture writes both glyphs as JSON escapes; jq decodes them).
check_contains "a branded title still names its tab"   "$out" "tab rename w1:t7 Squash the fixups"
check_absent   "the brand never reaches a label"       "$out" "$PI_BRAND"
check_absent   "nor does the working spinner"          "$out" "$PI_SPINNER"
check_contains "a branded cwd title is refused"        "$out" "tab rename w1:t8 omp"
check_absent   "nor the directory behind the brand"    "$out" "tab rename w1:t8 api"
teardown

# ======================================================================
# Scenario 29: AGENT_TITLES=0 is how a user keeps program names, so nothing about
#   the old naming may change under it -- PROGRAM_ALIASES included, which is the
#   pair to the unit check that a title outranks an alias. Same pane as scenario
#   28's t1: a title that would certainly have been used. The alias comes from a
#   real config file (arrays cannot travel through the environment), which also
#   pins that the config still loads before naming.sh reads its defaults.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0 AGENT_TITLES=0
printf 'PROGRAM_ALIASES=("claude=cl")\n' >"$HERDR_AUTOMATIC_RENAME_CONFIG"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"claude","agent_status":"working",
   "terminal_title_stripped":"Squash merge command","foreground_cwd":"/home/u/dev/api"}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"claude","cmdline":"claude"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "titles off -> the alias names the tab" "$out" "tab rename w1:t1 cl"
check_absent   "and the task title is not used"        "$out" "Squash merge command"
teardown

# ======================================================================
# Scenario 30: which pane a split tab is ABOUT. A tab holding an agent and a
#   shell is about the agent, and it stays about the agent while you read the
#   shell half -- so the naming pane is not simply the one focus sits in. An IDLE
#   agent is the other side of that: it has nothing to report, and outranking the
#   pane you are actually looking at would be taking the name away from the work
#   you are doing. herdr publishes agent_status per pane, and the snapshot carries
#   the layouts that say where focus sits inside each tab, so the whole rule is
#   decided in the reshape (hence a snapshot fixture and no titles anywhere: this
#   scenario is about pane choice alone).
#   t1: focused pane is a shell, the other pane holds a WORKING agent -> the agent.
#   t2: the same shape with an IDLE agent -> the focused shell keeps the name.
#   t3: the focused pane holds the agent itself, and another pane holds a WORKING
#       one. Focus wins: the tab is named from the pane you are in, not from the
#       busiest one in it.
#   t4: BLOCKED is at work too -- an agent waiting on a permission prompt is the
#       most interesting thing in the session, and dropping that arm would be
#       invisible everywhere else.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":2,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":2,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w1:t3","label":"3","pane_count":2,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w1:t4","label":"4","pane_count":2,"focused":false,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true},
    {"pane_id":"p2","tab_id":"w1:t1","focused":false,"agent":"claude","agent_status":"working"},
    {"pane_id":"p3","tab_id":"w1:t2","focused":false},
    {"pane_id":"p4","tab_id":"w1:t2","focused":false,"agent":"claude","agent_status":"idle"},
    {"pane_id":"p5","tab_id":"w1:t3","focused":false,"agent":"claude","agent_status":"idle"},
    {"pane_id":"p6","tab_id":"w1:t3","focused":false,"agent":"codex","agent_status":"working"},
    {"pane_id":"p7","tab_id":"w1:t4","focused":false},
    {"pane_id":"p8","tab_id":"w1:t4","focused":false,"agent":"amp","agent_status":"blocked"}
  ],
  "layouts":[
    {"tab_id":"w1:t1","focused_pane_id":"p1"},
    {"tab_id":"w1:t2","focused_pane_id":"p3"},
    {"tab_id":"w1:t3","focused_pane_id":"p5"},
    {"tab_id":"w1:t4","focused_pane_id":"p7"}
  ],
  "agents":[]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"claude","cmdline":"claude"}]}}}
JSON
fixture procinfo_p3.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":300,
  "foreground_processes":[{"pid":300,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture procinfo_p4.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":400,
  "foreground_processes":[{"pid":400,"argv0":"claude","cmdline":"claude"}]}}}
JSON
fixture procinfo_p5.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":500,
  "foreground_processes":[{"pid":500,"argv0":"claude","cmdline":"claude"}]}}}
JSON
fixture procinfo_p6.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":600,
  "foreground_processes":[{"pid":600,"argv0":"codex","cmdline":"codex"}]}}}
JSON
fixture procinfo_p7.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":700,
  "foreground_processes":[{"pid":700,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture procinfo_p8.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":800,
  "foreground_processes":[{"pid":800,"argv0":"amp","cmdline":"amp"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "a working agent names the split tab"      "$out" "tab rename w1:t1 claude"
check_absent   "the focused shell does not name it"       "$out" "tab rename w1:t1 zsh"
check_contains "an idle agent leaves the focused pane"    "$out" "tab rename w1:t2 zsh"
check_absent   "an idle agent never outranks focus"       "$out" "tab rename w1:t2 claude"
check_contains "the focused pane's own agent names it"    "$out" "tab rename w1:t3 claude"
check_absent   "a busier agent elsewhere does not win"    "$out" "tab rename w1:t3 codex"
check_contains "a blocked agent is at work as well"       "$out" "tab rename w1:t4 amp"
check_absent   "the shell half does not name that one"    "$out" "tab rename w1:t4 zsh"
teardown

# ======================================================================
# Scenario 31: the reset action says what it did. Both actions are meant for a
#   keybinding, and a reset that finds nothing to re-adopt otherwise produces no
#   feedback at all -- an invisible no-op reads as a broken keybinding.
#   Pass 1: the tab is opted out (renamed by hand) and reset is aimed at it, so
#   the notification and the rename that follows it have to agree -- reporting a
#   re-adoption that did not happen is worse than saying nothing.
#   Pass 2: no tab id anywhere and no focused tab to fall back to, so there is
#   nothing to re-adopt. Pass 3: naming is off entirely, which is the same
#   headline for a different reason -- the body is the only thing that separates
#   them, so both are pinned by their body.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"","enabled":false}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"incident","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
HERDR_TAB_ID=w1:t1 run_event reset
out=$(log)
check_contains "reset re-adopts the tab it was aimed at" "$out" "tab rename w1:t1 nvim"
check_contains "and reports the re-adoption"             "$out" \
  "notification show Tab re-adopted --body Automatic naming is on for this tab again."
# No tab id, no context JSON, and `tab list` (no --workspace) has no fixture, so
# the focused-tab fallback finds nothing either.
: >"$HERDR_MOCK_LOG"
run_event reset
out=$(log)
check_contains "with no tab to re-adopt it says so" "$out" \
  "notification show Nothing to reset --body No tab to re-adopt."
check_absent   "and claims no re-adoption"          "$out" "Tab re-adopted"
# Naming off: the same headline, and the body is what says why.
: >"$HERDR_MOCK_LOG"
NAME_TABS=0 HERDR_TAB_ID=w1:t1 run_event reset
out=$(log)
check_contains "with naming off it says why" "$out" \
  "notification show Nothing to reset --body Tab naming is off (NAME_TABS=0)."
check_absent   "and re-adopts nothing"       "$out" "Tab re-adopted"
teardown

# ======================================================================
# Scenario 32: the same titles, lifted the OTHER way. There are two
#   implementations of the lift -- the reshape in ar_reconcile, which puts each
#   tab's pane facts on its row from the snapshot, and ar_pane_facts, which reads
#   the pane list back per tab where no snapshot is available. Scenario 28 drives
#   the second (it ships no snapshot.json); scenario 30 ships one but carries no
#   titles at all, so until this scenario a break in the reshape's lift renamed
#   every agent tab in a live session and no test noticed.
#   t1 is the ordinary case, spinner glyph included.
#   t2 is the load-bearing one: the tab is a split whose FOCUSED pane is a shell
#   and whose other pane holds a working agent. Scenario 30 pins that the reshape
#   picks that agent's pane; this pins that it lifts the facts of the pane it
#   picked, not of the pane focus sits in. The shell half carries a title of its
#   own, so lifting from the wrong pane is visible either way -- as that title, or
#   as the "zsh" a pane with no agent falls back to.
#   t3 is the directory refusal, which the reshape computes from its own pane's
#   cwd, and the fold that goes with it ("API" against "api").
#   t4 reads herdr's unstripped title and its plain cwd, the fields an older herdr
#   may be the only one to fill.
#   t5 is the branded agent (issue #12), the same claim scenario 28 makes for the
#   other lift: oh-my-pi puts its brand in front of its status glyph, and with no
#   session title yet its label is the directory it sits in, so the brand has to
#   come off here too for the refusal behind it to fire.
#   No procinfo fixture exists for the panes named from a title (p1, p3, p5), so
#   those names can only have come from the reshape.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
# The spinner is written as its JSON escape (jq decodes it), so the fixture stays
# readable and no editor or copy-paste can eat the character.
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":2,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w1:t3","label":"3","pane_count":1,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w1:t4","label":"4","pane_count":1,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w1:t5","label":"5","pane_count":1,"focused":false,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"claude","agent_status":"working",
     "terminal_title_stripped":"\u2733 Squash merge command","foreground_cwd":"/home/u/dev/api"},
    {"pane_id":"p2","tab_id":"w1:t2","focused":true,
     "terminal_title_stripped":"Downloading the internet","foreground_cwd":"/home/u/dev/api"},
    {"pane_id":"p3","tab_id":"w1:t2","focused":false,"agent":"codex","agent_status":"working",
     "terminal_title_stripped":"Draft the changelog","foreground_cwd":"/home/u/dev/api"},
    {"pane_id":"p4","tab_id":"w1:t3","focused":false,"agent":"claude","agent_status":"working",
     "terminal_title_stripped":"API","foreground_cwd":"/home/u/dev/api"},
    {"pane_id":"p5","tab_id":"w1:t4","focused":false,"agent":"amp","agent_status":"working",
     "terminal_title":"Rename the tabs","cwd":"/home/u/dev/api"},
    {"pane_id":"p6","tab_id":"w1:t5","focused":false,"agent":"omp","agent_status":"working",
     "terminal_title_stripped":"\u03c0 \u280b api","foreground_cwd":"/home/u/dev/api"}
  ],
  "layouts":[
    {"tab_id":"w1:t1","focused_pane_id":"p1"},
    {"tab_id":"w1:t2","focused_pane_id":"p2"},
    {"tab_id":"w1:t3","focused_pane_id":"p4"},
    {"tab_id":"w1:t4","focused_pane_id":"p5"},
    {"tab_id":"w1:t5","focused_pane_id":"p6"}
  ],
  "agents":[]
}}}
JSON
# The shell half of t2, so a lift off the wrong pane produces a real "zsh" rename
# to assert the absence of rather than no rename at all.
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
# t3's fallback: its title is refused, so this is the name it must land on.
fixture procinfo_p4.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":400,
  "foreground_processes":[{"pid":400,"argv0":"claude","cmdline":"claude"}]}}}
JSON
# t5's fallback, for the same reason, once its brand is off.
fixture procinfo_p6.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":600,
  "foreground_processes":[{"pid":600,"argv0":"omp","cmdline":"omp"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "the snapshot names a tab after its task"  "$out" "tab rename w1:t1 Squash merge command"
check_absent   "no spinner reaches a snapshot label"      "$out" "$SPINNER"
check_contains "the PICKED pane's task names a split tab" "$out" "tab rename w1:t2 Draft the changelog"
check_absent   "the focused half's title is not lifted"   "$out" "Downloading the internet"
check_absent   "nor is the focused half named instead"    "$out" "tab rename w1:t2 zsh"
check_contains "a snapshot title that is just the cwd is refused" "$out" "tab rename w1:t3 claude"
check_absent   "the directory is never the label"         "$out" "tab rename w1:t3 API"
check_contains "the unstripped title is lifted too"       "$out" "tab rename w1:t4 Rename the tabs"
check_contains "a branded snapshot title is refused too" "$out" "tab rename w1:t5 omp"
check_absent   "no brand reaches a snapshot label"       "$out" "$PI_BRAND"
check_absent   "nor a working spinner"                   "$out" "$PI_SPINNER"
check_absent   "nor the directory behind them"           "$out" "tab rename w1:t5 api"
teardown

# ======================================================================
# Scenario 33: a snapshot with NO layouts, whose tab rows are about no pane at
#   all. The reshape lifts the facts of the pane it PICKED, and with no layouts to
#   ask (a herdr that does not publish them) it picks nothing for a tab whose only
#   agent is idle -- so the row's agent, title and cwd fields come out EMPTY.
#   ar_resolve_pane still answers, off the pane list, and reading the row as that
#   pane's facts erased both of the things the facts are for: the tab lost its task
#   title, and an agent behind a runtime lost the WRAPPER_PROGRAMS unwrap that
#   shipped in 0.6.1. So the row may only be read for the pane it describes.
#   t1 is the title half: an idle claude reporting a task, whose program is
#     "claude" -- the name the empty row produced.
#   t2 is the unwrap half: an idle codex behind npx, where the process reports the
#     runtime and "node" is the whole regression.
#   Both tabs are single-pane, which is the arm the pane-list fallback answers
#   with, and neither carries a layout to make the row trustworthy.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
# No "layouts" key at all. The tabs carry workspace_id or the per-workspace slice
# in ar_reconcile_tabs drops them and nothing is named.
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"claude","agent_status":"idle",
     "terminal_title_stripped":"Squash merge command","foreground_cwd":"/home/u/dev/api"},
    {"pane_id":"p2","tab_id":"w1:t2","focused":false,"agent":"codex","agent_status":"idle",
     "agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"019f"},
     "foreground_cwd":"/home/u/dev/api"}
  ],
  "agents":[]
}}}
JSON
# p1 runs the agent under its own name, so the program path has a name to land on.
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"claude","cmdline":"claude"}]}}}
JSON
# p2: codex through npx -- argv0 absent, argv[0] is the runtime (as in scenario 19).
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv":["node","/home/u/.npm/_npx/x/node_modules/.bin/codex"],
  "name":"MainThread","cmdline":"node /home/u/.npm/_npx/x/node_modules/.bin/codex"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "no layouts: the pane's own title still names the tab" "$out" \
  "tab rename w1:t1 Squash merge command"
check_absent   "an empty row never names it by program"  "$out" "tab rename w1:t1 claude"
check_contains "no layouts: the runtime is still unwrapped" "$out" "tab rename w1:t2 codex"
check_absent   "the runtime never reaches the tab bar"   "$out" "node"
teardown

# ======================================================================
# Scenario 34: layouts that cover SOME of the tabs -- the same fault as scenario
#   33, decided per TAB rather than per snapshot. One snapshot can carry a layout
#   for one tab and none for the next (a tab herdr has not laid out yet), so
#   "a snapshot was used" is not what makes a row's pane facts usable: the row
#   describes the pane the reshape picked, and nothing else.
#   t1 is covered by a layout, so its pane IS the picked pane and its lifted title
#     names it. No procinfo fixture for that pane, so the name can only have come
#     from the row -- the control that the cheap path still works.
#   t2 has no layout, so the pane comes from the pane list and its facts have to be
#     read there. Its program is "claude", the name the empty row produced.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"claude","agent_status":"idle",
     "terminal_title_stripped":"Draft the changelog","foreground_cwd":"/home/u/dev/api"},
    {"pane_id":"p2","tab_id":"w1:t2","focused":false,"agent":"claude","agent_status":"idle",
     "terminal_title_stripped":"Reticulating splines","foreground_cwd":"/home/u/dev/api"}
  ],
  "layouts":[
    {"tab_id":"w1:t1","focused_pane_id":"p1"}
  ],
  "agents":[]
}}}
JSON
# NOTE: no procinfo_p1.json on purpose -- the covered tab must be named from its row.
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"claude","cmdline":"claude"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "a covered tab is named from its row"      "$out" "tab rename w1:t1 Draft the changelog"
check_contains "an uncovered tab reads its own pane"      "$out" "tab rename w1:t2 Reticulating splines"
check_absent   "and is not named by program instead"      "$out" "tab rename w1:t2 claude"
teardown

# ======================================================================
# Scenario 35: reset on a tab that had NOT opted out. `state del` on a key that
#   was never there succeeds quietly, so a reset that got as far as the reconcile
#   used to report a re-adoption for ANY resolvable tab id -- and whether the tab
#   is back under naming is the one thing this keybinding exists to say. So the
#   opt-out is read BEFORE the delete, and a re-adoption needs that AND the tab
#   being named and owned again in the same pass.
#   Scenario 31 pins the arm where the tab HAD opted out (plus no tab at all and
#   naming off); these are the three ways a resolvable tab had not.
#   Pass 1: a fresh tab with no state entry at all.
#   Pass 2: the same tab right after, now owned by the plugin at the name it
#     computed (enabled true) -- the steady state of every named tab, and what
#     most resets are aimed at.
#   Pass 3: a tab id no fixture describes, which is what a stale id from a closed
#     tab looks like: nothing to rename and nothing to re-adopt.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
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
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
HERDR_TAB_ID=w1:t1 run_event reset
out=$(log)
check_contains "reset still names the tab it was aimed at" "$out" "tab rename w1:t1 nvim"
check_contains "a tab with no opt-out is told there was nothing" "$out" \
  "notification show Nothing to reset --body That tab was already named automatically."
check_absent   "and no re-adoption is claimed"            "$out" "Tab re-adopted"
# Pass 2: the same tab, now a name this plugin owns and has NOT been opted out of.
: >"$HERDR_MOCK_LOG"
check "pass 1 left the tab owned and enabled" "nvim true" \
  "$(jq -r '."w1:t1" | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
HERDR_TAB_ID=w1:t1 run_event reset
out=$(log)
check_contains "an owned tab is no re-adoption either" "$out" \
  "notification show Nothing to reset --body That tab was already named automatically."
check_absent   "still no re-adoption claimed"          "$out" "Tab re-adopted"
# Pass 3: an id that resolves to no tab at all.
: >"$HERDR_MOCK_LOG"
HERDR_TAB_ID=w9:t9 run_event reset
out=$(log)
check_contains "a stale tab id re-adopts nothing" "$out" \
  "notification show Nothing to reset --body No tab to re-adopt."
check_absent   "and says so without claiming one" "$out" "Tab re-adopted"
teardown

# ======================================================================
# Scenario 36: a reset whose rename does not land says so.
#   The tab HAD opted out, so the old rule reported a re-adoption the moment its
#   state was cleared -- but herdr rejects the rename, nothing claims the tab, and
#   on the next pass it reads as first-seen with a hand-typed name and opts itself
#   straight back out. The user had been told naming was back on. A re-adoption now
#   needs the claim as well, and the tab is told the reset did not take.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
export HERDR_MOCK_FAIL_RENAME=1
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"","enabled":false}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"notes","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
HERDR_TAB_ID=w1:t1 run_event reset
out=$(log)
check_contains "the reset still tries the rename"   "$out" "tab rename w1:t1 nvim"
check_contains "a rename that fails is not a re-adoption" "$out" \
  "notification show Reset did not take --body That tab had opted out, but the rename did not land."
check_absent   "and nothing claims otherwise"      "$out" "Tab re-adopted"
teardown

# ======================================================================
# Scenario 37: an action that cannot take the lock says so instead of vanishing.
#   Events defer to whoever holds the lock, which is right: any pass computes the
#   same names, so the holder does their work too. An action carries a request that
#   lives in its own process -- which tab to re-adopt, whether to strip -- so
#   handing it over drops it. It used to exit right there, before the notification,
#   so a reset pressed during a burst of events did nothing and said nothing.
#   A lock directory with a fresh timestamp is a held lock: younger than the steal
#   window, so ar_lock refuses it for the whole wait.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename/lock"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
HERDR_TAB_ID=w1:t1 run_event reset
out=$(log)
check_contains "a contended reset reports the wait" "$out" \
  "notification show Reset is waiting --body Another naming pass held the lock. Try again."
check_absent   "and renames nothing"               "$out" "tab rename"
check_absent   "and claims no re-adoption"         "$out" "Tab re-adopted"
: >"$HERDR_MOCK_LOG"
run_event --clear
out=$(log)
check_contains "a contended clear reports it too"  "$out" \
  "notification show Clear is waiting --body Another naming pass held the lock. Try again."
teardown

# ======================================================================
# Scenario 38: the reset force does not outlive the pass it was for.
#   ar_run coalesces: an event landing while a pass runs makes the holder run the
#   reconcile again. Every one of those passes used to inherit AR_FORCE_TAB, and a
#   forced tab has its opt-out check bypassed by design -- so renaming the tab by
#   hand inside that window meant the next loop took the name straight back, which
#   is the one thing this plugin promises not to do.
#   The mock raises the rerun flag from inside the first rename, which is the only
#   way to reach the second loop (ar_run clears the flag when it starts). The tab
#   label in the fixtures never changes, so on the second pass it reads exactly
#   like a tab renamed by hand: the pass must opt it out, not re-adopt it again.
#   The action still reports the re-adoption its first pass earned.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
export HERDR_MOCK_RERUN_ONCE="$XDG_STATE_HOME/herdr-automatic-rename/rerun"
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"","enabled":false}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"notes","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
HERDR_TAB_ID=w1:t1 run_event reset
out=$(log)
check_contains "the first pass re-adopts the tab" "$out" "tab rename w1:t1 nvim"
check_contains "and the action says so"           "$out" "notification show Tab re-adopted"
check "the rerun leaves the hand-typed name alone" " false" \
  "$(jq -r '."w1:t1" | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Scenario 39: a title is normalized where it is lifted, not later.
#   The refusals compare exact strings, and the label used to be normalized after
#   them: a title of "Claude Code " (one trailing space) matched no refusal, then
#   had the space trimmed on its way into the tab bar and was recorded as a task.
#   Same for "3 ", which is herdr's own tab label wearing a space. Both are lifted
#   in their final shape now, so the comparisons see what the tab would carry.
#   t3 is the other half: a real title arrives spinner-stripped, its inner run of
#   spaces collapsed, and its trailing space gone.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","pane_count":1,"focused":true},
          {"tab_id":"w1:t2","workspace_id":"w1","label":"2","pane_count":1,"focused":false},
          {"tab_id":"w1:t3","workspace_id":"w1","label":"3","pane_count":1,"focused":false}],
  "panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"claude","agent_status":"idle",
            "terminal_title_stripped":"Claude Code ","cwd":"/w/api"},
           {"pane_id":"p2","tab_id":"w1:t2","focused":false,"agent":"claude","agent_status":"idle",
            "terminal_title_stripped":"3 ","cwd":"/w/api"},
           {"pane_id":"p3","tab_id":"w1:t3","focused":false,"agent":"claude","agent_status":"idle",
            "terminal_title_stripped":"  Squash   merge command ","cwd":"/w/api"}],
  "layouts":[{"tab_id":"w1:t1","focused_pane_id":"p1"},
             {"tab_id":"w1:t2","focused_pane_id":"p2"},
             {"tab_id":"w1:t3","focused_pane_id":"p3"}],
  "agents":[]}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"claude","cmdline":"claude"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"claude","cmdline":"claude"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "a product name with a trailing space is still refused" "$out" "tab rename w1:t1 claude"
check_contains "so is herdr's own label with one"                      "$out" "tab rename w1:t2 claude"
check_contains "and a real title arrives in the shape it will carry"   "$out" "tab rename w1:t3 Squash merge command"
teardown

# ======================================================================
# Scenario 40: which of the three pane rules survives a snapshot with NO layouts.
#   Rules 1 and 3 both ask for the tab's own focused pane, so a herdr that
#   publishes no layouts can answer neither. Rule 2 asks only for an agent at
#   work among the tab's panes, so it still answers -- and a background
#   multi-pane tab, the one the pane list can say nothing about, is named after
#   that agent. Scenario 33 pins the other half on the same path: no layout and
#   no working agent picks nothing, and the pane-list inference takes over.
#   w1:t1 is the rule that survives: background, two panes, an agent WORKING in
#     the second. Named after its task, off a snapshot with no layouts at all.
#   w1:t2 is the boundary: the same tab with the agent IDLE. Rule 2 wants an
#     agent at work, so nothing is picked, and the pane-list inference has no
#     answer for a background multi-pane tab -- the tab keeps its placeholder.
#   A regression either way shows up here: restrict rule 2 to layouts and t1
#   stops being named; drop the status test and t2 starts being.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
# No "layouts" key, as an older herdr's snapshot has none.
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"api"}],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":2,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":2,"focused":false,"workspace_id":"w1"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":false,"foreground_cwd":"/home/u/dev/api"},
    {"pane_id":"p2","tab_id":"w1:t1","focused":false,"agent":"claude","agent_status":"working",
     "terminal_title_stripped":"Squash merge command","foreground_cwd":"/home/u/dev/api"},
    {"pane_id":"p3","tab_id":"w1:t2","focused":false,"foreground_cwd":"/home/u/dev/api"},
    {"pane_id":"p4","tab_id":"w1:t2","focused":false,"agent":"claude","agent_status":"idle",
     "terminal_title_stripped":"Check PR relevance","foreground_cwd":"/home/u/dev/api"}
  ],
  "agents":[]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"zsh","cmdline":"-zsh"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"claude","cmdline":"claude"}]}}}
JSON
fixture procinfo_p3.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":300,
  "foreground_processes":[{"pid":300,"argv0":"zsh","cmdline":"-zsh"}]}}}
JSON
fixture procinfo_p4.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":400,
  "foreground_processes":[{"pid":400,"argv0":"claude","cmdline":"claude"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "no layouts: an agent at work still names its tab" "$out" \
  "tab rename w1:t1 Squash merge command"
check_absent   "and never after the shell beside it"     "$out" "tab rename w1:t1 zsh"
check_absent   "an idle agent picks no pane without a layout" "$out" "tab rename w1:t2"
teardown

# ======================================================================
# Scenario 41: a state file jq cannot read does not end tab naming.
#   Every writer starts from the file already on disk, so an unparseable one used
#   to fail every write forever. The tab lost its ownership record, read as
#   hand-renamed on the next pass, opted out, and the reset action could not bring
#   it back either: re-adopting a tab is another write. Naming was dead for the
#   session, silently, and the only fix was deleting a file nothing mentions.
#   The third check is the one that matters. The rename and the healed file can
#   both look right while naming is still dead one event later, which is exactly
#   what the old code did.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1": {"auto": "nvim", "enab' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"nvim","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"lazygit","cmdline":"lazygit"}]}}}
JSON
HERDR_TAB_ID=w1:t1 run_event reset
out=$(log)
check_contains "reset renames past a broken state file" "$out" "tab rename w1:t1 lazygit"
check "and the tab is owned again" "lazygit true" \
  "$(jq -r '."w1:t1" | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
: >"$HERDR_MOCK_LOG"
# herdr now reports the label the reset just wrote, which is what makes the tab
# recognizably ours on the next pass rather than hand-renamed (see scenario 38).
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"lazygit","pane_count":1,"focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_event tab.focused
check_contains "a later event still follows the program" "$(log)" "tab rename w1:t1 nvim"
teardown

# ======================================================================
# Scenario 42: healing a broken state file does not hand a tab its name back.
#   The pass that heals the file also opts an already-named tab out, and that is
#   the intended answer rather than a gap. A tab whose record went with the file
#   has a label matching nothing state knows, which is exactly what a name typed
#   by hand looks like, and re-adopting on "the label happens to equal what we
#   would have computed" is the one thing the opt-out exists to refuse. What the
#   heal buys is that the opt-out is RECORDED, so the reset action works again
#   (scenario 41); before it, the write failed and nothing was recorded at all.
#   Pinned on an ordinary event, not on reset, because reset bypasses the opt-out
#   check by design and so cannot show this.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1": {"auto": "nvim", "enab' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"nvim","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_event tab.focused
check_absent "an ordinary event renames nothing" "$(log)" "tab rename"
check "the opt-out is recorded, not lost" " false" \
  "$(jq -r '."w1:t1" | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
check "and the file parses again"          "object" "$(jq -r 'type' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Scenario 43: one PROGRAM_ALIASES entry covers an agent under both spellings.
#   cursor-agent is known to herdr as kind "cursor", and which of the two names
#   reaches naming is an installation detail: a natively installed one arrives as
#   its executable, an npm-fronted one as the kind the WRAPPER_PROGRAMS unwrap
#   substitutes. Keyed exactly, the same config labelled the two panes
#   differently (issue #19). The alias comes from a real config file, arrays not
#   being able to travel through the environment.
#   t1: cursor-agent behind node, detected by herdr as "cursor".
#   t2: cursor-agent run natively.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
printf 'PROGRAM_ALIASES=("cursor-agent=cx")\n' >"$HERDR_AUTOMATIC_RENAME_CONFIG"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"cursor","agent_status":"idle"},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false,"agent":"cursor","agent_status":"idle"}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv":["node","/home/u/.npm/_npx/x/node_modules/.bin/cursor-agent"],
  "name":"MainThread","cmdline":"node /home/u/.npm/_npx/x/node_modules/.bin/cursor-agent"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"cursor-agent","cmdline":"cursor-agent"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "the kind takes the alias too" "$out" "tab rename w1:t1 cx"
check_contains "and so does the executable"   "$out" "tab rename w1:t2 cx"
check_absent   "neither spelling reaches a tab" "$out" "cursor"
teardown

# ======================================================================
# Scenario 44: a workspace whose tab list could not be read keeps its records.
#   Per-list path (no snapshot.json), two workspaces, every tab owned, plus one
#   record for a tab that is gone. The pass reads w1 and fails on w2's `tab
#   list`. It used to prune on what it saw, which was w1 alone, and every w2
#   record went with it: each of those tabs then read as renamed by hand on the
#   next pass and opted out for good. A pass that could not read every
#   workspace prunes nothing, the gone tab's record included, while the
#   workspace it did read is still named. The next full read prunes what is
#   really gone and keeps the rest.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '%s\n' '{"w1:t1":{"auto":"nvim","enabled":true},
  "w2:t1":{"auto":"vim","enabled":true},"w2:t2":{"auto":"lazygit","enabled":true},
  "w2:t9":{"auto":"htop","enabled":true}}' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[
  {"workspace_id":"w1","label":"api"},
  {"workspace_id":"w2","label":"web"}
]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"nvim","pane_count":1,"focused":true}]}}
JSON
fixture tabs_w2.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w2:t1","label":"vim","pane_count":1,"focused":true},
  {"tab_id":"w2:t2","label":"lazygit","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w2:t1","focused":true},
  {"pane_id":"p3","tab_id":"w2:t2","focused":true}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"lazygit","cmdline":"lazygit"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"vim","cmdline":"vim"}]}}}
JSON
fixture procinfo_p3.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":300,
  "foreground_processes":[{"pid":300,"argv0":"lazygit","cmdline":"lazygit"}]}}}
JSON
export HERDR_MOCK_FAIL_VERB="tab list --workspace w2"
run_event tab.focused
check_contains "the workspace that was read is still named" "$(log)" "tab rename w1:t1 lazygit"
check "the unread workspace keeps every record" "true true true" \
  "$(jq -r '[."w2:t1", ."w2:t2", ."w2:t9"] | map(.enabled | tostring) | join(" ")' "$STATE" 2>/dev/null)"
unset HERDR_MOCK_FAIL_VERB
: >"$HERDR_MOCK_LOG"
# herdr now reports the label the pass just wrote (see scenario 41).
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"lazygit","pane_count":1,"focused":true}]}}
JSON
run_event tab.focused
check "a full read prunes the tab that is gone" "null" \
  "$(jq -r '."w2:t9"' "$STATE" 2>/dev/null)"
check "and keeps the ones that are not" "true true true" \
  "$(jq -r '[."w1:t1", ."w2:t1", ."w2:t2"] | map(.enabled | tostring) | join(" ")' "$STATE" 2>/dev/null)"
check "with nothing to rename" "" "$(log)"
teardown

# ======================================================================
# Scenario 45: tab.closed waits for the closing tab to leave herdr's model, then
#   renumbers the survivors against the settled list. herdr fires the event while
#   the tab is still listed, so a reconcile that ran at once would have found
#   every number correct and left the tab after the gap reading "[3]" for good.
#   The mock serves t2 to the first two `tab get` polls and reports it gone on
#   the third, so the counter file pins that the wait ended on the first poll
#   that said gone (HERDR_MOCK_TAB_GONE_AFTER + 1) rather than on a timeout. The
#   tab list is the settled one, without t2. No panes fixture: nothing here can
#   be named, so the renames are the renumbering alone.
# ===============================================================teardown

# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
export HERDR_TAB_ID=w1:t2 HERDR_MOCK_TAB_GONE_AFTER=2
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '%s\n' '{"w1:t1":{"auto":"a","enabled":true},"w1:t2":{"auto":"b","enabled":true},
  "w1:t3":{"auto":"c","enabled":true}}' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tab_w1:t2.json <<'JSON'
{"result":{"tab":{"tab_id":"w1:t2","label":"[2] b"}}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"[1] a","pane_count":1,"focused":true},
  {"tab_id":"w1:t3","label":"[3] c","pane_count":1,"focused":false}
]}}
JSON
run_event tab.closed
out=$(log)
check_contains "the survivor after the gap moves up"  "$out" "tab rename w1:t3 [2] c"
check_absent   "the survivor before it is left alone" "$out" "tab rename w1:t1"
check "the wait ended on the first poll that reported the tab gone" \
  "$(( HERDR_MOCK_TAB_GONE_AFTER + 1 ))" "$(cat "$HERDR_MOCK_LOG.tabget")"
check "the closed tab's record is pruned" "false" "$(jq 'has("w1:t2")' "$STATE")"
teardown

# ======================================================================
# Scenario 46: a "priority"-sorted agent panel strips the numbers off, on a
#   herdr that would otherwise accept them. cmd+alt+N follows the panel's
#   visible order, and in priority mode that order is the attention queue, which
#   the CLI never exposes, so a fixed "[N]" can only be wrong. The status event
#   is the one herdr fires as the queue reorders, and the revert is the same
#   --clear that hands the agent back to detection (scenarios 3 and 16). Agents
#   are the only kind read here, so the tab and pane lists stay empty.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
export HERDR_MOCK_VERSION=0.7.4   # < 0.7.5: numbering would be allowed
printf 'agent_panel_sort = "priority"\n' >"$HERDR_CONFIG_FILE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[
  {"terminal_id":"term_a","pane_id":"w1:pA","name":"[1] claude","agent_session":{"agent":"claude"}},
  {"terminal_id":"term_b","pane_id":"w1:pB","name":"[2] codex","agent_session":{"agent":"codex"}}
]}}
JSON
run_event pane.agent_status_changed
out=$(log)
check_contains "priority sort: first agent reverted"  "$out" "agent rename w1:pA --clear"
check_contains "priority sort: second agent reverted" "$out" "agent rename w1:pB --clear"
check_absent   "priority sort: nothing renumbered"    "$out" "agent rename w1:pA ["
check_absent   "priority sort: nothing renumbered (2)" "$out" "agent rename w1:pB ["
teardown

# ======================================================================
# ar_agent_sort's TOML parse, called directly. The engine is sourced in a child
# bash, where BASH_SOURCE and $0 differ and its entry point stays quiet, and the
# sandbox's HERDR_CONFIG_FILE is the only config it can find (the client
# preference file that outranks it does not exist here). The first case is the
# bug this pins: a substring match read the comment as the value, so a user who
# annotated the line with the other choice got the other choice.
# ======================================================================
sort_of() {
  printf '%s\n' "$1" >"$HERDR_CONFIG_FILE"
  bash -c '. "$1"; ar_agent_sort' _ "$ENGINE"
}
setup
check "parse: a trailing comment is not the value" "spaces" \
  "$(sort_of 'agent_panel_sort = "spaces"  # or "priority"')"
check "parse: priority reads as priority" "priority" "$(sort_of 'agent_panel_sort = "priority"')"
check "parse: no such line defaults to spaces" "spaces" "$(sort_of '')"
teardown

# ======================================================================
# Scenario 47: the plugin's own rename does not buy a second full pass.
#   Every rename the pass issues re-fires tab.renamed, and that event used to
#   run the whole reconcile again to find every number already right. When
#   state says we own the tab at exactly the label it carries, the event exits
#   before the lock. The pane here runs vim while the record says nvim, so a
#   full pass would visibly rename the tab and the skipped one visibly does not.
#   A label typed by hand, or an event with no tab id, still gets the full pass.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"nvim","enabled":true,"ws":"api"}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}]}}
JSON
fixture tab_w1:t1.json <<'JSON'
{"result":{"tab":{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"vim","cmdline":"vim"}]}}}
JSON
export HERDR_TAB_ID=w1:t1
run_event tab.renamed
check "our own rename runs no pass"          "" "$(log)"
check "and touches no state"                 "nvim true" \
  "$(jq -r '."w1:t1" | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
# The same event with no tab id has nothing to check and runs the pass.
unset HERDR_TAB_ID
run_event tab.renamed
check_contains "without a tab id the pass runs" "$(log)" "tab rename w1:t1 [1] vim"
: >"$HERDR_MOCK_LOG"
printf '{"w1:t1":{"auto":"nvim","enabled":true,"ws":"api"}}\n' >"$STATE"
export HERDR_TAB_ID=w1:t1
# A label typed by hand is not ours, so the full pass runs and opts the tab out.
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] typed-by-hand","pane_count":1,"focused":true}]}}
JSON
fixture tab_w1:t1.json <<'JSON'
{"result":{"tab":{"tab_id":"w1:t1","label":"[1] typed-by-hand","pane_count":1,"focused":true}}}
JSON
run_event tab.renamed
check "a hand rename opts the tab out"       "false" "$(jq -r '."w1:t1".enabled' "$STATE" 2>/dev/null)"
check_absent "and is left alone"             "$(log)" "tab rename w1:t1"
# A seeded record is a guess, not ownership: the pass confirms it, then owns it.
: >"$HERDR_MOCK_LOG"
printf '{"w1:t1":{"auto":"nvim","enabled":true,"seeded":true}}\n' >"$STATE"
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}]}}
JSON
fixture tab_w1:t1.json <<'JSON'
{"result":{"tab":{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}}}
JSON
run_event tab.renamed
check_contains "a seeded record still gets the pass" "$(log)" "tab rename w1:t1 [1] vim"
unset HERDR_TAB_ID
teardown

# ======================================================================
# Scenario 48: the doctor action explains an owned tab. It runs one real pass
#   with tracing forced on and reports what THAT pass decided, so the record,
#   the label, and at least one trace line about the tab all appear on stdout,
#   and the first sections go out as a single notification for a keybinding
#   with no terminal. The trace file it made is its own and is gone afterwards.
#   A user's AR_TRACE stays off throughout: the action forces its own.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
SD="$XDG_STATE_HOME/herdr-automatic-rename"; mkdir -p "$SD"
printf '{"w1:t1":{"auto":"nvim","enabled":true,"ws":"api"}}\n' >"$SD/state.json"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"nvim","pane_count":1,"focused":true}]}}
JSON
fixture tab_w1:t1.json <<'JSON'
{"result":{"tab":{"tab_id":"w1:t1","label":"nvim","pane_count":1,"focused":true}}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
out=$(HERDR_TAB_ID=w1:t1 run_event doctor)
check_rc       "doctor exits 0"                          0 $?
check_contains "doctor names the tab"                    "$out" "tab: w1:t1"
check_contains "doctor prints the record"                "$out" "enabled=true"
check_contains "doctor prints the label"                 "$out" "label: [nvim]"
check_contains "doctor shows a trace line about the tab" "$out" "w1:t1 owned unchanged"
check_contains "doctor shows what the pass concluded"    "$out" "w1:t1 label already correct: [nvim]"
check_contains "doctor prints the naming knobs"          "$out" "NAME_TABS=1 NAME_PANES=1 AUTO_INDEX=0"
check "one notification"                                 "1" "$(log | grep -c '^notification show')"
check_contains "the notification carries the record"     "$(log)" "enabled=true"
check "the doctor's trace file is cleaned up"            "" "$(ls "$SD"/.doctor.* 2>/dev/null)"
check "no trace.log is left either"                      "" "$(ls "$SD"/trace.log 2>/dev/null)"
teardown

# ======================================================================
# Scenario 49: the doctor on a tab that opted out. This is the report issue
#   diagnosis keeps needing: the record says enabled=false and the trace names
#   the arm that left the label alone, so a user can tell "you renamed it by
#   hand once" from "nothing is running".
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
SD="$XDG_STATE_HOME/herdr-automatic-rename"; mkdir -p "$SD"
printf '{"w1:t1":{"auto":"","enabled":false}}\n' >"$SD/state.json"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"incident","pane_count":1,"focused":true}]}}
JSON
fixture tab_w1:t1.json <<'JSON'
{"result":{"tab":{"tab_id":"w1:t1","label":"incident","pane_count":1,"focused":true}}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
out=$(HERDR_TAB_ID=w1:t1 run_event doctor)
check_contains "doctor reports the opt-out record"  "$out" "enabled=false"
check_contains "and the arm that honored it"        "$out" "w1:t1 opt-out stands"
check_contains "and the label the user typed"       "$out" "label: [incident]"
check_absent   "doctor renames nothing"             "$(log)" "tab rename"
teardown

# ======================================================================
# Scenario 50: the doctor with no tab to explain. No tab id, no action context,
#   and `tab list` (no --workspace) has no fixture, so the focused-tab fallback
#   finds nothing. The notification says so, the exit status is still 0, and the
#   whole pass's trace is shown instead, since "is anything running" is the
#   question left.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
out=$(run_event doctor)
check_rc       "doctor still exits 0"                  0 $?
check_contains "doctor says no tab resolved"           "$out" "tab: none resolved"
check_contains "and shows the pass ran"                "$out" "lock acquired: action full pass"
check_contains "the notification says so too"         "$(log)" "notification show Doctor: no tab resolved"
teardown

# ======================================================================
# Scenario 51: an ordinary pass with AR_TRACE unset writes no trace file. The
#   hooks fire this on every prompt, and a file that grows in the state dir
#   without anyone asking is the one thing tracing must not do by default. Set
#   empty rather than unset, so a developer's own AR_TRACE cannot make this pass.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
SD="$XDG_STATE_HOME/herdr-automatic-rename"
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
AR_TRACE='' AR_TRACE_FILE='' run_event tab.focused
check_contains "the pass still names the tab"   "$(log)" "tab rename w1:t1 [1] zsh"
check "and leaves no trace.log behind"          "" "$(ls "$SD"/trace.log 2>/dev/null)"
# The same pass with tracing on writes to the default path in the state dir.
# herdr now reports the label the pass just wrote (see scenario 41).
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] zsh","pane_count":1,"focused":true}]}}
JSON
AR_TRACE=1 AR_TRACE_FILE='' run_event tab.focused
check_contains "with AR_TRACE set the file appears" \
  "$(cat "$SD/trace.log" 2>/dev/null)" "w1:t1 label already correct: [[1] zsh]"
check "and is private to the user" "600" "$(stat -c %a "$SD/trace.log" 2>/dev/null || stat -f %Lp "$SD/trace.log" 2>/dev/null)"

teardown

# ======================================================================
# Scenario 52: doctor under a held lock says so, like reset and clear, instead
#   of reporting the old state and label as if a pass had just run.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename/lock"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] zsh","pane_count":1,"focused":true}]}}
JSON
out=$(HERDR_TAB_ID=w1:t1 run_event doctor)
check_contains "a contended doctor says no pass ran" "$out" "held the lock"
check_contains "and notifies like the other actions" "$(log)" \
  "notification show Doctor is waiting --body Another naming pass held the lock. Try again."
check_absent   "and prints no report"           "$out" "record:"

teardown

t_summary
