#!/usr/bin/env bash
# Tests for TITLE_CONDENSE -- the keyword condensation layered on AGENT_TITLES.
#
# Two halves. The first is pure string in / string out against ar_condense_title,
# the way tests/test_naming.sh tests the rest of naming.sh. The second drives the
# real engine against the fake herdr, because the knob is only worth anything if
# it sits in the title path the reconcile actually walks, and a unit test cannot
# say whether it was wired in at all.
#
# This file is deliberately separate from the released suites rather than folded
# into them: TITLE_CONDENSE defaults to off, so every released expectation still
# describes the shipped behavior, and nothing here has to be re-resolved when
# those files change upstream.

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

SHELL_NAME=zsh
# shellcheck source=naming.sh
. "$here/../naming.sh"

# ---- what gets dropped ----
check "leading verb goes" "screensaver-timeout" \
  "$(ar_condense_title 'Adjust the screensaver timeout')"
check "filler goes throughout" "nightly-ETL-job-drops-rows" \
  "$(ar_condense_title 'Investigate why the nightly ETL job drops rows')"
# "port" is not in the list: measured against real titles it is a noun far more
# often than a verb here, and the leading position is exactly where that bites.
check "port is a subject, not a verb" "port-forwarding-broken" \
  "$(ar_condense_title 'Port forwarding is broken')"

# The list still matches spelling rather than part of speech, which is a real
# limit and not a bug to be fixed by lengthening the list. A title whose subject
# shares a listed verb spelling loses it, and taking the word out is the answer.
check "a listed spelling goes, verb or not" "needs-approval" \
  "$(ar_condense_title 'Plan needs approval')"
check "and dropping it from the list restores it" "plan-needs-approval" \
  "$(TITLE_LEAD_VERBS=(review adjust fix); ar_condense_title 'Plan needs approval')"

# The openers the corpus turned up that the hand-written list had missed.
check "analyze is a lead verb" "flashcard-pipeline-latency" \
  "$(ar_condense_title 'Analyze flashcard pipeline latency')"
check "troubleshoot is a lead verb" "waybar-restart-loop" \
  "$(ar_condense_title 'Troubleshoot the Waybar restart loop')"
check "a non-leading verb stays" "auth-rewrite-needs-review" \
  "$(ar_condense_title 'The auth rewrite needs review')"

# The order the agent wrote is the order kept: it put the salient words first,
# and re-ranking them by "distinctness" reads worse (see the note on the function).
check "word order is preserved" "RFC7-wording-clarity" \
  "$(ar_condense_title 'Review RFC7 wording for clarity')"

# ---- separators inside the title are word breaks ----
check "slash is a word break" "build-services-payments" \
  "$(ar_condense_title 'Fix build for services/payments')"
check "colon is a word break" "ADR-0028-step-3" \
  "$(ar_condense_title 'ADR 0028: step 3')"
# A kebab-case title is several words, so the cut lands between two of them
# rather than in the middle of one (issue #32).
check "hyphen is a word break" "foundation-claude" \
  "$(MAX_TITLE_LEN=18 ar_condense_title 'foundation-claude-handoff-config')"
check "a spaced dash is not a word" "parser-urgent" \
  "$(ar_condense_title 'Fix parser - urgent')"
# The verb and filler rules still read a hyphenated word whole, so a compound
# keeps its parts: only the cut sees the hyphen.
check "a compound's first part is not a lead verb" "build-time-cache-fix" \
  "$(ar_condense_title 'Build-time cache fix')"
check "nor are its inner parts filler" "end-to-end-tests-login" \
  "$(ar_condense_title 'end-to-end tests for login')"
check "a slug keeps its leading verb" "fix-host-reboot" \
  "$(MAX_TITLE_LEN=18 ar_condense_title 'fix-host-reboot-cycle')"

# ---- what this function deliberately does NOT do ----
# A leading glyph and a leading brand are both taken off upstream, by lead and
# debrand in AR_JQ_TASK, on every path that reaches here. So this function is
# never handed either, and it strips neither: a second copy of an upstream rule
# is free to drift from it. These two pin that contract, and the end-to-end
# scenarios below prove the engine really does strip them before we are called.
check "a leading brand is not ours to strip" "OC-reviewing-unpushed" \
  "$(ar_condense_title 'OC | Reviewing unpushed commits')"
check "nor is leading punctuation" ">>>-parser-rewrite" \
  "$(ar_condense_title '>>> Parser rewrite')"
# A pipe is still a word break, so a title that reaches us with one is split on
# it rather than carrying it into the label.
check "a pipe is a word break" "auth-login-flow" \
  "$(ar_condense_title 'auth | login flow')"

# ---- an all-caps identifier is not filler ----
# Filler is matched case-insensitively and the casing rule spares all-caps tokens,
# so without an exemption the two disagree and the identifier is the one that goes.
check "IT survives the filler list" "IT-outage" \
  "$(ar_condense_title 'Investigate IT outage')"
check "OR survives it too" "OR-parser-precedence" \
  "$(ar_condense_title 'Fix OR parser precedence')"
check "lowercase filler still goes" "screensaver-timeout" \
  "$(ar_condense_title 'Adjust the screensaver timeout')"
# Listing the word in capitals is how you ask for it to go anyway; lower case in
# the list does not reach an all-caps token.
check "a capitalised entry drops it" "wording" \
  "$(TITLE_FILLER_WORDS=(RFC the); ar_condense_title 'Fix the RFC wording')"
check "a lowercase entry does not" "RFC-wording" \
  "$(TITLE_FILLER_WORDS=(rfc the); ar_condense_title 'Fix the RFC wording')"
# Two documented costs of the rule, pinned so they are noticed if they change.
check "shouted prose keeps its capitals" "THE-parser" \
  "$(ar_condense_title 'Fix THE parser')"
check "a one-letter identifier is not covered" "record-resolution" \
  "$(ar_condense_title 'Fix A record resolution')"

# ---- casing ----
check "fold spares an identifier" "RFC7-wording-clarity" \
  "$(TITLE_CASE='fold' ar_condense_title 'Review RFC7 wording for clarity')"
check "lower folds it too" "rfc7-wording-clarity" \
  "$(TITLE_CASE='lower' ar_condense_title 'Review RFC7 wording for clarity')"
check "keep leaves the agent's casing" "RFC7-Wording-Clarity" \
  "$(TITLE_CASE='keep' ar_condense_title 'Review RFC7 Wording For Clarity')"
check "an unknown case behaves as fold" "RFC7-wording-clarity" \
  "$(TITLE_CASE='sideways' ar_condense_title 'Review RFC7 wording for clarity')"

# ---- separator ----
check "the separator is configurable" "screensaver timeout" \
  "$(TITLE_WORD_SEPARATOR=' ' ar_condense_title 'Adjust the screensaver timeout')"
check "and is charged to the budget" "nightly_ETL_job_drops" \
  "$(TITLE_WORD_SEPARATOR=_ MAX_TITLE_LEN=24 ar_condense_title 'Investigate why the nightly ETL job drops rows')"

# ---- the budget ----
# Whole words only, and it stops at the first that does not fit rather than
# skipping ahead to a shorter one: a later word reads as a non sequitur beside
# the ones before it.
check "stops at the first word that does not fit" "nightly-ETL-pipeline" \
  "$(MAX_TITLE_LEN=24 ar_condense_title 'Investigate why the nightly ETL pipeline drops duplicate rows')"
check "reserved text comes out of the budget" "nightly-ETL" \
  "$(MAX_TITLE_LEN=24 ar_condense_title 'Investigate why the nightly ETL pipeline drops duplicate rows' '            ')"
# A single word longer than the whole budget is cut rather than dropped, or the
# label would be empty and the sentence would come back instead.
check "an oversized lone word is cut" "supercalifragilisti" \
  "$(MAX_TITLE_LEN=19 ar_condense_title 'supercalifragilisticexpialidocious')"

# The budget is codepoints, not bytes. herdr may launch a plugin with no LC_*,
# where bash counts bytes and would cut a multibyte character in half. Counted as
# bytes this label stops after "funf" (5 bytes + 6 for the next word exceeds 11);
# counted as codepoints both words fit.
#
# The capital survives because the fold is ascii_downcase, which is jq's only
# case operation: its character CLASSES know Unicode, its case conversion does
# not. A non-ASCII capital therefore reaches the label as the agent wrote it.
check "the budget counts codepoints" "$(printf 'f\303\274nf-\303\204pfel')" \
  "$(LC_ALL=C MAX_TITLE_LEN=11 ar_condense_title "$(printf 'F\303\274nf \303\204pfel gefunden')")"

# ---- nothing to say ----
check "an empty title condenses to nothing" "" "$(ar_condense_title '')"
# All filler condenses to nothing, and the caller keeps the sentence rather than
# renaming the tab to an empty string.
check "an all-filler title condenses to nothing" "" "$(ar_condense_title 'to the of')"

# ---- the name prefix is priced in too ----
# TITLE_STYLE=name_and_task prepends "<name>:" out of this same budget, AFTER
# condensing. Unpriced, a label condensed to fill the budget was prefixed and
# then cut, and being fused with separators it has no space for the
# word-boundary trim to fall back on, so the cut landed mid-keyword.
check "the name prefix comes out of the budget" "nightly-ETL-job-drops" \
  "$(TITLE_STYLE=name_and_task ar_condense_title \
     'Investigate why the nightly ETL job drops rows' \
     "$(TITLE_STYLE=name_and_task ar_title_name_prefix claude 28)")"
# "claude:" plus that label is the 28 available exactly. Add the glyph and its
# space and one more word has to go, rather than the last one being cut. Both
# reserves are asked for the way ar_tab_name asks for them.
reserve_for() { # <program> <budget> -> the text the label will share
  printf '%s%s' "$(ar_icon_reserve "$1")" "$(ar_title_name_prefix "$1" "$2")"
}
reserve=$(TITLE_STYLE=name_and_task ICONS_ENABLED=1 reserve_for claude 28)
check "and so does the glyph beside it" "nightly-ETL-job" \
  "$(TITLE_STYLE=name_and_task ICONS_ENABLED=1 \
     ar_condense_title 'Investigate why the nightly ETL job drops rows' "$reserve")"
# The prefix ar_format will actually draw is the one charged: refused there, it
# costs the label nothing here.
check "a prefix that will not be drawn charges nothing" "" \
  "$(MAX_TITLE_LEN=12 TITLE_STYLE=name_and_task ar_title_name_prefix cursor-agent 12)"
check "and the plain style charges nothing either" "" \
  "$(ar_title_name_prefix claude 28)"
check "an alias is what gets charged" "cc:" \
  "$(PROGRAM_ALIASES=("claude=cc"); TITLE_STYLE=name_and_task ar_title_name_prefix claude 28)"

# ---- what it refuses to hand back ----
# A label longer than the title it replaces has inverted the point: ar_format
# would then cut prose that fitted. Only a separator of more than one character
# reaches this.
check "a label longer than the title is refused" "" \
  "$(TITLE_WORD_SEPARATOR=--- ar_condense_title 'API migration')"
# Equal length is not growth and is not refused: the casing is folded and the
# words are fused into the one token every other tab name is.
check "equal length is not growth" "squash-merge-command" \
  "$(ar_condense_title 'Squash merge command')"

# A leading "[<digits>]" is the shape ar_index_prefix writes, so ar_strip_prefix
# reads such a label back as a base somebody typed and the tab opts out of
# naming until a reset. The sentence keeps its leading verb and cannot wear the
# shape, so refusing hands back something safe.
check "an index-prefix shape is refused" "" \
  "$(TITLE_WORD_SEPARATOR=' ' ar_condense_title 'Fix [123] parser')"
check "and a bare bracketed number too" "" \
  "$(TITLE_WORD_SEPARATOR=' ' ar_condense_title 'Fix the [7]')"
# The default separator cannot form the shape -- ar_strip_prefix wants a space
# behind the bracket -- so the label ships.
check "the default separator does not reach it" "[123]-parser" \
  "$(ar_condense_title 'Fix [123] parser')"
# The shape is judged on what ar_format will STORE, not on what is written
# here: its scrub turns a run of whitespace or control characters into one
# space, so a separator of a tab passed a check looking for a literal space and
# the shape arrived at the tab one step later.
check "a tab separator does not slip the shape past" "" \
  "$(TITLE_WORD_SEPARATOR=$'\t' ar_condense_title 'Fix [12] parser')"
check "nor does a newline" "" \
  "$(TITLE_WORD_SEPARATOR=$'\n' ar_condense_title 'Fix [12] parser')"
check "nor a control character" "" \
  "$(TITLE_WORD_SEPARATOR=$'\001' ar_condense_title 'Fix [12] parser')"
# And a title that cannot wear the shape keeps such a separator regardless.
check "a title with no shape keeps the separator" "$(printf 'parser\trewrite')" \
  "$(TITLE_WORD_SEPARATOR=$'\t' ar_condense_title 'Fix the parser rewrite')"

# Only a LEADING one is the prefix shape. Elsewhere in the label it is words.
check "a bracketed number later in the label stays" "parser [123] rewrite" \
  "$(TITLE_WORD_SEPARATOR=' ' ar_condense_title 'Fix parser [123] rewrite')"

# ======================================================================
# End to end: the real engine, the fake herdr, TITLE_CONDENSE=1.
# ======================================================================
ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-condense.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"
  export HERDR_CONFIG_FILE="$SB/herdr.toml"
  printf 'agent_panel_sort = "spaces"\n' >"$HERDR_CONFIG_FILE"
  export HERDR_SOCKET_PATH="$SB/herdr.sock"
  export SHELL_NAME=zsh
  # A suite run from inside a live herdr pane inherits these, and a tab id no
  # fixture describes would reach the real session.
  unset HERDR_TAB_ID HERDR_PLUGIN_CONTEXT_JSON
  unset HERDR_MOCK_VERSION HERDR_MOCK_NO_VERSION HIDE_SHELL
  unset AUTO_INDEX_WORKSPACES AUTO_INDEX_TABS AUTO_INDEX_AGENTS
  # Every knob a scenario below turns on, cleared here rather than there: an
  # export that outlives its scenario is a later one testing something it did
  # not ask for, and it reads as a real failure in whichever runs next.
  unset TITLE_CONDENSE ICONS_ENABLED ICON_STYLE ICON_MAP ICON_FALLBACK
  unset MAX_TITLE_LEN MAX_NAME_LEN TITLE_WORD_SEPARATOR TITLE_CASE
}
# check_rename <name> <log> <tab id> <the WHOLE label>
#
# check_contains is a substring test, and every assertion here that mattered was
# written with it: a check for "XYZZ nightly-ETL-job-drops" passes just as well on
# a broken "XYZZ nightly-ETL-job-drops-m", so the tests written to catch a budget
# off by two characters all passed against the bug they were written for. This
# compares the label whole.
check_rename() {
  local want="tab rename $3 $4" got
  got=$(printf '%s\n' "$2" | grep -F "tab rename $3 " | head -1)
  check "$1" "$want" "$got"
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }
run_event() { /usr/bin/env bash "$ENGINE" "$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# ----------------------------------------------------------------------
# t1 is the ordinary case, spinner glyph included: the engine strips it, the
#    condensation gets prose, the tab gets keywords.
# t2 is a refusal. "Claude Code" never reaches the condensation at all, and the
#    tab falls back to the program name, exactly as with the knob off.
# t3 ships no procinfo fixture, so the mock serves "{}" and no program name can
#    be computed. A label here can only have come through the title path, which
#    is what pins the wiring rather than the function.
# ----------------------------------------------------------------------
setup
export NAME_TABS=1 AUTO_INDEX=0 TITLE_CONDENSE=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false},
  {"tab_id":"w1:t3","label":"3","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"claude","agent_status":"working",
   "terminal_title_stripped":"✳ Squash merge command","foreground_cwd":"/home/u/dev/api"},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false,"agent":"claude","agent_status":"idle",
   "terminal_title_stripped":"Claude Code","foreground_cwd":"/home/u/dev/api"},
  {"pane_id":"p3","tab_id":"w1:t3","focused":false,"agent":"claude","agent_status":"working",
   "terminal_title_stripped":"Investigate why the nightly ETL job drops rows",
   "foreground_cwd":"/home/u/dev/api"}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":1,
  "foreground_processes":[{"pid":1,"argv0":"claude","cmdline":"claude"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":2,
  "foreground_processes":[{"pid":2,"argv0":"claude","cmdline":"claude"}]}}}
JSON
out=$(run_event tab.created >/dev/null 2>&1; log)
check_rename   "the title is condensed onto the tab" "$out" w1:t1 "squash-merge-command"
check_absent   "the sentence never reaches herdr"    "$out" "Squash merge command"
check_rename   "a refused title still falls back"    "$out" w1:t2 "claude"
check_absent   "and is not condensed either"         "$out" "claude-code"
check_rename   "a title needs no process lookup"     "$out" w1:t3 "nightly-ETL-job-drops-rows"
teardown

# ----------------------------------------------------------------------
# The knob is off unless asked for: the same fixtures, no TITLE_CONDENSE, and
# the label is the sentence the released plugin has always written.
# ----------------------------------------------------------------------
setup
export NAME_TABS=1 AUTO_INDEX=0
unset TITLE_CONDENSE
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
out=$(run_event tab.created >/dev/null 2>&1; log)
check_rename   "off by default: the sentence survives" "$out" w1:t1 "Squash merge command"
teardown

# ----------------------------------------------------------------------
# The glyph and its space are prepended before ar_format truncates, so they come
# out of the same budget. Unreserved, a full-length label loses its tail to make
# room for them. MAX_NAME_LEN=20 puts MAX_TITLE_LEN at 28.
# ----------------------------------------------------------------------
setup
export NAME_TABS=1 AUTO_INDEX=0 TITLE_CONDENSE=1 ICONS_ENABLED=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"claude","agent_status":"working",
   "terminal_title_stripped":"Investigate why the nightly ETL job drops rows",
   "foreground_cwd":"/home/u/dev/api"}
]}}
JSON
out=$(run_event tab.created >/dev/null 2>&1; log)
# The glyph and its space bring the label to exactly the 28 available, so nothing
# is dropped: an earlier comment here claimed "drops-rows" no longer fitted, which
# was arithmetic that did not hold. Asserted whole, so a label short by any amount
# fails rather than passing on a prefix.
check_rename "the glyph is reserved out of the budget" "$out" w1:t1 "$(printf '\363\260\232\251') nightly-ETL-job-drops-rows"
teardown

# ----------------------------------------------------------------------
# The glyph reserve, which has to be the glyph and not an allowance for one.
# t1 ships an ICON_MAP entry four codepoints wide. Reserving a flat two would
#    leave the label two over budget, and ar_format would cut the last word in
#    half -- the one outcome condensing exists to prevent.
# t2 ships a program with no glyph at all (ICON_FALLBACK empty, program off the
#    map). Reserving anything there shortens the label to make room for nothing.
# ----------------------------------------------------------------------
setup
export NAME_TABS=1 AUTO_INDEX=0 TITLE_CONDENSE=1 ICONS_ENABLED=1
cat >"$SB/cfg.sh" <<'CFG'
ICON_MAP=("claude=XYZZ")
ICON_FALLBACK=""
MAX_TITLE_LEN=28
CFG
export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/cfg.sh"
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
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"claude","agent_status":"working",
   "terminal_title_stripped":"Investigate why the nightly ETL job drops many rows",
   "foreground_cwd":"/home/u/dev/api"},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false,"agent":"novelagent","agent_status":"working",
   "terminal_title_stripped":"Investigate why the nightly ETL job drops many rows",
   "foreground_cwd":"/home/u/dev/api"}
]}}
JSON
out=$(run_event tab.created >/dev/null 2>&1; log)
# "XYZZ " is five, so the task gets 23 of the 28 and stops at "drops";
# reserving two would have condensed to 26 and left ar_format to cut "many" in
# half. The whole label is asserted, not a prefix of it: a substring check here
# passes on any longer cut and proves nothing about where the budget landed.
check_rename   "a wide glyph is reserved whole"  "$out" w1:t1 "XYZZ nightly-ETL-job-drops"
check_rename   "no glyph reserves nothing"       "$out" w1:t2 "nightly-ETL-job-drops-many"
teardown

# ----------------------------------------------------------------------
# The brand an agent stamps on its own title comes off upstream, keyed to the
# agent, before this ever runs. t1 is opencode, whose "OC" is in TITLE_BRANDS.
# t2 is the same shape written by an agent that brands nothing, where those
# characters are content somebody typed and must survive.
# ----------------------------------------------------------------------
setup
export NAME_TABS=1 AUTO_INDEX=0 TITLE_CONDENSE=1
cat >"$SB/cfg.sh" <<'CFG'
TITLE_BRANDS=("opencode=OC")
CFG
export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/cfg.sh"
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
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"opencode","agent_status":"working",
   "terminal_title_stripped":"OC | Reviewing unpushed commits","foreground_cwd":"/home/u/dev/api"},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false,"agent":"claude","agent_status":"working",
   "terminal_title_stripped":"API | authentication migration","foreground_cwd":"/home/u/dev/api"}
]}}
JSON
out=$(run_event tab.created >/dev/null 2>&1; log)
check_rename   "a configured brand comes off"    "$out" w1:t1 "reviewing-unpushed-commits"
check_absent   "and does not reach the tab"      "$out" "OC-reviewing"
check_rename   "another agent keeps those chars" "$out" w1:t2 "API-authentication-migration"
teardown

# ----------------------------------------------------------------------
# And the default carries no opencode entry, so the badge stays. Deleting our own
# badge rule cost this, and the entry that would restore it is wider than the
# rule was: it would also take "OC" off "OC-192 incident", for somebody who never
# asked for condensing at all.
# ----------------------------------------------------------------------
setup
export NAME_TABS=1 AUTO_INDEX=0 TITLE_CONDENSE=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"opencode","agent_status":"working",
   "terminal_title_stripped":"OC | Reviewing unpushed commits","foreground_cwd":"/home/u/dev/api"}
]}}
JSON
out=$(run_event tab.created >/dev/null 2>&1; log)
check_rename   "unconfigured, the badge stays"   "$out" w1:t1 "OC-reviewing-unpushed"

# ----------------------------------------------------------------------
# Both title knobs at once, through the engine. ar_tab_name reserves what the
# label will share before condensing, and the name prefix is part of that: left
# out, a label condensed to fill the budget was prefixed by ar_format and then
# cut, and a fused label has no space for the word-boundary trim to fall back
# on, so the cut landed mid-keyword. Nothing tested the two together before.
# ----------------------------------------------------------------------
setup
export NAME_TABS=1 AUTO_INDEX=0 TITLE_CONDENSE=1 TITLE_STYLE=name_and_task ICONS_ENABLED=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"agent":"claude","agent_status":"working",
   "terminal_title_stripped":"Investigate why the nightly ETL job drops rows",
   "foreground_cwd":"/home/u/dev/api"}
]}}
JSON
out=$(run_event tab.created >/dev/null 2>&1; log)
check_rename "the name and the glyph are both reserved" "$out" w1:t1 \
  "$(printf '\363\260\232\251') claude:nightly-ETL-job"
teardown

t_summary
