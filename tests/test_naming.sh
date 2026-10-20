#!/usr/bin/env bash
# Unit tests for naming.sh -- the pure, herdr-free name computation.
# String in / string out, so every rule is testable without a live herdr.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

# Pin the shell name so bare-prompt cases are deterministic regardless of $SHELL.
SHELL_NAME=zsh
# shellcheck source=naming.sh
. "$here/../naming.sh"
# The engine too, for AR_JQ_CLEAN alone: the spinner strip a title gets before
# ar_title_clean ever sees it is a jq definition there now, and it is still worth
# pinning one seam over rather than only end to end (see the title section below).
# Sourcing the engine defines its functions and constants and runs nothing (the
# ar_main guard), which is what tests/test_prefix.sh relies on as well.
# shellcheck source=automatic-rename.sh
. "$here/../automatic-rename.sh"

# ---- bare prompt / shells ----
check "bare prompt -> shell name" "zsh" "$(ar_format '' '')"
check "explicit shell shows own name" "bash" "$(ar_format 'bash' 'bash')"
check "fish shell name" "fish" "$(ar_format 'fish' '')"

# ---- name-only programs (editors, agents, git) ----
check "nvim is name-only" "nvim" "$(ar_format 'nvim' 'nvim README.md')"
check "claude is name-only" "claude" "$(ar_format 'claude' 'claude --dangerously-skip-permissions')"
check "git is name-only" "git" "$(ar_format 'git' 'git status')"

# NAME_ONLY_PROGRAMS only bites with SHOW_PROGRAM_ARGS=1 (0 is the default and
# already renders bare names), so assert these there. Covers the agents herdr
# 0.9.2 detects, including the four whose executable differs from its --kind id.
check "grok is name-only" "grok" "$(SHOW_PROGRAM_ARGS=1 ar_format 'grok' 'grok --model x')"
check "agy is name-only" "agy" "$(SHOW_PROGRAM_ARGS=1 ar_format 'agy' 'agy --conversation 12')"
check "opencode is name-only" "opencode" "$(SHOW_PROGRAM_ARGS=1 ar_format 'opencode' 'opencode run x')"
check "cursor-agent name-only" "cursor-agent" "$(SHOW_PROGRAM_ARGS=1 ar_format 'cursor-agent' 'cursor-agent -p x')"
check "kiro-cli is name-only" "kiro-cli" "$(SHOW_PROGRAM_ARGS=1 ar_format 'kiro-cli' 'kiro-cli chat')"
check "letta-code is name-only" "letta-code" "$(SHOW_PROGRAM_ARGS=1 ar_format 'letta-code' 'letta-code --backend local')"
check "gemini is name-only" "gemini" "$(SHOW_PROGRAM_ARGS=1 ar_format 'gemini' 'gemini -p hi')"
check "muse is name-only" "muse" "$(SHOW_PROGRAM_ARGS=1 ar_format 'muse' 'muse --resume')"
check "muse-cli is name-only" "muse-cli" "$(SHOW_PROGRAM_ARGS=1 ar_format 'muse-cli' 'muse-cli chat')"
check "muse-code is name-only" "muse-code" "$(SHOW_PROGRAM_ARGS=1 ar_format 'muse-code' 'muse-code run')"

# Muse only ever runs as muse-bin-<version>, which no list can carry, so the
# fold onto herdr's own kind happens before every rule that keys on the name.
check "a versioned muse binary is named muse" "muse" \
  "$(SHOW_PROGRAM_ARGS=1 ar_format 'muse-bin-0.1.0-R708.1' 'muse-bin-0.1.0-R708.1 --resume')"
check "and takes the alias set for muse" "ms" "$(
  PROGRAM_ALIASES=("muse=ms")
  ar_format 'muse-bin-1.2.3' 'muse-bin-1.2.3'
)"
# herdr asks for a digit right after the prefix, so an unrelated binary that
# merely starts the same way keeps its own name.
check "muse-binary is not Muse" "muse-binary" \
  "$(SHOW_PROGRAM_ARGS=0 ar_format 'muse-binary' 'muse-binary -x')"
check "a bare muse-bin is not Muse either" "muse-bin" \
  "$(SHOW_PROGRAM_ARGS=0 ar_format 'muse-bin' 'muse-bin')"
# The fold sits ahead of the icon lookup too, so a versioned install draws the
# robot every other agent draws instead of the fallback. (The glyph itself is
# pinned by the icon section below, which reads its roster off the same list.)
check "a versioned muse binary draws the agent glyph" "$(printf '\363\260\232\251') muse" \
  "$(ICONS_ENABLED=1 ar_format 'muse-bin-0.1.0-R708.1' 'muse-bin-0.1.0-R708.1')"

# ---- ignored programs keep showing the shell ----
check "ls is ignored -> shell" "zsh" "$(ar_format 'ls' 'ls -la')"
check "cd is ignored -> shell" "zsh" "$(ar_format 'cd' 'cd ..')"

# ---- regular programs show their command line (SHOW_PROGRAM_ARGS default on) ----
SHOW_PROGRAM_ARGS=1
check "regular program shows cmdline" "htop -d 5" "$(ar_format 'htop' 'htop -d 5')"
check "regular program, args off -> name only" "psql" "$(SHOW_PROGRAM_ARGS=0 ar_format 'psql' 'psql -h db')"

# ---- program aliases win over category ----
PROGRAM_ALIASES=("clx=hn" "lazygit=lg")
check "alias clx->hn" "hn" "$(ar_format 'clx' 'clx --nerdfonts')"
check "alias lazygit->lg" "lg" "$(ar_format 'lazygit' 'lazygit')"
PROGRAM_ALIASES=()

# An agent whose executable differs from herdr's kind reaches ar_format under
# either spelling, depending on how it was installed (the WRAPPER_PROGRAMS path
# substitutes the kind), so one alias entry has to answer for both (issue #19).
PROGRAM_ALIASES=("cursor-agent=cu")
check "alias by executable, natively installed" "cu" "$(ar_format 'cursor-agent' 'cursor-agent')"
check "alias by executable, kind substituted" "cu" "$(ar_format 'cursor' 'cursor')"
PROGRAM_ALIASES=("kiro=k")
check "alias by kind, kind substituted" "k" "$(ar_format 'kiro' 'kiro')"
check "alias by kind, natively installed" "k" "$(ar_format 'kiro-cli' 'kiro-cli')"
# Only the two spellings of one agent are the same agent. A program that merely
# ends in the same suffix keeps its own name.
PROGRAM_ALIASES=("cursor-agent=cu")
check "another program is not the same agent" "sourcegraph" "$(ar_format 'sourcegraph' 'sourcegraph')"
PROGRAM_ALIASES=("git=g")
check "an unsuffixed program takes no alternate" "gitui" "$(ar_format 'gitui' 'gitui')"
# Both spellings have to be listed, which is what makes them one agent's two
# names: a suffix alone would hand an unrelated git-cli whatever git is aliased to.
check "a suffix is not a pairing on its own" "git-cli" "$(SHOW_PROGRAM_ARGS=0 ar_format 'git-cli' 'git-cli')"
PROGRAM_ALIASES=()

# ---- substitutions ----
check "poetry shell -> poetry" "poetry" "$(ar_format 'poetry' 'poetry shell')"
check "ipython3 collapse" "ipython3" "$(ar_format 'ipython3' '/usr/bin/ipython3')"

# ---- control characters and whitespace in a label ----
# argv can hold anything, and with SHOW_PROGRAM_ARGS=1 the command line IS the
# label. herdr sets the string verbatim, so a raw tab or newline out of a cmdline
# would land in the tab bar; worse, a label herdr normalized on the way in reads
# back as a string this plugin never set, and ar_name_eligible cannot tell that
# from a hand rename -- it would opt the tab out of naming for good. The control
# characters are written as printf escapes on purpose: a literal tab here is
# invisible to review and an editor or a copy-paste eats it silently.
check "tab in cmdline becomes a space" "htop -d 5" \
  "$(SHOW_PROGRAM_ARGS=1 ar_format 'htop' "$(printf 'htop\t-d 5')")"
check "newline in cmdline becomes a space" "htop -d 5" \
  "$(SHOW_PROGRAM_ARGS=1 ar_format 'htop' "$(printf 'htop\n-d 5')")"
check "BEL and ESC go the same way" "htop -d 5" \
  "$(SHOW_PROGRAM_ARGS=1 ar_format 'htop' "$(printf 'htop \x07-d\x1b 5')")"
check "runs of spaces collapse to one" "htop -d 5" \
  "$(SHOW_PROGRAM_ARGS=1 ar_format 'htop' 'htop   -d    5')"
check "leading and trailing space trimmed" "htop -d 5" \
  "$(SHOW_PROGRAM_ARGS=1 ar_format 'htop' '  htop -d 5  ')"
# A label with nothing to scrub must come through byte for byte -- the scrub sits
# on the path every name takes, so a label it rewrites is a label it broke.
check "ordinary label unchanged by the scrub" "htop -d 5" \
  "$(SHOW_PROGRAM_ARGS=1 ar_format 'htop' 'htop -d 5')"
# Control characters are ASCII-range bytes and a UTF-8 continuation byte is not,
# so scrubbing cannot cut a multibyte character in half on its way to the
# codepoint truncation below.
check "multibyte survives the scrub" "ünïcödé arg" \
  "$(SHOW_PROGRAM_ARGS=1 ar_format 'x' "$(printf 'ünïcödé\targ')")"

# ---- truncation (MAX_NAME_LEN), counted by codepoint ----
check "truncates to MAX_NAME_LEN" "12345678901234567890" \
  "$(MAX_NAME_LEN=20 ar_format 'x' '123456789012345678901234567890')"
# A multibyte string must be cut on a codepoint boundary, never mid-byte.
check "multibyte truncation is clean" "ünïcödé" \
  "$(MAX_NAME_LEN=7 ar_format 'x' 'ünïcödéxxxxxxx')"

# And a label that FITS must be left alone, which is a different claim: bash
# counts bytes under a C locale (herdr may launch a plugin with no LC_*), so a
# multibyte label inside its budget still looked over it. What followed was not a
# cut, since ar_trunc correctly found nothing to cut, but the word-boundary trim
# that runs after one, which took a whole word off a label that fitted. Run under
# LC_ALL=C, because that is the only place the bug exists.
# A TITLE, because the word-boundary trim that does the damage runs only for one.
# Nine codepoints and thirteen bytes, in a budget of nine: it fits, ar_trunc finds
# nothing to cut, and the trim used to take "x" off anyway.
check "a fitting multibyte title is untouched" "ünïcödé x" \
  "$(LC_ALL=C MAX_TITLE_LEN=9 ar_format 'claude' '' "$(printf '\303\274n\303\257c\303\266d\303\251 x')")"
# ---- ar_fits: the byte test holds in one direction only ----
check_rc "ascii inside the budget fits" 0 "$(ar_fits 'abcdef' 8; echo $?)"
check_rc "ascii over the budget does not" 1 "$(ar_fits 'abcdefghij' 8; echo $?)"
# Eight codepoints, sixteen bytes: the cheap test fails and only a codepoint
# count can say it fits.
check_rc "multibyte inside the budget fits under C" 0 \
  "$(LC_ALL=C ar_fits "$(printf 'àààààààà')" 8; echo $?)"
check_rc "multibyte over the budget does not" 1 \
  "$(LC_ALL=C ar_fits "$(printf 'ààààààààà')" 8; echo $?)"

# ---- icons ----
# Expected glyphs are built from explicit UTF-8 byte escapes rather than pasted
# literals: bash 3.2 has no $'\uXXXX', and the Private Use Area codepoints these
# tests assert on are precisely what an editor or a copy-paste silently ate once
# before (the old ar_icon shipped with every arm returning "", so ICONS_ENABLED
# was a no-op through v0.2.1). Byte escapes cannot be eaten that way, so these
# tests still fail loudly if the glyphs ever vanish from icons.sh again.
g_nvim=$(printf '\xee\x9a\xae')      # U+E6AE nf-custom-neovim
g_vim=$(printf '\xee\x98\xab')       # U+E62B nf-custom-vim
g_git=$(printf '\xee\x9c\x82')       # U+E702 nf-dev-git
g_node=$(printf '\xee\x9c\x98')      # U+E718 nf-dev-nodejs_small
g_python=$(printf '\xee\x9c\xbc')    # U+E73C nf-dev-python
g_docker=$(printf '\xef\x8c\x88')    # U+F308 nf-linux-docker
g_cargo=$(printf '\xee\x9e\xa8')     # U+E7A8 nf-dev-rust
g_go=$(printf '\xee\x98\xa7')        # U+E627 nf-seti-go
g_agent=$(printf '\xf3\xb0\x9a\xa9') # U+F06A9 nf-md-robot
g_htop=$(printf '\xee\xae\xa2')      # U+EBA2

# ar_icon must return a real glyph per program group, not the empty string.
check "ar_icon nvim" "$g_nvim" "$(ar_icon nvim)"
check "ar_icon vim" "$g_vim" "$(ar_icon vim)"
check "ar_icon gvim" "$g_vim" "$(ar_icon gvim)"
check "ar_icon git" "$g_git" "$(ar_icon git)"
check "ar_icon lazygit" "$g_git" "$(ar_icon lazygit)"
check "ar_icon node" "$g_node" "$(ar_icon node)"
check "ar_icon pnpm" "$g_node" "$(ar_icon pnpm)"
check "ar_icon python3" "$g_python" "$(ar_icon python3)"
check "ar_icon docker" "$g_docker" "$(ar_icon docker)"
check "ar_icon cargo" "$g_cargo" "$(ar_icon cargo)"
check "ar_icon go" "$g_go" "$(ar_icon go)"
check "ar_icon claude" "$g_agent" "$(ar_icon claude)"
check "ar_icon codex" "$g_agent" "$(ar_icon codex)"
# htop used to be the "unknown program" sentinel; the upstream map knows it.
check "ar_icon htop" "$g_htop" "$(ar_icon htop)"

# Every program the engine names by itself has a glyph of its own. The roster is
# read out of NAME_ONLY_PROGRAMS rather than typed again here, which is the whole
# point: a hand-copied list only catches a typo in a name somebody already
# remembered to add in both files, and maki spent two herdr releases drawing the
# "?" fallback for exactly that reason. The robot glyph's bytes stay pinned by
# the claude and codex checks above.
for _prog in "${NAME_ONLY_PROGRAMS[@]}"; do
  check "ar_icon $_prog is mapped" "mapped" \
    "$([ -n "$(ICON_FALLBACK='' ar_icon "$_prog")" ] && echo mapped || echo unmapped)"
done

# A program missing from the map gets no glyph by default, since a tab with no
# icon already says "unmapped" and a "?" reads as an error. ICON_FALLBACK opts
# back in to a glyph.
check "ar_icon unknown -> empty" "" "$(ar_icon nosuchprog)"
check "ar_icon unknown, fallback set -> fallback" "?" "$(ICON_FALLBACK='?' ar_icon nosuchprog)"
# The fallback must never apply to the empty argument (ar_format only asks for
# a real program; ar_icon '' is a guard, not a lookup).
check "ar_icon empty arg -> empty" "" "$(ar_icon '')"
check "ar_icon empty arg -> empty" "" "$(ar_icon '')"

# ICON_MAP overrides win over both the builtin map and the fallback. (Arrays
# cannot be passed as a command prefix -- bash exports them as a flat string --
# so the assignment is a separate statement before the call, as elsewhere.)
check "ICON_MAP overrides builtin glyph" "$g_vim" "$(
  ICON_MAP=("nvim=${g_vim}")
  ar_icon nvim
)"
check "ICON_MAP covers unknown program" "$g_agent" "$(
  ICON_MAP=("nosuchprog=${g_agent}")
  ar_icon nosuchprog
)"

# ICON_STYLE wiring, end to end through ar_format.
check "icon style default is icon+name" "$g_nvim nvim" \
  "$(ICONS_ENABLED=1 ar_format 'nvim' 'nvim')"
check "icon style 'name_and_icon' is icon+name" "$g_git git" \
  "$(ICONS_ENABLED=1 ICON_STYLE=name_and_icon ar_format 'git' 'git status')"
check "icon style 'icon' is glyph only" "$g_nvim" \
  "$(ICONS_ENABLED=1 ICON_STYLE=icon ar_format 'nvim' 'nvim')"
check "icon style 'name' suppresses glyph" "nvim" \
  "$(ICONS_ENABLED=1 ICON_STYLE=name ar_format 'nvim' 'nvim')"

# Icons off (the default) never prepends a glyph, even for a known program.
check "icons off -> no glyph" "nvim" "$(ar_format 'nvim' 'nvim')"
# Unknown program with icons on: plain name, no glyph.
check "icons on, unknown -> plain name" "nosuchprog" \
  "$(ICONS_ENABLED=1 SHOW_PROGRAM_ARGS=0 ar_format 'nosuchprog' 'nosuchprog -d 5')"
# Unknown program with icons on and a fallback set: fallback glyph + name.
check "icons on, fallback set, unknown -> fallback glyph + name" "? nosuchprog" \
  "$(ICONS_ENABLED=1 ICON_FALLBACK='?' SHOW_PROGRAM_ARGS=0 ar_format 'nosuchprog' 'nosuchprog -d 5')"
# An ignored program keeps showing the shell, so it gets no icon either --
# even though sudo has a real glyph in the map and ls would hit the fallback.
check "icons on, ignored program -> shell name, no icon" "zsh" \
  "$(ICONS_ENABLED=1 ar_format 'sudo' 'sudo apt update')"
# Shells get no icon even when the map knows them (zsh is in icons.sh, dash is
# not): precmd names an idle prompt via ar_format "" "", which `[ -n "$prog" ]`
# denies an icon, so a shell glyph here would flip the label between "zsh" and
# "<glyph> zsh" on every reconcile. The last check pins both paths to the same
# string.
check "icons on, shell program -> shell name, no icon" "zsh" \
  "$(ICONS_ENABLED=1 ar_format 'zsh' '-zsh')"
check "icons on, shell missing from map -> no fallback glyph" "dash" \
  "$(ICONS_ENABLED=1 ar_format 'dash' '')"
check "idle prompt and shell reconcile agree with icons on" \
  "$(ICONS_ENABLED=1 ar_format '' '')" \
  "$(ICONS_ENABLED=1 ar_format "$SHELL_NAME" '')"
# SHELL_NAME follows the user's real login shell, which can sit outside the
# fixed SHELLS six (nu, tcsh, elvish, ...). prog == SHELL_NAME is its own
# shell arm, so a reconcile reads the bare name (never the cmdline, even with
# SHOW_PROGRAM_ARGS=1 -- "-elvish" would dodge a name-based comparison) and
# gets no glyph or fallback, keeping it equal to the idle prompt.
check "odd login shell (elvish) gets no icon" "elvish" \
  "$(SHELL_NAME=elvish ICONS_ENABLED=1 ar_format 'elvish' '')"
check "odd login shell outside map (nu) -> no fallback glyph" "nu" \
  "$(SHELL_NAME=nu ICONS_ENABLED=1 ar_format 'nu' '')"
check "odd login shell with args on -> shell name, no icon" "elvish" \
  "$(SHELL_NAME=elvish ICONS_ENABLED=1 SHOW_PROGRAM_ARGS=1 ar_format 'elvish' '-elvish')"
check "idle and odd-shell reconcile agree with args on" \
  "$(SHELL_NAME=elvish ICONS_ENABLED=1 SHOW_PROGRAM_ARGS=1 ar_format '' '')" \
  "$(SHELL_NAME=elvish ICONS_ENABLED=1 SHOW_PROGRAM_ARGS=1 ar_format 'elvish' '-elvish')"
# Under ICON_STYLE=icon a lone fallback glyph would be the whole label, so it
# is suppressed and the plain name kept; name_and_icon still shows "? name"
# (pinned above).
check "icon style 'icon' with unknown program -> plain name" "nosuchprog" \
  "$(ICONS_ENABLED=1 ICON_STYLE=icon ICON_FALLBACK='?' SHOW_PROGRAM_ARGS=0 ar_format 'nosuchprog' 'nosuchprog -d 5')"
# ICON_MAP works end to end through ar_format.
check "ICON_MAP override end to end" "$g_agent nosuchprog" \
  "$(
    ICON_MAP=("nosuchprog=${g_agent}")
    ICONS_ENABLED=1 SHOW_PROGRAM_ARGS=0 ar_format 'nosuchprog' 'nosuchprog -x'
  )"

# A glyph is one codepoint, so "<glyph> <name>" must be truncated by codepoint,
# never mid-byte. node is not name-only, so its cmdline is long enough to cut:
# MAX_NAME_LEN=6 keeps the glyph, the space, and 4 chars of the name.
# Four bytes, one codepoint: the widest ordinary case, and what makes the floor
# fail when it counts bytes.
g_sushi=$(printf '\360\237\215\243')
check "icon+name truncates on codepoint boundary" "$g_node node" \
  "$(ICONS_ENABLED=1 MAX_NAME_LEN=6 SHOW_PROGRAM_ARGS=1 ar_format 'node' 'nodeandmore')"

# The other half of that claim: a glyph plus a label that FITS must be left
# whole. Under a C locale the byte count made this look over budget, and the
# word-boundary trim then cut back to the only space there is, the one behind the
# glyph, leaving the glyph alone on the tab.
check "a fitting icon+title is untouched" "$g_node nöde" \
  "$(LC_ALL=C ICONS_ENABLED=1 MAX_TITLE_LEN=7 ar_format 'node' '' "$(printf 'n\303\266de')")"
# A title that IS over budget still has to keep a word. The half-budget floor
# decides that, and counting it in bytes let a four-byte glyph clear it alone, so
# an over-budget title came back as the glyph and nothing else.
# An array cannot be a command prefix, so this one sets up in a subshell.
check "an over-budget icon+title keeps a word" "$g_sushi abcdef" \
  "$(LC_ALL=C; ICONS_ENABLED=1; ICON_MAP=("node=$g_sushi"); MAX_TITLE_LEN=8; ar_format 'node' '' 'abcdef ghijkl')"

# ---- HIDE_SHELL: every shell-ish case names the tab nothing (issue #5) ----
# The empty label is what makes herdr fall back to rendering its own tab number,
# so these must be EMPTY strings, not $SHELL_NAME and not a space.
check "hide_shell bare prompt" "" "$(HIDE_SHELL=1 ar_format '' '')"
check "hide_shell explicit fish" "" "$(HIDE_SHELL=1 ar_format 'fish' '-fish')"
check "hide_shell explicit bash" "" "$(HIDE_SHELL=1 ar_format 'bash' 'bash')"
check "hide_shell ignored ls" "" "$(HIDE_SHELL=1 ar_format 'ls' 'ls -la')"
# The login shell is hidden too, even outside SHELLS and with args on: without
# the prog == SHELL_NAME arm, "nu" would name itself on reconcile while the
# idle prompt stays blank (the HIDE_SHELL gap from the 0.4.0 release).
check "hide_shell login shell outside SHELLS (nu)" "" \
  "$(SHELL_NAME=nu HIDE_SHELL=1 SHOW_PROGRAM_ARGS=1 ar_format 'nu' '-nu')"
# Only shells are hidden: a real program is named exactly as before.
check "hide_shell keeps nvim" "nvim" "$(HIDE_SHELL=1 ar_format 'nvim' 'nvim README.md')"
check "hide_shell keeps program" "htop" "$(HIDE_SHELL=1 SHOW_PROGRAM_ARGS=0 ar_format 'htop' 'htop -d 5')"
# An alias is a label the user asked for by hand, so it outlives the knob.
check "hide_shell keeps alias on a shell" "sh" \
  "$(
    PROGRAM_ALIASES=("fish=sh")
    HIDE_SHELL=1 ar_format 'fish' '-fish'
  )"
# Off (the default) is the old behavior, unchanged.
check "hide_shell off -> shell name" "zsh" "$(HIDE_SHELL=0 ar_format '' '')"
got=$(bash -c 'SHELL_NAME=zsh; . "$1"; ar_format "" ""' _ "$here/../naming.sh")
check "HIDE_SHELL defaults to off" "zsh" "$got"

# ---- default: SHOW_PROGRAM_ARGS defaults to 0 (regular program -> name only) ----
got=$(bash -c 'SHELL_NAME=zsh; . "$1"; ar_format htop "htop -d 5"' _ "$here/../naming.sh")
check "SHOW_PROGRAM_ARGS defaults to name-only" "htop" "$got"

# ---- config arrays: an intentionally-empty override must survive the guard ----
# naming.sh uses `declare -p`, not `${arr+x}` (which reports a zero-element array
# as unset and would silently restore the default list). Source it fresh in a
# subshell with IGNORED_PROGRAMS=() and confirm `ls` is no longer suppressed.
got=$(bash -c 'SHELL_NAME=zsh; SHOW_PROGRAM_ARGS=1; IGNORED_PROGRAMS=(); . "$1"; ar_format ls "ls -la"' _ "$here/../naming.sh")
check "empty IGNORED_PROGRAMS override survives" "ls -la" "$got"

# ---- ar_title_clean: the task a title describes, or nothing ----
# A coding agent keeps its terminal title on the work in progress, which is the
# one thing naming five tabs after their program cannot do: they all read
# "claude". So the title is the better name -- but only while it says something
# about the work, and an agent spends real time saying nothing (it has just
# started, the session was cleared, it is repeating the directory back). Each
# refusal below is one of those, and each is the difference between a tab that
# tells you what it is doing and one that tells you less than "claude" did.
#
# The non-ASCII expectations are written as UTF-8 byte escapes for the same
# reason as the icon glyphs above: bash 3.2 has no $'\uXXXX', and a pasted
# character is precisely what an editor or a copy-paste has silently eaten before.
spinner=$(printf '\xe2\x9c\xb3')                       # U+2733, one of claude's four
uber=$(printf '\xc3\x9cberpr\xc3\xbcfung der Anfrage') # "Überprüfung der Anfrage"

# The strip and the lowercasing both happen in the jq that lifts a title off a
# pane, so ar_title_clean receives the title already stripped and already folded,
# plus the pane's directory folded the same way. This helper stands in for that jq
# -- tr matches jq's ascii_downcase, which leaves a non-ASCII letter alone -- so
# each check below stays one readable line and the argument order the engine
# passes (see ar_tab_name) is written down once.
# The fold here mirrors the engine's, ASCII only, for the same reason it gives.
# shellcheck disable=SC2018,SC2019
_clean() {
  ar_title_clean "$1" "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" \
    "$(printf '%s' "${3:-}" | tr 'A-Z' 'a-z')" "${2:-}"
}
# And the strip itself, one seam over, through the definition the engine shares
# between its two title lifts (def task in AR_JQ_TASK, which the engine concatenates
# after AR_JQ_CLEAN for the `clean` and `lc` it builds on). The spinner an agent parks
# on the front of its title changes with its status, so a title carried through
# with the glyph still on it would rename the tab on every change. The strip lives
# in jq because jq's character classes know Unicode, where a byte-wise strip in
# bash would read the first byte of "Ü" as non-alphanumeric and eat the letter.
# tests/test_reconcile.sh scenarios 28 and 32 assert the same thing end to end, on
# each of the two paths that lift a title off a pane.
# The optional second argument is the brand the agent in the pane stamps on the
# front of its titles, which the engine looks up per pane (see _brand); "" is every
# agent that stamps none, which is what every check written before this one passes.
_task() { printf '%s' "$1" | jq -Rr --arg b "${2:-}" "$AR_JQ_CLEAN$AR_JQ_TASK"'task($b)'; }
# And the lookup, over the real TITLE_BRANDS: the engine joins the array with
# newlines and hands it to each lift as one argument, so a map that comes out
# empty is a strip that never runs.
_brand() { printf '%s\n' "${TITLE_BRANDS[@]}" \
  | jq -Rrs --arg a "$1" "$AR_JQ_CLEAN$AR_JQ_TASK"'brandmap[$a | lc] // ""'; }

check "leading spinner is stripped" "Squash merge command" \
  "$(_task "$spinner Squash merge command")"
# Only the LEADING run of non-alphanumerics goes: punctuation inside the sentence
# is the agent's own wording and stays.
check "punctuation inside a title survives" "Fix: the parser, again" \
  "$(_task 'Fix: the parser, again')"
# A title that is nothing but a spinner strips away to nothing, which is what
# leaves the empty-title refusal below to cover that case whole.
check "a title that is only a spinner strips to nothing" "" "$(_task "$spinner ")"
# Titles are prose in whatever language the user works in, so a non-ASCII letter
# must survive the strip intact -- both behind a spinner and as the first thing in
# the title, which is the byte the naive strip ate.
check "a multibyte title survives the spinner strip" "$uber" "$(_task "$spinner$uber")"
check "a multibyte first letter is not eaten" "$uber" "$(_task "$uber")"

# ---- the brand an agent stamps on its own titles ----

# oh-my-pi puts its brand FIRST and the status glyph second: "PI SP <spinner> SP
# label" while it works, "PI SP > SP label" when the turn is yours, "PI SP ! SP
# label" when it wants you, and "PI: SP label" with its title state off
# (buildTerminalTitleWithState in oh-my-pi's title-generator.ts). The strip above
# only takes a LEADING run of non-alphanumerics, and jq reads the brand as a
# letter, so it stopped on character one and every one of those states reached the
# tab as a different label -- a rename on each status change, spinner and all
# (issue #12). Naming the brand takes it off and leaves the separator to the strip
# that was already there. Built from its UTF-8 bytes for the same reason the
# spinner is: a literal glyph is what an editor eats without saying so.
pi=$(printf '\317\200')             # the brand, U+03C0
braille=$(printf '\342\240\213')   # one of its ten working frames, U+280B

check "the brand and the spinner both go" "Fix the parser bug" \
  "$(_task "$pi $braille Fix the parser bug" "$pi")"
# Every other status has to reduce to the SAME label, because that is the rename
# the tab would otherwise do on each of them. A second working frame is the same
# string shape as the first and would pin nothing; the separators below are not.
check "the your-turn separator reads the same" "Fix the parser bug" \
  "$(_task "$pi > Fix the parser bug" "$pi")"
check "the needs-you separator reads the same" "Fix the parser bug" \
  "$(_task "$pi ! Fix the parser bug" "$pi")"
# With the title state off the separator is a colon against the brand, no space.
check "the title-state-off form reads the same" "Fix the parser bug" \
  "$(_task "$pi: Fix the parser bug" "$pi")"
# A brand with no label behind it is an agent with nothing to report, and it has
# to stay empty so the refusals below hand the tab back to the program name.
check "a brand and separator alone strip to nothing" "" "$(_task "$pi >" "$pi")"
check "a brand alone strips to nothing" "" "$(_task "$pi" "$pi")"
# The brand comes off the FRONT of a title, not out of a word that starts with it.
check "a word starting with the brand is kept" "${pi}calc rewrite" \
  "$(_task "${pi}calc rewrite" "$pi")"
# The brand belongs to the agent that stamps it: the same title from an agent with
# no brand configured is that agent's own wording and stays whole.
check "an unbranded agent keeps the title" "$pi $braille oxc" \
  "$(_task "$pi $braille oxc" "")"
# The brand is compared against the FRONT of the title, so anything in front of it
# has to be gone by then: herdr's own leading whitespace, a control character clean
# turned into a space, or a glyph another agent might park there. Without the strip
# ahead of the compare this whole title reaches the tab, brand and glyph included.
check "a brand behind whitespace still goes" "oxc" "$(_task " $pi $braille oxc" "$pi")"
check "a brand behind a spinner too"        "oxc" "$(_task "$braille $pi oxc" "$pi")"
# An ASCII brand is matched ignoring case, as every other title compare is.
check "an ASCII brand folds case" "x" "$(_task 'PI > x' 'pi')"

# The lookup that picks the brand: keyed by herdr's agent kind, which is "pi" for
# pi and "omp" for oh-my-pi (both are canonical kinds in herdr's src/detect/mod.rs).
check "pi's brand is configured"        "$pi" "$(_brand pi)"
check "oh-my-pi's kind maps to it too"  "$pi" "$(_brand omp)"
check "the kind is folded like the rest" "$pi" "$(_brand OMP)"
check "an agent with no brand gets none" "" "$(_brand claude)"

# End to end over the seam: the reported case. oh-my-pi with no session title yet
# labels itself after the directory it sits in, so once the brand is off, what is
# left is the pane's own cwd -- which the refusals below already knew to hand back
# to the program name. Before the brand strip this reached the tab as
# "PI <spinner> oxc" and no refusal could see it.
check "brand plus spinner plus cwd is refused" "" \
  "$(_clean "$(_task "$pi $braille oxc" "$pi")" omp oxc)"

check "a task title is the answer" "Squash merge command" \
  "$(_clean 'Squash merge command' claude api)"

# The refusals. Each returns "" so naming falls back to the program name.
check "an empty title says nothing" "" "$(_clean '' claude api)"
# A bare number is herdr's own tab label read back off the pane, not a task.
check "a bare number is refused" "" "$(_clean '3' claude api)"
# ... but a number is only a refusal when it is the WHOLE title: "3 files
# changed" is a task, and a prefix test would have thrown it away.
check "a title that merely starts with a digit is kept" "3 files changed" \
  "$(_clean '3 files changed' claude api)"
# The agent naming itself, in the three shapes it does that. Every comparison is
# case-insensitive because the agent chooses the capitalization, not the user.
check "the agent kind is refused" "" "$(_clean 'claude' claude api)"
check "the agent kind, any case" "" "$(_clean 'Claude' claude api)"
# "<kind> code" is refused without being listed, which is what covers an agent
# whose startup title TITLE_IGNORE has never heard of. droid is deliberately not
# in the default list, so this pins the rule rather than the list.
check "the kind followed by code is refused" "" "$(_clean 'Droid Code' droid api)"
check "the pane directory repeated back is refused" "" \
  "$(_clean 'api' claude api)"
check "the pane directory, any case" "" "$(_clean 'API' claude api)"

# A title that is a PATH says where the agent sits, not what it is doing, and an
# agent with nothing to report is exactly where that comes from. The list of
# refusals catches the bare directory name; these catch the path it ends. The last
# case is the one that has to survive: a task description is allowed a slash.
check "an absolute path title is refused"  "" "$(_clean "/home/u/dev/api" claude api)"
# The tilde is DATA here: this is the title an agent set, and expanding it would
# throw away the case under test.
# shellcheck disable=SC2088
check "a tilde path title is refused"      "" "$(_clean "~/dev/api" claude api)"
# The tilde is DATA here: this is the title an agent set, and expanding it would
# throw away the case under test.
# shellcheck disable=SC2088
check "a dot directory title is refused"   "" "$(_clean "~/.config" claude .config)"
check "a task with a slash is kept"        "Fix CI/CD pipeline" \
  "$(_clean "Fix CI/CD pipeline" claude myproj)"
# The tail rule reads a path, not a sentence that ends in one. This description
# ends in exactly the directory it works on, which is the case the whitespace
# guard exists for.
check "a description ending in the dir is kept" "Fix build for services/payments" \
  "$(_clean "Fix build for services/payments" claude payments)"
# The tilde is DATA here: this is the title an agent set, and expanding it would
# throw away the case under test.
# shellcheck disable=SC2088
check "a bare path with no slash left is refused" "" "$(_clean "~/.config" claude .config)"
# A trailing slash names the same directory, and the tail of a string that ends in
# one is empty -- which matches no directory and would walk the whole path past
# every refusal above.
check "a trailing slash does not walk a path past it" "" "$(_clean "/home/u/dev/api/" claude api)"
# The tilde is DATA here: this is the title an agent set, and expanding it would
# throw away the case under test.
# shellcheck disable=SC2088
check "nor does one on a tilde path"                  "" "$(_clean "~/dev/api/" claude api)"
# The tilde is DATA here: this is the title an agent set, and expanding it would
# throw away the case under test.
# shellcheck disable=SC2088
check "nor on a dot directory"                        "" "$(_clean "~/.config/" claude .config)"
# The guard trims ONE trailing slash, so a description is still read as a sentence.
check "a task ending in a slash is still kept" "Fix CI/CD pipeline/" \
  "$(_clean "Fix CI/CD pipeline/" claude myproj)"
# A pane herdr reports no directory for must not turn an empty comparison into a
# refusal: every title would match it and no agent tab would ever get a name.
check "no pane directory refuses nothing" "Squash merge command" \
  "$(_clean 'Squash merge command' claude '')"
# TITLE_IGNORE catches the rest, including titles that name an agent other than
# the one in the pane (an agent launched from a claude pane leaves one behind).
check "a TITLE_IGNORE entry is refused" "" "$(_clean 'New Session' claude api)"
check "a TITLE_IGNORE entry, any case" "" "$(_clean 'UNTITLED' claude api)"
check "another agent's name is still refused" "" "$(_clean 'opencode' claude api)"
# A non-ASCII title must not accidentally MATCH a refusal either: the fold is
# ASCII-only on both sides, exactly as jq's ascii_downcase is.
check "a multibyte title survives" "$uber" "$(_clean "$uber" claude api)"

# TITLE_IGNORE is compared against a title that is already lowercase, so the list
# is lowercased too rather than documented as case-sensitive: README and
# config.example.sh have always promised case-insensitive matching, and before the
# fold an entry a user wrote the way it reads matched nothing at all. Both checks
# need a fresh shell -- the list is guarded with `declare -p` (see
# IGNORED_PROGRAMS above) and folded once per run, so an assignment here would
# come too late for either.
got=$(bash -c 'SHELL_NAME=zsh; TITLE_IGNORE=(); . "$1"; ar_title_clean "New Session" "new session" api claude' _ "$here/../naming.sh")
check "empty TITLE_IGNORE override survives" "New Session" "$got"
got=$(bash -c 'SHELL_NAME=zsh; TITLE_IGNORE=("Ready To Code"); . "$1"; ar_title_clean "Ready to code" "ready to code" api claude' _ "$here/../naming.sh")
check "a mixed-case TITLE_IGNORE entry is folded" "" "$got"

# ---- ar_format with a title: the task IS the label ----
check "a title becomes the label" "Squash merge command" \
  "$(ar_format 'claude' '' 'Squash merge command')"
# ---- TITLE_STYLE: the agent alongside its task ----
# Every agent shares one robot glyph and a title replaces the program name, so a
# session of several agents has nothing left saying which is on which task.
check "task alone is the default" "auth flow" \
  "$(ar_format 'claude' '' 'auth flow')"
check "name_and_task keeps both" "claude:auth flow" \
  "$(TITLE_STYLE=name_and_task ar_format 'claude' '' 'auth flow')"
# An alias IS wanted here, unlike the plain-title rule below: asking for the name
# is asking for the name you chose for it.
check "the alias is what shows" "cc:auth flow" \
  "$(PROGRAM_ALIASES=("claude=cc"); TITLE_STYLE=name_and_task ar_format 'claude' '' 'auth flow')"
check "an unaliased agent shows its kind" "codex:auth flow" \
  "$(PROGRAM_ALIASES=("claude=cc"); TITLE_STYLE=name_and_task ar_format 'codex' '' 'auth flow')"
# The name is charged to MAX_TITLE_LEN, so the task gives up the room and the tab
# does not grow. Without a title there is nothing to prefix, and "cc:cc" would say
# nothing twice.
# 18 characters, three of them the name, and the word-boundary trim then takes
# the partial word: without the prefix the same title keeps "why" as well.
check "the name is priced into the budget" "cc:Investigate" \
  "$(PROGRAM_ALIASES=("claude=cc"); MAX_TITLE_LEN=18 TITLE_STYLE=name_and_task ar_format 'claude' '' 'Investigate why the nightly job fails')"
check "and the same title without it keeps more" "Investigate why" \
  "$(MAX_TITLE_LEN=18 ar_format 'claude' '' 'Investigate why the nightly job fails')"
# A REFUSED title, not an absent one: ar_title_clean turns the agent naming
# itself into the empty string, and only then does the program name path run.
check "a refused title is not prefixed" "cc" \
  "$(PROGRAM_ALIASES=("claude=cc"); TITLE_STYLE=name_and_task ar_format 'claude' 'claude' \
     "$(ar_title_clean 'Claude Code' 'claude code' 'api' 'claude')")"

# The prefix is all or nothing. Truncation treats the label as prose, so a name
# with no room for a task was kept INSTEAD of one -- name_and_task rendering as
# name only, which is the single thing it must not do. Below the floor the name
# goes; above it both appear.
check "no room for a task drops the name" "auth flow" \
  "$(MAX_TITLE_LEN=13 TITLE_STYLE=name_and_task ar_format 'cursor-agent' '' 'auth flow rewrite')"
check "room for both keeps both" "cursor-agent:auth" \
  "$(MAX_TITLE_LEN=20 TITLE_STYLE=name_and_task ar_format 'cursor-agent' '' 'auth flow rewrite')"
check "MIN_TASK_LEN moves the floor" "cursor-agent:auth" \
  "$(MIN_TASK_LEN=4 MAX_TITLE_LEN=17 TITLE_STYLE=name_and_task ar_format 'cursor-agent' '' 'auth flow rewrite')"
# A name with a space in it was cut at the space and shown alone; it is dropped now.
check "a name too wide is dropped, not cut" "auth flow" \
  "$(PROGRAM_ALIASES=("claude=Claude Code"); MAX_TITLE_LEN=12 TITLE_STYLE=name_and_task ar_format 'claude' '' 'auth flow')"
# An alias of nothing but blanks left a bare colon in front of the task, the
# scrub that would have removed it running after the prefix was decided.
check "an alias that scrubs to nothing is no prefix" "auth flow" \
  "$(PROGRAM_ALIASES=("claude= "); TITLE_STYLE=name_and_task ar_format 'claude' '' 'auth flow')"
check "an unknown style reads as task" "auth flow" \
  "$(TITLE_STYLE=sideways ar_format 'claude' '' 'auth flow')"

# The glyph and its space come out of the same budget, and after the prefix was
# decided: the floor was short by their width on every iconned tab, so a task of
# four characters shipped where seven was promised.
check "the glyph is charged to the prefix floor" "$(printf '\363\260\232\251') auth flow rewrite" \
  "$(ICONS_ENABLED=1 MAX_TITLE_LEN=20 TITLE_STYLE=name_and_task ar_format 'cursor-agent' '' 'auth flow rewrite')"
check "and a budget that seats both still does" "$(printf '\363\260\232\251') claude:auth flow" \
  "$(ICONS_ENABLED=1 MAX_TITLE_LEN=28 TITLE_STYLE=name_and_task ar_format 'claude' '' 'auth flow')"
# ICON_STYLE=name draws no glyph, so there is nothing to charge for.
check "no glyph drawn charges nothing" "cursor-agent:auth" \
  "$(ICONS_ENABLED=1 ICON_STYLE=name MAX_TITLE_LEN=20 TITLE_STYLE=name_and_task ar_format 'cursor-agent' '' 'auth flow rewrite')"

# A multiword name is refused whatever the budget, not only when it is too wide
# for one: the trim cuts at the LAST space in the label, which is inside such a
# name, and it took the task with it -- "SuperLongAgent" alone on the tab.
check "a multiword name is refused" "authenticationflowrefactoring" \
  "$(PROGRAM_ALIASES=("claude=SuperLongAgent Extra"); MAX_TITLE_LEN=29 TITLE_STYLE=name_and_task ar_format 'claude' '' 'authenticationflowrefactoring')"
check "even where it would have fitted" "auth flow" \
  "$(PROGRAM_ALIASES=("claude=Claude Code"); MAX_TITLE_LEN=28 TITLE_STYLE=name_and_task ar_format 'claude' '' 'auth flow')"
# The title is taken ahead of PROGRAM_ALIASES on purpose. An alias shortening
# "claude" to "cl" asks for a tidier program name, not for the work to be hidden;
# AGENT_TITLES=0 is the knob for wanting program names, and the pair below pins
# both directions of that.
check "a title beats an alias" "Squash merge command" \
  "$(
    PROGRAM_ALIASES=("claude=cl")
    ar_format 'claude' 'claude' 'Squash merge command'
  )"
check "with no title the alias still wins" "cl" \
  "$(
    PROGRAM_ALIASES=("claude=cl")
    ar_format 'claude' 'claude'
  )"
# Icons annotate the program the tab is running, which the title does not change:
# a task-named claude tab still reads as an agent tab in the tab bar.
check "a title still gets the program's icon" "$g_agent Squash merge command" \
  "$(ICONS_ENABLED=1 ar_format 'claude' '' 'Squash merge command')"

# A title is a sentence and needs more room than a command name, so it is cut at
# MAX_TITLE_LEN (28) rather than MAX_NAME_LEN (20). This one is 24 characters:
# under the command budget it would lose its last word for no reason.
check "a title gets the title budget" "Rebase onto main branch!" \
  "$(ar_format 'claude' '' 'Rebase onto main branch!')"
# Over the budget it is cut back to a word boundary, because "Investigate the
# flaky reconc" reads as a rendering bug where "Investigate the flaky" reads as a
# summary.
check "an over-long title is cut at a word" "Investigate the flaky" \
  "$(ar_format 'claude' '' 'Investigate the flaky reconcile test')"
# The word boundary is only worth it while most of the budget survives: one long
# word after a short one would leave "Fix", which says less than a cut word does.
check "a word boundary that leaves too little is not used" "Fix aaaaaaaaaaaaaaaa" \
  "$(MAX_TITLE_LEN=20 ar_format 'claude' '' 'Fix aaaaaaaaaaaaaaaaaaaaaa')"
# And the word cut belongs to titles alone: a command line is not prose, and
# dropping its last argument would be losing information, not tidying. The budget
# and the boundary here are the ones the rule WOULD fire on, so this fails if the
# cut ever escapes the title path.
check "a command line is still cut mid-word" "psql -c aaaaaaaaaaaaaaaaa bb" \
  "$(MAX_NAME_LEN=28 SHOW_PROGRAM_ARGS=1 ar_format 'psql' 'psql -c aaaaaaaaaaaaaaaaa bbbbbbbbbbbb')"

# The knob and the budget both default on/28 in naming.sh, so a user who has
# never heard of either gets task-named agent tabs. AGENT_TITLES is read by the
# engine (ar_tab_name), which is why ar_format takes the title as an argument
# instead: with the knob off no title is passed and every program rule applies as
# before, pinned by the alias check above and end to end in tests/test_reconcile.sh.
got=$(bash -c '. "$1"; printf %s "$AGENT_TITLES"' _ "$here/../naming.sh")
check "AGENT_TITLES defaults to on" "1" "$got"
got=$(bash -c '. "$1"; printf %s "$MAX_TITLE_LEN"' _ "$here/../naming.sh")
check "MAX_TITLE_LEN defaults to 28" "28" "$got"
# ... and that 28 is MAX_NAME_LEN + 8, not a number of its own: somebody who
# narrows the label budget for a narrow tab bar means the titles too, and a fixed
# default would have left them at 28 while command names shrank to 12.
got=$(bash -c 'MAX_NAME_LEN=12; . "$1"; printf %s "$MAX_TITLE_LEN"' _ "$here/../naming.sh")
check "MAX_TITLE_LEN follows MAX_NAME_LEN" "20" "$got"
# The derivation is only the DEFAULT, so a config that sets both still gets both.
got=$(bash -c 'MAX_NAME_LEN=12; MAX_TITLE_LEN=40; . "$1"; printf %s "$MAX_TITLE_LEN"' _ "$here/../naming.sh")
check "an explicit MAX_TITLE_LEN still wins" "40" "$got"

# ======================================================================
# The context half of a label: where the work is happening.
# ======================================================================
# A tab says WHAT is running; on its own that leaves five "claude" tabs across
# three checkouts telling each other apart by position alone. The context is the
# other half -- the directory the pane sits in, the branch it has checked out, the
# machine it reached over ssh -- joined in front of the program with CONTEXT_SEP.

# ---- ar_context_dir: the directory a pane sits in ----
HOME_SAVE=$HOME
HOME=/Users/tester
check "a project directory names the context" "api" \
  "$(ar_context_dir '/Users/tester/dev/api' 'web')"
# The home directory and the filesystem root are where a shell sits when it is
# nowhere in particular, and "tester" or "/" says nothing a tab bar has room for.
check "the home directory says nothing" "" "$(ar_context_dir '/Users/tester' 'web')"
check "the filesystem root says nothing" "" "$(ar_context_dir '/' 'web')"
check "no directory at all says nothing" "" "$(ar_context_dir '' 'web')"
# A relative path is not a directory this plugin can reason about: it is whatever
# the reader's cwd happens to make it, and herdr reports absolute paths.
check "a relative path says nothing" "" "$(ar_context_dir 'dev/api' 'web')"
# herdr shows the workspace above its tabs, so a tab in the workspace named after
# its own directory spends half its width repeating what is already on screen.
check "the workspace name is not repeated" "" "$(ar_context_dir '/Users/tester/dev/api' 'api')"
check "the repeat is matched ignoring ASCII case" "" "$(ar_context_dir '/Users/tester/dev/API' 'api')"
# ASCII, and only ASCII, whatever locale the process was launched under. herdr
# may start the plugin with no LC_* while the shell hook inherits the user's
# UTF-8: a fold that followed the locale would have the two naming paths
# disagree about this tab, which is a tab that flips on every prompt.
for _loc in C en_US.UTF-8; do
  check "non-ASCII case is not folded (LC_ALL=$_loc)" "ÄPI" \
    "$(LC_ALL=$_loc ar_context_dir '/Users/tester/dev/ÄPI' 'äpi')"
  check "ASCII case still is (LC_ALL=$_loc)" "" \
    "$(LC_ALL=$_loc ar_context_dir '/Users/tester/dev/API' 'api')"
done
# herdr names a worktree workspace after the branch with the convention in front
# of it stripped, so its directory ends with the workspace's name and the two are
# the same place: "bugfix-proj-482-fix" under a workspace called
# "proj-482-fix" is not a tab that has gone anywhere.
check "a worktree prefix is the same place" "" \
  "$(ar_context_dir '/Users/tester/dev/wt/bugfix-proj-482-fix' 'proj-482-fix')"
check "and the separator is required" "aaaproj-482-fix" \
  "$(MAX_CONTEXT_LEN=20 ar_context_dir '/Users/tester/dev/wt/aaaproj-482-fix' 'proj-482-fix')"
# The same place spelled with a different separator. herdr's worktree manager
# names a workspace after the BRANCH, slashes and all, while the worktree
# directory the branch is checked out in gets those slashes flattened to
# hyphens -- so the two say one thing in two spellings, and a compare that read
# them character for character put the directory back in the tab.
check "a slash and a hyphen are the same separator" "" \
  "$(ar_context_dir '/Users/tester/dev/wt/feature-proj-482-fix' 'feature/proj-482-fix')"
check "so are a dot and an underscore" "" \
  "$(ar_context_dir '/Users/tester/dev/api_docs' 'api.docs')"
check "and a worktree prefix across spellings is still the same place" "" \
  "$(ar_context_dir '/Users/tester/dev/wt/bugfix-proj-482-fix' 'proj/482/fix')"
# Folding the separators does not weaken the rule that wanted one: what stands
# between the prefix and the workspace's name must still BE a separator.
check "the separator is still required across spellings" "aaaproj-482-fix" \
  "$(MAX_CONTEXT_LEN=20 ar_context_dir '/Users/tester/dev/wt/aaaproj-482-fix' 'proj/482/fix')"
# The other direction is a different directory, not a prefix convention: a tab in
# api-docs under a workspace called api has genuinely gone somewhere.
check "a longer name is not a prefix convention" "api-docs" \
  "$(ar_context_dir '/Users/tester/dev/api-docs' 'api')"
# ... and only those, so a tab whose directory has left its workspace
# behind is exactly the one that keeps saying where it is.
check "a different directory still shows" "api" "$(ar_context_dir '/Users/tester/dev/api' 'api-docs')"
# A workspace nobody has named (or a path with no workspace to compare) dedupes
# against nothing.
check "no workspace name dedupes nothing" "api" "$(ar_context_dir '/Users/tester/dev/api' '')"
check "a trailing slash names the same directory" "api" \
  "$(ar_context_dir '/Users/tester/dev/api/' 'web')"
# The context gets its own budget: it is a project name, not a sentence, and the
# activity beside it still needs the room MAX_NAME_LEN gives it.
check "a long directory is cut to MAX_CONTEXT_LEN" "aaaaaaaaaaaa" \
  "$(ar_context_dir '/Users/tester/dev/aaaaaaaaaaaaaaaaaaaa' 'web')"
# A directory is reduced the way a branch is, and for the same reason: a worktree
# is usually named after the work in it, so a cut through the middle of one
# ("bugfix-proj-") throws away the part that identifies it.
check "an over-long directory yields its issue key" "PROJ-482" \
  "$(ar_context_dir '/Users/tester/dev/wt/bugfix-proj-482-fix-rev-discrepancy' 'web')"
check "and otherwise ends on a whole word" "herdr-prompt" \
  "$(ar_context_dir '/Users/tester/dev/herdr-prompt-picker' 'web')"
check "MAX_CONTEXT_LEN is configurable" "aaaa" \
  "$(MAX_CONTEXT_LEN=4 ar_context_dir '/Users/tester/dev/aaaaaaaaaaaaaaaaaaaa' 'web')"
# One switch turns the whole context half off, and it lives here rather than at
# each call site so the reconcile and the shell hook cannot disagree about it.
check "TAB_CONTEXT=0 turns the context off" "" \
  "$(TAB_CONTEXT=0 ar_context_dir '/Users/tester/dev/api' 'web')"
HOME=$HOME_SAVE

# ---- ar_branch_label: which slice of a project a tab is on ----
# A branch qualifies the context: "api › feat/oauth › nvim" says which slice of
# the project the tab is on, where the directory alone says only which project.
check "a branch that fits is left whole" "feat/oauth" "$(ar_branch_label 'feat/oauth' 'main')"
# The same claim under a C locale, where bash measures the name in bytes: a
# non-ASCII branch inside its budget looked over it, and the reduction cut it back
# to the first separator. Eleven codepoints, twenty bytes, budget of twelve.
check "a fitting multibyte branch is left whole" "абв-где-жзи" \
  "$(LC_ALL=C MAX_BRANCH_LEN=12 ar_branch_label "$(printf '\320\260\320\261\320\262-\320\263\320\264\320\265-\320\266\320\267\320\270')" 'main')"
# And one that genuinely overflows must be cut at the same place in either
# locale: deciding to shorten was fixed before the offset the cut uses was.
# Fifteen codepoints in a budget of twelve, so it reduces either way.
check "an overlong multibyte branch cuts alike" "абв-где" \
  "$(LC_ALL=C MAX_BRANCH_LEN=12 ar_branch_label "$(printf '\320\260\320\261\320\262-\320\263\320\264\320\265-\320\266\320\267\320\270\320\272\320\273\320\274\320\275')" 'main')"
# The trunk says nothing -- every tab in the repository would carry it alike --
# and which branch that is comes from the repository rather than from a list of
# names, so a team whose trunk is "develop" gets the same silence.
check "the trunk contributes nothing" "" "$(ar_branch_label 'main' 'main')"
check "a non-default trunk name is silent too" "" "$(ar_branch_label 'develop' 'develop')"
check "a branch called main off a develop trunk shows" "main" "$(ar_branch_label 'main' 'develop')"
# A repository that records no default falls back to the conventional trunk
# names (see TRUNK_BRANCHES below), so this one is quiet and a branch that is not
# one of them still shows.
check "a repository with no default falls back to the list" "" "$(ar_branch_label 'main' '')"
# Compared exactly, because git refs are: "Main" beside a "main" trunk is a
# different branch and has something to say.
check "the trunk compare is exact" "Main" "$(ar_branch_label 'Main' 'main')"
# An issue key identifies the work whatever convention wraps it, so it wins
# outright over cutting -- and it is the one value allowed past the budget,
# because half a key identifies nothing.
check "an over-long branch yields its issue key" "MC-13675" \
  "$(ar_branch_label 'bugfix-asa-cpanel-uapi-mc-13675' 'main')"
check "the key is upper-cased" "PROJ-517" \
  "$(ar_branch_label 'feature/proj-517-qa-bot-programmatic' 'main')"
# Failing a key, the namespace goes first (it is the half every branch shares)
# and what is left is cut at a whole word.
check "a long branch loses its namespace and its tail" "filter" \
  "$(ar_branch_label 'fix/filter-sentry-errors-in-the-agent' 'main')"
check "and is cut at a word boundary" "reticulate" \
  "$(ar_branch_label 'reticulate-splines-thoroughly' 'main')"
# A hyphen-and-digits pair that is not a key must not be mistaken for one:
# "utf-8" has too few digits, "release" too many letters.
check "utf-8 is not an issue key" "utf-8-decode" \
  "$(MAX_BRANCH_LEN=30 ar_branch_label 'utf-8-decode' 'main')"
check "MAX_BRANCH_LEN=0 leaves branches out" "" \
  "$(MAX_BRANCH_LEN=0 ar_branch_label 'feat/oauth' 'main')"
check "SHOW_BRANCH=0 leaves branches out" "" \
  "$(SHOW_BRANCH=0 ar_branch_label 'feat/oauth' 'main')"
# TAB_CONTEXT is the switch for the whole context half, branch included: a user
# who asked for none of it did not ask for some of it.
check "TAB_CONTEXT=0 leaves branches out too" "" \
  "$(TAB_CONTEXT=0 ar_branch_label 'feat/oauth' 'main')"
check "a detached hash passes through" "3f2a1b9" "$(ar_branch_label '3f2a1b9' 'main')"
# A repository that records no default branch -- one cloned without an
# origin/HEAD, or one that was never cloned -- would otherwise show its branch on
# every tab alike, which is the column of noise the trunk rule exists to prevent.
# Only as a fallback: a repository that DOES record one is believed over any list.
check "no recorded default: a conventional trunk is still quiet" "" \
  "$(ar_branch_label 'main' '')"
check "... and so are the others" "" "$(ar_branch_label 'develop' '')"
check "but a real branch still shows" "feat/oauth" "$(ar_branch_label 'feat/oauth' '')"
check "a recorded default is believed over the list" "main" \
  "$(ar_branch_label 'main' 'develop')"
check "TRUNK_BRANCHES is configurable" "main" \
  "$(TRUNK_BRANCHES=(release) ar_branch_label 'main' '')"
# A first word too long to fit has no separator to cut back to, so it is cut
# where the budget ends -- on a codepoint boundary, which is the one case here
# that pays for a jq.
check "one long word is cut where the budget ends" "aaaaaaaaaaaa" \
  "$(ar_branch_label 'aaaaaaaaaaaaaaaaaaaa' 'main')"
check "a multibyte branch is not sliced in half" "über-lange" \
  "$(ar_branch_label 'über-lange-namen' 'main')"
# ar_upper raises ASCII letters and leaves everything else alone.
check "upper: a key" "MC-13675" "$(ar_upper 'mc-13675')"
check "upper: mixed already" "PROJ-517" "$(ar_upper 'Proj-517')"
check "upper: non-letters survive" "A.B_C/D" "$(ar_upper 'a.b_c/d')"
check "nothing checked out, nothing shown" "" "$(ar_branch_label '' 'main')"

# ---- a branch that repeats what is already on screen ----
# herdr shows the workspace above the tabs and the tab shows its own context, so
# a branch that says the same thing again spends width on what the reader can
# already see. A worktree named after its branch is the common case.
check "a branch the workspace already says is dropped" "Herdr auto title" \
  "$(ar_label '/Users/tester/dev/wt/auto-title' 'auto-title' 'auto-title' 'claude' '' 'Herdr auto title')"
check "a branch the directory already says is dropped" "PROJ-482 › claude" \
  "$(ar_label '/Users/tester/dev/wt/bugfix-proj-482-fix' 'other' 'PROJ-482' 'claude' '')"
check "the compare ignores ASCII case" "auto-title › claude" \
  "$(ar_label '/Users/tester/dev/wt/auto-title' 'other' 'AUTO-TITLE' 'claude' '')"
check "a branch that says something new stays" "api › feat/oauth › claude" \
  "$(ar_label '/Users/tester/dev/api' 'other' 'feat/oauth' 'claude' '')"
# Separators fold here for the same reason they fold in the context: a branch
# and the directory it is checked out in are one name in two spellings.
check "a branch the directory says in another spelling is dropped" "feat-oauth › claude" \
  "$(ar_label '/Users/tester/dev/feat-oauth' 'other' 'feat/oauth' 'claude' '')"

# ---- ar_ssh_host: the machine a pane reached ----
# A pane running ssh is about the machine on the other end, not the directory it
# was launched from. Options are parsed rather than guessed at, because the first
# word after `ssh` is as often an option's value as it is a host.
check "the plain form" "prod-01" "$(ar_ssh_host 'ssh prod-01')"
check "an option with a separate value" "prod-01" "$(ar_ssh_host 'ssh -p 2222 prod-01')"
check "an option with an attached value" "prod-01" "$(ar_ssh_host 'ssh -p2222 prod-01')"
check "a switch" "prod-01" "$(ar_ssh_host 'ssh -4 prod-01')"
# Short options cluster, and the one that takes a value need not be alone in the
# word: `-4p 2222` is IPv4, port 2222. Reading only a lone letter as a value flag
# named one tab after its port number.
check "a cluster whose last letter takes a value" "prod-01" "$(ar_ssh_host 'ssh -4p 2222 prod-01')"
check "a cluster with the value attached" "prod-01" "$(ar_ssh_host 'ssh -4p2222 prod-01')"
check "a cluster of switches only" "prod-01" "$(ar_ssh_host 'ssh -46 prod-01')"
# An IPv6 address is bracketed, and the colons inside are the address rather than
# a port.
check "a bracketed IPv6 host" "[2001:db8::1]" "$(MAX_CONTEXT_LEN=20 ar_ssh_host 'ssh [2001:db8::1]')"
check "... with a port after it" "[2001:db8::1]" \
  "$(MAX_CONTEXT_LEN=20 ar_ssh_host 'ssh [2001:db8::1]:2222')"
# An option whose value is a COMMAND cannot be split back out of a flattened
# command line: the words inside it look exactly like arguments of ssh itself,
# and a ProxyCommand names another machine entirely -- the parse would take the
# bastion for the destination. Refused rather than guessed at, so the tab reads
# "ssh", which is what it read before any of this existed.
check "a quoted proxy command is refused" "" \
  "$(ar_ssh_host 'ssh -o ProxyCommand="ssh -W %h:%p bastion" prod-01')"
# ... and refused the same way when the quotes are already gone, which is how the
# reconcile sees it: a shell strips them before exec, so herdr joins an argv that
# no longer has them. The two naming paths have to reach the same label from the
# two shapes, or the tab flips between them on every prompt.
check "an unquoted proxy command is refused too" "" \
  "$(ar_ssh_host 'ssh -o ProxyCommand=ssh -W %h:%p bastion prod-01')"
check "and by whatever case it was written in" "" \
  "$(ar_ssh_host 'ssh -o proxycommand=ssh -W %h:%p bastion prod-01')"
check "a remote command is refused as well" "" \
  "$(ar_ssh_host 'ssh -o RemoteCommand=tail -f /var/log/syslog prod-01')"
# ssh takes the setting attached to the flag too, and that form has to be read
# the same way: it was the flag's own word that told us a setting was coming.
check "an attached proxy command is refused" "" \
  "$(ar_ssh_host 'ssh -oProxyCommand=ssh -W %h:%p bastion prod-01')"
check "an attached ordinary setting still parses" "prod-01" \
  "$(ar_ssh_host 'ssh -oStrictHostKeyChecking=no prod-01')"
# An ordinary -o option has a value that cannot hold a space, so it parses.
check "an ordinary -o option still parses" "prod-01" \
  "$(ar_ssh_host 'ssh -o StrictHostKeyChecking=no prod-01')"
# ... quoted or not, again because the two paths see it both ways.
check "quoted or not, the same answer" "prod-01" \
  "$(ar_ssh_host 'ssh -o "StrictHostKeyChecking=no" prod-01')"
check "a long option's value" "prod-01" "$(ar_ssh_host 'ssh -o StrictHostKeyChecking=no prod-01')"
# The user is dropped: root@prod-01 and deploy@prod-01 are the same machine, and
# a tab bar has no room to say who is logged in.
check "the user is dropped" "prod-01" "$(ar_ssh_host 'ssh deploy@prod-01')"
# Everything after the destination is the remote command, which the machine's own
# terminal title is what reports.
check "a remote command is not the host" "prod-01" \
  "$(ar_ssh_host 'ssh prod-01 tail -f /var/log/syslog')"
check "-- ends the options" "prod-01" "$(ar_ssh_host 'ssh -- prod-01')"
# ... and ends them for good: a destination that looks like an option after it is
# still the destination, which is the whole reason for writing it.
check "-- means what follows is positional" "-weird-host" "$(ar_ssh_host 'ssh -- -weird-host')"
check "the url form" "prod-01" "$(ar_ssh_host 'ssh ssh://deploy@prod-01:2222')"
check "no destination at all" "" "$(ar_ssh_host 'ssh')"
check "an option with nothing after it" "" "$(ar_ssh_host 'ssh -p')"
check "not ssh at all" "" "$(ar_ssh_host 'nvim README.md')"
check "a long host is cut to the context budget" "aaaaaaaaaaaa" \
  "$(ar_ssh_host 'ssh aaaaaaaaaaaaaaaaaaaa')"
# ... and ends on a whole word where the name has one, like a directory or a
# branch: "quans-ssh-ma" says less about a machine than "quans-ssh" does.
check "a long host ends on a whole word" "quans-ssh" \
  "$(ar_ssh_host 'ssh -t quannguyen@quans-ssh-macbook tmux new-session')"
check "TAB_CONTEXT=0 names no machine" "" "$(TAB_CONTEXT=0 ar_ssh_host 'ssh prod-01')"

# ---- ar_label: an ssh pane is named after the machine ----
check "the machine leads, ssh follows" "prod-01 › ssh" \
  "$(ar_label '/home/u/dev/api' 'web' '' 'ssh' 'ssh prod-01')"
# The branch is read from the directory ssh was launched in, which says nothing
# about the machine on the other end -- and printed beside prod-01 it would read
# as that machine's.
check "no branch on a remote pane" "prod-01 › ssh" \
  "$(ar_label '/home/u/dev/api' 'web' 'MC-13675' 'ssh' 'ssh prod-01')"
# ... and neither does the local directory, for the same reason.
check "no local directory either" "prod-01 › ssh" \
  "$(ar_label '/home/u/dev/api' '' '' 'ssh' 'ssh prod-01')"
# With no host to name, the tab still says it is remote.
check "an unreadable destination still says ssh" "ssh" \
  "$(ar_label '/home/u/dev/api' 'web' '' 'ssh' 'ssh -p')"
# A command line is not shown for ssh even with SHOW_PROGRAM_ARGS on: the host
# it carries is already the context, and the rest is the remote command.
check "the command line is not repeated" "prod-01 › ssh" \
  "$(SHOW_PROGRAM_ARGS=1 ar_label '/home/u/dev/api' 'web' '' 'ssh' 'ssh -p 2222 prod-01')"
# With the context off, an ssh tab is named like any other program, as it was
# before any of this existed.
check "TAB_CONTEXT=0 leaves ssh to the program rules" "ssh -p 2222 prod-01" \
  "$(TAB_CONTEXT=0 SHOW_PROGRAM_ARGS=1 ar_label '/home/u/dev/api' 'web' '' 'ssh' 'ssh -p 2222 prod-01')"

# ---- ar_compose: joining the halves ----
check "context and activity are joined" "api › nvim" "$(ar_compose 'api' '' 'nvim')"
check "a branch sits between them" "api › feat/oauth › nvim" \
  "$(ar_compose 'api' 'feat/oauth' 'nvim')"
check "no context leaves the activity alone" "nvim" "$(ar_compose '' '' 'nvim')"
check "a branch with no context still shows" "feat/oauth › nvim" \
  "$(ar_compose '' 'feat/oauth' 'nvim')"
# An empty activity is HIDE_SHELL asking for no label at all, and half a label is
# not what it asked for: the tab is handed back to herdr whole.
check "an empty activity empties the whole label" "" "$(ar_compose 'api' 'feat/x' '')"
check "the separator is configurable" "api | nvim" \
  "$(CONTEXT_SEP=' | ' ar_compose 'api' '' 'nvim')"
# A directory may be named anything a filesystem accepts, and the shell hook
# takes its context from a raw $PWD rather than from a value herdr's jq has
# cleaned. A control character reaching the tab bar is the visible half of that;
# the invisible half is herdr handing the label back normalized, which the
# opt-out machine cannot tell from a name somebody typed.
check "a control character in the context is scrubbed" "we b › nvim" \
  "$(ar_compose "$(printf 'we\002b')" '' 'nvim')"
check "a tab in the context is scrubbed" "we b › nvim" \
  "$(ar_compose "$(printf 'we\tb')" '' 'nvim')"

# ---- ar_border_title: an agent's name on its pane border ----
check "a named agent's pane shows the name" "reviewer" "$(ar_border_title reviewer claude '')"
check "an unnamed agent gets no title" "" "$(ar_border_title '' claude '')"
# herdr draws a reported title above a pane name the user typed, so a label wins.
check "a pane with a label of its own gets none" "" "$(ar_border_title reviewer claude notes)"
check "a name that only repeats the kind gets none" "" "$(ar_border_title claude claude '')"
check "the kind compare ignores ASCII case" "" "$(ar_border_title Codex codex '')"
check "a name that only starts with the kind still shows" "claude-2" \
  "$(ar_border_title claude-2 claude '')"
ar_border_title api codex '' >/dev/null
check "the title is published for the engine's loop" "api" "$AR_BORDER_TITLE"
ar_border_title codex codex '' >/dev/null
check "and cleared when there is none" "" "$AR_BORDER_TITLE"

t_summary
