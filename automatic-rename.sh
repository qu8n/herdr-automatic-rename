#!/usr/bin/env bash
#
# herdr-automatic-rename - one plugin, two toggleable features:
#
#   NAME_TABS=1   auto-name each tab after its foreground program, or the shell
#                 name at a bare prompt (manual renames opt a tab out). Applies
#                 to tabs only.
#   AUTO_INDEX=1  prefix each workspace, tab, and agent with the 1-9 number of
#                 its jump keybind (switch_workspace/switch_tab/focus_agent) as
#                 "[N] <base>". Applies to workspaces, tabs, and agents -- except
#                 agents are numbered ONLY when the panel is grouped-sorted;
#                 "priority" sort reorders the panel behind an API we can't read,
#                 so agent numbers are stripped there (see ar_agent_sort).
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

# The prerequisite checks, config + naming load, toggle defaults, mode parse, and
# dispatch all live in ar_main (bottom of file) so that sourcing this file for
# unit tests loads ONLY the function definitions and touches nothing at runtime.

# ======================================================================
# prefix helpers (the "[N] " contract, shared by both features)
# ======================================================================

# ar_strip_prefix <label> -> label with a leading "[<digits>] " removed. Only
# strips when the bracketed part is all digits (so user text like "[wip] foo" is
# left untouched), and removes the EXACT reconstructed "[num] " literal so this
# is the precise inverse of ar_index_prefix (a malformed label such as "[1]x] foo"
# is left alone by both, never diverging).
ar_strip_prefix() {
  local s=$1 num
  case "$s" in
    \[[0-9]*\]\ *)
      num=${s#\[}; num=${num%%\]*}
      case "$num" in
        ''|*[!0-9]*) printf '%s' "$s" ;;
        *)           printf '%s' "${s#"[$num] "}" ;;
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
    \[[0-9]*\]\ *)
      num=${s#\[}; num=${num%%\]*}
      case "$num" in
        ''|*[!0-9]*) printf '' ;;
        *)           printf '[%s] ' "$num" ;;
      esac
      ;;
    *) printf '' ;;
  esac
}

# ar_desired <position> <base> -> the label this item should have.
#   --clear             -> always the bare base (strip numbering)
#   AUTO_INDEX off       -> bare base (self-heals a stale prefix as items reconcile)
#   AUTO_INDEX on, 1..9  -> "[N] base"
#   AUTO_INDEX on, 10+   -> bare base (no keybind reaches it)
ar_desired() {
  local n=$1 base=$2
  if [ "$CLEAR" = "1" ] || [ "$AUTO_INDEX" != "1" ]; then printf '%s' "$base"; return; fi
  if [ "$n" -ge 1 ] && [ "$n" -le 9 ]; then
    printf '[%d] %s' "$n" "$base"
  else
    printf '%s' "$base"
  fi
}

# A label counts as "unnamed" (fair game for FIRST-TIME auto-naming, and a
# throwaway to defer in the placeholder skip) when it is empty or a plain integer
# -- herdr's generated tab labels are small integers ("1", "2"...).
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
ar_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$AR_LOCK_TOKEN" > "$LOCK_DIR/owner" 2>/dev/null
    return 0
  fi
  local now mt age
  now=$(date +%s 2>/dev/null || echo 0)
  mt=$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo "$now")
  age=$(( now - mt ))
  if [ "$age" -gt 30 ]; then
    rm -f "$LOCK_DIR/owner" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s' "$AR_LOCK_TOKEN" > "$LOCK_DIR/owner" 2>/dev/null
      return 0
    fi
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
ar_state_get() { # <tab_id> <field>
  [ -f "$STATE_FILE" ] || return 0
  # NOT `.[$t][$f] // empty`: `//` treats a boolean `false` as absent, so the
  # `enabled` flag would read back as "" and an opted-out tab would look
  # first-seen on every pass (re-adopting a deliberately numeric name). Emit the
  # value unless it is genuinely null/missing.
  jq -r --arg t "$1" --arg f "$2" '.[$t][$f] as $v | if $v == null then empty else $v end' \
    "$STATE_FILE" 2>/dev/null
}
ar_state_set() { # <tab_id> <auto-name> <enabled true|false>
  local base tmp
  base='{}'
  [ -f "$STATE_FILE" ] && base=$(cat "$STATE_FILE" 2>/dev/null)
  [ -n "$base" ] || base='{}'
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 0
  if printf '%s' "$base" | jq --arg t "$1" --arg a "$2" --argjson e "$3" \
       '.[$t] = {auto: $a, enabled: $e}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}
ar_state_del() { # <tab_id>
  [ -f "$STATE_FILE" ] || return 0
  local tmp
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 0
  if jq --arg t "$1" 'del(.[$t])' "$STATE_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}
ar_state_prune() { # <keep tab_ids...> - drop entries for tabs that no longer exist
  [ -f "$STATE_FILE" ] || return 0
  local keep tmp
  keep=$(printf '%s\n' "$@" | jq -R . | jq -s .) || return 0
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 0
  if jq --argjson keep "$keep" \
       'with_entries(select(.key as $k | $keep | index($k)))' "$STATE_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}

# ar_name_eligible <tab_id> <base label, prefix already stripped>
# The manual-rename exclusion state machine. Returns 0 (eligible for auto-naming)
# or 1 (leave the base alone). May write opt-out state as a side effect. Needs no
# computed name, so an opted-out tab costs no process-info call.
ar_name_eligible() {
  local tab=$1 slabel=$2 enabled auto
  enabled=$(ar_state_get "$tab" enabled)
  auto=$(ar_state_get "$tab" auto)
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
    else ar_state_set "$tab" "" false; return 1 # user renamed -> opt out
    fi
  fi
}

# ======================================================================
# tab-name computation (herdr-touching; feeds ar_format from naming.sh)
# ======================================================================

# ar_resolve_pane <tab_id> <pane_count> <focused> -> the active pane_id or "".
# The sole pane of a single-pane tab, else the globally focused pane for the
# focused tab. A background multi-pane tab exposes no active pane over the socket
# and returns "" (its name is left as-is until it is next focused). Reads the
# cached $AR_PANES_JSON.
ar_resolve_pane() {
  local tid=$1 pc=$2 foc=$3
  printf '%s' "$AR_PANES_JSON" | jq -r --arg t "$tid" --arg pc "$pc" --arg foc "$foc" '
    (.result.panes // .panes // []) as $p
    | ($p | map(select(.tab_id == $t))) as $tp
    | (if $pc == "1" then $tp[0]
       elif $foc == "true" then (($p | map(select(.focused)) | .[0]) // $tp[0])
       else null end)
    | if . == null then "" else (.pane_id // "") end
  ' 2>/dev/null
}

# ar_pane_program <pane_id> -> TSV "program<TAB>cmdline".
# The foreground command is the process-group leader (pid == group id). At a bare
# prompt the leader IS the login shell, whose argv0 ("-zsh") strips to "zsh".
# program comes from argv0 (NOT .name -- agents like claude report a version
# string as .name), with a login shell's leading "-" removed and the path stripped.
ar_pane_program() {
  local out
  out=$("$HERDR" pane process-info --pane "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '
    (.result.process_info // .process_info) as $pi
    | ($pi.foreground_process_group_id) as $g
    | ($pi.foreground_processes // []) as $fp
    | ($fp | map(select(.pid == $g)) | first) as $p
    | if ($p == null) then
        ["", ""]
      else
        [ (($p.argv0 // $p.name // "") | sub("^-"; "") | split("/") | last),
          ($p.cmdline // (($p.argv // []) | join(" "))) ]
      end
    | @tsv
  ' 2>/dev/null
}

# ar_tab_name <tab_id> <pane_count> <focused> -> computed base name, or "" when
# the active pane can't be resolved / process-info fails.
ar_tab_name() {
  local pane info prog="" cmd=""
  pane=$(ar_resolve_pane "$1" "$2" "$3")
  [ -n "$pane" ] || { printf ''; return 0; }
  # process-info can fail transiently (pane closing, socket hiccup) or resolve no
  # foreground process; both leave prog empty. Return "" so the caller keeps the
  # tab's current name, rather than falling through to ar_format "" "" ->
  # $SHELL_NAME and clobbering (e.g.) an "nvim" tab with "zsh" on a blip.
  info=$(ar_pane_program "$pane") || { printf ''; return 0; }
  IFS=$'\t' read -r prog cmd <<< "$info"
  [ -n "$prog" ] || { printf ''; return 0; }
  ar_format "$prog" "$cmd"
}

# ======================================================================
# reconcilers
# ======================================================================

# Workspaces: alt+N follows the SIDEBAR (grouped visible) order, which is NOT the
# raw `workspace list` array order. herdr groups workspaces that share a repo into
# a nested "space" keyed by .worktree.repo_key (the repo's .git path): the space
# renders at the array position of its first-appearing member, members nested in
# array order; a workspace with no worktree is its own singleton space. A newly
# created worktree is APPENDED at the array end but nests with its earlier repo
# group, so we rebuild the grouped order and number by THAT (tag each workspace
# with its array index _i, map each group key to its members' min _i as the
# anchor, sort by [anchor, _i]). A COLLAPSED space hides its members from alt+N
# but herdr persists collapse only in session.json, so we assume expanded.
# Arg 1 is a cached `workspace list` JSON.
ar_renumber_workspaces() {
  local json=$1 rows wid label base want i=0
  [ -n "$json" ] || return 0
  rows=$(printf '%s' "$json" | jq -r '
    (.result.workspaces // .workspaces // [])
    | [ to_entries[] | .value + {_i: .key} ]
    | ( group_by(.worktree.repo_key // ("@ws:" + .workspace_id))
        | map({ (.[0].worktree.repo_key // ("@ws:" + .[0].workspace_id)): (map(._i) | min) })
        | add ) as $anchor
    | sort_by([ $anchor[(.worktree.repo_key // ("@ws:" + .workspace_id))], ._i ])
    | .[] | [.workspace_id, (.label // "")] | @tsv' 2>/dev/null)
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r wid label; do
    [ -n "$wid" ] || continue
    i=$(( i + 1 ))
    base=$(ar_strip_prefix "$label")
    [ -n "$base" ] || continue          # empty label: nothing to number, leave it
    want=$(ar_desired "$i" "$base")
    [ "$want" = "$label" ] && continue
    "$HERDR" workspace rename "$wid" "$want" >/dev/null 2>&1 || true
  done <<< "$rows"
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
    tjson=$("$HERDR" tab list --workspace "$w" 2>/dev/null) || continue
    rows=$(printf '%s' "$tjson" | jq -r '
      (.result.tabs // .tabs // [])[]
      | [ .tab_id, (.label // ""), (.pane_count // 0), (.focused // false) ] | @tsv' 2>/dev/null)
    [ -n "$rows" ] || continue
    i=0
    while IFS=$'\t' read -r tid label pcount foc; do
      [ -n "$tid" ] || continue
      i=$(( i + 1 ))
      AR_SEEN_TABS="$AR_SEEN_TABS $tid"
      base0=$(ar_strip_prefix "$label")
      base=$base0
      named=0
      if [ "$CLEAR" != "1" ] && [ "$NAME_TABS" = "1" ]; then
        if ar_name_eligible "$tid" "$base0"; then
          name=$(ar_tab_name "$tid" "$pcount" "$foc")
          if [ -n "$name" ]; then
            base=$name
            named=1
            ar_state_set "$tid" "$name" true   # record ownership even if no rename
          fi
        fi
      fi
      # Can't form a sensible "[i] " for an empty base -- leave it until herdr
      # gives the tab a label.
      [ -n "$base" ] || continue
      # Placeholder skip: with naming ON but no name computed yet, a bare-integer
      # base is herdr's transient placeholder ("3"). Numbering it now would flash
      # a throwaway "[3] 3" that the next event/zsh hook clobbers to "[3] zsh".
      # Defer this pass; the position (i) is still counted so later tabs are
      # correct. With naming OFF we DO number it (nothing else ever will), and
      # --clear must strip, so both skip this guard.
      if [ "$CLEAR" != "1" ] && [ "$NAME_TABS" = "1" ] && [ "$named" = "0" ]; then
        case "$base" in
          *[!0-9]*) : ;;      # has a non-digit -> real base, number it
          *)        continue ;;  # all digits -> placeholder, defer
        esac
      fi
      want=$(ar_desired "$i" "$base")
      [ "$want" = "$label" ] && continue
      "$HERDR" tab rename "$tid" "$want" >/dev/null 2>&1 || true
    done <<< "$rows"
  done <<< "$(printf '%s' "$wsjson" | jq -r '(.result.workspaces // .workspaces // [])[].workspace_id' 2>/dev/null)"
}

# ar_agent_revert <terminal_id> <base> <detected>
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
# HERDR_CONFIG_FILE overrides the path (for non-default sessions or testing).
ar_agent_sort() {
  local cfg="${HERDR_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}" line
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
# In "priority" sort the panel order is dynamic and API-invisible (see
# ar_agent_sort), so there we strip our numbering exactly like --clear does.
ar_renumber_agents() {
  local json rows tid label detected base want i=0 n j strip=0
  json=$("$HERDR" agent list 2>/dev/null) || return 0
  rows=$(printf '%s' "$json" | jq -r '
    (.result.agents // .agents // [])[]
    | [ (.terminal_id // .pane_id // ""), (.name // .agent // ""), (.agent_session.agent // .agent // "") ] | @tsv' 2>/dev/null)
  [ -n "$rows" ] || return 0

  # Revert to detection (strip our "[N]") on uninstall OR whenever the agent panel
  # is priority-sorted: a fixed-order number can only be wrong against a queue we
  # cannot observe. Grouped mode falls through to numbering below.
  if [ "$CLEAR" = "1" ]; then
    strip=1
  elif [ "$(ar_agent_sort)" = "priority" ]; then
    strip=1
  fi
  if [ "$strip" = "1" ]; then
    while IFS=$'\t' read -r tid label detected; do
      [ -n "$tid" ] || continue
      base=$(ar_strip_prefix "$label")
      base=$(ar_unpark_base "$base" "$detected")
      [ "$base" = "$label" ] && continue
      ar_agent_revert "$tid" "$base" "$detected"
    done <<< "$rows"
    return 0
  fi

  local -a P_TID P_WANT
  while IFS=$'\t' read -r tid label detected; do
    [ -n "$tid" ] || continue
    i=$(( i + 1 ))
    base=$(ar_strip_prefix "$label")
    base=$(ar_unpark_base "$base" "$detected")
    # A slot with no name AND no detected kind still counts toward the position
    # but we can't form "[N] base" for it -- leave it until herdr names it.
    [ -n "$base" ] || continue
    want=$(ar_desired "$i" "$base")
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

# ======================================================================
# passes
# ======================================================================

# Full reconcile of every list, gated by the toggles. --clear ignores the toggles
# and strips everything (the uninstall path).
ar_reconcile() {
  local wsjson
  # A reset deletes the target tab's state once (under the lock) so it re-adopts.
  if [ -n "${AR_FORCE_TAB:-}" ] && [ -z "${AR_FORCE_DONE:-}" ]; then
    ar_state_del "$AR_FORCE_TAB"
    AR_FORCE_DONE=1
  fi
  wsjson=$("$HERDR" workspace list 2>/dev/null) || wsjson=""
  if [ "$CLEAR" != "1" ] && [ "$NAME_TABS" = "1" ]; then
    AR_PANES_JSON=$("$HERDR" pane list 2>/dev/null) || AR_PANES_JSON='{"result":{"panes":[]}}'
  fi
  if [ "$CLEAR" = "1" ] || [ "$AUTO_INDEX" = "1" ]; then
    ar_renumber_workspaces "$wsjson"
  fi
  if [ "$CLEAR" = "1" ] || [ "$AUTO_INDEX" = "1" ] || [ "$NAME_TABS" = "1" ]; then
    AR_SEEN_TABS=""
    ar_reconcile_tabs "$wsjson"
    [ "$NAME_TABS" = "1" ] && [ -n "$AR_SEEN_TABS" ] && ar_state_prune $AR_SEEN_TABS
  fi
  if [ "$CLEAR" = "1" ] || [ "$AUTO_INDEX" = "1" ]; then
    ar_renumber_agents
  fi
}

# Fast path for the shell hooks: rename only the current tab (no cross-tab work).
# preexec passes the command line; precmd (back at the prompt) names by the shell.
# Preserves the existing "[N]" prefix when AUTO_INDEX is on, drops it when off.
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
      IFS=$'\t' read -r prog cmd <<< "$info"
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
  label=$(printf '%s' "$raw" | jq -r '(.result.tab // .tab).label // ""' 2>/dev/null)

  if [ "$AUTO_INDEX" = "1" ]; then prefix=$(ar_index_prefix "$label"); else prefix=""; fi
  slabel=$(ar_strip_prefix "$label")
  ar_name_eligible "$tab" "$slabel" || return 0
  [ -n "$name" ] || return 0
  want="${prefix}${name}"
  if [ "$want" != "$label" ]; then
    "$HERDR" tab rename "$tab" "$want" >/dev/null 2>&1 || return 0
  fi
  ar_state_set "$tab" "$name" true
}

# Coalesce bursts: only the lock holder works; contenders raise the rerun flag
# and exit, and the holder loops until no new work arrives (bounded). A fast pass
# escalates to a full reconcile the moment any rerun is seen -- a full reconcile
# is a superset of the single-tab rename, so a structural event that raced a
# preexec is still handled (and its lost rename recovered) inside this loop.
ar_run() {
  local want="${1:-full}"
  ar_lock || { : > "$RERUN_FLAG" 2>/dev/null || true; exit 0; }
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
  [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
  . "$AR_ROOT/naming.sh"

  # Feature toggles (default on). A config value of 0 wins because := only fills
  # an unset/empty var.
  : "${NAME_TABS:=1}"
  : "${AUTO_INDEX:=1}"

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
      ar_run full
      ;;
    clear|--clear)
      ar_run full                            # CLEAR=1 already set above
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
