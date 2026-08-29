#!/usr/bin/env bash
#
# herdr-automatic-rename - one plugin, two toggleable features:
#
#   NAME_TABS=1   auto-name each tab after its foreground program, or the shell
#                 name at a bare prompt (manual renames opt a tab out). Applies
#                 to tabs only.
#   AUTO_INDEX=1  prefix each workspace, tab, and agent with the 1-9 number of
#                 its jump keybind (switch_workspace/switch_tab/focus_agent) as
#                 "[N] <base>". Per-scope overrides AUTO_INDEX_WORKSPACES,
#                 AUTO_INDEX_TABS and AUTO_INDEX_AGENTS each default to
#                 AUTO_INDEX and win over it when set, so "numbered tabs, plain
#                 workspaces" is AUTO_INDEX_WORKSPACES=0 on its own (issue #8).
#                 Agents are numbered only on herdr < 0.7.5 (newer herdr rejects
#                 a bracketed agent name outright, see ar_agent_prefix_ok) and
#                 only when the panel is grouped-sorted ("priority" sort reorders
#                 the panel behind an API we can't read, see ar_agent_sort).
#                 Agent prefixes are stripped in both cases.
#
# Naming a kind and switching it off does not merely stop numbering: its pass
# still runs and strips the prefixes already there, so the change is visible on
# the next event rather than waiting for the "clear" action (see ar_reconcile).
# Nothing records which prefixes we wrote, so that strip also takes a hand-typed
# "[1] incident" down to "incident"; ar_strip_prefix's all-digits rule is the
# whole of the protection, and it is what keeps "[wip] foo" intact.
#
# Which is why it is the NAMING that arms it, not the value. A config carrying
# only AUTO_INDEX=0 predates these settings, has never had us touch its
# workspace or agent labels, and keeps that no-op behavior on upgrade. Tabs are
# the exception, and only because they were already stripped this way whenever
# NAME_TABS was on.
#
# Both default on and are configured in config.sh ($HERDR_AUTOMATIC_RENAME_CONFIG). A
# single unified reconcile drives both: one pass computes a tab's base name and
# its "[N]" prefix together and issues one rename per item, so a brand-new tab
# settles at "[3] zsh" in a single rename with no placeholder flicker.
#
# Invoked several ways, all routing through ar_run:
#   * herdr [[events]] hooks:     automatic-rename.sh <event.name>
#   * shell preexec/precmd hooks: automatic-rename.sh preexec "<cmdline>"
#                                 automatic-rename.sh precmd [<shell-name>]
#   * the "reset" action:         automatic-rename.sh reset      (re-adopt active tab)
#   * the "clear" action:         automatic-rename.sh --clear    (strip all prefixes)
#
# The live per-command hooks ship with the plugin under shell/ (hook.zsh,
# hook.bash, hook.fish); each passes its own shell name to precmd so a bare
# prompt in a bash/fish pane reads "bash"/"fish" rather than $SHELL.
#
# herdr has no per-tab metadata and no auto/manual flag, so the manual-rename
# exclusion is tracked here: a JSON state file remembers the last base we set
# per tab_id and whether auto-naming is still enabled for it. Config and state
# live at FIXED paths (not $HERDR_PLUGIN_{CONFIG,STATE}_DIR) so the herdr-invoked
# and shell-invoked runs share one store: the preexec/precmd runs are launched by
# the shell, not herdr, and never receive the HERDR_PLUGIN_* env vars. Needs jq.
#
# Targets bash 3.2 (macOS /bin/bash): no associative arrays, no namerefs.

# Resolve our own directory so `. "$AR_ROOT/naming.sh"` works whether herdr runs
# us (HERDR_PLUGIN_ROOT is set), we are executed directly, or we are SOURCED by
# the test suite. BASH_SOURCE[0] points at this file in all three cases; $0 would
# be the test runner when sourced.
AR_ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
HERDR="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-automatic-rename"
STATE_FILE="$STATE_DIR/state.json"
LOCK_DIR="$STATE_DIR/lock"
RERUN_FLAG="$STATE_DIR/rerun"
CONFIG_FILE="${HERDR_AUTOMATIC_RENAME_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-automatic-rename/config.sh}"

# Ordered `sed -E` rewrites for directory-derived workspace labels. Config loads
# later and may replace this empty default.
declare -p WORKSPACE_SUBSTITUTE_SETS >/dev/null 2>&1 || WORKSPACE_SUBSTITUTE_SETS=()

# `task` is the shape a TITLE arrives in: control characters gone, the leading run
# of non-alphanumerics gone (an agent parks a spinner glyph there), the agent's own
# brand gone with it, no trailing space, and inner runs of it collapsed. One
# normalization, because the refusals in ar_title_clean compare exact strings and
# the label is what they compared: a title of "Claude Code " used to match no
# refusal and then be trimmed into a label.
#
# The brand is the argument, because it belongs to the agent in the pane and each
# lift knows which one that is. `brandmap` turns $AR_TITLE_BRANDS (TITLE_BRANDS,
# newline-joined) into the table `taskof` looks it up in, and `debrand` takes the
# brand off only at the very front and only when a non-alphanumeric follows it, so a
# title that merely starts with it keeps it. `lead` runs on BOTH sides of the
# debrand: a title arrives with anything in front of the brand -- a control
# character clean turned into a space, herdr's own leading whitespace, a glyph an
# agent parked there -- and the compare is against the front of the string, so the
# brand has to be at the front by then (see TITLE_BRANDS in naming.sh, issue #12).
# Only a pane whose agent HAS a brand pays for either, which is why the pair sits
# behind one length test: for everything else the second strip could never match.
#
# These four live in their own string because only the two title lifts call them,
# and $AR_JQ_CLEAN is prefixed onto five other jq programs that would compile them
# for nothing. Concatenate it AFTER $AR_JQ_CLEAN, which is where `clean` and `lc`
# come from.
#
# Every jq below that hands a herdr-supplied string to a shell variable runs it
# through clean first, and joins its rows on a literal tab rather than using @tsv.
# @tsv keeps a row parseable by ESCAPING what would break it, and those escapes
# are the problem: a tab out of argv arrives as the two printable characters \t,
# which no scrub can tell from text somebody typed, and every backslash in the
# value is doubled on the way past -- numbering a tab called "C:\temp" rewrote it
# to "C:\\temp". Removing the control characters instead makes the row
# unambiguous without touching anything the user can see.
AR_JQ_CLEAN='def clean: (. // "") | tostring | gsub("[[:cntrl:]]"; " ");
def lc: clean | ascii_downcase;'
# The jq below is a PROGRAM, not a string with shell expansions in it, so the
# single quotes are the point: $b and $brands are jq's own variables, bound by
# --arg at each call site.
# shellcheck disable=SC2016
AR_JQ_TASK='def lead: sub("^[^[:alnum:]]+"; "");
def brandmap: [ split("\n")[] | capture("^(?<k>[^=]+)=(?<v>.*)$")
  | { key: (.k | ascii_downcase), value: .v } ] | from_entries;
def debrand($b): ($b | length) as $n
  | if (.[:$n] | ascii_downcase) == ($b | ascii_downcase)
       and (.[$n:] | test("^([^[:alnum:]]|$)")) then .[$n:] else . end;
def task($b): clean | lead
  | (if ($b | length) > 0 then debrand($b) | lead else . end)
  | sub("[[:space:]]+$"; "") | gsub("[[:space:]]+"; " ");
def taskof($brands; $agent): task($brands[$agent | lc] // "");'

# Those rows are split on the ASCII unit separator rather than a tab, because
# bash counts a tab as IFS WHITESPACE: `read` collapses a run of them, so one
# empty field shifts every field after it. A tab with an empty label -- what
# HIDE_SHELL leaves behind -- parsed its pane count as its label and was never
# named again. A non-whitespace delimiter keeps empty fields where they belong,
# and clean has already taken every character of this class out of the values, so
# it cannot turn up inside one. jq spells it [31] | implode, for the same reason
# this file cannot: a literal control character in source is unreadable.
AR_ROW_SEP=$'\037'

# The prerequisite checks, config + naming load, toggle defaults, mode parse, and
# dispatch all live in ar_main (bottom of file) so that sourcing this file for
# unit tests loads ONLY the function definitions and touches nothing at runtime.

# ======================================================================
# prefix helpers (the "[N] " contract, shared by both features)
# ======================================================================

# The three toggle predicates. Between them they are the only readers of
# AUTO_INDEX and the per-kind overrides, so the "an override beats AUTO_INDEX"
# rule has one implementation and cannot drift between the formatter
# (ar_desired) and the passes that decide whether to run at all.
#
# Each reads the config variables as they were written, resolving the fallback
# where it is used rather than rewriting the variables up front. That keeps them
# pure functions of the config: order-independent, idempotent, and unable to
# lose the difference between a kind the config NAMED and one that inherited its
# value -- a difference ar_index_pass depends on, and one that a resolve step
# would have to snapshot before destroying.
#
# An unknown kind is off rather than on in all three: every caller passes a
# literal, so reaching the default means a typo, and refusing to number is the
# recoverable half of that (a wrong rename is not).

# ar_index_on <workspaces|tabs|agents> -> 0 when that kind is numbered.
# The ":-1" is where "both features default on" lives for numbering.
ar_index_on() {
  case "$1" in
    workspaces) [ "${AUTO_INDEX_WORKSPACES:-${AUTO_INDEX:-1}}" = "1" ] ;;
    tabs)       [ "${AUTO_INDEX_TABS:-${AUTO_INDEX:-1}}" = "1" ] ;;
    agents)     [ "${AUTO_INDEX_AGENTS:-${AUTO_INDEX:-1}}" = "1" ] ;;
    *)          false ;;
  esac
}

# ar_index_explicit <kind> -> 0 when the config named that kind itself rather
# than inheriting AUTO_INDEX. Set-but-empty does not count, matching the ":-"
# above, so the two stay in step by construction.
#
# This is what separates "I turned workspace numbering off" from "I have had
# AUTO_INDEX=0 set for a year". Only the first asks for the prefixes already on
# those rows to be cleaned up; the second is a config that predates the setting
# and must keep behaving as it did, because the cleanup cannot tell a prefix we
# wrote from one the user typed (see the strip note at the top of this file).
ar_index_explicit() {
  case "$1" in
    workspaces) [ -n "${AUTO_INDEX_WORKSPACES:-}" ] ;;
    tabs)       [ -n "${AUTO_INDEX_TABS:-}" ] ;;
    agents)     [ -n "${AUTO_INDEX_AGENTS:-}" ] ;;
    *)          false ;;
  esac
}

# ar_index_pass <kind> -> 0 when that kind's reconcile pass has work to do.
#
# Two ways it can: the kind is numbered, or the config named it and switched it
# off, which asks for the prefixes already there to be stripped. A kind that
# merely inherited "off" asks for neither, and gets skipped exactly as it was
# before per-kind settings existed. --clear overrides all of it, being the
# uninstall path that strips everything.
ar_index_pass() {
  [ "$CLEAR" = "1" ] || ar_index_on "$1" || ar_index_explicit "$1"
}

# ar_strip_prefix <label> -> label with a leading "[<digits>] " removed. Only
# strips when the bracketed part is all digits (so user text like "[wip] foo" is
# left untouched), and removes the EXACT reconstructed "[num] " literal so this
# is the precise inverse of ar_index_prefix (a malformed label such as "[1]x] foo"
# is left alone by both, never diverging).
#
# The "[N]" prefix may also stand alone, with an empty base: that is the label a
# numbered HIDE_SHELL tab carries, and without accepting it here a hidden tab would
# read its own "[3]" back as a hand-typed base and opt out.
#
# Workspaces and agents share these helpers, so a row labeled exactly "[N]" strips
# to "" for them too. Both numbering paths guard on a non-empty base and leave such
# a row alone; the agent revert path does not, and would rename it to "". Only a
# tab is ever numbered with an empty base, so reaching that needs a hand-typed "[3]".
ar_strip_prefix() {
  local s=$1 num
  case "$s" in
    \[[0-9]*\]\ *|\[[0-9]*\])
      num=${s#\[}; num=${num%%\]*}
      case "$num" in
        ''|*[!0-9]*)   printf '%s' "$s" ;;
        *)
          if [ "$s" = "[$num]" ]; then printf ''
          else printf '%s' "${s#"[$num] "}"
          fi ;;
      esac
      ;;
    *) printf '%s' "$s" ;;
  esac
}

# ar_index_prefix <label> -> the leading "[<digits>] " or "" when absent. Used by
# the fast path to carry an existing number forward without recomputing position.
ar_index_prefix() {
  local s=$1 num
  case "$s" in
    \[[0-9]*\]\ *|\[[0-9]*\])
      num=${s#\[}; num=${num%%\]*}
      case "$num" in
        ''|*[!0-9]*) printf '' ;;
        *)           printf '[%s] ' "$num" ;;
      esac
      ;;
    *) printf '' ;;
  esac
}

# ar_desired <scope> <position> <base> -> the label this item should have.
#   --clear              -> always the bare base (strip numbering)
#   scope off            -> bare base (self-heals a stale prefix as items reconcile)
#   scope on, 1..9       -> "[N] base"
# Any other position -> bare base, because no keybind reaches the item: it sits
# past the 9th slot, or (position 0) the sidebar does not render it at all, which
# is how ar_workspace_positions reports a row hidden inside a collapsed space.
ar_desired() {
  local scope=$1 n=$2 base=$3
  if [ "$CLEAR" = "1" ] || ! ar_index_on "$scope"; then printf '%s' "$base"; return; fi
  if [ "$n" -ge 1 ] && [ "$n" -le 9 ]; then
    # An empty base (a HIDE_SHELL tab) is numbered "[3]", not "[3] " -- herdr
    # would drop the trailing space anyway, and ar_strip_prefix reads the bare
    # form back as the empty base it came from.
    printf '[%d]%s' "$n" "${base:+ $base}"
  else
    printf '%s' "$base"
  fi
}

# A label counts as "unnamed" -- fair game for FIRST-TIME auto-naming, and the
# form herdr hands back to a tab we deliberately left label-less -- when it is
# empty or a plain integer, because herdr's generated tab labels are small
# integers ("1", "2"...). Callers for which an empty label is instead a finished
# answer gate on a non-empty argument first; ar_reconcile_tabs' placeholder skip
# does exactly that.
ar_is_placeholder() {
  [ -z "$1" ] && return 0
  case "$1" in
    *[!0-9]*) return 1 ;;
    *)        return 0 ;;
  esac
}

# ======================================================================
# cross-invocation lock (mkdir is atomic; 30s steal window)
# ======================================================================
# An ownership token stamped inside the lock dir means ar_unlock only ever
# removes OUR lock, never one another run re-created after a steal, so the
# release-recheck-reacquire dance in ar_run is safe. 30s is comfortably longer
# than any normal full pass, so a slow run is not stolen out from under itself.
AR_LOCK_TOKEN="$$-${RANDOM:-0}-$(date +%s 2>/dev/null || echo 0)"

# ar_lock_mtime <dir> <fallback> -> that directory's mtime in epoch seconds, or
# the fallback when neither stat spelling answers (GNU takes -c, BSD takes -f).
# Read three times per steal, which is the whole reason it is a function.
#
# mtime and not ctime, on purpose: a lock's mtime is when its owner file was
# written, which is what "abandoned" is measured from. Note what that costs on the
# moved-aside copy, since it is not obvious -- `mv` is a rename and a rename does
# not touch the moved directory's mtime, so that copy still carries the age it had
# before the move. Which is exactly what the freshness check below wants to read;
# it is only worth writing down because a check for "was this moved recently"
# cannot be built on it, and one was, and it was dead code that read as working.
ar_lock_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '%s' "$2"
}
# ar_lock_stamp -> put our token in the lock we just created, and say whether it
# landed. A redirection that fails is reported by the SHELL, before printf runs, so
# the `2>/dev/null` that used to sit here silenced nothing and the caller was told
# it held a lock carrying no token: it would reconcile, and its own ar_unlock would
# match nothing and release nothing. The lock path can be gone by now, taken away
# by another contender's steal between our mkdir and this write.
ar_lock_stamp() {
  { printf '%s' "$AR_LOCK_TOKEN" > "$LOCK_DIR/owner"; } 2>/dev/null || return 1
  # OUR token, not merely a non-empty file: granted has to mean the same thing
  # ar_unlock later checks, or a pass can hold a lock it will never release. The
  # write can land somewhere that is no longer ours, since a steal can take the
  # name away between the mkdir above and this line.
  [ "$(cat "$LOCK_DIR/owner" 2>/dev/null)" = "$AR_LOCK_TOKEN" ]
}

# Give the lock name back after a write to its owner file did not land. `rmdir`
# alone cannot: the shell creates `owner` the moment it opens the redirect, so a
# write that died on ENOSPC or a quota leaves a zero-byte file behind and the
# rmdir fails on it. What stands is the very thing every caller below is trying
# to avoid, a lock carrying a token nothing matches, which ar_unlock will not
# touch and no contender may steal until it ages out 30 seconds later.
# Only an EMPTY owner file is removed. A non-empty one is a whole token, and a
# steal can take this name away between our mkdir and the write that failed, so
# the file would be the live holder's rather than ours.
ar_lock_giveback() {
  [ -s "$LOCK_DIR/owner" ] || rm -f "$LOCK_DIR/owner" 2>/dev/null
  rmdir "$LOCK_DIR" 2>/dev/null
}
ar_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    ar_lock_stamp && return 0
    # A stamp that could not land leaves a lock nobody holds: ar_unlock matches no
    # token in it and no contender may steal it while its mtime is fresh, so every
    # event after this one does nothing. Give the name back. Reachable without any
    # race at all -- a umask of 222 makes every mkdir here unwritable, and so do
    # ENOSPC, a quota, and a read-only remount.
    ar_lock_giveback
    return 1
  fi
  local now mt age stale
  now=$(date +%s 2>/dev/null || echo 0)
  mt=$(ar_lock_mtime "$LOCK_DIR" "$now")
  age=$(( now - mt ))
  if [ "$age" -gt 30 ]; then
    # Read the age once more, right before acting on it. Between the first read
    # and here another contender can have stolen this lock, rebuilt it and started
    # working, and moving THAT aside is what strands a live holder and frees the
    # name for a third. Re-reading does not close the race, nothing available to a
    # shell can, but it stops a burst from cascading: each loser that moves the
    # winner's brand-new lock opens another window doing it. Measured over 200
    # trials of six contenders against one abandoned lock, this line is the
    # difference between 23 trials that produced two holders and none of them.
    # Fail SAFE, like the read above: an unreadable lock stands in as age 0 and is
    # refused. The fallback used to be epoch 0, which reads as 55 years old and
    # authorizes the steal, and the lock path is routinely unreadable here -- it is
    # the one fork between another stealer's mv and its reservation. Measured, that
    # fallback fired 213 times over 60 bursts and every one of them moved whatever
    # brand-new lock had appeared at that path.
    now=$(date +%s 2>/dev/null || echo 0)
    mt=$(ar_lock_mtime "$LOCK_DIR" "$now")
    [ $(( now - mt )) -gt 30 ] || return 1
    # Claim the right to steal in ONE step. The old sequence was rm + rmdir +
    # mkdir, and a second contender's rm emptied the lock the FIRST one had just
    # created: its rmdir then took that fresh lock away and its mkdir handed it a
    # parallel claim, so two passes ran at once and their whole-file state writes
    # clobbered each other -- which reads, one pass later, as a tab renamed by
    # hand, and opts it out of naming for good. `mv` onto a name that does not
    # exist is a single rename(2), so exactly one contender wins it and every
    # loser finds no source left to move. The destination carries the whole token,
    # not just $$, so residue from a crashed run with a recycled pid cannot be
    # mistaken for a free name.
    stale="$LOCK_DIR.stale.$AR_LOCK_TOKEN"
    # Clear our own destination first. `mv` onto an existing directory moves the
    # source INSIDE it, and the nested lock is then invisible to everything below:
    # its token cannot be read, so it looks unclaimed, and the rm that follows
    # destroys a live holder's lock and frees the name for a second pass. Only
    # residue left by a dead run of this same token can put something there, and
    # the token is weaker than it looks (a fresh $RANDOM moves by a fixed step per
    # pid), so the guard is cheap next to what it prevents. plans/001 named this
    # exact nesting as a stop-and-report condition.
    rm -rf -- "$stale" 2>/dev/null
    mv "$LOCK_DIR" "$stale" 2>/dev/null || return 1
    # RESERVE the name before deciding anything, one syscall after the move. The
    # move leaves the lock path empty, and the age that authorized it was measured
    # on a directory this mv no longer moves: two contenders can both find one lock
    # stale, and the second arrives here after the first has already stolen it,
    # rebuilt it and started reconciling, so what it just moved aside is a LIVE
    # lock. While the path stands empty a third contender wins the plain mkdir at
    # the top of this function and reconciles beside a holder that never lost its
    # lock, which is the double-holder this whole function exists to prevent.
    # Taking the name first shuts that window at one syscall and leaves the freshness
    # question to be answered at leisure, by whoever now holds the name.
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      rm -rf -- "$stale" 2>/dev/null            # lost the reservation; drop the copy
      return 1
    fi
    now=$(date +%s 2>/dev/null || echo 0)
    mt=$(ar_lock_mtime "$stale" "$now")
    if [ $(( now - mt )) -le 30 ]; then
      # What we moved was somebody's live lock. Put their token in the lock we now
      # hold, so their own ar_unlock still recognizes it and releases it, and lose
      # the race ourselves. Copying the token rather than moving the directory back
      # is deliberate: `mv` onto a name that exists moves the source INSIDE it, so
      # a hand-back would nest their lock in ours and leave a directory ar_unlock
      # can never rmdir.
      # Read the token BEFORE writing anywhere: `>` truncates its target before cat
      # runs, so a victim with no token yet had ours erase whatever it wrote into the
      # directory we reserved, and a lock with an empty owner is one nothing can
      # release until it ages out. When there is no token to hand back, nobody had
      # claimed that lock either, so let the name go instead of parking an ownerless
      # lock on it. Both of those measured as the common case, not the rare one.
      # The write is braced and checked for the same reason the stamp above is: the
      # shell reports a failed redirection itself, so an unbraced `2>/dev/null`
      # silences nothing and the error lands on the user's prompt, these being
      # preexec hooks. And a hand-back that did not land leaves the same ownerless
      # lock as a failed stamp, so it ends the same way, by giving the name back.
      local vic
      vic=$(cat "$stale/owner" 2>/dev/null)
      rm -rf -- "$stale" 2>/dev/null
      if [ -n "$vic" ] && { printf '%s' "$vic" > "$LOCK_DIR/owner"; } 2>/dev/null; then
        :
      else
        ar_lock_giveback
      fi
      return 1
    fi
    rm -rf -- "$stale" 2>/dev/null
    ar_lock_stamp && return 0
    ar_lock_giveback                        # same as above: never leave it ownerless
    return 1
  fi
  return 1
}
ar_unlock() {
  [ "$(cat "$LOCK_DIR/owner" 2>/dev/null)" = "$AR_LOCK_TOKEN" ] || return 0
  rm -f "$LOCK_DIR/owner" 2>/dev/null
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# ======================================================================
# naming state (atomic temp+mv; jq keyed by tab_id; only NAME_TABS uses it)
# ======================================================================
# ar_state_read -> the state object as JSON, or "{}" when the file is missing OR
# unparseable. The two are the same answer: nothing is known about any tab. They
# used to differ, and that is the bug -- every writer below starts from this file,
# so one jq could not parse froze the store forever. The tab whose ownership went
# with it reads as hand-renamed on the next pass, opts out, and the reset action
# cannot bring it back either, since re-adopting it is another write. Naming was
# dead for the session with nothing said and no way back but deleting the file.
#
# It answers with ONE object, and slurps to be sure of it. jq reads top-level
# values as a STREAM, so `type == "object"` alone says yes to a file holding two
# of them and hands the pair straight back: the writers then apply their update
# to each document and write both out, so that file stays multi-document for
# good, and ar_state_get starts emitting one value per document into a variable
# no comparison in the opt-out machine can match. Requiring `length == 1` is
# what makes "unreadable" cover every shape a state file can be broken into.
# An array or a bare null is refused for the same reason: it parses, it is not a
# store, and assigning a key into it is not a write this file can come back from.
#
# One extra jq per write is what validating costs. Writes are the rare path,
# because ar_state_claim skips one whose state already says what the pass just
# computed, which is the steady state for every named tab on every event.
ar_state_read() {
  local base=""
  # A file we could not READ is not an empty store, and answering {} for it is
  # how a good state file gets destroyed: the writer below starts from that {}
  # and moves a one-key file over the top, so every other tab's record goes, and
  # each of those tabs then carries a label state knows nothing about -- a name
  # typed by hand, as far as the next pass can tell, so each opts itself out.
  # Callers must not write on a non-zero return.
  #
  # The tell is cat's own exit status, NOT whether bytes are left on disk. A file
  # holding a newline and nothing else reads back empty, because command
  # substitution strips trailing newlines, and it still has a byte in it: judging
  # by size refuses to heal it and freezes the store exactly the way an
  # unparseable file used to. `echo > state.json` during a hand recovery makes
  # one. A file that has genuinely gone (deleted between the -f and the cat)
  # fails the read and is refused once, which the next pass reads as missing.
  if [ -f "$STATE_FILE" ] && ! base=$(cat "$STATE_FILE" 2>/dev/null); then
    return 1
  fi
  [ -n "$base" ] || { printf '{}'; return 0; }
  printf '%s' "$base" | jq -c -s \
    'if length == 1 and (.[0] | type) == "object" then .[0] else {} end' 2>/dev/null \
    || printf '{}'
}

# ar_state_get reads the file directly and needs no repair path: an unreadable
# file yields no value, and no value already means "nothing known about this tab".
ar_state_get() { # <tab_id> <field>
  [ -f "$STATE_FILE" ] || return 0
  # NOT `.[$t][$f] // empty`: `//` treats a boolean `false` as absent, so the
  # `enabled` flag would read back as "" and an opted-out tab would look
  # first-seen on every pass (re-adopting a deliberately numeric name). Emit the
  # value unless it is genuinely null/missing.
  jq -r --arg t "$1" --arg f "$2" '.[$t][$f] as $v | if $v == null then empty else $v end' \
    "$STATE_FILE" 2>/dev/null
}
ar_state_set() { # <tab_id> <auto-name> <enabled true|false> [source-name]
  local base tmp source=${4:-} filter=".[\$t] = {auto: \$a, enabled: \$e}"
  base=$(ar_state_read) || return 1        # unreadable: leave the file alone
  # A write that did not land reports it. Ownership IS this file, so swallowing a
  # full disk or an unwritable state directory told the reset action a tab was
  # re-adopted while the next pass, finding no entry, opted it straight back out.
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
  [ "$#" -lt 4 ] || filter=".[\$t] = {auto: \$a, enabled: \$e, source: \$s}"
  if printf '%s' "$base" | jq --arg t "$1" --arg a "$2" --argjson e "$3" --arg s "$source" \
       "$filter" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE" || return 1
  else
    rm -f "$tmp"
    return 1
  fi
}
ar_state_del() { # <tab_id>
  local tmp
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 0
  local base
  base=$(ar_state_read) || { rm -f "$tmp"; return 0; }   # unreadable: leave it alone
  if printf '%s' "$base" | jq --arg t "$1" 'del(.[$t])' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}
ar_state_prune() { # <keep tab_ids...> - drop entries for tabs that no longer exist
  # The keep list is joined on newlines, so an id carrying one would split into two
  # entries that match nothing and the tab would be pruned while it still exists,
  # reading as hand-renamed on the next pass. Ids reach here through `clean`, which
  # is what keeps a control character out of one (see AR_JQ_CLEAN).
  local keep tmp
  keep=$(printf '%s\n' "$@" | jq -R . | jq -s .) || return 0
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 0
  local base
  base=$(ar_state_read) || { rm -f "$tmp"; return 0; }   # unreadable: leave it alone
  # "ws:" keys belong to the workspace tracker (ar_state_prune_ws prunes those),
  # and a keep list of tab ids never holds one: selecting on this list ALONE wiped
  # every workspace's ownership record on the pass after it was written, so each
  # workspace read as first-seen, found a label that was no longer herdr's own
  # derivation, and opted itself out of tracking for good -- issue #13 again, one
  # layer down. Each kind prunes its own keys and leaves the other's alone.
  if printf '%s' "$base" | jq --argjson keep "$keep" \
       'with_entries(select((.key | startswith("ws:")) or (.key as $k | $keep | index($k))))' \
       > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}

# ar_state_claim <tab_id> <name> <named 0|1> - record that we own <tab_id> at
# <name>, unless nothing has changed. State already saying exactly this is the
# steady state -- every named tab, on every pass -- and ar_state_set rewrites the
# whole file, so the guard keeps a quiet session from rewriting it per tab per
# event. Reads what ar_name_eligible published for this same tab.
ar_state_claim() {
  [ "$3" = "1" ] || return 0
  # Ownership has to be RECORDED, not merely computed, before a reset can say the
  # tab is back under naming: reporting it any earlier told the user it worked when
  # the rename failed, or when the state write did, and a tab in either position
  # opts itself straight back out on the next pass.
  if [ "${AR_STATE_ENABLED:-}" = "true" ] && [ "${AR_STATE_AUTO:-}" = "$2" ]; then
    :                                    # state already says this; nothing to write
  elif ! ar_state_set "$1" "$2" true; then
    return 1
  fi
  [ -n "${AR_FORCE_TAB:-}" ] && [ "$1" = "$AR_FORCE_TAB" ] && AR_FORCE_ADOPTED=1
  return 0
}

# ar_name_eligible <tab_id> <base label, prefix already stripped>
# The manual-rename exclusion state machine. Returns 0 (eligible for auto-naming)
# or 1 (leave the base alone). May write opt-out state as a side effect. Needs no
# computed name, so an opted-out tab costs no process-info call.
#
# The two fields it reads are published as AR_STATE_ENABLED / AR_STATE_AUTO for
# the tab just examined, so a caller about to record ownership can tell an
# unchanged claim (the steady state, every pass, for every named tab) from one
# worth writing -- ar_state_set rewrites the whole state file.
ar_name_eligible() {
  local tab=$1 slabel=$2 enabled auto
  enabled=$(ar_state_get "$tab" enabled)
  auto=$(ar_state_get "$tab" auto)
  AR_STATE_ENABLED=$enabled
  AR_STATE_AUTO=$auto
  if [ -n "${AR_FORCE_TAB:-}" ] && [ "$tab" = "$AR_FORCE_TAB" ]; then
    return 0                                    # reset forces re-adoption
  elif [ -z "$enabled" ]; then
    # First time we see this tab: adopt herdr's generated placeholder label
    # (empty or a bare integer); anything else was named by hand -> opt out.
    if ar_is_placeholder "$slabel"; then return 0
    else ar_state_set "$tab" "" false; return 1
    fi
  elif [ "$enabled" = "false" ]; then
    # Opted out. Re-adopt ONLY on an explicit clear (empty label); a numeric
    # label is a deliberate name, not a reset (use the reset action for that).
    if [ -z "$slabel" ]; then return 0
    else return 1
    fi
  else
    # We own it; keep updating while the base still matches what we last set.
    if [ "$slabel" = "$auto" ]; then return 0
    elif [ -z "$slabel" ]; then return 0        # user cleared it -> re-adopt
    # A HIDE_SHELL tab is owned with an EMPTY auto name, and herdr may hand a
    # label-less tab its generated number back (a restored session, its own
    # relabeling). Reading that as a hand rename would freeze the tab on the
    # number and stop naming it once a real program starts, so keep ownership.
    elif [ -z "$auto" ] && ar_is_placeholder "$slabel"; then return 0
    else ar_state_set "$tab" "" false; return 1 # user renamed -> opt out
    fi
  fi
}

# ======================================================================
# tab-name computation (herdr-touching; feeds ar_format from naming.sh)
# ======================================================================

# ar_resolve_pane <tab_id> <pane_count> <focused> <layout_pane> -> the active
# pane_id, or "" when this tab has none to name from.
#
# <layout_pane> is the pane the snapshot reshape in ar_reconcile picked for this
# tab and carried on its row (which is why this costs no herdr call and no jq of
# its own): the tab's own focused pane, or the agent at work in it. herdr
# publishes one layout per tab, so it answers for every tab, and it is why a
# background multi-pane tab can be named at all. See "Which pane names a tab" in
# docs/ARCHITECTURE.md.
#
# Everything below is the fallback for a herdr whose snapshot carries no layouts
# and for the per-list path, which has none: the sole pane of a single-pane tab,
# else the tab's OWN focused pane, else "". Nothing here reads the session-wide
# focus, and a multi-pane tab with no focused pane of its own gets no answer
# rather than an arbitrary one -- pane focus follows whichever client moved it
# last, so a focused tab whose panes all read unfocused is what a second client
# or a remote attach looks like, and its first pane is a guess. Reads the cached
# $AR_PANES_JSON.
ar_resolve_pane() {
  local tid=$1 pc=$2 foc=$3 lp=${4:-}
  if [ -n "$lp" ]; then
    printf '%s' "$lp"
    return 0
  fi
  printf '%s' "$AR_PANES_JSON" | jq -r --arg t "$tid" --arg pc "$pc" --arg foc "$foc" '
    (.result.panes // .panes // []) as $p
    | ($p | map(select(.tab_id == $t))) as $tp
    | (if $pc == "1" then $tp[0]
       elif $foc == "true" then ($tp | map(select(.focused)) | .[0])
       else null end)
    | if . == null then "" else (.pane_id // "") end
  ' 2>/dev/null
}

# ar_pane_facts <pane_id> -> sets AR_PANE_AGENT / AR_PANE_TITLE /
# AR_PANE_TITLE_LC / AR_PANE_DIR_LC from the cached pane list. herdr publishes all
# of it on the pane object itself, so this needs no herdr call on any version.
#
# On the snapshot path those values arrive already lifted, on the tab row (see the
# reshape in ar_reconcile), and this runs only where that path is unavailable.
# Reading the whole pane list back per tab is what it costs, which is why the
# snapshot path does not.
#
# AR_PANE_AGENT is herdr's own detection result (.agent). The panes carrying it
# are exactly the ones `agent list` reports (verified against a live herdr 0.8.0).
# The neighboring .agent_session is deliberately NOT consulted: it is a resume
# reference, and a pane can carry one while detection reports nothing (herdr#803's
# half-wired state), so naming from it would bypass the detection gate on a stale
# ref.
#
# AR_PANE_TITLE is what the program running there set as the terminal title. For a
# coding agent that is a description of the work in progress, which is the whole
# of AGENT_TITLES. herdr keeps an ANSI-stripped copy, and _stripped means exactly
# that -- a spinner glyph is still on the front of it (see ar_title_clean).
#
# AR_PANE_DIR is the directory the pane is in, needed only to recognize a title
# that is just that directory repeated back.
ar_pane_facts() {
  local out
  AR_PANE_AGENT=""; AR_PANE_TITLE=""; AR_PANE_TITLE_LC=""; AR_PANE_DIR_LC=""
  out=$(printf '%s' "$AR_PANES_JSON" | jq -r --arg p "$1" \
    --arg brands "${AR_TITLE_BRANDS:-}" "$AR_JQ_CLEAN$AR_JQ_TASK"'
    ($brands | brandmap) as $brand
    | (.result.panes // .panes // []) | map(select(.pane_id == $p)) | .[0] as $pane
    # ascii_downcase folds ASCII only, so a title and a directory that differ just
    # by the case of a non-ASCII letter are not seen as equal. Deliberate: the
    # refusals it feeds are about product names and directory names, and a
    # Unicode-aware compare would have to move back into jq per tab.
    | ($pane.terminal_title_stripped // $pane.terminal_title
       | taskof($brand; $pane.agent)) as $t
    | [ ($pane.agent | clean), $t, ($t | ascii_downcase),
        ((($pane.foreground_cwd // $pane.cwd | clean) | split("/") | last) // "" | ascii_downcase) ]
    | join([31] | implode)' 2>/dev/null)
  IFS=$AR_ROW_SEP read -r AR_PANE_AGENT AR_PANE_TITLE AR_PANE_TITLE_LC AR_PANE_DIR_LC <<< "$out"
}

# ar_split_program <ar_pane_program output> -> sets AR_PROG / AR_CMD.
# Two lines in, two globals out: `read` would do it, but it reports the missing
# second line (an empty command line, which command substitution has already
# trimmed away) as a failure, and this runs inside an && chain.
ar_split_program() {
  AR_PROG=${1%%$'\n'*}
  case $1 in
  *$'\n'*) AR_CMD=${1#*$'\n'} ;;
  *) AR_CMD="" ;;
  esac
}

# ar_pane_program <pane_id> -> "program" and "cmdline", one per line.
# The foreground command is the process-group leader (pid == group id). At a bare
# prompt the leader IS the login shell, whose argv0 ("-zsh") strips to "zsh".
#
# program comes from how the process was INVOKED, preferring .argv0, then argv[0].
# .name is the last resort because it is the on-disk executable, which is often
# not what the user typed: agents like claude report a version string there, and
# on NixOS a wrapped program reports the internal ".<prog>-wrapped" binary while
# argv[0] still holds the real name (issue #6). herdr only emits .argv0 on some
# platforms -- Linux builds send argv/cmdline/name alone -- so argv[0] is what
# keeps those from falling through to .name.
# A login shell's leading "-" is removed and any path stripped.
ar_pane_program() {
  local out
  out=$("$HERDR" pane process-info --pane "$1" 2>/dev/null) || return 1
  # Each value on its own LINE, which is only safe because clean has taken the
  # newlines out (see AR_JQ_CLEAN).
  printf '%s' "$out" | jq -r "$AR_JQ_CLEAN"'
    (.result.process_info // .process_info) as $pi
    | ($pi.foreground_process_group_id) as $g
    | ($pi.foreground_processes // []) as $fp
    # Where herdr names NO foreground group (some Linux container and sandbox
    # setups: it cannot read one, so this field is null) it can still report the
    # processes in the pane, and a list of exactly ONE is not ambiguous: there is
    # nothing to choose between, so naming the tab after it is not a guess and
    # beats leaving naming dead on those hosts.
    #
    # Two or more with no named group IS a guess, and this plugin does not make
    # it. herdr documents its own degraded detection as one where a background job
    # can look like the foreground one, and it does not order this list (a live
    # 0.8.0 lists a `caffeinate` child ahead of the `claude` leader it belongs
    # to), so a pick here could name the tab after something nobody is running --
    # and the reconcile would then own that name until the process set changed.
    #
    # A named group whose process is absent from the list is also a no-answer:
    # that is a group racing its own exit, where the name the tab already has is
    # the better answer. So is an EMPTY list, which yields ["", ""] as before.
    | (if $g == null then (if ($fp | length) == 1 then $fp[0] else null end)
       else ($fp | map(select(.pid == $g)) | first) end) as $p
    | if ($p == null) then
        "", ""
      else
        (($p.argv0 // (($p.argv // [])[0]) // $p.name // "") | clean | sub("^-"; "") | split("/") | last),
        (($p.cmdline // (($p.argv // []) | join(" "))) | clean)
      end
  ' 2>/dev/null
}

# ar_tab_name <tab_id> <pane_count> <focused> <layout_pane> -> base name on stdout.
# Returns 1 when the name can't be computed (no resolvable pane, process-info
# failure); a successful HIDE_SHELL computation returns 0 with EMPTY output, so
# the caller must read the status, not the string, to tell the two apart.
ar_tab_name() {
  local pane info prog="" cmd="" title=""
  pane=$(ar_resolve_pane "$1" "$2" "$3" "${4:-}")
  [ -n "$pane" ] || return 1
  # The caller may already hold this pane's facts, lifted onto the tab row -- but
  # only for the pane the reshape PICKED, which is <layout_pane>. Where that came
  # back empty (a snapshot carrying no layouts, or no layout for this tab) the pane
  # above was resolved from the pane list instead, and its facts are still unread:
  # trusting the row there cost the tab its title AND the wrapper unwrap, so a
  # node-fronted codex read "node" again.
  if [ -z "${4:-}" ] || [ "$pane" != "$4" ]; then
    ar_pane_facts "$pane"
  fi
  # An agent tab is named after the work the agent reports, when it reports any:
  # five claude tabs all read "claude" otherwise, which is the one thing naming
  # them by program cannot fix. This answer also needs no process lookup, so an
  # agent-heavy session spends fewer herdr round-trips than it did before (the
  # local work is a wash: one jq over the pane row instead of one over the
  # process-info reply).
  if [ "${AGENT_TITLES:-1}" = "1" ] && [ -n "$AR_PANE_AGENT" ]; then
    title=$(ar_title_clean "$AR_PANE_TITLE" "$AR_PANE_TITLE_LC" "$AR_PANE_DIR_LC" "$AR_PANE_AGENT")
    if [ -n "$title" ]; then
      ar_format "$AR_PANE_AGENT" "" "$title"
      return 0
    fi
  fi
  # process-info can fail transiently (pane closing, socket hiccup) or resolve no
  # foreground process; both leave prog empty. Fail so the caller keeps the tab's
  # current name, rather than falling through to ar_format "" "" -> $SHELL_NAME
  # and clobbering (e.g.) an "nvim" tab with "zsh" on a blip.
  info=$(ar_pane_program "$pane") || return 1
  ar_split_program "$info"
  prog=$AR_PROG
  cmd=$AR_CMD
  [ -n "$prog" ] || return 1
  # An agent installed through npm or npx fronts as its runtime, so the tab would
  # be named "node" for a pane herdr knows is running codex. Where the foreground
  # program is one of those runtimes AND herdr reports an agent for the pane, its
  # answer wins. Both conditions are needed: a plain `node server.js` tab has no
  # agent and keeps its name, and an agent that reports its own name never
  # reaches this.
  if ar_in_list "$prog" "${WRAPPER_PROGRAMS[@]}" && [ -n "$AR_PANE_AGENT" ]; then
    prog=$AR_PANE_AGENT
    cmd=$AR_PANE_AGENT
  fi
  ar_format "$prog" "$cmd"
}

# ======================================================================
# reconcilers
# ======================================================================

# ar_herdr_session_dir -> the directory herdr keeps this session's state in: the
# config dir for the default session, ~/.config/herdr/sessions/<name>/ for a named
# one. Both session.json and that session's config.toml live there, and herdr puts
# the API socket there too and exports HERDR_SOCKET_PATH into plugin commands AND
# pane environments, so stripping the socket's filename names the right directory
# from the herdr-invoked pass and the shell hooks alike. Falls back to the default
# session's dir when the variable is unset.
ar_herdr_session_dir() {
  if [ -n "${HERDR_SOCKET_PATH:-}" ]; then
    printf '%s' "${HERDR_SOCKET_PATH%/*}"
  else
    printf '%s/herdr' "${XDG_CONFIG_HOME:-$HOME/.config}"
  fi
}

# ar_collapsed_spaces -> JSON array of the space keys (repo_key strings) whose
# sidebar group is collapsed right now. herdr exposes collapse NOWHERE in the API
# (no field on workspace list / api snapshot, no event, protocol 17), and stores
# it only as session.json's top-level collapsed_space_keys, so we read that file
# the way ar_agent_sort reads config.toml. See docs/ARCHITECTURE.md for why that
# leaves the numbers up to herdr's 5-second save debounce behind a collapse. A
# missing or unreadable file means "nothing collapsed", which is how the plugin
# behaved before it read this at all.
ar_collapsed_spaces() {
  jq -c '[ .collapsed_space_keys[]? | strings ]' \
    "$(ar_herdr_session_dir)/session.json" 2>/dev/null || printf '[]'
}

# ar_workspace_positions <workspace-list-json> <collapsed-spaces-json>
#   -> one "<workspace_id>\t<label>\t<position>" row per workspace, where position
#      is its 1-based slot in herdr's VISIBLE sidebar order, or 0 when the sidebar
#      does not render it at all.
#
# alt+N resolves through that visible order (herdr's workspace_at_visible_position
# -> visible_workspace_order), NOT the raw `workspace list` array order, so this
# mirrors herdr's own workspace_list_entries_inner (src/ui/sidebar.rs). Keep the
# rules in this one place, in herdr's order, so re-checking them against upstream
# stays cheap:
#   * Workspaces sharing a .worktree.repo_key nest into one "space", but ONLY when
#     the repo has 2+ open workspaces AND one of them is the main checkout
#     (is_linked_worktree false). Two linked worktrees with no main workspace stay
#     separate top-level rows in array order.
#   * A space renders at the slot of its first-appearing member, and the row that
#     heads it is the MAIN checkout, with the other members nested after it in
#     array order, so a worktree listed before its main repo does not lead.
#   * A COLLAPSED space renders its head row alone. Its other members are hidden,
#     which is what position 0 means. The one exception herdr makes is the FOCUSED
#     member: a collapsed space keeps the active workspace rendered under its
#     parent, so that row still counts and every row after it shifts down. Numbers
#     therefore move when the user only collapses, expands, or switches workspaces.
#
# No herdr calls and no file reads: both inputs are passed in, so this is directly
# testable (see tests/test_ws_order.sh).
ar_workspace_positions() {
  printf '%s' "$1" | jq -r --argjson collapsed "$2" "$AR_JQ_CLEAN"'
    [ (.result.workspaces // .workspaces // []) | to_entries[]
      | .value + { _i: .key,
                   _k: (.value.worktree.repo_key // ""),
                   _linked: (.value.worktree.is_linked_worktree // false) } ] as $rows
    # repo_key -> its members in SIDEBAR order (head first), for the keys that nest
    | ( reduce $rows[] as $r ({}; if $r._k == "" then . else .[$r._k] += [$r._i] end)
        | with_entries(
            ( [ .value[] | select($rows[.]._linked == false) ] | first ) as $head
            | select($head != null and (.value | length) >= 2)
            | .value = [ $head ] + [ .value[] | select(. != $head) ] ) ) as $spaces
    | ( [ $rows[] | select(.focused) | ._i ] | first ) as $active
    | ( [ $rows[]
          | ._k as $k | ._i as $i | $spaces[$k] as $mem
          | if $mem == null then $i                 # renders as its own row
            elif $i != ($mem | min) then empty      # space already rendered at its first member
            else $mem[0],                           # the main checkout heads it
                 ( if $collapsed | index($k)
                   then ( $active | select(. != null and . != $mem[0] and $rows[.]._k == $k) )
                   else $mem[1:][] end )
            end ] ) as $order
    | $rows[] | ._i as $i | ($order | index($i)) as $pos
    | [ (.workspace_id | clean), (.label | clean),
        ((if $pos == null then 0 else $pos + 1 end) | tostring) ]
    | join([31] | implode)' 2>/dev/null
}

# ar_workspace_identities -> one "<workspace_id><SEP><identity_cwd>" row per
# workspace herdr has an identity directory for, or nothing at all.
#
# identity_cwd is herdr's OWN tracked directory for a workspace: it follows the
# focused pane's cwd. herdr labels the workspace after it -- until the first
# rename, which freezes the derivation for good while identity_cwd goes on
# updating (issue #13). Reading the value back is what lets a numbered workspace
# keep tracking its directory, and a pane cwd out of `pane list` is not a
# substitute: herdr updates identity_cwd for the FOCUSED pane only, and a pass
# would have to decide which pane speaks for a split.
#
# Same file, and the same two caveats, as ar_collapsed_spaces: herdr publishes the
# value nowhere in its API (no field on `workspace list` or `api snapshot`,
# checked against protocol 17), and session.json is saved on a 5-second debounce,
# so a cd lands on the label an event or two later rather than instantly. A
# missing, unreadable, or older-herdr file yields no rows, which is what makes
# the caller fall back to the label it wrote last pass -- the behavior before
# this existed.
ar_workspace_identities() {
  jq -r "$AR_JQ_CLEAN"'
    .workspaces[]? | select(type == "object")
    | ((.id // .workspace_id) | strings | clean) as $w
    | (.identity_cwd | strings | clean) as $c
    | select($w != "" and $c != "")
    | [ $w, $c ] | join([31] | implode)' \
    "$(ar_herdr_session_dir)/session.json" 2>/dev/null || printf ''
}

# ar_project_base <dir> -> the base herdr labels a workspace sitting in <dir>:
# the name of the repository <dir> belongs to, or <dir>'s own name outside a repo.
#
# Measured against herdr 0.8.2, both arms. A workspace whose pane cds from a repo
# root into a subdirectory keeps the repo's name; one that cds between plain
# directories takes the new directory's name. Taking the basename alone would
# rename the workspace on every cd inside the project, which is the opposite of
# what this feature is for.
#
# The walk looks for `.git` rather than asking git, because a linked worktree's
# `.git` is a FILE and its repo name is the checkout's own directory name (herdr
# labels those by the checkout, not the main repo), which is exactly what the
# first hit up the chain gives -- and it costs no process. It stops at "/" and
# tolerates a relative or empty path by answering the plain basename.
ar_project_base() {
  local dir=$1
  case "$dir" in
    /*) while [ -n "$dir" ] && [ "$dir" != "/" ]; do
          if [ -e "$dir/.git" ]; then break; fi
          dir=${dir%/*}
        done
        [ -n "$dir" ] && [ "$dir" != "/" ] || dir=$1 ;;
  esac
  dir=${dir%/}
  printf '%s' "${dir##*/}"
}

# ar_workspace_subst <base> -> a directory-derived workspace label with each
# configured rewrite applied in order.
ar_workspace_subst() {
  local s=$1 expr
  for expr in "${WORKSPACE_SUBSTITUTE_SETS[@]}"; do
    s=$(printf '%s' "$s" | sed -E "$expr")
  done
  printf '%s' "$s"
}

# ar_workspace_pane_dirs <workspace-list-json> -> one "<workspace_id><SEP><dir>"
# row per workspace, from the panes the pass already holds: its focused pane, or
# a pane of the tab it has active, or any pane of it.
#
# This is what covers a workspace herdr has not persisted yet. session.json is
# saved on a 5-second debounce, and a workspace created inside that window is in
# no copy of the file, so the pass numbering it seconds after it opened has no
# identity to compare its label against. Every new workspace passes through that
# state, and treating it as "a label nobody derived" opted the workspace out of
# tracking for good: the numbering rename lands first, and by the time herdr
# writes the file the label it wrote is already the stale one. Reading the pane's
# directory instead settles the comparison at creation, where the two agree.
#
# A pane list is not a substitute for identity_cwd in the steady state, though.
# herdr moves identity_cwd with the workspace's ACTIVE pane, and which pane that
# is takes the layout to answer (ar_resolve_pane, the same problem tab naming
# has), so a workspace whose split panes sit in different directories is exactly
# where a guess disagrees with herdr's own label.
ar_workspace_pane_dirs() {
  local wsjson=$1
  [ -n "${AR_PANES_JSON:-}" ] || return 0
  jq -r -n "$AR_JQ_CLEAN"'
    ($pn.result.panes // $pn.panes // []) as $panes
    | ($ws.result.workspaces // $ws.workspaces // [])[]
    | (.workspace_id | clean) as $w
    | (.active_tab_id | clean) as $at
    | [ $panes[] | select((.workspace_id | clean) == $w) ] as $mine
    | ( ( [ $mine[] | select(.focused == true) ] | .[0] )
        // ( [ $mine[] | select((.tab_id | clean) == $at) ] | .[0] )
        // ( $mine | .[0] ) ) as $p
    | select($p != null)
    | ((($p.foreground_cwd // $p.cwd) | clean)) as $c
    | select($c != "")
    | [ $w, $c ] | join([31] | implode)' \
    --argjson ws "$wsjson" --argjson pn "$AR_PANES_JSON" 2>/dev/null || printf ''
}

# ar_identity_base <workspace_id> -> the base herdr derives for it. Reads the
# rows ar_workspace_identities put in AR_WS_IDENTITY first, since that is herdr's
# own answer, and falls back to the pane directory in AR_WS_PANEDIR for a
# workspace too new to be in the file. Returns 1 when neither knows it, which is
# not the same answer as an empty base: no row means nothing is known.
# A loop rather than a jq per row, because a pass sees every workspace and each
# map is one read.
ar_identity_base() { # <workspace_id>
  local wid=$1 k v rows
  for rows in "${AR_WS_IDENTITY:-}" "${AR_WS_PANEDIR:-}"; do
    [ -n "$rows" ] || continue
    while IFS=$AR_ROW_SEP read -r k v; do
      if [ "$k" = "$wid" ]; then ar_project_base "$v"; return 0; fi
    done <<< "$rows"
  done
  return 1
}

# ar_ws_track_eligible <workspace_id> <base label, prefix stripped> <identity base>
# The manual-rename exclusion for workspaces: 0 to take the base from herdr's
# directory derivation, 1 to leave the label's own base alone. Keyed "ws:<id>" in
# the same state file the tabs use, which no tab id can collide with (a tab id
# carries its workspace and a colon) and no tab prune may drop.
#
# Two ways in. The label already IS herdr's derivation, which covers a workspace
# seen for the first time and one renamed back by hand -- the recovery path, since
# workspaces have no `reset` action. Or state says we own it and the base is still
# what we last wrote, which is the case that survives a cd: herdr's derivation has
# moved on and ours has not, and only the record tells that apart from a name
# somebody typed. Anything else is somebody's name and is left alone for good.
ar_ws_track_eligible() {
  local key="ws:$1" slabel=$2 ibase=$3 enabled auto source
  enabled=$(ar_state_get "$key" enabled)
  auto=$(ar_state_get "$key" auto)
  source=$(ar_state_get "$key" source)
  AR_WS_STATE_ENABLED=$enabled
  AR_WS_STATE_AUTO=$auto
  AR_WS_STATE_SOURCE=$source
  if [ "$slabel" = "$ibase" ]; then
    return 0
  elif [ "$enabled" = "true" ] && [ "$slabel" = "$auto" ]; then
    return 0
  fi
  [ "$enabled" = "false" ] || ar_state_set "$key" "" false
  return 1
}

# ar_ws_claim <workspace_id> <base> <source> - record that we own this workspace's base,
# unless state already says exactly that (the steady state, every pass, for every
# tracked workspace: ar_state_set rewrites the whole file). Reads what
# ar_ws_track_eligible published for this same workspace. Only ever called for a
# base the workspace CARRIES -- a base recorded for a rename that never landed
# reads as a hand-typed name one pass later, and opts the workspace out.
ar_ws_claim() {
  if [ "${AR_WS_STATE_ENABLED:-}" = "true" ] && [ "${AR_WS_STATE_AUTO:-}" = "$2" ] &&
     [ "${AR_WS_STATE_SOURCE:-}" = "$3" ]; then
    return 0
  fi
  ar_state_set "ws:$1" "$2" true "$3"
}

# ar_ws_subst_pending -> 0 when a prior substitution still differs from its
# directory-derived source and needs one pass after the rules are removed.
ar_ws_subst_pending() {
  local base
  base=$(ar_state_read) || return 1
  printf '%s' "$base" | jq -e '
    any(to_entries[]?;
      (.key | startswith("ws:"))
      and .value.enabled == true
      and (.value.source | type) == "string"
      and .value.auto != .value.source)
  ' >/dev/null 2>&1
}

# ar_state_prune_ws <keep workspace_ids...> - drop the "ws:" records of
# workspaces that no longer exist, and touch no other key (the tabs own theirs,
# and ar_state_prune is called with tab ids alone). Writes only when the pruned
# document differs, so a steady session leaves the file alone.
ar_state_prune_ws() {
  local keep base pruned tmp
  keep=$(printf '%s\n' "$@" | jq -R . | jq -s .) || return 0
  base=$(ar_state_read) || return 0                      # unreadable: leave it alone
  pruned=$(printf '%s' "$base" | jq -c --argjson keep "$keep" \
    'with_entries(select((.key | startswith("ws:") | not)
                         or ((.key | ltrimstr("ws:")) as $w | $keep | index($w))))' \
    2>/dev/null) || return 0
  [ -n "$pruned" ] && [ "$pruned" != "$base" ] || return 0
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 0
  if printf '%s' "$pruned" > "$tmp"; then mv "$tmp" "$STATE_FILE"; else rm -f "$tmp"; fi
}

# Workspaces: number them by herdr's visible sidebar order, and keep the base
# tracking the workspace's directory. Arg 1 is a cached `workspace list` JSON.
#
# The base comes from herdr's identity_cwd, not from the label we wrote last pass.
# Recycling the label is what made issue #13: the first numbering rename freezes
# herdr's own directory derivation, so a label built out of the previous label can
# never move again, and a workspace kept the name it had when it was created.
# Ownership decides per workspace whether that swap applies (ar_ws_track_eligible),
# and --clear skips it entirely: the uninstall path strips prefixes and retitles
# nothing.
ar_renumber_workspaces() {
  local json=$1 rows wid label pos base want ibase track prefix index_pass=0 seen=""
  [ -n "$json" ] || return 0
  ar_index_pass workspaces && index_pass=1
  rows=$(ar_workspace_positions "$json" "$(ar_collapsed_spaces)")
  if [ -z "$rows" ]; then
    [ "$CLEAR" = "1" ] || ar_state_prune_ws
    return 0
  fi
  AR_WS_IDENTITY=""
  AR_WS_PANEDIR=""
  if [ "$CLEAR" != "1" ]; then
    AR_WS_IDENTITY=$(ar_workspace_identities)
    AR_WS_PANEDIR=$(ar_workspace_pane_dirs "$json")
  fi
  while IFS=$AR_ROW_SEP read -r wid label pos; do
    [ -n "$wid" ] || continue
    seen="$seen $wid"
    base=$(ar_strip_prefix "$label")
    track=0
    if ibase=$(ar_identity_base "$wid") && ar_ws_track_eligible "$wid" "$base" "$ibase"; then
      base=$(ar_workspace_subst "$ibase")
      track=1
    fi
    [ -n "$base" ] || continue          # empty label: nothing to number, leave it
    if [ "$index_pass" = "1" ]; then
      want=$(ar_desired workspaces "$pos" "$base")  # position 0 (hidden) -> bare, like 10+
    elif [ "$track" = "1" ]; then
      prefix=$(ar_index_prefix "$label")
      want="${prefix}${base}"
    else
      want=$label
    fi
    if [ "$want" != "$label" ]; then
      "$HERDR" workspace rename "$wid" "$want" >/dev/null 2>&1 || continue
    fi
    if [ "$track" = "1" ] &&
       { [ "$index_pass" = "1" ] || [ "$base" != "$ibase" ] ||
         [ "${AR_WS_STATE_ENABLED:-}" = "true" ]; }; then
      ar_ws_claim "$wid" "$base" "$ibase"
    fi
  done <<< "$rows"
  # A workspace id carries no whitespace (both go through `clean`), so the
  # space-joined list splits into one argument per workspace.
  # shellcheck disable=SC2086
  [ "$CLEAR" = "1" ] || ar_state_prune_ws $seen
}

# Tabs: cmd+N indexes the focused workspace's tabs by ARRAY ORDER (NOT the
# non-contiguous .number field), so renumber each workspace's tabs 1..N
# independently by array position. This is also where auto-naming happens (tabs
# are the only item both features touch), so per tab we compute the base ONCE
# (naming if owned/eligible, else the stripped current base) and apply the
# position prefix in a single rename. Arg 1 is the cached `workspace list` JSON.
ar_reconcile_tabs() {
  local wsjson=$1 w tjson rows tid label pcount foc base0 base named name i want
  [ -n "$wsjson" ] || return 0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    if [ "${AR_HAVE_SNAPSHOT:-0}" = "1" ]; then
      # Slice this workspace's tabs out of the cached snapshot, preserving array
      # order (what cmd+N numbers by). Same shape as `tab list --workspace`, plus
      # the _name_pane the reshape joined on (see ar_resolve_pane).
      tjson=$(printf '%s' "$AR_SNAP_TABS_JSON" | jq -c --arg w "$w" \
        '{result:{tabs:[(.result.tabs // [])[]|select(.workspace_id==$w)]}}' 2>/dev/null)
    else
      tjson=$("$HERDR" tab list --workspace "$w" 2>/dev/null) || continue
    fi
    [ -n "$tjson" ] || continue
    rows=$(printf '%s' "$tjson" | jq -r "$AR_JQ_CLEAN"'
      (.result.tabs // .tabs // [])[]
      | [ (.tab_id | clean), (.label | clean), ((.pane_count // 0) | tostring),
          ((.focused // false) | tostring), (._name_pane // ""),
          (((.label // "") != (.label | clean)) | tostring),
          (._name_agent // ""), (._name_title // ""), (._name_title_lc // ""),
          (._name_dir_lc // "") ]
      | join([31] | implode)' 2>/dev/null)
    [ -n "$rows" ] || continue
    i=0
    while IFS=$AR_ROW_SEP read -r tid label pcount foc lpane dirty \
      AR_PANE_AGENT AR_PANE_TITLE AR_PANE_TITLE_LC AR_PANE_DIR_LC; do
      [ -n "$tid" ] || continue
      i=$(( i + 1 ))
      AR_SEEN_TABS="$AR_SEEN_TABS $tid"
      base0=$(ar_strip_prefix "$label")
      base=$base0
      named=0
      if [ "$CLEAR" != "1" ] && [ "$NAME_TABS" = "1" ]; then
        # Status, not emptiness: under HIDE_SHELL an empty name IS the name. With
        # the knob off it is not, because a config can erase a name it did compute
        # (MAX_NAME_LEN=0, a SUBSTITUTE_SETS rule that matches everything) and
        # blanking a tab over that was never the deal. The fast path declines it too.
        if ar_name_eligible "$tid" "$base0" && name=$(ar_tab_name "$tid" "$pcount" "$foc" "$lpane") \
           && { [ -n "$name" ] || [ "${HIDE_SHELL:-0}" = "1" ]; }; then
          base=$name
          named=1
        fi
      fi
      # herdr has not labeled this tab yet and we computed no name, so there is no
      # sensible "[i] " to form -- leave it until one of those changes. An empty
      # base is still written whenever the emptiness is deliberate: HIDE_SHELL just
      # named this tab nothing (named=1), or the label is already a bare "[i]" from
      # an earlier hidden pass, which still has to follow a renumber and to be
      # stripped by --clear. Both of those have a label, so testing it is enough.
      if [ -z "$label" ] && [ "$named" = "0" ]; then
        continue
      fi
      # Placeholder skip: with naming ON but no name computed yet, a bare-integer
      # base is herdr's transient placeholder ("3"). Numbering it now would flash
      # a throwaway "[3] 3" that the next event/zsh hook clobbers to "[3] zsh".
      # Defer this pass; the position (i) is still counted so later tabs are
      # correct. With naming OFF we DO number it (nothing else ever will), and
      # --clear must strip, so both skip this guard. An EMPTY base is not a
      # placeholder here (hence the -n, which ar_is_placeholder alone would not
      # give us): it got past the check above as a hidden tab, whose whole point is
      # to carry no name, so there is nothing to wait for.
      if [ "$CLEAR" != "1" ] && [ "$NAME_TABS" = "1" ] && [ "$named" = "0" ] \
         && [ -n "$base" ] && ar_is_placeholder "$base"; then
        continue
      fi
      want=$(ar_desired tabs "$i" "$base")
      # Ownership is recorded for a name the tab actually CARRIES: the label is
      # already right, or the rename reported success. Recording it for a rename
      # that failed (herdr rejected the label, the socket blipped) left state
      # claiming a base the tab does not have, and the next pass read that
      # mismatch as a hand rename and opted the tab out of naming for good --
      # recoverable only through the reset action. Same order as ar_fast_once.
      # A label that already matches needs no rename -- unless the label herdr
      # holds is not the one just compared. Rows arrive with their control
      # characters replaced (see AR_JQ_CLEAN), so a label carrying one reads as
      # equal to the cleaned name and would otherwise keep that character for
      # good. Worth a rename only for a name this plugin owns: a label it does
      # not own keeps whatever the user put there, control characters included.
      if { [ "$want" = "$label" ] && { [ "$named" = "0" ] || [ "$dirty" != "true" ]; }; } \
         || "$HERDR" tab rename "$tid" "$want" >/dev/null 2>&1; then
        ar_state_claim "$tid" "$name" "$named"
      fi
    done <<< "$rows"
  done <<< "$(printf '%s' "$wsjson" | jq -r '(.result.workspaces // .workspaces // [])[].workspace_id' 2>/dev/null)"
}

# ar_agent_revert <pane_id> <base> <detected>
# Remove our numbering from an agent (used by --clear and positions 10+). Reverts
# an auto-named agent to detection (which also sidesteps herdr's duplicate
# manual-name rejection when several agents share a base like "claude"); a
# genuinely user-named agent keeps its name.
ar_agent_revert() {
  local tid=$1 base=$2 detected=$3
  if [ -n "$detected" ] && [ "$base" = "$detected" ]; then
    "$HERDR" agent rename "$tid" --clear >/dev/null 2>&1 || true
  else
    "$HERDR" agent rename "$tid" "$base" >/dev/null 2>&1 || true
  fi
}

# ar_unpark_base <base> <detected> -> base with a stuck park-temp suffix removed.
# The two-phase swap below parks each agent at a UNIQUE temp "[N] <base> <tid>"
# then finalizes to "[N] <base>". If a finalize loses to herdr, the agent stays
# at the temp name; on the next pass ar_strip_prefix removes only "[N] " and the
# glued id becomes part of the base, freezing the agent. Recover the real base by
# dropping a trailing park token (" term_<hex>" or " <ws>:<pane>") ONLY when what
# remains is exactly the detected kind, so a real multi-word user name is untouched.
ar_unpark_base() {
  local base=$1 detected=$2 stripped
  [ -n "$detected" ] || { printf '%s' "$base"; return; }
  case "$base" in
    "$detected "*) ;;
    *) printf '%s' "$base"; return ;;
  esac
  case "${base##* }" in
    term_*|w[0-9]*:*) ;;
    *) printf '%s' "$base"; return ;;
  esac
  stripped=${base% *}
  if [ "$stripped" = "$detected" ]; then
    printf '%s' "$detected"
  else
    printf '%s' "$base"
  fi
}

# ar_version_lt <a> <b> -> 0 when dotted version a orders before b. Compares the
# first three numeric fields, treating a missing field as 0 ("0.8" = "0.8.0"), and
# reports "not less than" for anything non-numeric so an unparseable version never
# unlocks a version-gated path. Pure, so tests/test_prefix.sh exercises it directly.
ar_version_lt() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  local a="$1." b="$2." i=0 af bf
  while [ "$i" -lt 3 ]; do
    af=${a%%.*}; a=${a#*.}
    bf=${b%%.*}; b=${b#*.}
    [ -n "$af" ] || af=0
    [ -n "$bf" ] || bf=0
    case "$af$bf" in *[!0-9]*) return 1 ;; esac
    [ "$af" -lt "$bf" ] && return 0
    [ "$af" -gt "$bf" ] && return 1
    i=$(( i + 1 ))
  done
  return 1
}

# ar_herdr_version -> the running herdr's dotted version ("0.8.0"), or rc 1 when
# it cannot be read. `herdr --version` prints "herdr <version>"; take the first
# field shaped like a number and drop any trailing build metadata.
ar_herdr_version() {
  local out f
  out=$("$HERDR" --version 2>/dev/null) || return 1
  for f in $out; do
    case "$f" in
      [0-9]*.[0-9]*) printf '%s' "${f%%[!0-9.]*}"; return 0 ;;
    esac
  done
  return 1
}

# ar_agent_prefix_ok -> 0 when this herdr accepts "[N] <base>" as an agent name.
#
# herdr 0.7.5 added valid_agent_name (^[a-z][a-z0-9_-]{0,31}$, src/app/agents.rs)
# and now rejects anything else with `invalid_agent_name`, so a bracketed number
# is structurally impossible there -- every rename fails and the agent keeps
# whatever name it had. Agents are therefore numbered only below 0.7.5, and the
# prefixes are stripped at or above it, which also cleans up "[N] " names left
# stuck by an older herdr + older plugin (see ar_renumber_agents). An unreadable
# version is treated as restricted: refusing to number is recoverable, issuing
# renames herdr rejects is not.
#
# Workspace and tab renames are unaffected -- those labels are free-form.
ar_agent_prefix_ok() {
  local v
  v=$(ar_herdr_version) || return 1
  ar_version_lt "$v" "0.7.5"
}

# ar_agent_sort -> "priority" or "spaces" (grouped). herdr renders the agent panel
# in its agent_panel_sort order: "spaces"/"workspaces" (grouped by space) or
# "priority" (attention queue). cmd+alt+N follows that VISIBLE order, but the CLI
# (`agent list`, `api snapshot`) always returns the fixed grouped order and herdr
# exposes neither the panel's displayed order nor a resort event, so in "priority"
# mode we cannot know the order a static "[N]" would have to match. We therefore
# number agents only in grouped mode (where agent-list order IS the panel order)
# and strip the prefixes in "priority" mode (see ar_renumber_agents). herdr
# rewrites agent_panel_sort into config.toml the instant the sort is toggled, so
# the file is the live source of truth; default (key unset) is "spaces".
# A named session keeps its own config.toml beside its session.json, so the path
# comes from ar_herdr_session_dir; HERDR_CONFIG_FILE overrides it for testing.
ar_agent_sort() {
  local cfg="${HERDR_CONFIG_FILE:-$(ar_herdr_session_dir)/config.toml}" line
  line=$(grep -E '^[[:space:]]*agent_panel_sort[[:space:]]*=' "$cfg" 2>/dev/null | tail -n1)
  case "${line#*=}" in
    *priority*) printf 'priority' ;;
    *)          printf 'spaces' ;;
  esac
}

# Agents: cmd+alt+N indexes agent-list order. The display label is .name (what
# agent rename sets) falling back to .agent when unnamed. Count EVERY agent-list
# row in order, including a degraded row whose .agent is null (it stays in the
# list and is still reached by cmd+alt+N), so our counter stays in sync with
# herdr's sidebar. agent rename REJECTS a manual name already held by another
# terminal, so positions 1-9 (unique "[N]" targets) use a two-phase park (unique
# temps first, then finals) and positions 10+ (bare, non-unique) revert individually.
#
# The rename target is .pane_id, the only form every supported herdr resolves:
# 0.7.5's resolve_agent_target (src/app/terminal_targets.rs) accepts a current
# pane id or a unique agent name and no longer matches .terminal_id, which the
# older resolve_terminal_target tried first. .terminal_id stays as a fallback for
# a row that somehow carries no pane id.
#
# Numbering is skipped (and existing prefixes stripped) in two cases: a herdr that
# rejects bracketed agent names (ar_agent_prefix_ok) and a "priority"-sorted panel,
# whose order is dynamic and API-invisible (ar_agent_sort). Both strip exactly the
# way --clear does.
ar_renumber_agents() {
  local json rows tid label detected base want i=0 n j strip=0
  if [ "${AR_HAVE_SNAPSHOT:-0}" = "1" ]; then
    json="$AR_SNAP_AGENTS_JSON"
  else
    json=$("$HERDR" agent list 2>/dev/null) || return 0
  fi
  [ -n "$json" ] || return 0
  rows=$(printf '%s' "$json" | jq -r "$AR_JQ_CLEAN"'
    (.result.agents // .agents // [])[]
    | [ (.pane_id // .terminal_id // "" | clean), (.name // .agent // "" | clean),
        (.agent_session.agent // .agent // "" | clean) ]
      | join([31] | implode)' 2>/dev/null)
  [ -n "$rows" ] || return 0

  # Revert to detection (strip our "[N]") on uninstall, with agent numbering
  # switched off, on a herdr that rejects bracketed agent names, OR whenever the
  # agent panel is priority-sorted: a fixed-order number can only be wrong
  # against a queue we cannot observe. Grouped mode on an older herdr with the
  # scope on falls through to numbering below.
  #
  # The toggle is tested BEFORE the two probes below on purpose: ar_agent_prefix_ok
  # shells out for the herdr version and ar_agent_sort reads config.toml, and a
  # config with agents switched off should not pay for either on every event.
  if [ "$CLEAR" = "1" ]; then
    strip=1
  elif ! ar_index_on agents; then
    strip=1
  elif ! ar_agent_prefix_ok; then
    strip=1
  elif [ "$(ar_agent_sort)" = "priority" ]; then
    strip=1
  fi
  if [ "$strip" = "1" ]; then
    while IFS=$AR_ROW_SEP read -r tid label detected; do
      [ -n "$tid" ] || continue
      base=$(ar_strip_prefix "$label")
      base=$(ar_unpark_base "$base" "$detected")
      [ "$base" = "$label" ] && continue
      ar_agent_revert "$tid" "$base" "$detected"
    done <<< "$rows"
    return 0
  fi

  local -a P_TID P_WANT
  while IFS=$AR_ROW_SEP read -r tid label detected; do
    [ -n "$tid" ] || continue
    i=$(( i + 1 ))
    base=$(ar_strip_prefix "$label")
    base=$(ar_unpark_base "$base" "$detected")
    # A slot with no name AND no detected kind still counts toward the position
    # but we can't form "[N] base" for it -- leave it until herdr names it.
    [ -n "$base" ] || continue
    want=$(ar_desired agents "$i" "$base")
    [ "$want" = "$label" ] && continue
    if [ "$i" -ge 1 ] && [ "$i" -le 9 ]; then
      P_TID+=("$tid"); P_WANT+=("$want")
    else
      ar_agent_revert "$tid" "$base" "$detected"
    fi
  done <<< "$rows"

  n=${#P_TID[@]}
  [ "$n" -gt 0 ] || return 0
  if [ "$n" -gt 1 ]; then
    for (( j = 0; j < n; j++ )); do
      "$HERDR" agent rename "${P_TID[$j]}" "${P_WANT[$j]} ${P_TID[$j]}" >/dev/null 2>&1 || true
    done
  fi
  for (( j = 0; j < n; j++ )); do
    "$HERDR" agent rename "${P_TID[$j]}" "${P_WANT[$j]}" >/dev/null 2>&1 || true
  done
}

# ar_wait_tab_gone <tab_id> - block (bounded ~3s) until a just-closed tab has left
# herdr's model, so the reconcile that follows never numbers by a stale list.
# herdr keeps a closing tab in `tab list` until its pane finishes tearing down;
# the tab.closed event fires while it is still listed, so an immediate reconcile
# would find every number already correct and change nothing. Waiting for the id
# to disappear turns that race into a settled read.
ar_wait_tab_gone() {
  local t=$1 i=0 raw
  [ -n "$t" ] || return 0
  while [ "$i" -lt 60 ]; do
    raw=$("$HERDR" tab get "$t" 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0
    printf '%s' "$raw" | jq -e '(.result.tab // .tab) | has("tab_id")' >/dev/null 2>&1 || return 0
    i=$(( i + 1 ))
    sleep 0.05 2>/dev/null || return 0
  done
}

# ar_notify <title> <body> - tell the user an action ran. Both actions are meant
# for a keybinding, where the only other feedback is the tab bar redrawing (or,
# for a reset that finds nothing to re-adopt, nothing at all). Best effort: an
# older herdr without `notification show` just declines.
ar_notify() {
  "$HERDR" notification show "$1" --body "$2" >/dev/null 2>&1 || true
}

# ======================================================================
# passes
# ======================================================================

# Full reconcile of every list. Each pass consults its own toggle to decide
# whether to number or to strip; --clear ignores the toggles and strips
# everything (the uninstall path).
ar_reconcile() {
  local wsjson snap workspace_pass=0
  if ar_index_pass workspaces || [ "${#WORKSPACE_SUBSTITUTE_SETS[@]}" -gt 0 ] ||
     ar_ws_subst_pending; then
    workspace_pass=1
  fi
  # A reset deletes the target tab's state once (under the lock) so it re-adopts.
  # Whether there was anything to re-adopt is read BEFORE the delete, because that
  # is what the action reports back and `del` on a key that was never there
  # succeeds quietly: a stale tab id would otherwise be told it was re-adopted.
  if [ -n "${AR_FORCE_TAB:-}" ] && [ -z "${AR_FORCE_DONE:-}" ]; then
    [ "$(ar_state_get "$AR_FORCE_TAB" enabled)" = "false" ] && AR_FORCE_WAS_OUT=1
    ar_state_del "$AR_FORCE_TAB"
    AR_FORCE_DONE=1
  fi
  # One `herdr api snapshot` (herdr >= 0.7.2) carries the workspace, tab, pane,
  # and agent lists in a single socket round-trip, in the SAME order and with the
  # same fields as the individual `... list` commands -- and numbering reads array
  # order, so that equal ordering is load-bearing (verified against a live herdr).
  # It replaces the old per-reconcile fan-out of `workspace list` + `pane list` +
  # `agent list` + one `tab list` per workspace. We reshape each slice into the
  # `{result:{...}}` envelope the existing jq already expects and cache the tab /
  # agent slices for ar_reconcile_tabs / ar_renumber_agents. Any failure (older
  # herdr with no `api snapshot`, a socket hiccup) falls back to the separate list
  # calls, so this never raises the plugin's min herdr version. Per-tab foreground
  # detection (`pane process-info`) is unaffected -- the snapshot carries panes but
  # not each pane's foreground process, so naming still samples per named tab.
  AR_HAVE_SNAPSHOT=0
  AR_SNAP_TABS_JSON=""
  AR_SNAP_AGENTS_JSON=""
  snap=$("$HERDR" api snapshot 2>/dev/null) || snap=""
  if [ -n "$snap" ] && printf '%s' "$snap" \
       | jq -e '(.result.snapshot // .snapshot).workspaces' >/dev/null 2>&1; then
    AR_HAVE_SNAPSHOT=1
    wsjson=$(printf '%s' "$snap" | jq -c \
      '{result:{workspaces:((.result.snapshot // .snapshot).workspaces // [])}}' 2>/dev/null)
    # Each tab carries the pane its NAME comes from as _name_pane: per-tab data,
    # joined here so the tab loop never asks for it again (see ar_resolve_pane).
    #
    # Which pane that is, in order:
    #   1. the tab's own focused pane, when an agent is running in it;
    #   2. any pane of the tab holding an agent that is working or blocked;
    #   3. the tab's own focused pane.
    # A tab split between an agent and a shell is about the agent, and it stays
    # about the agent while you read the shell half -- but an IDLE agent does not
    # outrank whatever you are actually looking at.
    #
    # A herdr with no layouts cannot answer rules 1 or 3, since both are the tab's
    # own focused pane, so such a tab is picked by rule 2 or not at all: an agent at
    # work still names its tab there, and everything else falls to the pane-list
    # inference in ar_resolve_pane. Deliberate -- the rule needs no layout, and a
    # split with an agent working in it is the case the rule exists for.
    AR_SNAP_TABS_JSON=$(printf '%s' "$snap" | jq -c \
      --arg brands "${AR_TITLE_BRANDS:-}" "$AR_JQ_CLEAN$AR_JQ_TASK"'
      ($brands | brandmap) as $brand
       | (.result.snapshot // .snapshot) as $s
       | ($s.layouts // []) as $lay
       | ($s.panes // []) as $pan
       | {result:{tabs:[ $s.tabs[]? | .tab_id as $t
           | (($lay | map(select(.tab_id == $t)) | .[0].focused_pane_id) // "") as $lp
           | ($pan | map(select(.tab_id == $t and (.agent // "") != ""))) as $ag
           | ( ($ag | map(select(.pane_id == $lp)) | .[0].pane_id)
             # At work means not resting, so a status herdr adds later counts as
             # interesting instead of dropping out of the rule silently.
             // ($ag | map(select((.agent_status // "unknown") as $st
                                  | $st != "idle" and $st != "done" and $st != "unknown"))
                     | .[0].pane_id)
             // $lp ) as $pick
           | ($pan | map(select(.pane_id == $pick)) | .[0]) as $p
           | ($p.terminal_title_stripped // $p.terminal_title
              | taskof($brand; $p.agent)) as $ti
           | . + { _name_pane: $pick,
                   _name_agent: ($p.agent | clean),
                   _name_title: $ti,
                   _name_title_lc: ($ti | ascii_downcase),
                   _name_dir_lc: ((($p.foreground_cwd // $p.cwd | clean)
                                   | split("/") | last) // "" | ascii_downcase) } ]}}' 2>/dev/null)
    AR_SNAP_AGENTS_JSON=$(printf '%s' "$snap" | jq -c \
      '{result:{agents:((.result.snapshot // .snapshot).agents // [])}}' 2>/dev/null)
    # Lifted whatever the toggles say, because the workspace pass wants them as
    # well (ar_workspace_pane_dirs) and the snapshot is already in hand: one jq
    # over memory, no herdr call. The per-list path below still fetches only when
    # tab naming needs it, since there a pane list is a round-trip.
    if [ "$CLEAR" != "1" ]; then
      AR_PANES_JSON=$(printf '%s' "$snap" | jq -c \
        '{result:{panes:((.result.snapshot // .snapshot).panes // [])}}' 2>/dev/null)
      [ -n "$AR_PANES_JSON" ] || AR_PANES_JSON='{"result":{"panes":[]}}'
    fi
  else
    wsjson=$("$HERDR" workspace list 2>/dev/null) || wsjson=""
    if [ "$CLEAR" != "1" ] &&
       { [ "$NAME_TABS" = "1" ] || [ "$workspace_pass" = "1" ]; }; then
      AR_PANES_JSON=$("$HERDR" pane list 2>/dev/null) || AR_PANES_JSON='{"result":{"panes":[]}}'
    fi
  fi
  # ar_index_pass decides which kinds have numbering work to do, or a prefix to
  # strip. Workspace substitutions and tab naming also run their pass without
  # numbering.
  if [ "$workspace_pass" = "1" ]; then
    ar_renumber_workspaces "$wsjson"
  fi
  if ar_index_pass tabs || [ "$NAME_TABS" = "1" ]; then
    AR_SEEN_TABS=""
    ar_reconcile_tabs "$wsjson"
    # AR_SEEN_TABS is a space-joined list and ar_state_prune takes one tab id per
    # argument, so the split is the call. herdr tab ids carry no whitespace.
    # shellcheck disable=SC2086
    [ "$NAME_TABS" = "1" ] && [ -n "$AR_SEEN_TABS" ] && ar_state_prune $AR_SEEN_TABS
  fi
  if ar_index_pass agents; then
    ar_renumber_agents
  fi
  # The force was for this pass. ar_run can loop the reconcile when events land
  # while it runs, and a tab still forced on a later loop is a tab whose opt-out
  # check is still bypassed: rename it by hand inside that window and the next loop
  # would take the name back instead of leaving it alone, which is the one promise
  # this plugin makes. AR_FORCE_WAS_OUT and AR_FORCE_ADOPTED outlive it, because
  # the action still has to report what happened.
  AR_FORCE_TAB=""
}

# Fast path for the shell hooks: rename only the current tab (no cross-tab work).
# preexec passes the command line; precmd (back at the prompt) names by the shell.
# Preserves the existing "[N]" prefix when tab numbering is on, drops it when off.
#
# preexec has two modes. Default: trust the command line's first word as the
# program (accurate for external commands and expanded aliases). Sampled
# (AR_FAST_SAMPLE=1, the hook classified the word as a shell construct --
# function/builtin/reserved/typo): the word is NOT the program, so read the
# pane's real foreground process instead. An instant construct has exited by
# sample time (leader = the shell -> name already "zsh" -> no rename, no
# flicker); a construct wrapping nvim samples as nvim. On sampling failure
# rename nothing -- never guess.
ar_fast_once() {
  local tab="${HERDR_TAB_ID:-}"
  [ -n "$tab" ] || return 0
  local prog="" cmd="" info name label raw prefix slabel enabled auto want
  if [ "$MODE" = "preexec" ]; then
    if [ "${AR_FAST_SAMPLE:-}" = "1" ]; then
      info=$(ar_pane_program "${HERDR_PANE_ID:-}") || return 0
      ar_split_program "$info"
      prog=$AR_PROG
      cmd=$AR_CMD
      [ -n "$prog" ] || return 0
    else
      cmd="${AR_FAST_ARG:-}"
      prog="${cmd%% *}"; prog="${prog##*/}"
    fi
  fi
  name=$(ar_format "$prog" "$cmd")
  # A failed `tab get` must NOT look like an empty label (which would read as a
  # placeholder and clobber a hand-picked name). Only proceed on a real tab object.
  raw=$("$HERDR" tab get "$tab" 2>/dev/null) || return 0
  [ -n "$raw" ] || return 0
  printf '%s' "$raw" | jq -e '(.result.tab // .tab) | has("label")' >/dev/null 2>&1 || return 0
  label=$(printf '%s' "$raw" | jq -r "$AR_JQ_CLEAN"'(.result.tab // .tab).label | clean' 2>/dev/null)

  if ar_index_on tabs; then prefix=$(ar_index_prefix "$label"); else prefix=""; fi
  slabel=$(ar_strip_prefix "$label")
  ar_name_eligible "$tab" "$slabel" || return 0
  # Empty is a real answer under HIDE_SHELL (name the tab nothing, keeping the
  # number alone when there is one); anywhere else it means we have no name.
  if [ -z "$name" ]; then
    [ "${HIDE_SHELL:-0}" = "1" ] || return 0
    prefix="${prefix% }"                        # "[3] " -> "[3]", "" stays ""
  fi
  want="${prefix}${name}"
  if [ "$want" != "$label" ]; then
    "$HERDR" tab rename "$tab" "$want" >/dev/null 2>&1 || return 0
  fi
  ar_state_claim "$tab" "$name" 1
}

# Coalesce bursts: only the lock holder works; contenders raise the rerun flag
# and exit, and the holder loops until no new work arrives (bounded). A fast pass
# escalates to a full reconcile the moment any rerun is seen -- a full reconcile
# is a superset of the single-tab rename, so a structural event that raced a
# preexec is still handled (and its lost rename recovered) inside this loop.
ar_run() {
  local want="${1:-full}" mode="${2:-event}" tries=0
  while ! ar_lock; do
    # An EVENT can defer: raising the rerun flag makes whoever holds the lock do
    # this work too, and every pass computes the same thing. An ACTION cannot. Its
    # request lives in this process (AR_FORCE_TAB, CLEAR), so handing the job over
    # would drop it silently -- a reset pressed during a burst of events did
    # nothing at all, and said nothing either, since exiting here never reached the
    # notification. So it waits for its turn, and gives up rather than hanging.
    if [ "$mode" != "action" ]; then
      : > "$RERUN_FLAG" 2>/dev/null || true
      exit 0
    fi
    tries=$(( tries + 1 ))
    [ "$tries" -ge 20 ] && return 1   # ~2s, where a pass runs in well under one
    sleep 0.1 2>/dev/null || return 1
  done
  trap 'ar_unlock' EXIT
  local guard=0
  while :; do
    rm -f "$RERUN_FLAG" 2>/dev/null || true
    if [ "$want" = "fast" ]; then ar_fast_once; else ar_reconcile; fi
    want=full                              # any re-pass is a full reconcile
    guard=$(( guard + 1 ))
    [ "$guard" -ge 8 ] && break
    [ -f "$RERUN_FLAG" ] && continue
    ar_unlock
    [ -f "$RERUN_FLAG" ] || break
    ar_lock || break
  done
}

# ======================================================================
# entry point
# ======================================================================
# ar_main holds everything that must NOT run when this file is sourced for tests:
# the jq/herdr prerequisite checks, the config + naming load, the toggle
# defaults, the mode parse, and the dispatch.
ar_main() {
  set -o pipefail

  command -v jq >/dev/null 2>&1 || exit 0
  command -v "$HERDR" >/dev/null 2>&1 || exit 0
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

  # Config overrides must load BEFORE naming.sh (its defaults only fill unset vars).
  # The config path is the user's, resolved at runtime, so shellcheck has no file
  # to read here.
  # shellcheck source=/dev/null
  [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
  # shellcheck source=naming.sh
  . "$AR_ROOT/naming.sh"

  # TITLE_BRANDS as one argument for the two title lifts, joined here so neither
  # pays for it per pane. Both look a brand up by the pane's agent kind, and the
  # snapshot lift reshapes every tab in one jq, so the lookup cannot be done out
  # here. printf -v rather than a command substitution because this runs on every
  # event and every shell hook, and the fast path never lifts a title at all: a
  # fork for a value it throws away is the one cost the hook path cannot amortize.
  # An empty list leaves a lone newline, which brandmap reads as no entries.
  printf -v AR_TITLE_BRANDS '%s\n' "${TITLE_BRANDS[@]}"

  # Naming toggle (default on). A config value of 0 wins because := only fills
  # an unset/empty var. Numbering needs nothing here: AUTO_INDEX, the per-kind
  # overrides and their shared default are read straight from the config by
  # ar_index_on and ar_index_explicit.
  : "${NAME_TABS:=1}"

  MODE="${1:-event}"
  CLEAR=0
  case "$MODE" in --clear|clear) CLEAR=1 ;; esac

  case "$MODE" in
    preexec)
      [ "$NAME_TABS" = "1" ] || exit 0
      AR_FAST_ARG="${2:-}"                    # the command line being run
      # $3 = "shell": the hook resolved the command word to a shell construct
      # (function/builtin/reserved/typo), which never becomes the foreground
      # process. Give the construct a moment to finish or spawn its real
      # program, then name by what actually holds the pane (see ar_fast_once).
      # The settle sleep runs BEFORE ar_run so the lock is never held asleep.
      if [ "${3:-}" = "shell" ]; then
        AR_FAST_SAMPLE=1
        sleep 0.2 2>/dev/null || true
      fi
      ar_run fast
      ;;
    precmd)
      [ "$NAME_TABS" = "1" ] || exit 0
      # Optional 2nd arg = the calling shell's own name, so a bare prompt in a
      # bash/fish pane reads "bash"/"fish" instead of $SHELL (the login shell).
      # Absent (a bare `precmd` from an older caller) -> keep the SHELL_NAME
      # default from naming.sh/config. ar_format returns SHELL_NAME for an empty
      # program, which is exactly the bare-prompt case the precmd fast path hits.
      [ -n "${2:-}" ] && SHELL_NAME="$2"
      ar_run fast
      ;;
    reset)
      # Prefer the documented action inputs (HERDR_TAB_ID, then the context JSON);
      # fall back to the focused tab so reset still targets something.
      tab="${HERDR_TAB_ID:-}"
      if [ -z "$tab" ] && [ -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ]; then
        tab=$(printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" \
          | jq -r '.tab.tab_id // .tab.id // .tab_id // empty' 2>/dev/null)
      fi
      if [ -z "$tab" ]; then
        tab=$("$HERDR" tab list 2>/dev/null \
          | jq -r 'first((.result.tabs // .tabs)[] | select(.focused) | .tab_id) // empty' 2>/dev/null)
      fi
      [ -n "$tab" ] && [ "$NAME_TABS" = "1" ] && AR_FORCE_TAB="$tab"
      if ! ar_run full action; then
        ar_notify "Reset is waiting" "Another naming pass held the lock. Try again."
        exit 0
      fi
      # Two facts, both from the pass that just ran: the tab HAD opted out
      # (AR_FORCE_WAS_OUT, read before its state was cleared) and it is named and
      # owned again (AR_FORCE_ADOPTED, set where that claim is recorded). Only both
      # together are a re-adoption. Either alone is worth saying out loud, because
      # a keybinding has nothing else to report with.
      if [ -n "${AR_FORCE_WAS_OUT:-}" ] && [ -n "${AR_FORCE_ADOPTED:-}" ]; then
        ar_notify "Tab re-adopted" "Automatic naming is on for this tab again."
      elif [ -n "${AR_FORCE_WAS_OUT:-}" ]; then
        ar_notify "Reset did not take" "That tab had opted out, but the rename did not land."
      elif [ "$NAME_TABS" != "1" ]; then
        ar_notify "Nothing to reset" "Tab naming is off (NAME_TABS=0)."
      elif [ -n "${AR_FORCE_ADOPTED:-}" ]; then
        ar_notify "Nothing to reset" "That tab was already named automatically."
      else
        ar_notify "Nothing to reset" "No tab to re-adopt."
      fi
      ;;
    clear|--clear)
      if ar_run full action; then            # CLEAR=1 already set above
        ar_notify "Number prefixes cleared" "Base names restored, agents back to detection."
      else
        ar_notify "Clear is waiting" "Another naming pass held the lock. Try again."
      fi
      ;;
    tab.closed)
      ar_wait_tab_gone "${HERDR_TAB_ID:-}"   # settle before the reconcile
      ar_run full                            # renumbers survivors; ar_state_prune drops the closed tab
      ;;
    *)
      ar_run full                            # any other herdr event
      ;;
  esac
}

# Execute only when run as a script, never when sourced (the test suite sources
# this file to unit-test the pure helpers). BASH_SOURCE[0] == $0 iff executed.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  ar_main "$@"
fi
