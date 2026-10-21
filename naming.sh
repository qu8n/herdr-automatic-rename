# naming.sh - pure, herdr-free name computation for herdr-automatic-rename.
#
# Sourced by automatic-rename.sh. Every function is string-in / string-out (no herdr
# or filesystem calls) so the logic is unit-testable on its own (see
# tests/test_naming.sh). Targets bash 3.2 (macOS /bin/bash): no associative
# arrays, no namerefs. Functions share the ar_ prefix with the engine, which
# calls ar_label across the module seam.
#
# Two environment variables are read for DEFAULTS, both below: $SHELL names the
# shell a bare prompt is labeled with, and $HOME is the directory ar_context_dir
# treats as nowhere in particular. Neither is looked up per call.
#
# Naming rule: a tab is named after its foreground program (nvim, claude, git,
# ...). At a bare prompt, or while a quick throwaway command runs, it shows the
# shell name (e.g. zsh) instead -- or nothing at all with HIDE_SHELL=1. Loosely
# modeled on tmux-window-name, minus the directory-based naming.
#
# Every list below is guarded with `declare -p` rather than `${VAR+x}`, so
# clearing one in config.sh (e.g. IGNORED_PROGRAMS=()) actually takes effect:
# `${VAR+x}` reports a zero-element array as unset and would overwrite it.

# Icon knobs, the glyph map, and ar_icon live in icons.sh (same directory) so
# this file stays free of the 100+ entry glyph table. Sourcing it here keeps
# every caller of naming.sh (automatic-rename.sh and the test suite) working
# unchanged. icons.sh loads after config.sh has run, so its defaults only fill
# unset vars.
_ar_icons_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=icons.sh
. "$_ar_icons_dir/icons.sh"
unset _ar_icons_dir

# ---- configurable knobs (override in config.sh / $HERDR_AUTOMATIC_RENAME_CONFIG) ----
# The ACTIVITY half of a label -- the program, or an agent's task -- is cut to
# this. Each part of a label carries a budget of its own (MAX_CONTEXT_LEN and
# MAX_BRANCH_LEN are the others), so the whole is bounded by construction and
# there is no total to keep in step with the parts.
: "${MAX_NAME_LEN:=20}"     # truncate the program name to this many chars
: "${SHOW_PROGRAM_ARGS:=0}" # 1 = regular programs show their full command line; 0 = name only

# 1 = name a tab running a coding agent after the task the agent reports in its
# terminal title ("Squash merge command"), rather than after the agent program
# ("claude"). Coding agents keep that title current as the work changes, so this
# is what tells five claude tabs apart. herdr publishes it on the pane, so the
# name costs no extra call -- and where it lands the tab needs no process lookup
# at all. 0 names every agent tab after its program, as before.
#
# A title only replaces the program name when it says something: see
# ar_title_clean for what gets refused. Whenever it refuses, naming falls back to
# the program, PROGRAM_ALIASES included.
: "${AGENT_TITLES:=1}"

# What an agent tab shows once AGENT_TITLES has a task to show. "task" is the
# released answer: the task alone, the agent having been replaced by it.
# "name_and_task" keeps both, joined by a colon -- "claude:auth-flow", or through
# PROGRAM_ALIASES "cc:auth-flow".
#
# Which agent is on a task is not otherwise recoverable from the tab. The icon map
# gives every agent herdr detects the same robot glyph, deliberately so, and a
# title then replaces the one place the program name appeared. That is fine for a
# session of one agent and loses something in a session of three, where "cc:" and
# "oc:" are the difference between two tabs that otherwise read alike.
#
# The name is priced into MAX_TITLE_LEN with everything else, so it is the task
# that gives up the characters, not the tab that grows. Where a title is refused
# nothing is prefixed: the tab falls back to the program name, and "cc:cc" says
# nothing twice. Any other value reads as "task".
: "${TITLE_STYLE:=task}"

# The least task worth printing beside a name. The prefix is dropped rather than
# shown alone when the budget cannot seat both, so this is what "both" means: a
# name, its colon, and this many characters of the task. Seven is about a short
# word and a hyphen; below that the tab says who far more loudly than what.
: "${MIN_TASK_LEN:=7}"

# Truncate a title to this many characters, at a word boundary where one is close
# enough. Titles are sentences, not command names, so they get more room than a
# command name -- but derived from MAX_NAME_LEN, so narrowing that for a narrow
# tab bar narrows titles with it instead of leaving them at a fixed 28.
: "${MAX_TITLE_LEN:=$(( ${MAX_NAME_LEN:-20} + 8 ))}"

# Field separator for the rows this module reads, matching AR_ROW_SEP in
# automatic-rename.sh, which sets it before sourcing this file (the fallback here
# is what lets the module and its tests stand alone). A tab or a newline would not
# do: bash counts both as IFS whitespace and `read` collapses them, losing an
# empty field. Change one and change the other.
: "${AR_ROW_SEP:=$'\037'}"

# ---- the context half of a label (TAB_CONTEXT) ----

# 1 = put the context in front of the program: the directory the pane sits in,
# the branch it has checked out, the machine it reached over ssh. A tab says WHAT
# is running; without this half, five agent tabs across three checkouts read alike
# and tell each other apart by position only. 0 names by the program alone, as
# before.
#
# The switch is read inside ar_context_dir rather than at each call site, because
# the reconcile and the shell hook both compute labels and a label they disagree
# about is a tab that flips on every prompt.
: "${TAB_CONTEXT:=1}"

# Truncate the directory part to this many characters. It is a project name, not
# a sentence, and the program beside it still needs the room MAX_NAME_LEN gives
# it -- so it gets a budget of its own rather than eating that one.
: "${MAX_CONTEXT_LEN:=12}"

# 1 = qualify the context with the branch the pane's repository has checked out:
# "api > MC-13675 > nvim". It says which slice of a project a tab is on, where
# the directory alone says only which project. 0 leaves branches out, and so
# does MAX_BRANCH_LEN=0.
: "${SHOW_BRANCH:=1}"

# The branches treated as a trunk when the repository records no default of its
# own -- one cloned without an origin/HEAD, or one that was never cloned. A
# repository that DOES record one is believed over this list, so a team whose
# trunk is "release" is not second-guessed. Assigning the array replaces the
# default; TRUNK_BRANCHES=() shows every branch in such a repository.
declare -p TRUNK_BRANCHES >/dev/null 2>&1 || TRUNK_BRANCHES=(main master develop trunk)

# Longest branch a label may carry, in characters. Twelve holds an issue key, or
# a word and part of the next. A branch over it is reduced rather than dropped:
# see ar_branch_label.
: "${MAX_BRANCH_LEN:=12}"

# What joins the parts of a label. Where a part came from -- a directory, a
# branch, a program -- is not something a separator can convey, so every part
# shares one. Written as its UTF-8 bytes for the reason icons.sh writes its
# glyphs that way: a literal one is what an editor or a copy-paste eats without
# saying so. This is U+203A, a single right-pointing angle quote.
: "${CONTEXT_SEP:=$' \342\200\272 '}"

# Name shown at a bare prompt (no foreground program), and while an
# IGNORED_PROGRAMS command runs, so the tab holds steady instead of flickering.
: "${SHELL_NAME:=${SHELL##*/}}"
: "${SHELL_NAME:=zsh}"

# 1 = give the tab no name at all in every case that would otherwise show the
# shell: a bare prompt, an explicit SHELLS entry, an IGNORED_PROGRAMS command.
# The empty label hands the tab back to herdr, which then renders its own tab
# number, so a shell tab reads "3" instead of "zsh" (issue #5). With AUTO_INDEX=1
# the label keeps the jump number and nothing else ("[3]"), so the tab can still
# be jumped to.
: "${HIDE_SHELL:=0}"

# Foreground processes that mean "a shell prompt" -> shown by their own name.
declare -p SHELLS >/dev/null 2>&1 || SHELLS=(zsh bash sh fish dash ksh)

# Programs shown by bare name, without command-line args (i.e. with
# SHOW_PROGRAM_ARGS=1, which is what makes this list visible). Coding agents are
# included so an agent tab reads as "claude" rather than its full invocation.
#
# The agent entries are the executable names herdr itself detects as interactive
# agents (src/detect/mod.rs, herdr 0.9.2). Four differ from herdr's --kind id
# and every spelling is listed: cursor-agent (kind "cursor"), kiro-cli (kind
# "kiro"), letta-code (kind "letta"), and muse-cli / muse-code (kind "muse",
# whose fourth spelling is the versioned binary ar_format folds -- see there).
# aider is not a herdr agent kind but is a real agent, so it stays.
declare -p NAME_ONLY_PROGRAMS >/dev/null 2>&1 || NAME_ONLY_PROGRAMS=(nvim vim vi view gvim git lazygit gitui lazydocker
  claude codex aider pi gemini cursor cursor-agent devin agy antigravity cline omp mastracode opencode
  copilot kimi kiro kiro-cli droid amp grok hermes kilo qodercli qwen maki letta letta-code muse muse-cli muse-code)

# Quick tools that should not take over the tab name: while one runs the tab
# keeps showing the shell (SHELL_NAME) so it does not flicker.
declare -p IGNORED_PROGRAMS >/dev/null 2>&1 || IGNORED_PROGRAMS=(ls eza ll la cd z zoxide cat bat less more echo pwd clear which man head tail wc cp mv rm mkdir touch fzf sudo doas)

# Language runtimes and package runners that front for the program you actually
# launched. An agent installed from npm is usually a bin shim pointing at a JS
# entrypoint: the kernel execs the interpreter, so the foreground process is
# node and the tab would be named after it. A pip or pipx console script is the
# same story for python. (An agent whose package ships or execs a native binary
# -- claude, opencode -- reports its own name and never needs this.)
#
# Where herdr has detected an agent in that pane, its answer is used instead (see
# ar_tab_name). Everywhere else these are named as any other program, so a plain
# `node server.js` tab is untouched.
declare -p WRAPPER_PROGRAMS >/dev/null 2>&1 || WRAPPER_PROGRAMS=(node bun deno npx bunx npm pnpm yarn
  python python3 uv uvx pipx ruby)

# Ordered, complete `sed -E` programs applied to the final display string.
declare -p SUBSTITUTE_SETS >/dev/null 2>&1 || SUBSTITUTE_SETS=(
  's|.*ipython([32])|ipython\1|'
  's|.*poetry shell.*|poetry|'
)

# The same, for the directory-derived label a WORKSPACE carries. Empty by
# default: a workspace shows the name of the directory it sits in, and a rule
# here is somebody asking for a shorter spelling of it.
#
# Not a naming knob, despite the company it keeps -- it applies whether or not
# tabs are named. It lives in this file because it is string-in / string-out
# like everything else here, and because config.sh has to get first refusal on
# the default (see the `declare -p` note at the top).
declare -p WORKSPACE_SUBSTITUTE_SETS >/dev/null 2>&1 || WORKSPACE_SUBSTITUTE_SETS=()

# Titles that name the agent instead of the work it is doing. An agent sets one
# of these before it has a task (at startup, or once a session is cleared), and a
# tab reading "Claude Code" says less than "claude" does. Matched case-insensitively
# against the whole title. The agent kind itself, that kind followed by "code", the
# directory the pane sits in, and a bare number are refused without being listed.
declare -p TITLE_IGNORE >/dev/null 2>&1 || TITLE_IGNORE=("claude code" "codex cli" "gemini cli"
  "opencode" "amp code" "cursor agent" "new session" "untitled")

# Agents that stamp their own brand on the FRONT of every title, as
# "<herdr agent kind>=<brand>" pairs. oh-my-pi titles a session
# "<brand> <spinner> Fix the parser" while it works, "<brand> > ..." when the turn
# is yours, "<brand> ! ..." when it wants you, and "<brand>: ..." with its title
# state off, so its brand arrives in front of the status glyph rather than behind
# it. The spinner strip only takes a LEADING run of non-alphanumerics and jq reads
# the brand as a letter, so the strip stopped on it and each of those states
# reached the tab as a different label: the glyph on show, and a rename on every
# status change (issue #12). Naming the brand takes it off and leaves the separator
# to the strip that was already there -- so a title of nothing but brand and glyph
# empties out and the tab falls back to the program name, which is the answer an
# agent with no task wants.
#
# Only at the very front, and only with a non-alphanumeric behind it, so a title
# that merely starts with the same letter keeps it. Matched ignoring the case of
# ASCII letters, like every other title compare. The brand is written as its bytes
# for the reason icons.sh writes its glyphs that way: a literal one is what an
# editor eats without saying so. "pi" and "omp" are both canonical herdr agent
# kinds (src/detect/mod.rs, herdr 0.8.2) and both are the same program's brand.
#
# opencode brands the same way with letters rather than a glyph, "OC | Reviewing
# unpushed commits", and an "opencode=OC" entry does strip it. It is deliberately
# NOT in the default here. debrand takes a brand off wherever a non-alphanumeric
# or the end of the string follows it, matching ASCII case-insensitively, which is
# wider than a badge before a pipe: it also takes "OC" off "OC-192 incident" and
# "oc" off "oc | access policy". That is a judgement about opencode titles for
# this project to make, and making it here would change what a tab reads for
# somebody who never turned condensing on.
declare -p TITLE_BRANDS >/dev/null 2>&1 || TITLE_BRANDS=("pi="$'\317\200' "omp="$'\317\200')

# 1 = condense a title into its keywords before it becomes a label, instead of
# showing the agent's sentence with the tail cut off. A title arrives as prose
# ("Adjust the screensaver timeout") and MAX_TITLE_LEN takes the end off it, so
# the words that say WHICH task this is are the first to go. Condensing drops a
# leading verb and the filler and joins what is left, which fits the same budget
# while keeping the nouns: "screensaver-timeout".
#
# Off by default, so a config that does not name it gets the title exactly as
# AGENT_TITLES has always rendered it. That is also what keeps this a bolt-on:
# every released test asserts the sentence, and a default of 1 would rewrite
# their expectations rather than add to them.
: "${TITLE_CONDENSE:=0}"

# Verbs an agent opens a title with. Every tab reading "Fix ..." or "Add ..."
# spends its first word saying what the tab beside it also says, so a LEADING one
# is dropped. Leading only, so "the auth rewrite needs review" keeps its "review".
#
# Measured rather than imagined. The corpus is the LAST title Claude Code
# generated in each of the 65 titled sessions on one machine over three weeks,
# which is the title the engine itself reads (transcript.sh takes last(inputs)).
# Measuring the first title instead gives 36 and 31, one session having been
# retitled while it ran; the numbers below are the selection that ships.
#
# The other 1735 transcripts there are subagent runs and headless "sdk-cli"
# invocations, neither of which Claude Code titles at all. Those are unlikely to
# be sitting in a tab somebody is reading, though nothing stops one being launched
# in a terminal, so read this as "titled sessions" rather than "every tab".
#
# THIS list fires on 35 of the 65, and 30 of those get a content word back inside
# the same budget. No two DIFFERENT titles among the 65 condense to the same
# label with the list on or off, so the drop buys information without costing
# distinctness. (Two of the 65 are the same title from two sessions, and those
# do condense alike, which is the corpus repeating itself rather than the rule
# losing anything.) "analyze" was
# the most frequent opener the first hand-written list had missed, seven of the
# 65; "troubleshoot", "optimize" and "show" one each.
#
# "port" was taken OUT on judgement, not on evidence: the word appears nowhere in
# these 65, so this corpus says nothing either way. It reads as a noun far more
# often than a verb in the work these titles describe.
#
# One population is NOT measured here. Where an agent never titled its session,
# the engine condenses the first prompt the user typed instead, and those are
# phrased differently from a title an agent wrote. On this machine that group is
# all headless automation, so it could not be sampled.
#
# The list matches spelling, not part of speech, so a title whose subject shares
# a verb's spelling loses it. The failure that matters is two tabs colliding:
# "Review flashcard generation" and "Implement flashcard generation" both reduce
# to "flashcard-generation". It did not happen across those 65, but the corpus is
# one person and one agent, which is the argument for a knob rather than a
# constant. TITLE_LEAD_VERBS=() turns the rule off.
declare -p TITLE_LEAD_VERBS >/dev/null 2>&1 || TITLE_LEAD_VERBS=(review adjust add fix update
  create make check investigate debug refactor implement write set setup configure explore
  improve build test run clean remove delete migrate rename draft plan research diagnose audit
  analyze troubleshoot optimize show)

# Words dropped wherever they appear. A tab label is not a sentence, so articles,
# prepositions and phrasal-verb particles only spend the budget.
declare -p TITLE_FILLER_WORDS >/dev/null 2>&1 || TITLE_FILLER_WORDS=(a an the to for of on in at
  and or with from into via why how what that if whether is are be it its this up out off down over back)

# What joins the surviving words. The default fuses the label into one token, the
# shape every other tab name has; " " reads as the phrase instead. Its length is
# charged to MAX_TITLE_LEN like any other character.
: "${TITLE_WORD_SEPARATOR:=-}"

# Casing. "fold" downcases every word except an all-caps-and-digits identifier: a
# sentence-case capital is the agent writing a sentence rather than signal, while
# the shape of "ETL" carries meaning. "lower" folds the identifiers too, and
# "keep" leaves the agent's casing alone.
: "${TITLE_CASE:=fold}"

# Exact program-name renames: "<program>=<label>" pairs. A matching foreground
# program is shown as <label> regardless of its category (e.g. "clx=hn" makes a
# clx tab read "hn"). Takes priority over every rule except the bare-prompt shell
# name. Set this in config.sh, e.g. PROGRAM_ALIASES=("clx=hn" "lazygit=lg").
#
# An agent known by two names (cursor-agent, kind "cursor") answers to either of
# them, since which one reaches naming says only how it was installed. See
# ar_other_spelling.
declare -p PROGRAM_ALIASES >/dev/null 2>&1 || PROGRAM_ALIASES=()

# ---- helpers ----

# ar_in_list <needle> <list items...>
ar_in_list() {
  local n=$1 e
  shift
  for e in "$@"; do [ "$e" = "$n" ] && return 0; done
  return 1
}

# ar_other_spelling <name> -> the same agent's other spelling, or empty.
#
# Two agents are known by two names: the executable (cursor-agent, kiro-cli) and
# herdr's --kind id (cursor, kiro). Which of the two reaches naming is an
# installation detail -- a natively installed agent arrives as its executable,
# an npm-fronted one as the kind the WRAPPER_PROGRAMS unwrap substitutes -- so a
# lookup keyed by name has to answer for both. NAME_ONLY_PROGRAMS already lists
# both spellings of every such agent, so the pair is read off that list rather
# than out of a second table that would have to be kept in step with it: strip
# the suffix, or add it, and take the answer only when the list carries it too.
#
# BOTH spellings have to be listed, which is what makes them one agent under two
# names. The suffix alone is not a pairing: git is on the list, so a name derived
# by stripping "-cli" would hand an unrelated git-cli whatever alias git carries.
ar_other_spelling() {
  local n=$1 alt suffix
  ar_in_list "$n" "${NAME_ONLY_PROGRAMS[@]}" || return 0
  for suffix in -agent -cli; do
    case "$n" in
    *"$suffix") alt=${n%"$suffix"} ;;
    *) alt="$n$suffix" ;;
    esac
    if ar_in_list "$alt" "${NAME_ONLY_PROGRAMS[@]}"; then
      printf '%s' "$alt"
      return 0
    fi
  done
}

# ar_alias <program> -> its PROGRAM_ALIASES label, or empty when unaliased.
#
# An agent is matched under either of its spellings (see ar_other_spelling), so
# one entry covers it however it was installed. The exact name is tried first,
# so a config naming both spellings separately still gets each one.
ar_alias() {
  local n=$1 pair alt=""
  [ -n "$n" ] || return 0
  [ ${#PROGRAM_ALIASES[@]} -gt 0 ] || return 0
  for pair in "${PROGRAM_ALIASES[@]}"; do
    case "$pair" in
    "$n="*)
      printf '%s' "${pair#*=}"
      return 0
      ;;
    esac
  done
  alt=$(ar_other_spelling "$n")
  [ -n "$alt" ] || return 0
  for pair in "${PROGRAM_ALIASES[@]}"; do
    case "$pair" in
    "$alt="*)
      printf '%s' "${pair#*=}"
      return 0
      ;;
    esac
  done
}

# ar_subst <string> -> string with SUBSTITUTE_SETS applied in order
ar_subst() {
  local s=$1 expr
  for expr in "${SUBSTITUTE_SETS[@]}"; do
    s=$(printf '%s' "$s" | sed -E "$expr")
  done
  printf '%s' "$s"
}

# ar_ws_subst <string> -> string with WORKSPACE_SUBSTITUTE_SETS applied in order.
# The empty rule list is the common case and forks nothing.
ar_ws_subst() {
  local s=$1 expr
  for expr in "${WORKSPACE_SUBSTITUTE_SETS[@]}"; do
    s=$(printf '%s' "$s" | sed -E "$expr")
  done
  printf '%s' "$s"
}

# ar_trunc <string> <max> -> the string cut to <max> Unicode codepoints.
#
# Not bytes: bash's ${#s} and ${s:0:$max} count those under a C/POSIX locale
# (herdr may launch plugins with no LC_*), which slices a multibyte character in
# half and emits mojibake. jq (already a hard dependency) always reads its input
# as UTF-8, so it slices on codepoint boundaries whatever the ambient locale is;
# the byte cut is the fallback for a jq that is somehow unavailable. The length
# test is a byte count on purpose -- a string of fewer bytes than max is also of
# fewer codepoints, so the fork is skipped for every label that does not need it.
ar_trunc() {
  local s=$1 max=$2 cut
  [ "${#s}" -gt "$max" ] || { printf '%s' "$s"; return 0; }
  cut=$(printf '%s' "$s" | jq -Rrs --argjson n "$max" '.[:$n]' 2>/dev/null || printf '')
  [ -n "$cut" ] || cut=${s:0:$max}
  printf '%s' "$cut"
}

# ar_fits <string> <max> -> 0 when the string is at most <max> codepoints wide.
#
# The same byte test ar_trunc opens with, and it holds in only one direction: a
# string of no more bytes than max is of no more codepoints either, so passing is
# proof it fits and costs nothing. FAILING is not proof of the opposite, because
# under a C locale a multibyte string counts several bytes per character, and
# that is the half two callers below used to take as a decision.
#
# Only a string that fails the cheap test AND carries a byte outside ASCII pays
# for jq, which is a label at its budget in a language that needs one. A jq that
# cannot run answers "does not fit", which is what both callers did before this
# existed.
#
# The one-way property holds where bash counts bytes, which is C and POSIX, and
# where it counts characters of valid UTF-8. A legacy multibyte locale that is not
# UTF-8 is outside it: bytes there may count as one shell character and more than
# one jq codepoint, so the cheap accept could pass something jq would refuse. The
# plugin is not tested in one. Bytes that are not valid UTF-8 have no codepoint
# length at all; jq decodes them to replacements, so a name made of them may now
# reach a tab as its own bytes where it once reached it as U+FFFD.
ar_fits() {
  local n
  [ "${#1}" -le "$2" ] && return 0
  # Where every byte is ASCII the two counts are the same number, so the test
  # above was exact in both directions and the answer is already known. That is
  # nearly every label and every branch, and it keeps them at no process at all:
  # only a value carrying a byte above 0x7F, and only one at its budget, asks jq.
  case $1 in
  *[!$'\01'-$'\177']*) : ;;
  *) return 1 ;;
  esac
  n=$(printf '%s' "$1" | jq -Rrs 'length' 2>/dev/null) || return 1
  [ -n "$n" ] && [ "$n" -le "$2" ]
}

# ar_icon_reserve <program> -> the text ar_format prepends for this program's
# icon, or "". The literal text rather than an allowance for it: ICON_MAP takes
# any string, so a flat two is right for one glyph and wrong for everything
# else, and a caller pricing a budget needs what will actually be spent.
#
# ICON_STYLE=icon draws the glyph INSTEAD of the label, so nothing a title
# caller decides reaches the tab and there is nothing to reserve; "name" draws
# no glyph at all. Only the default pays.
ar_icon_reserve() {
  [ "${ICONS_ENABLED:-0}" = "1" ] || return 0
  case "${ICON_STYLE:-name_and_icon}" in
  icon | name) return 0 ;;
  esac
  local ic
  ic=$(ar_icon "$1")
  [ -n "$ic" ] && printf '%s ' "$ic"
}

# ar_title_name_prefix <program> <budget> -> "<name>:", the prefix ar_format
# puts in front of a task under TITLE_STYLE=name_and_task, or "" where it will
# not. One answer, read by both the formatter that prepends it and the condenser
# that has to price it, because two derivations of the same decision are free to
# drift and only one of them would be under test.
#
# Here an alias IS wanted, which is the difference from the plain-title rule:
# asking for the name is asking for the name you chose for it.
#
# The prefix is all or nothing. Truncation treats a label as prose, so a name
# that does not leave room for a task would be kept INSTEAD of one: at a budget
# of twelve "cursor-agent" filled the tab on its own. That renders name_and_task
# as name only, which is the one thing it must not do, so the task keeps what it
# needs and the name goes when it cannot be afforded -- this asks for the task
# with the name added, not the other way about.
#
# A name carrying a space is refused whatever the budget. The word-boundary trim
# cuts at the LAST space in the whole label, which for a multiword name is
# inside the name: an alias of "SuperLongAgent Extra" rendered "SuperLongAgent"
# alone, the task gone and the name itself clipped. A single-word name cannot be
# reached that way, the colon joining it to the task with no space to cut at.
#
# An alias of nothing but spaces or control characters is scrubbed to nothing
# and refused, rather than leaving a bare colon in front of the task.
#
# The glyph is charged here too, being prepended out of this same budget after
# this decision. Over-reserving is the safe direction: it only ever refuses the
# prefix and hands the task the room back.
#
# Asked of ar_fits, which answers in codepoints and answers without a process
# wherever the value is ASCII.
ar_title_name_prefix() {
  [ "${TITLE_STYLE:-task}" = "name_and_task" ] && [ -n "$1" ] || return 0
  local aliased pad
  aliased=$(ar_alias "$1")
  aliased=${aliased:-$1}
  case $aliased in
  *[[:cntrl:]]* | *" "*) aliased=$(printf '%s' "$aliased" | tr -s '[:cntrl:] ' ' ')
                         aliased=${aliased# }; aliased=${aliased% } ;;
  esac
  case $aliased in
  "" | *" "*) return 0 ;;
  esac
  printf -v pad '%*s' "${MIN_TASK_LEN:-7}" ""
  ar_fits "$(ar_icon_reserve "$1")$aliased:$pad" "$2" || return 0
  printf '%s:' "$aliased"
}

# ar_context_dir <pane directory> <workspace base label> -> the directory part of
# the context, or "" when the directory says nothing worth a tab's width.
#
# The BASENAME, not ar_project_base's answer: that walks up to the repository a
# directory belongs to, which is what herdr names a WORKSPACE after and therefore
# the one thing a tab in it must not repeat. A tab cd'd into a subdirectory of
# its project says which subdirectory, where the repository name would say what
# the sidebar says.
#
# Normally the project name, then. Refused: a relative path (whatever
# the reader's cwd makes of it -- herdr reports absolute ones), the filesystem
# root, and the home directory, which is where a shell sits when it is nowhere in
# particular.
#
# Also refused: the name of the workspace the tab is in. herdr shows that above
# the tabs, so a tab there spends half its width repeating what is already on
# screen. Matched ignoring the case of ASCII letters and which separator a name
# was built out of (_AR_FOLD_IN), and exactly otherwise -- a tab whose directory
# has left its workspace behind is exactly the one that keeps saying where it is.
ar_context_dir() {
  local dir=$1 ws=$2 base
  AR_CONTEXT=""
  [ "${TAB_CONTEXT:-1}" = "1" ] || return 0
  case $dir in /*) ;; *) return 0 ;; esac
  dir=${dir%/}                        # a trailing slash names the same directory
  [ -n "$dir" ] || return 0           # ... and "/" is left with nothing
  [ "$dir" = "${HOME%/}" ] && return 0
  base=${dir##*/}
  [ -n "$base" ] || return 0
  if [ -n "$ws" ]; then
    # Folded here rather than by the shell's own case-insensitive compare, which
    # follows the locale: herdr may launch the plugin with no LC_* at all while
    # the shell hook inherits the user's UTF-8, and then the two naming paths
    # would disagree about whether a directory repeats its workspace -- which is
    # a tab that flips on every prompt. ASCII, deterministically, in both.
    local folded
    # The exact match is the common one and settles it without folding anything,
    # which matters because the fold walks a string a character at a time on a
    # path that runs per tab and again per prompt.
    [ "$base" = "$ws" ] && return 0
    ar_case "$base" "$_AR_FOLD_IN" "$_AR_FOLD_OUT"
    folded=$AR_CASE
    ar_case "$ws" "$_AR_FOLD_IN" "$_AR_FOLD_OUT"
    [ "$folded" = "$AR_CASE" ] && return 0
    # herdr names a worktree workspace after the branch with the convention in
    # front of it stripped, so the directory ends with the workspace's name and
    # the two are the same place. The separator is required, or a workspace
    # called "api" would swallow a tab that really is in "legacy-api" -- and
    # folding the separators does not weaken that: what stands between the
    # convention and the name must still BE one, whichever of them was written.
    case $folded in *-"$AR_CASE") return 0 ;; esac
  fi
  AR_CONTEXT=$(ar_shorten "$base" "${MAX_CONTEXT_LEN:-12}")
  printf '%s' "$AR_CONTEXT"
}

# The characters branch names are built out of. Cutting a long one at any of
# them ends it on a whole word.
_AR_BRANCH_SEPS='-_./ '

# The alphabet, for ar_upper. Two strings and an index rather than `tr`, because
# what this raises is an issue key on a path that runs per named tab on every
# event and again on every shell prompt, and `tr` is a process.
_AR_LOWER='abcdefghijklmnopqrstuvwxyz'
_AR_UPPER='ABCDEFGHIJKLMNOPQRSTUVWXYZ'

# The alphabet the two "is this already on screen?" compares fold through: ASCII
# case AND the separators a name is built out of, in one ar_case pass.
#
# The separators go in because one name reaches this file in two spellings.
# herdr's worktree manager labels a workspace after the BRANCH, slashes and all
# (feature/proj-482-fix), while the worktree directory the branch is checked out
# in gets those slashes flattened to hyphens (feature-proj-482-fix) -- a branch
# cannot carry a path separator into a directory name. Compared character for
# character the two disagree, and the tab then put the directory back in its
# label beside the workspace already saying it: "PROJ-482 > claude" under a
# "feature/proj-482-fix" workspace, which is the name twice.
#
# Which way they fold does not matter, only that both sides fold the same, so
# they all become the hyphen, the separator nearly every name is written with.
#
# Folded in the alphabet rather than in a pass of its own because these compares
# run per named tab on every herdr event and again on every shell prompt, and
# ar_case walks a string one character at a time. One walk did the case, and one
# walk now does the case and the separators both, so the fix costs nothing.
#
# Written out rather than built, because ar_case reads the two as one mapping and
# they are only a mapping while they are the same length: a separator added to
# the first needs a hyphen added to the second.
_AR_FOLD_IN="$_AR_UPPER-_./"
_AR_FOLD_OUT="$_AR_LOWER----"

# An issue key: two to six letters and at least two digits, on its own rather
# than inside a longer word. The bounds are what keep it clear of hyphenated
# words ("utf-8" has too few digits, "release-2026" too many letters). Held in a
# variable because bash 3.2 matches an unquoted one as a pattern and a quoted one
# as a literal.
_AR_BRANCH_KEY='(^|[^[:alnum:]])([[:alpha:]]{2,6}-[[:digit:]]{2,6})([^[:digit:]]|$)'

# ar_upper <string> -> the string with its ASCII lowercase letters raised, and
# every other character left exactly as it is. Folding ASCII alone is deliberate,
# as everywhere else in this file: what this raises is a tracker's own alphabet,
# not the user's prose.
ar_upper() {
  ar_case "$1" "$_AR_LOWER" "$_AR_UPPER"
  printf '%s' "$AR_CASE"
}

# ar_case <string> <alphabet in> <alphabet out> -> sets AR_CASE to the string
# with every letter of the first alphabet swapped for the one at its position in
# the second, and everything else left exactly as it is.
#
# The answer comes back in a global because both callers are on the path that
# runs per named tab on every event and again on every shell prompt, and a
# command substitution is a fork. It is also why this is not `tr`.
ar_case() {
  local s=$1 in=$2 out=$3 acc="" c rest
  AR_CASE=""
  while [ -n "$s" ]; do
    c=${s%"${s#?}"}                     # the first character, however wide
    s=${s#?}
    # A letter cuts the alphabet in two, and where it sits is how much is left.
    # A character that is not one leaves the alphabet whole, which is the test.
    rest=${in#*"$c"}
    [ "$rest" != "$in" ] && c=${out:$(( ${#in} - ${#rest} - 1 )):1}
    acc=$acc$c
  done
  AR_CASE=$acc
}

# ar_branch_wanted -> 0 when a branch would be shown at all. Its own function
# because the engine asks BEFORE reading a repository: the answer is no reads at
# all rather than reads whose answer is thrown away.
ar_branch_wanted() {
  [ "${TAB_CONTEXT:-1}" = "1" ] || return 1
  [ "${SHOW_BRANCH:-1}" = "1" ] || return 1
  [ "${MAX_BRANCH_LEN:-12}" -gt 0 ] 2>/dev/null || return 1
}

# ar_branch_label <branch or short hash> <the repository's default branch>
#   -> what the branch contributes to a label, or "" when it contributes nothing.
#
# Three rules keep it from saying anything it has not earned:
#
#   The trunk contributes nothing. Every tab in the repository would carry it
#   alike, so it is a column of noise. The comparison is exact, because git refs
#   are: a branch named `Main` beside a `main` trunk is a different branch.
#
#   A name that fits is left whole. `feat/oauth` keeps the namespace that tells
#   it from `fix/oauth`; only a name too wide is touched at all.
#
#   Reducing one prefers an issue key outright, because that identifies the work
#   whatever convention wraps it, and it is the one value allowed past the
#   budget: half a key identifies nothing. Failing a key the namespace goes --
#   it is the half every branch in the repository shares -- and what is left is
#   cut at a whole word.
ar_branch_label() {
  local branch=$1 default=$2 max=${MAX_BRANCH_LEN:-12} cut next
  # Asked again here, though the engine asks before it reads a repository: this
  # is the rule, and a rule that is only enforced by its caller is one a second
  # caller can miss.
  ar_branch_wanted || return 0
  [ -n "$branch" ] || return 0
  if [ -n "$default" ]; then
    [ "$branch" = "$default" ] && return 0
  else
    ar_in_list "$branch" "${TRUNK_BRANCHES[@]}" && return 0
  fi
  ar_shorten "$branch" "$max"
}

# ar_shorten <value> <max> -> the value reduced to what is worth <max> columns.
#
# An issue key wins outright, because it identifies the work whatever convention
# wraps it, and it is the one value allowed past the budget: half a key
# identifies nothing. Failing a key the namespace goes -- it is the half every
# branch in a repository shares -- and what is left is cut at a whole word.
#
# Branches and worktree directories are named the same way by the same people
# ("bugfix-proj-482-fix-rev-discrepancy" is both), so both are reduced here rather
# than one being cut through the middle.
ar_shorten() {
  local branch=$1 max=$2 cut next
  ar_fits "$branch" "$max" && { printf '%s' "$branch"; return 0; }
  if [[ $branch =~ $_AR_BRANCH_KEY ]]; then
    ar_upper "${BASH_REMATCH[2]}"
    return 0
  fi
  branch=${branch##*/}
  # Deciding to shorten is one thing and cutting is another: bash indexes by BYTE
  # under a C locale, so a name carrying anything outside ASCII was sliced at the
  # wrong offset and cut back to an earlier separator than it needed. Plain ASCII,
  # which is nearly every branch, is indexed exactly right by bash and pays no
  # process; only a name with a byte above 0x7F asks jq. $next is then read at the
  # width of the head, which is bytes under C and characters elsewhere, and is the
  # right offset in either.
  case $branch in
  *[!$'\01'-$'\177']*) cut=$(ar_trunc "$branch" "$max") ;;
  *) cut=${branch:0:$max} ;;
  esac
  next=${branch:${#cut}:1}
  # When the character that did not fit is itself a separator the head already
  # ends on a whole word, and cutting again would throw one away.
  case $next in
  ["$_AR_BRANCH_SEPS"]) ;;
  *)
    case $cut in
    # Cutting back to a separator is also what makes the slice above safe: a
    # separator is ASCII, so a cut at one lands on a character boundary whatever
    # the locale made of the slice. Only a first word too long to fit has no
    # separator to fall back to, and that alone pays for ar_trunc's jq.
    *["$_AR_BRANCH_SEPS"]*) cut=${cut%["$_AR_BRANCH_SEPS"]*} ;;
    *) cut=$(ar_trunc "$branch" "$max") ;;
    esac
    ;;
  esac
  # A separator on either end says nothing on its own.
  cut=${cut#["$_AR_BRANCH_SEPS"]}
  cut=${cut%["$_AR_BRANCH_SEPS"]}
  printf '%s' "$cut"
}

# ar_compose <context> <branch> <activity> -> the tab's base label.
#
# Read as a path from the general to the particular -- where the work is, then
# what is being done -- with CONTEXT_SEP between every pair. Each part arrives
# already cut to its own budget, so the whole is bounded by construction and
# there is no second number to keep in step.
#
# An empty activity is HIDE_SHELL asking for no label at all, and half a label is
# not what it asked for: the tab is handed back to herdr whole.
ar_compose() {
  local ctx=$1 branch=$2 activity=$3 out=""
  [ -n "$activity" ] || return 0
  [ -n "$ctx" ] && out=$ctx
  [ -n "$branch" ] && { [ -n "$out" ] && out="$out$CONTEXT_SEP$branch" || out=$branch; }
  [ -n "$out" ] && out="$out$CONTEXT_SEP$activity" || out=$activity
  # Scrub what only this half of a label can carry in. The reconcile's directory
  # arrives through jq's `clean` and the activity is scrubbed by ar_format, but
  # the shell hook takes its directory from a raw $PWD -- and a directory may be
  # named anything a filesystem accepts. A control character reaching the tab bar
  # is the visible half of it; the invisible half is that herdr hands the label
  # back normalized, which reads as a name somebody typed and opts the tab out of
  # naming for good. Guarded, so a clean label pays no fork (the common case).
  case $out in
  *[[:cntrl:]]* | *"  "*) out=$(printf '%s' "$out" | tr -s '[:cntrl:] ' ' ')
                          out=${out# }; out=${out% } ;;
  esac
  printf '%s' "$out"
}

# ar_title_clean <title> <title lowercased> <pane directory lowercased> <agent kind>
#   -> the task the title describes, or "" when it describes no task and the
#      program name is the better label.
#
# The title arrives with its leading run of non-alphanumerics already gone, and
# a trailing non-ASCII one that stands apart as its own word: an agent parks a
# spinner glyph at one end while it works, and herdr reports the title with the
# glyph still on, so a tab would flip between "Task" and "<glyph> Task"
# on every status change. That strip and the lowercasing happen in the jq that
# lifts the title off the pane (see AR_JQ_CLEAN), because jq knows Unicode where a
# byte-wise strip in bash would eat the first letter of "Überprüfung" and a
# byte-wise fold would not touch it. Everything left here is a comparison, so this
# function costs nothing.
ar_title_clean() {
  local t=$1 lower=$2 dirlc=$3 kind=$4
  [ -n "$t" ] || return 0
  # A bare number is herdr's own tab label handed back, not a task.
  case $t in *[!0-9]*) : ;; *) return 0 ;; esac
  # Everything that names the agent instead of its work: the kind on its own, the
  # kind with "code" after it, the directory the pane sits in, and the titles an
  # agent shows before there is a task. $dirlc may be empty and $lower never is,
  # so an unknown directory refuses nothing.
  ar_title_ignore_fold
  ar_in_list "$lower" "$kind" "$kind code" "$dirlc" "${_ar_title_ignore_lc[@]}" && return 0
  # A title that is a PATH is the same "nothing to say yet" answer in a longer
  # coat: an agent titling itself `~/dev/api` or `/home/u/dev/api` is naming where
  # it sits, not what it is doing. The list above catches the bare directory name;
  # this catches the path that ends in it.
  #
  # Only for a title with no whitespace in it, though, or a real description would
  # go the same way: "Fix build for services/payments" in a directory called
  # payments ends in exactly that word. A path has no spaces; a sentence about the
  # work almost always does. The leading dot is dropped from the directory too,
  # because a title of "~/.config" has already lost its own to the strip above.
  #
  # The trailing slash comes off before the tail is taken: `~/dev/api/` names the
  # same directory `~/dev/api` does, and ${lower##*/} on a string that ends in one
  # is EMPTY, which matches no directory and walked the whole path through.
  case $lower in
  *[[:space:]]*) : ;;
  *) local tail=${lower%/}; tail=${tail##*/}
     [ -n "$dirlc" ] && { [ "$tail" = "$dirlc" ] || [ "$tail" = "${dirlc#.}" ]; } && return 0 ;;
  esac
  printf '%s' "$t"
}

# ar_title_ignore_fold - lowercase TITLE_IGNORE once per run, into
# $_ar_title_ignore_lc. The comparison above is against a lowercased title, and a
# user writing "New Session" should not silently get nothing, so the list is
# folded rather than documented as case-sensitive. Folded on first use, not at
# load: the shell hooks source this file on every prompt and never name a tab
# after a title.
ar_title_ignore_fold() {
  [ -n "${_ar_title_ignore_done:-}" ] && return 0
  _ar_title_ignore_done=1
  _ar_title_ignore_lc=()
  [ "${#TITLE_IGNORE[@]}" -gt 0 ] || return 0
  local entry
  # Folding ASCII only is deliberate: the comparisons this feeds are product and
  # directory names, and the Unicode-aware fold happens in jq (see AR_JQ_CLEAN).
  # ar_case rather than `tr`, so this file has one case-fold and not two.
  for entry in "${TITLE_IGNORE[@]}"; do
    [ -n "$entry" ] || continue
    ar_case "$entry" "$_AR_UPPER" "$_AR_LOWER"
    _ar_title_ignore_lc+=("$AR_CASE")
  done
}


# ar_condense_title <title> [<reserved>] -> a task label, or "".
#
# The label fits MAX_TITLE_LEN minus <reserved>'s length: the caller passes the
# literal text that will share the label (a name part and its joint, a glyph
# and its space), and jq measures it in codepoints, because bash's ${#} counts
# bytes under a C locale and would overcharge anything non-ASCII.
#
# Selects; never generates, with one exception: the FIRST surviving word, when it
# alone is longer than the budget, is cut rather than dropped, and the cut lands
# on a codepoint rather than a grapheme, so a word ending in a combining mark or a
# ZWJ sequence can be left dangling. Dropping it instead would empty the label and
# hand the tab the untouched sentence.
#
# The two are NOT the same label. The sentence keeps the words this function drops
# and the casing it folds, so "Investigate Supercalifragilisticexpialidocious
# tail" reaches a 19-character tab as "supercalifragilisti" here and as
# "Investigate" through the fallback. Which reads better is a judgement; that they
# differ is not, and an earlier note claiming they were identical was wrong.
#
# The agent already wrote the summary, so the work here is only to shorten it: drop a leading verb (TITLE_LEAD_VERBS), drop filler
# (TITLE_FILLER_WORDS), then take whole words from the front until the budget is
# spent, stopping at the first word that does not fit rather than skipping ahead
# (a later short word would read as a non sequitur next to the ones before it).
#
# Words are taken in the order the agent wrote them. Selecting by "distinctness"
# instead -- proper nouns, gerunds, rare words -- measurably reads worse: it
# prefers where the work happens over what it is ("screensaver Ubuntu" for
# "Adjust screensaver timeout on the Ubuntu box"), and an -ing word in these
# summaries is usually a modifier ("streaming pipeline"), so promoting it evicts
# the noun carrying the meaning. The input is already ordered by an agent that
# put the salient words first; this trusts that rather than re-ranking it.
#
# One jq program rather than a bash loop: jq is already a hard dependency, reads
# UTF-8 regardless of the ambient locale (see the truncation note in ar_format),
# and keeps this a single subprocess per tab.
ar_condense_title() {
  local title=$1 reserved=${2:-} max=${MAX_TITLE_LEN:-28}
  [ -n "$title" ] || return 0
  printf '%s' "$title" | jq -Rrs \
    --argjson max "$max" \
    --arg reserved "$reserved" \
    --arg sep "${TITLE_WORD_SEPARATOR:--}" \
    --arg case "${TITLE_CASE:-fold}" \
    --arg verbs "${TITLE_LEAD_VERBS[*]}" \
    --arg filler "${TITLE_FILLER_WORDS[*]}" '
      . as $orig
    | ([$max - ($reserved | length), 0] | max) as $m
    | ($verbs  | ascii_downcase | split(" ")) as $verb
    | ($filler | ascii_downcase | split(" ")) as $fill
    # The filler list as WRITTEN, alongside the folded one, and the identifier
    # shape defined once for the two rules that share it. Duplicating the pattern
    # was called a guarantee that they could not drift, which it was not.
    | ($filler | split(" ")) as $fillraw
    | "^[A-Z0-9]{2,}$" as $ident
    # Separators inside the title are word breaks, not characters, so
    # "tab/workspace" is two words rather than one long one. The hyphen is
    # handled later, at the cut (see below).
    #
    # Nothing strips a leading glyph or a leading brand here, though both reach
    # a title: the engine has already run lead and debrand, the two definitions
    # in AR_JQ_TASK, on every path that arrives here, which is the two pane lifts
    # and both transcript reads. Doing either again would be a second copy of a
    # rule upstream owns, free to drift from it and answering to no test.
    | gsub("[/,;:|]+"; " ")
    | [splits("[[:space:]]+")]
    | map(select(length > 0))
    | . as $words
    | (if ($words | length) > 0 and ($verb | index($words[0] | ascii_downcase))
       then $words[1:] else $words end)
    # An all-caps token is an identifier, and the casing rule below spares it for
    # exactly that reason. Filler is matched without regard to case, so without
    # this the two rules disagree and the identifier loses: "Investigate IT
    # outage" became "outage" and "Fix OR parser precedence" became
    # "parser-precedence", because "it" and "or" are filler.
    #
    # Listing the word in capitals overrides that and drops it again, which is
    # the escape hatch for a project whose filler really is an all-caps token.
    # Lower case in the list does not, so a title carrying "RFC" keeps it whether
    # or not somebody wrote "rfc" there. Emphatic prose keeps its capitals too:
    # "Fix THE parser" reads as "THE-parser", the rule having no way to tell a
    # shouted article from a short identifier.
    #
    # Two characters at least, matching the casing rule. A single letter is not
    # covered, so "Fix A record resolution" loses its "A".
    | map(. as $w | select(
        (($fill | index($w | ascii_downcase)) | not)
        or (($w | test($ident)) and (($fillraw | index($w)) | not))
      ))
    # Casing: a sentence-case capital is the agent writing a sentence, not
    # signal; an all-caps-and-digits token is an identifier whose shape means
    # something. "fold" spares only the identifiers, "lower" folds those too,
    # "keep" touches nothing. Anything else behaves as the "fold" default.
    | map(if $case == "keep" then .
          elif $case == "lower" then ascii_downcase
          elif test($ident) then .
          else ascii_downcase end)
    # The hyphen is a word break for the cut only. A kebab-case title read as
    # one word was cut mid-token ("foundation-claude-") once it ran past the
    # budget (issue #32), so its parts are taken one at a time. The verb and
    # filler rules above still read the hyphenated word whole: split before
    # them, "Build-time cache fix" lost "build" as a verb and "end-to-end"
    # lost "to" as filler. A dash standing alone splits to nothing and goes.
    | map(split("-") | map(select(length > 0))) | add // []
    | reduce .[] as $w ({out: "", done: false};
        if .done then .
        elif .out == "" then {out: ($w[:$m]), done: false}
        elif ((.out | length) + ($sep | length) + ($w | length)) <= $m then {out: (.out + $sep + $w), done: false}
        else {out: .out, done: true} end)
    | .out
    # Two ways a candidate is worse than the sentence it would replace, and both
    # hand the sentence back rather than shipping the label.
    #
    # A label LONGER than the title has inverted the whole point: a separator of
    # more than one character can spend more budget than the prose it replaced,
    # and then ar_format cuts a label that would have fitted. Equal length is
    # fine and is on purpose -- that is the casing folded and the words fused
    # into the one token every other tab name is -- so only growth is refused.
    #
    # A leading "[<digits>]" is the shape ar_index_prefix writes and
    # ar_strip_prefix reads back. A label wearing it is read at the next
    # reconcile as a base somebody typed by hand, and the tab opts out of
    # naming until a reset. Only a separator carrying whitespace reaches this --
    # the default "-" cannot -- but the cost when it does is the tab, not the
    # label.
    #
    # Whitespace OR a control character, because the shape is judged on what
    # ar_format will STORE rather than on what is written here: its scrub turns
    # any run of either into one space, so a separator of a tab produced
    # "[12]\tparser" here, passed a check looking for a literal space, and
    # reached the tab as "[12] parser" -- the shape, arriving one step later.
    | if . != "" and (length <= ($orig | length))
         and ((test("^\\[[0-9]+\\]([[:space:][:cntrl:]]|$)")) | not)
      then . else "" end
  ' 2>/dev/null
}
# ---- helpers ----

# ssh options whose value is a SEPARATE argument, so `ssh -p 2222 prod-01` does
# not read 2222 as the destination. Everything else starting with a dash is a
# switch, or carries its value attached. From ssh(1); a flag added later reads as
# a switch here, which costs at most the tab saying `ssh` alone for one release.
_AR_SSH_VALUE_FLAGS='BbcDEeFIiJLlmOoPpQRSWw'

# The `-o` settings whose value is a COMMAND, and so the only ssh arguments that
# routinely carry spaces. A command line reaches this module flattened, and a
# value with a space in it has already been split into words that look exactly
# like arguments of ssh itself -- a ProxyCommand parses as its own bastion, which
# is a tab confidently naming the wrong machine. Seeing one of these is how that
# is recognized; the answer is to refuse the line. Written lowercase and compared
# folded, since ssh does not care how they are spelled.
_AR_SSH_COMMAND_OPTS=(proxycommand remotecommand localcommand knownhostscommand setenv)

# ar_ssh_setting_opaque <setting=value> -> 0 when that -o setting takes a COMMAND
# for its value, and so when nothing after it on a flattened command line can be
# trusted: the command's own words are already mixed in with ssh's, and a
# ProxyCommand parses as its own bastion -- a tab confidently naming the wrong
# machine. Folded, since ssh does not care how a setting is spelled.
ar_ssh_setting_opaque() {
  ar_case "${1%%=*}" "$_AR_UPPER" "$_AR_LOWER"
  ar_in_list "$AR_CASE" "${_AR_SSH_COMMAND_OPTS[@]}"
}

# ar_ssh_host <command line> -> the machine the pane reached, or "" when the
# command is not ssh or names no destination.
#
# A pane running ssh is about the machine on the other end. Its directory is the
# local one it was launched from and says nothing about the remote; the remote's
# own terminal title says what is being done there but never which machine, which
# is exactly what a row of identical shells needs.
#
# The destination is the first argument that is neither an option nor an option's
# value. Everything after it is the remote command. The user is dropped:
# root@prod-01 and deploy@prod-01 are the same machine, and a tab bar has no room
# to say who is logged in.
ar_ssh_host() {
  AR_SSH_HOST=""
  [ "${TAB_CONTEXT:-1}" = "1" ] || return 0
  local word host="" skip=0 setting=0 done=0 cluster letter words=()
  case ${1%% *} in */ssh | ssh) ;; *) return 0 ;; esac
  case $1 in *' '*) ;; *) return 0 ;; esac    # ssh with no arguments names nobody
  # Quotes come off before anything is read, so that the same command line reads
  # the same both ways round. The shell hook is handed the line AS TYPED, quotes
  # and all; the reconcile is handed a flattened argv, which a shell stripped the
  # quotes from before it ever ran. A rule that fired on one shape and not the
  # other would have the two naming paths disagree, which is a tab that flips on
  # every prompt.
  local line=$1
  line=${line//\"/}
  line=${line//\'/}
  # Splitting IS the parse. A command line reaches here as one string with its
  # quoting already gone (herdr joins argv, and the shell hook is handed the line
  # as typed), so there is nothing better to split on -- and a hostname has no
  # spaces in it. `read -a` rather than a bare `for word in $1`, because that
  # would expand a glob in the line and would need `set -f` around it, which is a
  # process-wide setting to be flipping under the reconcile that called this.
  IFS=' ' read -ra words <<< "${line#* }"
  for word in ${words[@]+"${words[@]}"}; do
    if [ "$skip" = "1" ]; then
      skip=0
      if [ "$setting" = "1" ]; then
        setting=0
        ar_ssh_setting_opaque "$word" && return 0
      fi
      continue
    fi
    if [ "$done" = "0" ]; then
      case $word in
      --)
        done=1                          # everything after this is positional
        continue
        ;;
      -[!-]*)
        # Short options cluster, and the one that takes a value need not be alone
        # in the word: `-4p 2222` is IPv4 on port 2222. So the cluster is read
        # left to right until a value-taking letter turns up; what follows it in
        # the same word is its value, and an empty remainder means the value is
        # the next word.
        cluster=${word#-}
        while [ -n "$cluster" ]; do
          letter=${cluster%"${cluster#?}"}
          cluster=${cluster#?}
          case $_AR_SSH_VALUE_FLAGS in
          *"$letter"*)
            # ssh takes -o's setting either attached to the flag or as the next
            # word, and both forms have to be read: the attached one is what
            # `-oProxyCommand=...` writes.
            if [ -n "$cluster" ]; then
              [ "$letter" = "o" ] && ar_ssh_setting_opaque "$cluster" && return 0
            else
              skip=1
              [ "$letter" = "o" ] && setting=1
            fi
            break
            ;;
          esac
        done
        continue
        ;;
      -*) continue ;;
      esac
    fi
    host=$word
    break
  done
  [ -n "$host" ] || return 0
  host=${host#ssh://}                   # the url form ssh accepts
  host=${host##*@}                      # whoever is logged in
  case $host in
  # A bracketed IPv6 address: the colons inside it are the address, not a port,
  # and the brackets are what say so.
  \[*\]*) host=${host%%\]*}\] ;;
  *)
    host=${host%%:*}                    # the port the url form carries
    host=${host%%/*}                    # ... and the path
    ;;
  esac
  [ -n "$host" ] || return 0
  # Shortened the way a directory is, not cut where the budget ends: a machine
  # called quans-ssh-macbook reads as "quans-ssh", where the plain cut leaves
  # "quans-ssh-ma" and a column spent on half a word.
  AR_SSH_HOST=$(ar_shorten "$host" "${MAX_CONTEXT_LEN:-12}")
  printf '%s' "$AR_SSH_HOST"
}

# ar_branch_new <branch> <what the reader can already see> -> the branch, or ""
# when it says nothing that is not on screen already.
#
# herdr shows the workspace above the tabs and the tab shows its own context, so
# a branch repeating either spends width on what the reader is looking at. A
# worktree named after the branch checked out in it is the common case, not a
# corner: "auto-title > auto-title > Rename the tabs" says one thing three times.
# Containment rather than equality, because the directory is usually the branch
# with a convention wrapped round it ("bugfix-" in front, the ticket in the
# middle). Folded through _AR_FOLD_IN, like the context compare next door, and
# for the same reason: a branch and the directory it is checked out in are one
# name in two spellings, "feat/oauth" checked out in "feat-oauth".
ar_branch_new() {
  local branch=$1 said
  AR_BRANCH_NEW=""
  [ -n "$branch" ] || return 0
  ar_case "$2" "$_AR_FOLD_IN" "$_AR_FOLD_OUT"
  said=$AR_CASE
  ar_case "$branch" "$_AR_FOLD_IN" "$_AR_FOLD_OUT"
  case $said in *"$AR_CASE"*) return 0 ;; esac
  AR_BRANCH_NEW=$branch
  printf '%s' "$branch"
}

# ar_label <pane directory> <workspace base> <branch> <program|""> <cmdline> [title]
#   -> the whole label a tab should carry.
#
# The branch arrives as an argument where the directory arrives raw, because
# reading it is a filesystem walk and this module does not touch the filesystem
# (see git.sh). So it is the one part a caller has to remember: ar_branch_of next
# to the engine's two naming paths is what both of them call for it.
#
# The one entry point for naming a tab. Both callers -- the reconcile and the
# shell hook's fast path -- go through it, so neither can skip a step the other
# takes: a label they disagree about is a tab that flips on every prompt. That is
# why the raw directory comes in rather than a context computed outside.
ar_label() {
  local ctx
  # A pane running ssh is named after the machine it reached, and after nothing
  # local: the branch is read from the directory ssh was launched in, and printed
  # beside prod-01 it would read as that machine's, while the directory itself is
  # only where the user was standing when they left. The `ssh` mark stays in the
  # activity, which is where the program rules would have put it anyway. The test
  # is the program name, so nothing but an ssh pane pays for the parse.
  if [ "$4" = "ssh" ] && [ "${TAB_CONTEXT:-1}" = "1" ]; then
    ar_ssh_host "$5" >/dev/null
    ar_format ssh ssh "${6:-}" >/dev/null
    ar_compose "$AR_SSH_HOST" "" "$AR_ACTIVITY"
    return 0
  fi
  # Each part is read back off the global its function publishes rather than out
  # of a command substitution. Four parts, four subshells, once per named tab on
  # every herdr event: on a session of a dozen tabs that was most of the cost of
  # a reconcile, and a fork is a whole shell on macOS.
  ar_context_dir "$1" "$2" >/dev/null
  ctx=$AR_CONTEXT
  ar_format "$4" "$5" "${6:-}" >/dev/null
  ar_branch_new "$3" "$ctx $2" >/dev/null
  ar_compose "$ctx" "$AR_BRANCH_NEW" "$AR_ACTIVITY"
}

# ar_format <program|""> <cmdline> [title] -> final tab label
#   program == "" means a bare prompt (name by the shell).
ar_format() {
  local prog=$1 cmdline=$2 title=${3:-} name="" ic aliased="" is_shell=0 max=${MAX_NAME_LEN:-20}
  AR_ACTIVITY=""
  # Muse ships as muse-bin-<version> (muse-bin-0.1.0-R708.1) and never runs under
  # a bare name, so no exact-match list can carry the process a pane actually
  # shows. herdr folds those onto its "muse" kind (is_muse_versioned_binary,
  # src/detect/mod.rs), asking for a digit right after the prefix so an unrelated
  # muse-binary stays unmatched, and this mirrors that rule. Folding here rather
  # than in each list puts it ahead of all three things that key on the name --
  # the alias lookup below, the program lists, and the icon map -- so a versioned
  # install is named, aliased and glyphed the way a named one is. Inline because
  # every reconcile and every shell prompt runs this function.
  case "$prog" in muse-bin-[0-9]*) prog=muse ;; esac
  # Only the program-name chain below consults an alias, so a title (or a bare
  # prompt) does not pay for the lookup.
  [ -n "$prog" ] && [ -z "$title" ] && aliased=$(ar_alias "$prog")
  if [ -n "$title" ]; then
    # A task title from ar_title_clean. It replaces the program name outright,
    # alias and all: AGENT_TITLES is the switch for wanting the task instead, and
    # an alias set to shorten "claude" to "cl" is not a request to hide the work.
    # It still gets the icon for the program below, and its own length budget.
    name=$title
    max=${MAX_TITLE_LEN:-28}
    # TITLE_STYLE=name_and_task puts the agent back in front of its task. Here an
    # alias IS wanted, which is the difference from the rule above: asking for the
    # name is asking for the name you chose for it.
    #
    # $prog is the agent kind on every route that reaches here today, the callers
    # passing herdr detection rather than the pane foreground, so the alias lookup
    # needs nothing new. That is a property of those callers and not a promise
    # this function makes: ar_format takes a title for any program, and one handed
    # a shell would read "zsh:...". Nothing calls it that way.
    #
    # It also means the alias is looked up by agent KIND here, where a tab named
    # by program looks it up by program name. Those differ for two agents,
    # cursor-agent (kind cursor) and kiro-cli (kind kiro), and ar_alias answers
    # to either spelling for exactly that reason, so one entry covers the agent
    # whichever name reaches it (issue #19).
    if [ "${TITLE_STYLE:-task}" = "name_and_task" ]; then
      aliased=$(ar_title_name_prefix "$prog" "$max")
      [ -n "$aliased" ] && name="$aliased$name"
    fi
  elif [ -z "$prog" ]; then
    name=$SHELL_NAME
    is_shell=1
  elif [ -n "$aliased" ]; then
    name=$aliased # user rename (PROGRAM_ALIASES) wins
  elif ar_in_list "$prog" "${SHELLS[@]}"; then
    name=$prog
    is_shell=1 # a shell shows its own name (zsh)
  elif [ "$prog" = "$SHELL_NAME" ]; then
    name=$prog
    is_shell=1 # the login shell, even outside SHELLS (nu, tcsh, ...)
  elif ar_in_list "$prog" "${IGNORED_PROGRAMS[@]}"; then
    name=$SHELL_NAME
    is_shell=1 # quick tools: keep showing the shell
  elif ar_in_list "$prog" "${NAME_ONLY_PROGRAMS[@]}"; then
    name="$(ar_subst "$prog")" # nvim, claude, ...: just the name
  elif [ "${SHOW_PROGRAM_ARGS:-0}" = "1" ] && [ -n "$cmdline" ]; then
    name="$(ar_subst "$cmdline")"
  else
    name="$(ar_subst "$prog")"
  fi

  # HIDE_SHELL: drop the shell label entirely and let herdr number the tab. An
  # explicit PROGRAM_ALIASES entry for a shell (e.g. "fish=sh") is a name the
  # user asked for by hand, so it survives; nothing else about a shell tab does
  # -- bare prompt, an explicit SHELLS entry, an IGNORED_PROGRAMS command, or
  # the login shell itself.
  if [ "${HIDE_SHELL:-0}" = "1" ] && [ "$is_shell" = "1" ]; then
    printf ''
    return 0
  fi

  # Icons annotate the program the tab is named after. Skip them whenever the
  # label is a shell name: precmd names an idle prompt via ar_format "" "",
  # which `[ -n "$prog" ]` denies an icon, so a glyph here would flip the label
  # between "zsh" and "<glyph> zsh" on every reconcile. is_shell covers the
  # bare prompt, the fixed SHELLS six, IGNORED_PROGRAMS, and the login shell
  # itself (SHELL_NAME may sit outside SHELLS -- nu, tcsh, elvish -- yet still
  # hit the map, or the fallback, at reconcile); comparing against SHELL_NAME
  # additionally keeps a cmdline- or alias-derived label of the same text plain.
  if [ "${ICONS_ENABLED:-0}" = "1" ] && [ -n "$prog" ] && [ "$is_shell" = "0" ] &&
    [ "$name" != "$SHELL_NAME" ]; then
    ic=$(ar_icon "$prog")
    # A lone fallback glyph says nothing about the program, so under
    # ICON_STYLE=icon it is skipped and the plain name is kept: rg -> "rg",
    # not "?". (name_and_icon still shows "? rg" with ICON_FALLBACK='?'.)
    if [ "${ICON_STYLE:-name_and_icon}" = "icon" ] && [ -n "$ic" ] && [ "$ic" = "$ICON_FALLBACK" ]; then
      ic=""
    fi
    if [ -n "$ic" ]; then
      case "${ICON_STYLE:-name_and_icon}" in
      icon) name=$ic ;;                      # icon only
      name) : ;;                             # name only (icon suppressed)
      name_and_icon | *) name="$ic $name" ;; # icon + name (default)
      esac
    fi
  fi
  # Scrub what a command line can carry into a label: control characters (argv
  # can hold a newline or a tab, and SHOW_PROGRAM_ARGS=1 puts argv in the label)
  # and runs of whitespace. herdr takes the string verbatim, so an unscrubbed one
  # reaches the tab bar as it is.
  #
  # One tr both translates and squeezes, and only for a label that needs it: the
  # case guard keeps the fork off a clean label, which is nearly all of them and
  # all of the ones on the shell-hook path. Squeezing FIRST is what makes the
  # single-character trims below enough. A UTF-8 label survives either tr: a
  # bytewise one never matches a continuation byte (every one is >= 0x80, outside
  # the class), and a locale-aware one consumes whole characters.
  case $name in
  *[[:cntrl:]]* | *"  "*) name=$(printf '%s' "$name" | tr -s '[:cntrl:] ' ' ') ;;
  esac
  name=${name# }
  name=${name% }

  # Cut to the budget, in codepoints. Asking bash for the width instead put a
  # label that fits into this branch under a C locale: ar_trunc handed it straight
  # back, having correctly found nothing to cut, and the word-boundary trim below
  # then took a word off a label that was never over budget. With a wide enough
  # glyph in front, the only space is the one behind it and the trim left the
  # glyph alone on the tab.
  if ! ar_fits "$name" "$max"; then
    name=$(ar_trunc "$name" "$max")
    # A title is a sentence, so cut it at a word boundary rather than mid-word --
    # but only when that leaves most of the budget, since "Investigate" tells you
    # more than "I" does.
    if [ -n "$title" ]; then
      # ${name% *} is the whole string when there is no space in it, so a single
      # long word is left cut where it was. The half-budget floor is what stops
      # "Investigate" from becoming "I".
      #
      # Counted the same way the budget is. Calling it a heuristic and leaving it
      # in bytes was wrong: the floor still compares against half of a CHARACTER
      # budget, and under a C locale a four-byte glyph cleared it on its own, so a
      # genuinely over-budget title came back as the glyph and nothing else, which
      # is the symptom this commit exists to remove. ar_fits is asked the opposite
      # question, so a floor of n is "does not fit in n-1".
      local short=${name% *}
      ar_fits "$short" $(( max / 2 - 1 )) || name=$short
    fi
  fi
  AR_ACTIVITY=$name
  printf '%s' "$name"
}

# ar_border_title <agent name> <agent kind> <pane label> -> the title an agent's
# pane border should carry (NAME_PANES), or "" for none. Also sets
# AR_BORDER_TITLE, so the engine's per-pane loop reads it without a fork.
#
# The name is the one `herdr agent start <name>` or `herdr agent rename` gave the
# agent, with any "[N] " an older herdr's agent numbering put in front already
# taken off. herdr draws a reported title above a pane name typed with `pane
# rename`, so a pane with a label of its own gets none, and that label shows. A
# name that only repeats the kind ("claude" on a claude pane) gets none either:
# it says nothing herdr's own agent label would not, and the border stays free
# for it.
ar_border_title() {
  local name=$1 kind
  AR_BORDER_TITLE=""
  [ -n "$name" ] && [ -z "$3" ] || return 0
  ar_case "$2" "$_AR_UPPER" "$_AR_LOWER"
  kind=$AR_CASE
  ar_case "$name" "$_AR_UPPER" "$_AR_LOWER"
  [ "$AR_CASE" = "$kind" ] && return 0
  # shellcheck disable=SC2034  # read by ar_name_panes in the engine next door
  AR_BORDER_TITLE=$name
  printf '%s' "$name"
}
