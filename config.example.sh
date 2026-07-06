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

# Prefix workspaces, tabs, and agents with their 1-9 jump-key number, e.g.
# "[2] api". Set to 0 to name without numbering.
# AUTO_INDEX=1

# ---- naming knobs (only used when NAME_TABS=1) ----

# 1 = a regular program shows its full command line ("psql -h db"); 0 = just its
# name ("psql"). Default 0.
# SHOW_PROGRAM_ARGS=0

# Truncate the final label to this many characters (counted by codepoint).
# MAX_NAME_LEN=20

# Name shown at a bare prompt. Defaults to your $SHELL's basename.
# SHELL_NAME=zsh

# Programs that count as "a shell prompt" and are shown by their own name.
# Assigning the array replaces the default; SHELLS=() disables the category.
# SHELLS=(zsh bash sh fish dash ksh)

# Programs shown by name only, without command-line args. Coding agents live
# here so an agent tab reads "claude" instead of its full invocation.
# NAME_ONLY_PROGRAMS=(nvim vim vi view gvim git lazygit gitui lazydocker claude codex aider)

# Quick commands that should not take over the tab name: while one runs, the tab
# keeps showing the shell so it does not flicker.
# IGNORED_PROGRAMS=(ls eza ll la cd z zoxide cat bat less more echo pwd clear which man head tail wc cp mv rm mkdir touch fzf sudo doas)

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
