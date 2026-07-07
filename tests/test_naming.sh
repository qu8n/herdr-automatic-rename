#!/usr/bin/env bash
# Unit tests for naming.sh -- the pure, herdr-free name computation.
# String in / string out, so every rule is testable without a live herdr.

here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

# Pin the shell name so bare-prompt cases are deterministic regardless of $SHELL.
SHELL_NAME=zsh
. "$here/../naming.sh"

# ---- bare prompt / shells ----
check "bare prompt -> shell name"      "zsh"  "$(ar_format '' '')"
check "explicit shell shows own name"  "bash" "$(ar_format 'bash' 'bash')"
check "fish shell name"                "fish" "$(ar_format 'fish' '')"

# ---- name-only programs (editors, agents, git) ----
check "nvim is name-only"    "nvim"   "$(ar_format 'nvim' 'nvim README.md')"
check "claude is name-only"  "claude" "$(ar_format 'claude' 'claude --dangerously-skip-permissions')"
check "git is name-only"     "git"    "$(ar_format 'git' 'git status')"

# ---- ignored programs keep showing the shell ----
check "ls is ignored -> shell" "zsh" "$(ar_format 'ls' 'ls -la')"
check "cd is ignored -> shell" "zsh" "$(ar_format 'cd' 'cd ..')"

# ---- regular programs show their command line (SHOW_PROGRAM_ARGS default on) ----
SHOW_PROGRAM_ARGS=1
check "regular program shows cmdline"   "htop -d 5"    "$(ar_format 'htop' 'htop -d 5')"
check "regular program, args off -> name only" "psql" "$(SHOW_PROGRAM_ARGS=0 ar_format 'psql' 'psql -h db')"

# ---- program aliases win over category ----
PROGRAM_ALIASES=("clx=hn" "lazygit=lg")
check "alias clx->hn"       "hn" "$(ar_format 'clx' 'clx --nerdfonts')"
check "alias lazygit->lg"   "lg" "$(ar_format 'lazygit' 'lazygit')"
PROGRAM_ALIASES=()

# ---- substitutions ----
check "poetry shell -> poetry" "poetry"   "$(ar_format 'poetry' 'poetry shell')"
check "ipython3 collapse"      "ipython3" "$(ar_format 'ipython3' '/usr/bin/ipython3')"

# ---- truncation (MAX_NAME_LEN), counted by codepoint ----
check "truncates to MAX_NAME_LEN" "12345678901234567890" \
  "$(MAX_NAME_LEN=20 ar_format 'x' '123456789012345678901234567890')"
# A multibyte string must be cut on a codepoint boundary, never mid-byte.
check "multibyte truncation is clean" "ünïcödé" \
  "$(MAX_NAME_LEN=7 ar_format 'x' 'ünïcödéxxxxxxx')"

# ---- icons ----
check "icon style 'name' suppresses glyph" "nvim" \
  "$(ICONS_ENABLED=1 ICON_STYLE=name ar_format 'nvim' 'nvim')"

# ---- default: SHOW_PROGRAM_ARGS defaults to 0 (regular program -> name only) ----
got=$(bash -c 'SHELL_NAME=zsh; . "$1"; ar_format htop "htop -d 5"' _ "$here/../naming.sh")
check "SHOW_PROGRAM_ARGS defaults to name-only" "htop" "$got"

# ---- config arrays: an intentionally-empty override must survive the guard ----
# naming.sh uses `declare -p`, not `${arr+x}` (which reports a zero-element array
# as unset and would silently restore the default list). Source it fresh in a
# subshell with IGNORED_PROGRAMS=() and confirm `ls` is no longer suppressed.
got=$(bash -c 'SHELL_NAME=zsh; SHOW_PROGRAM_ARGS=1; IGNORED_PROGRAMS=(); . "$1"; ar_format ls "ls -la"' _ "$here/../naming.sh")
check "empty IGNORED_PROGRAMS override survives" "ls -la" "$got"

t_summary
