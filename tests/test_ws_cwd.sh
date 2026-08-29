#!/usr/bin/env bash
# Integration test: a numbered workspace still follows its directory (issue #13).
#
# herdr labels a workspace after identity_cwd, its own tracked directory: the
# repository that directory belongs to, or the directory itself outside a repo.
# The FIRST `workspace rename` freezes that derivation for good -- herdr keeps
# identity_cwd up to date and never re-labels from it again -- so numbering a
# workspace used to stop its label tracking cd, permanently.
#
# The engine takes the base from identity_cwd (session.json, next to
# $HERDR_SOCKET_PATH, the file ar_collapsed_spaces already reads) instead of
# recycling the label it wrote last pass. Ownership gates it: a label that is
# neither herdr's derivation nor our own last write was typed by somebody, so it
# is left alone -- the same promise the tab opt-out makes.

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

# ======================================================================
# ar_project_base: the derivation itself, against real directories. Sourcing the
# engine loads the functions and runs nothing.
# ======================================================================
# shellcheck source=automatic-rename.sh
. "$ENGINE"

PB=$(mktemp -d "${TMPDIR:-/tmp}/hal-pbase.XXXXXX")
mkdir -p "$PB/plain/sub" "$PB/co/src/deep" "$PB/wt"
: >"$PB/co/.git"                       # a checkout: `.git` as a FILE, as a linked worktree has
mkdir -p "$PB/repo/.git" "$PB/repo/pkg"   # and as a directory, as a main checkout has
check "repo root itself"        "co"    "$(ar_project_base "$PB/co")"
check "inside the checkout"     "co"    "$(ar_project_base "$PB/co/src/deep")"
check "git dir, not file"       "repo"  "$(ar_project_base "$PB/repo/pkg")"
check "outside any repo"        "sub"   "$(ar_project_base "$PB/plain/sub")"
check "trailing slash ignored"  "sub"   "$(ar_project_base "$PB/plain/sub/")"
check "relative path: basename" "notes" "$(ar_project_base "some/notes")"
check "empty path: empty base"  ""      "$(ar_project_base "")"

WORKSPACE_SUBSTITUTE_SETS=('s|^worktree-|wt-|')
check "workspace display rewrite" "wt-feature" "$(ar_workspace_subst "worktree-feature")"
check "workspace rewrite nonmatch" "project-a" "$(ar_workspace_subst "project-a")"
WORKSPACE_SUBSTITUTE_SETS=()
rm -rf "$PB"

# Numbering only (NAME_TABS off, no tab/pane fixtures), so the rename log holds
# workspace renames alone. State is NOT sandboxed per scenario on purpose in the
# multi-pass ones: ownership has to survive from one event to the next.
setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-wscwd.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"   # absent -> env toggles win
  export HERDR_CONFIG_FILE="$SB/herdr.toml"
  printf 'agent_panel_sort = "spaces"\n' >"$HERDR_CONFIG_FILE"
  export HERDR_SOCKET_PATH="$SB/herdr.sock"            # session.json sits beside it
  export SHELL_NAME=zsh
  export NAME_TABS=0 AUTO_INDEX=1
  unset AUTO_INDEX_WORKSPACES CLEAR
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }
# ws <id> <label>  -- one workspace, no worktree (its own sidebar row).
ws() { printf '{"workspace_id":"%s","label":"%s","focused":false}' "$1" "$2"; }
workspaces() { printf '{"result":{"workspaces":[%s]}}\n' "$(printf '%s' "$*")" \
  >"$HERDR_MOCK_DIR/workspaces.json"; }
# repo <path>  -- make <path> (under $SB) a checkout: a directory with a `.git`
# in it, which is what ar_project_base walks for. A `.git` FILE, as a linked
# worktree has, since that is the case a `-d` test would miss.
repo() { mkdir -p "$SB$1" && : >"$SB$1/.git"; }
# session <"id=cwd" ...>  -- the session file herdr persists, with identity_cwd.
# The directories are made real (rooted at $SB) because ar_project_base walks them
# looking for a repo, so a fictional path would only ever exercise the non-repo arm.
session() {
  local rows="" e p
  for e in "$@"; do
    p=$SB${e#*=}
    mkdir -p "$p"
    rows="$rows${rows:+,}$(printf '{"id":"%s","label":null,"identity_cwd":"%s"}' \
      "${e%%=*}" "$p")"
  done
  printf '{"version":7,"collapsed_space_keys":[],"workspaces":[%s]}\n' "$rows" \
    >"$SB/session.json"
}
run_event() { /usr/bin/env bash "$ENGINE" "$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
clear_log() { : >"$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# ======================================================================
# Scenario 1: the bug. A fresh workspace is numbered, its pane cds elsewhere,
#   and the next event must re-label it from the new directory.
# ======================================================================
setup
workspaces "$(ws w1 project-a)"
session "w1=/home/u/project-a"
run_event workspace.created
check_contains "fresh ws numbered" "$(log)" "workspace rename w1 [1] project-a"

clear_log
workspaces "$(ws w1 '[1] project-a')"
session "w1=/home/u/project-b"
run_event pane.focused
check_contains "label follows cd" "$(log)" "workspace rename w1 [1] project-b"

# ...and settles: a second event over the same state renames nothing.
clear_log
workspaces "$(ws w1 '[1] project-b')"
run_event pane.focused
check "settled: no rename" "" "$(log)"
teardown

# ======================================================================
# Scenario 2: cd INSIDE the repo keeps the repo's name. herdr labels a workspace
#   after the repository its directory belongs to, so walking down into src/ is
#   not a rename -- taking the directory's own basename would rename the
#   workspace on every cd inside the project.
# ======================================================================
setup
repo /repos/herdr
workspaces "$(ws w1 '[1] herdr')"
session "w1=/repos/herdr/docs/deep"
run_event pane.focused
check "cd within the repo: no rename" "" "$(log)"

# ...and leaving the repo for a plain directory takes that directory's name.
clear_log
session "w1=/elsewhere/notes"
run_event pane.focused
check_contains "leaving the repo tracks the directory" "$(log)" "workspace rename w1 [1] notes"
teardown

# ======================================================================
# Scenario 3: a label nobody derived is a label somebody typed. The plugin
#   numbers it and never touches the base again, even as identity_cwd moves.
# ======================================================================
setup
workspaces "$(ws w1 'incident room')"
session "w1=/home/u/project-a"
run_event workspace.created
check_contains "hand-named ws still numbered" "$(log)" "workspace rename w1 [1] incident room"

clear_log
workspaces "$(ws w1 '[1] incident room')"
session "w1=/home/u/project-b"
run_event pane.focused
check "hand-named base survives a cd" "" "$(log)"
teardown

# ======================================================================
# Scenario 4: a rename typed over a label we owned opts the workspace out from
#   then on -- the tab promise, for workspaces.
# ======================================================================
setup
workspaces "$(ws w1 project-a)"
session "w1=/home/u/project-a"
run_event workspace.created                       # adopt at project-a

clear_log
workspaces "$(ws w1 '[1] war room')"              # typed over our label
session "w1=/home/u/project-b"
run_event pane.focused
check "typed-over label is left alone" "" "$(log)"

clear_log
workspaces "$(ws w1 '[1] war room')"
session "w1=/home/u/project-c"
run_event pane.focused
check "and stays left alone after another cd" "" "$(log)"
teardown

# ======================================================================
# Scenario 5: renaming a workspace back to what herdr would call it hands
#   tracking back. That is the recovery path, since a workspace has no `reset`.
# ======================================================================
setup
workspaces "$(ws w1 '[1] war room')"
session "w1=/home/u/project-a"
run_event pane.focused                            # opts out (nobody derived that)

clear_log
workspaces "$(ws w1 '[1] project-a')"             # renamed back by hand
session "w1=/home/u/project-a"
run_event pane.focused
check "matching label is not renamed" "" "$(log)"

clear_log
workspaces "$(ws w1 '[1] project-a')"
session "w1=/home/u/project-b"
run_event pane.focused
check_contains "tracking resumes" "$(log)" "workspace rename w1 [1] project-b"
teardown

# ======================================================================
# Scenario 6: no identity_cwd to read -- no session file at all (herdr older
#   than the field, an unreadable file) -- falls back to recycling the label,
#   which is what the plugin did before it read this. Numbering still works.
# ======================================================================
setup
workspaces "$(ws w1 project-a)"
rm -f "$SB/session.json"
run_event workspace.created
check_contains "no session file: still numbered" "$(log)" "workspace rename w1 [1] project-a"

clear_log
workspaces "$(ws w1 '[1] project-a')"
run_event pane.focused
check "no session file: label recycled, no churn" "" "$(log)"
teardown

# ======================================================================
# Scenario 7: --clear only strips. It is the uninstall path, so it must not
#   rewrite a base to the directory name on its way out.
# ======================================================================
setup
workspaces "$(ws w1 '[1] war room')"
session "w1=/home/u/project-b"
/usr/bin/env bash "$ENGINE" --clear >/dev/null 2>&1
check_contains "clear strips the prefix only" "$(log)" "workspace rename w1 war room"
check_absent   "clear does not retitle"       "$(log)" "project-b"
teardown

# ======================================================================
# Scenario 8: numbering off but explicitly named (AUTO_INDEX_WORKSPACES=0) asks
#   for the prefix to be stripped, and the base still tracks the directory.
# ======================================================================
setup
export AUTO_INDEX_WORKSPACES=0
workspaces "$(ws w1 '[1] project-a')"
session "w1=/home/u/project-a"
run_event pane.focused                            # adopt, and strip the prefix
check_contains "numbering off: prefix stripped" "$(log)" "workspace rename w1 project-a"

clear_log
workspaces "$(ws w1 project-a)"
session "w1=/home/u/project-b"
run_event pane.focused
check_contains "numbering off: bare base tracks cd" "$(log)" "workspace rename w1 project-b"
teardown

# ======================================================================
# Scenario 9: a rename that FAILS records no ownership. A base we did not land
#   is indistinguishable, one pass later, from a name typed by hand.
# ======================================================================
setup
export HERDR_MOCK_FAIL_RENAME=1
workspaces "$(ws w1 project-a)"
session "w1=/home/u/project-a"
run_event workspace.created
unset HERDR_MOCK_FAIL_RENAME
check "failed rename claims nothing" \
  "" "$(jq -r '."ws:w1".auto // ""' "$XDG_STATE_HOME/herdr-automatic-rename/state.json" 2>/dev/null)"
teardown

# ======================================================================
# Scenario 10: a workspace that closes takes its ownership record with it, so a
#   long session does not grow one entry per workspace it ever had.
# ======================================================================
setup
workspaces "$(ws w1 project-a)" , "$(ws w2 project-b)"
session "w1=/home/u/project-a" "w2=/home/u/project-b"
run_event workspace.created
state=$XDG_STATE_HOME/herdr-automatic-rename/state.json
check "both owned" "project-a project-b" \
  "$(jq -r '[."ws:w1".auto, ."ws:w2".auto] | join(" ")' "$state" 2>/dev/null)"

workspaces "$(ws w1 '[1] project-a')"             # w2 closed
session "w1=/home/u/project-a"
run_event workspace.closed
check "closed ws pruned"  "null"       "$(jq -r '."ws:w2" | tostring' "$state" 2>/dev/null)"
check "open ws kept"      "project-a"  "$(jq -r '."ws:w1".auto' "$state" 2>/dev/null)"
teardown

# ======================================================================
# Scenario 11: the tab pass must not prune the workspace records. Both kinds
#   live in one state file, and a tab keep-list never names a workspace: pruning
#   on it alone dropped every "ws:" record on the pass after it was written, so
#   each workspace read as first-seen against a label that was no longer herdr's
#   derivation and opted itself out -- the same bug, one layer down. Found live,
#   not in the suite, which is why it is pinned here.
# ======================================================================
setup
export NAME_TABS=1
workspaces "$(ws w1 project-a)"
session "w1=/home/u/project-a"
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
state=$XDG_STATE_HOME/herdr-automatic-rename/state.json
check "ws record survives the tab prune" "project-a" \
  "$(jq -r '."ws:w1".auto // ""' "$state" 2>/dev/null)"
check "tab record written too"           "nvim" \
  "$(jq -r '."w1:t1".auto // ""' "$state" 2>/dev/null)"

clear_log
workspaces "$(ws w1 '[1] project-a')"
session "w1=/home/u/project-b"
run_event tab.focused
check_contains "and tracking still works" "$(log)" "workspace rename w1 [1] project-b"
teardown

# ======================================================================
# Scenario 12: the workspace herdr has not persisted yet, which is EVERY new
#   one for up to five seconds. It is in no copy of session.json, so a pass
#   numbering it seconds after it opened used to read "a label nobody derived",
#   opt it out for good, and leave it on its creation name forever -- the very
#   bug, surviving the fix. The pane's own directory settles the comparison at
#   creation, where herdr's label and the pane agree. Snapshot path, since that
#   is what herdr >= 0.7.2 gives every pass.
# ======================================================================
setup
mkdir -p "$SB/home/project-a" "$SB/home/project-b"
snapshot() {   # snapshot <ws label> <pane cwd under $SB>
  cat >"$HERDR_MOCK_DIR/snapshot.json" <<JSON
{"result":{"snapshot":{"workspaces":[
  {"workspace_id":"w1","label":"$1","focused":true,"active_tab_id":"w1:t1"}
],"tabs":[],"panes":[
  {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,
   "foreground_cwd":"$SB$2"}
],"agents":[]}}}
JSON
}
session "w9=/home/other"                          # the file exists, without w1 in it
snapshot project-a /home/project-a
run_event workspace.created
check_contains "unpersisted ws numbered" "$(log)" "workspace rename w1 [1] project-a"
state=$XDG_STATE_HOME/herdr-automatic-rename/state.json
check "and claimed from its pane" "project-a" \
  "$(jq -r '."ws:w1".auto // ""' "$state" 2>/dev/null)"

# The pane cds while herdr still has not written the file: tracking already works.
clear_log
snapshot '[1] project-a' /home/project-b
run_event pane.focused
check_contains "tracks before herdr persists it" "$(log)" "workspace rename w1 [1] project-b"
teardown

# ======================================================================
# Scenario 13: the create prompt (`prompt_new_workspace_name`) types the name
#   before the plugin ever sees the workspace, and that name is not what the
#   pane's directory would give. It gets numbered and nothing else, which is the
#   promise the README makes.
# ======================================================================
setup
mkdir -p "$SB/home/project-a" "$SB/home/project-b"
session "w9=/home/other"
snapshot 'incident room' /home/project-a
run_event workspace.created
check_contains "typed name numbered" "$(log)" "workspace rename w1 [1] incident room"

clear_log
snapshot '[1] incident room' /home/project-b
run_event pane.focused
check "typed name never retitled" "" "$(log)"
teardown

# ======================================================================
# Scenario 14: once herdr HAS persisted the workspace, its identity_cwd wins
#   over the pane directory. herdr moves identity with the workspace's active
#   pane and answering which pane that is takes the layout, so the file is the
#   answer and the panes are only the stand-in for a workspace missing from it.
# ======================================================================
setup
mkdir -p "$SB/home/from-identity" "$SB/home/from-pane"
cat >"$HERDR_MOCK_DIR/snapshot.json" <<JSON
{"result":{"snapshot":{"workspaces":[
  {"workspace_id":"w1","label":"[1] stale","focused":true,"active_tab_id":"w1:t1"}
],"tabs":[],"panes":[
  {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,
   "foreground_cwd":"$SB/home/from-pane"}
],"agents":[]}}}
JSON
session "w1=/home/from-identity"
printf '{"ws:w1":{"auto":"stale","enabled":true}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json" 2>/dev/null \
  || { mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"; \
       printf '{"ws:w1":{"auto":"stale","enabled":true}}\n' \
         >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"; }
run_event pane.focused
check_contains "identity_cwd wins" "$(log)" "workspace rename w1 [1] from-identity"
check_absent   "pane dir ignored"  "$(log)" "from-pane"
teardown

# ======================================================================
# Scenario 15: workspace substitutions change only the displayed, derived name
# and compose with numbering.
# ======================================================================
setup
printf '%s\n' "WORKSPACE_SUBSTITUTE_SETS=('s|^worktree-|wt-|')" \
  >"$HERDR_AUTOMATIC_RENAME_CONFIG"
workspaces "$(ws w1 worktree-feature)"
session "w1=/home/u/worktree-feature"
run_event workspace.created
check_contains "numbered workspace display rewritten" "$(log)" "workspace rename w1 [1] wt-feature"

clear_log
workspaces "$(ws w1 '[1] wt-feature')"
run_event pane.focused
check "rewritten workspace settles" "" "$(log)"
teardown

# ======================================================================
# Scenario 16: substitutions run without numbering when AUTO_INDEX is off.
# ======================================================================
setup
export AUTO_INDEX=0
printf '%s\n' "WORKSPACE_SUBSTITUTE_SETS=('s|^worktree-|wt-|')" \
  >"$HERDR_AUTOMATIC_RENAME_CONFIG"
workspaces "$(ws w1 worktree-feature)"
session "w1=/home/u/worktree-feature"
run_event workspace.created
check_contains "unnumbered workspace display rewritten" "$(log)" "workspace rename w1 wt-feature"
teardown

# ======================================================================
# Scenario 17: the list-command fallback derives a new workspace from its pane
# before session.json has persisted it.
# ======================================================================
setup
export AUTO_INDEX=0
printf '%s\n' "WORKSPACE_SUBSTITUTE_SETS=('s|^worktree-|wt-|')" \
  >"$HERDR_AUTOMATIC_RENAME_CONFIG"
mkdir -p "$SB/home/worktree-feature"
workspaces "$(ws w1 worktree-feature)"
session "w9=/home/other"
fixture panes.json <<JSON
{"result":{"panes":[
  {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true,
   "foreground_cwd":"$SB/home/worktree-feature"}
]}}
JSON
run_event workspace.created
check_contains "fallback workspace display rewritten" "$(log)" "workspace rename w1 wt-feature"
teardown

# ======================================================================
# Scenario 18: a matching pattern does not rewrite a name typed by the user.
# ======================================================================
setup
export AUTO_INDEX=0
printf '%s\n' "WORKSPACE_SUBSTITUTE_SETS=('s|^worktree-|wt-|')" \
  >"$HERDR_AUTOMATIC_RENAME_CONFIG"
workspaces "$(ws w1 '[1] worktree-incident')"
session "w1=/home/u/project-a"
run_event workspace.created
check "manual workspace name not rewritten" "" "$(log)"
teardown

# ======================================================================
# Scenario 19: removing the substitution restores the derived workspace label
# even when global numbering is off and would not otherwise run this pass.
# ======================================================================
setup
export AUTO_INDEX=0
printf '%s\n' "WORKSPACE_SUBSTITUTE_SETS=('s|^worktree-|wt-|')" \
  >"$HERDR_AUTOMATIC_RENAME_CONFIG"
workspaces "$(ws w1 worktree-feature)"
session "w1=/home/u/worktree-feature"
run_event workspace.created

clear_log
: >"$HERDR_AUTOMATIC_RENAME_CONFIG"
workspaces "$(ws w1 wt-feature)"
run_event pane.focused
check_contains "removed rewrite restores derived name" "$(log)" \
  "workspace rename w1 worktree-feature"
teardown

# ======================================================================
# Scenario 20: a substitution-only pass does not claim a workspace when no rule
# changes its name, so removing the rules cannot leave stale ownership records.
# ======================================================================
setup
export AUTO_INDEX=0
printf '%s\n' "WORKSPACE_SUBSTITUTE_SETS=('s|^worktree-|wt-|')" \
  >"$HERDR_AUTOMATIC_RENAME_CONFIG"
workspaces "$(ws w1 project-a)"
session "w1=/home/u/project-a"
run_event workspace.created
check "nonmatching rewrite does not rename" "" "$(log)"
check "nonmatching rewrite claims no state" "" \
  "$(jq -r '."ws:w1".auto // ""' "$XDG_STATE_HOME/herdr-automatic-rename/state.json" 2>/dev/null)"
teardown

# ======================================================================
# Scenario 21: removing the last rewritten workspace also removes its pending
# restoration state instead of scheduling an empty workspace pass forever.
# ======================================================================
setup
export AUTO_INDEX=0
printf '%s\n' "WORKSPACE_SUBSTITUTE_SETS=('s|^worktree-|wt-|')" \
  >"$HERDR_AUTOMATIC_RENAME_CONFIG"
workspaces "$(ws w1 worktree-feature)"
session "w1=/home/u/worktree-feature"
run_event workspace.created

: >"$HERDR_AUTOMATIC_RENAME_CONFIG"
workspaces
session "w9=/home/other"
run_event workspace.closed
check "closed rewritten workspace state pruned" "null" \
  "$(jq -r '."ws:w1" | tostring' "$XDG_STATE_HOME/herdr-automatic-rename/state.json" 2>/dev/null)"
teardown

t_summary
