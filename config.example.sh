# herdr-automatic-rename configuration.
#
# Copy to ~/.config/herdr-automatic-rename/config.sh and uncomment what you want to
# change (or point $HERDR_AUTOMATIC_RENAME_CONFIG somewhere else). This file is sourced
# by automatic-rename.sh BEFORE naming.sh, so anything set here wins over the defaults.
# Every setting has a working default, so an empty config is fine.

# ---- feature toggles (both default on) ----

# Auto-name each tab after its foreground program (the shell name at a bare
# prompt). Set to 0 to leave tab names alone.
# NAME_TABS=1

# Prefix workspaces and tabs with their 1-9 jump-key number, e.g. "[2] api". Set
# to 0 to name without numbering. Agents are included only on herdr < 0.7.5:
# newer herdr rejects a bracketed agent name, so those rows keep their detected
# names (and lose any prefix an older setup left on them).
# AUTO_INDEX=1

# Numbering, per item kind. Each defaults to AUTO_INDEX and overrides it when
# set, so AUTO_INDEX stays the one knob for "number everything" or "number
# nothing" and these carve out the exceptions. Numbered tabs with plain
# workspace names, for instance, is the first line on its own:
# AUTO_INDEX_WORKSPACES=0
# AUTO_INDEX_TABS=1
# AUTO_INDEX_AGENTS=1
#
# Setting one of these to 0 also removes the prefixes already on those rows, on
# the next herdr event -- no need to run the "clear" action.
#
# That cleanup cannot tell one "[N] " apart from another. Nothing records which
# prefixes this plugin wrote, so a name you typed yourself that starts with a
# bracketed number, say "[1] incident", loses the bracket too. Naming the kind
# here is how you ask for the cleanup and accept that. A config with only
# AUTO_INDEX=0 in it never triggers it, so workspace and agent labels stay as
# they are. Tabs are the exception, and only under NAME_TABS=1: that pass runs
# for the naming, and has always taken the prefix off on its way through.
# Anything else in brackets ("[wip] foo") is left alone, digits are the only
# trigger.

# Ordered `sed -E` rewrites for directory-derived workspace names. These change
# only the label shown by herdr; they do not rename the directory or Git
# worktree. A hand-entered name that differs from the derived directory name is
# left unchanged. Herdr exposes no way to distinguish a hand-entered name that
# exactly matches the derived name. For example, shorten "worktree-feature" to
# "wt-feature":
# WORKSPACE_SUBSTITUTE_SETS=(
#   's|^worktree-|wt-|'
# )

# ---- naming knobs (only used when NAME_TABS=1) ----

# 1 = a regular program shows its full command line ("psql -h db"); 0 = just its
# name ("psql"). Default 0.
# SHOW_PROGRAM_ARGS=0

# Truncate the final label to this many characters (counted by codepoint).
# MAX_NAME_LEN=20

# 1 = name a tab running a coding agent after the task the agent reports in its
# terminal title ("Squash merge command") instead of after the program
# ("claude"), which is what tells five claude tabs apart. herdr publishes the
# title on the pane, so the label costs no extra call. A title that names the
# agent rather than the work, one that is just the pane's directory, and a bare
# number are refused, and the tab falls back to the program name (aliases
# included). 0 names every agent tab after its program.
# AGENT_TITLES=1

# Truncate a title to this many characters, at a word boundary when that leaves
# most of the budget. A title is a sentence rather than a command name, so it
# needs more room than MAX_NAME_LEN gives -- and with numbering on the "[N] "
# prefix eats four more. Defaults to MAX_NAME_LEN plus 8, so narrowing that for a
# narrow tab bar narrows titles with it.
# MAX_TITLE_LEN=28

# Titles that name the agent instead of the work it is doing, matched against the
# whole title, ignoring the case of ASCII letters. An agent sets one of these before
# it has a task (at startup, or once a session is cleared), and "Claude Code"
# says less than "claude" does. The agent's own kind, that kind followed by
# "code", the directory the pane sits in, and a bare number are refused without
# being listed. Assigning the array replaces the default; TITLE_IGNORE=() leaves
# only those built-in refusals.
# TITLE_IGNORE=("claude code" "codex cli" "gemini cli" "opencode" "amp code" "cursor agent" "new session" "untitled")

# Agents that stamp their own brand on the FRONT of every terminal title, as
# "<herdr agent kind>=<brand>" pairs. Most agents put their status glyph first and
# the plugin takes it off; oh-my-pi puts the brand first and the glyph second
# ("π ⠋ Fix the parser" while it works, "π > ..." at your turn, "π ! ..." when it
# wants you), so without the brand named here the glyph reached the tab and the
# label changed on every status change. The brand is removed only at the very
# front and only when a non-alphanumeric follows it, so a title that merely starts
# with the same letter keeps it, and the case of ASCII letters is ignored.
# Assigning the array replaces the default.
# TITLE_BRANDS=("pi=π" "omp=π")

# Name shown at a bare prompt. Defaults to your $SHELL's basename.
# SHELL_NAME=zsh

# 1 = don't name a shell tab at all: a bare prompt, an explicit shell, an
# IGNORED_PROGRAMS command, and the login shell itself (SHELL_NAME, which may be
# outside the SHELLS list) all leave the label empty, and herdr shows its own
# tab number there instead of "zsh". With AUTO_INDEX=1 the label keeps the jump
# number alone ("[3]"). Programs are named as usual either way.
# HIDE_SHELL=0

# Programs that count as "a shell prompt" and are shown by their own name.
# Assigning the array replaces the default; SHELLS=() disables the category.
# SHELLS=(zsh bash sh fish dash ksh)

# Programs shown by name only, without command-line args. Coding agents live
# here so an agent tab reads "claude" instead of its full invocation.
# NAME_ONLY_PROGRAMS=(nvim vim vi view gvim git lazygit gitui lazydocker claude codex aider)

# Quick commands that should not take over the tab name: while one runs, the tab
# keeps showing the shell so it does not flicker.
# IGNORED_PROGRAMS=(ls eza ll la cd z zoxide cat bat less more echo pwd clear which man head tail wc cp mv rm mkdir touch fzf sudo doas)

# Language runtimes and package runners that front for the program you actually
# launched. An agent installed from npm is usually a bin shim pointing at a JS
# entrypoint, so the foreground process is `node` and the tab would be named
# after the runtime; pip and pipx console scripts do the same through `python`.
# When one of these is the foreground program in a pane herdr has detected an
# agent in, the tab is named after that agent instead ("codex", not "node").
# Both conditions are needed, so a plain `node server.js` tab keeps its name.
# Add your interpreter here if it resolves to a versioned name (python3.12).
# WRAPPER_PROGRAMS=(node bun deno npx bunx npm pnpm yarn python python3 uv uvx pipx ruby)

# Rename specific programs on the tab. "<program>=<label>" pairs; wins over every
# rule except the bare-prompt shell name.
# PROGRAM_ALIASES=(
#   "lazygit=lg"
#   "clx=hn"
# )

# Ordered `sed -E` rewrites applied to the final label.
# SUBSTITUTE_SETS=(
#   's|.*ipython([32])|ipython\1|'
#   's|.*poetry shell.*|poetry|'
# )

# Prepend a Nerd Font glyph (needs a Nerd Font). ICON_STYLE is one of
# name_and_icon (default), name, or icon.
# ICONS_ENABLED=0
# ICON_STYLE=name_and_icon

# Glyph shown when a program is missing from the builtin map (which comes from
# tmux-nerd-font-window-name's defaults.yml, ~170 programs). An empty string
# turns the fallback off, so unknown programs get no icon. Under ICON_STYLE=icon
# the fallback is treated as "no glyph": a bare "?" says nothing about the
# program, so the plain name is kept instead. Shell labels never get an icon
# either way (SHELLS, the login shell, and IGNORED_PROGRAMS commands): the tab
# is showing the shell, not the program.
# ICON_FALLBACK='?'

# Per-program icon overrides, "<program>=<glyph>" pairs; wins over the builtin
# map and the fallback. Glyphs are literal Nerd Font characters.
# ICON_MAP=(
#   "claude=󰚩"
#   "lazygit=󰊢"
# )
