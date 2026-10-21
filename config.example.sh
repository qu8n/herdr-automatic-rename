# herdr-automatic-rename configuration.
#
# Copy this file to ~/.config/herdr-automatic-rename/config.sh (or point
# $HERDR_AUTOMATIC_RENAME_CONFIG at another path) and uncomment what you want to
# change. The plugin sources it before its defaults, so anything set here wins.
# Every setting has a working default, so an empty config is fine.
#
# Array settings replace their default when assigned. Assign () to empty one.

# ---- features ----

# Name each tab after its foreground program (the shell name at a prompt). 0
# leaves tab names alone.
# NAME_TABS=1

# Show each agent's herdr name (`herdr agent start <name>`, `herdr agent
# rename`) on its pane border, which herdr draws on split panes. The name is a
# display-only title, so the pane's own name is never changed. A pane you named
# yourself keeps that name, and a name that only repeats the agent ("claude") is
# not shown. A rename shows at the next herdr event. 0 turns this off and takes
# the names back off at the next event (below herdr 0.7.2, as each agent exits).
# NAME_PANES=1

# Give each agent pane its own topic, what that agent says it is working on,
# as the `topic` token. herdr's sidebar shows it where a row asks for `$topic`
# (see the README). It follows AGENT_TITLES and TITLE_CONDENSE like a tab name
# does. Needs herdr 0.7.4 or newer. 0 turns this off and takes the topics back
# off at the next event.
# PANE_TOPICS=1

# Prefix workspaces and tabs with their 1-9 jump-key number, e.g. "[2] api". 0
# turns numbering off. Agents get a number only on herdr below 0.7.5, because
# newer herdr rejects a bracketed agent name.
# AUTO_INDEX=1

# Numbering per item kind. Each one defaults to AUTO_INDEX and overrides it when
# set. For numbered tabs with plain workspace names, set only the first line.
# AUTO_INDEX_WORKSPACES=0
# AUTO_INDEX_TABS=1
# AUTO_INDEX_AGENTS=1
#
# Setting one of these to 0 also strips existing "[N] " prefixes from that kind
# at the next herdr event. The plugin does not record which prefixes it wrote,
# so a name you typed that starts with "[1] " loses it too. Brackets without
# digits ("[wip] foo") are left alone. AUTO_INDEX=0 alone does not strip
# workspace or agent prefixes. Tabs lose theirs anyway when NAME_TABS=1, since
# naming rewrites them.

# 1 puts this machine's hostname in front of the first tab of each workspace:
# "HPmini: [1] api › nvim". The hostname is `uname -n` without the DNS domain,
# then trimmed by HOST_PREFIX_STRIP. The plugin only ever removes a tag it added
# itself, so turning this off cleans up at the next event and a hand-typed name
# is never touched.
# HOST_PREFIX=0
#
# What joins the hostname to the rest of the label. Safe to change mid-session.
# Tabs the plugin names pick up the new separator at the next event.
# HOST_PREFIX_SEP=": "
#
# Substrings removed from the hostname, wherever they occur. Empty by default.
# For example, show every "Omarchy-<name>" machine as "<name>". If nothing is
# left, the first tab shows the separator alone (": [1] fish"), so a broken
# hostname looks different from HOST_PREFIX=0. Run the `clear` action to remove
# a tag the plugin can no longer recognize.
# HOST_PREFIX_STRIP=("Omarchy-")

# Ordered `sed -E` rewrites for the workspace name herdr takes from its
# directory. Empty by default. They change only the label: the directory and the
# Git worktree keep their names. They apply whether or not NAME_TABS is on. For
# example, show "worktree-feature" as "wt-feature":
# WORKSPACE_SUBSTITUTE_SETS=(
#   's|^worktree-|wt-|'
# )
#
# Only names the plugin derived are rewritten. A workspace name you typed
# yourself is left alone, unless it matches the directory name exactly (herdr
# cannot tell the two apart). Deleting the rules restores the plain names at the
# next herdr event. With workspace numbering off there is no next pass, so run
# the `clear` action instead.

# ---- naming (only used when NAME_TABS=1) ----

# 1 puts the context in front of the program: the pane's directory, its Git
# branch, or the ssh host, joined by CONTEXT_SEP ("api › MC-13675 › nvim"). 0
# names by the program alone.
#
# The directory is left out when it is your home directory, the filesystem root,
# or the same as the workspace name (herdr already shows that above the tabs). A
# worktree directory named after the workspace's branch counts as the same. A
# directory longer than MAX_CONTEXT_LEN is shortened the way a branch is, so
# "bugfix-proj-482-fix-rev-discrepancy" reads as "PROJ-482".
#
# A pane running ssh shows the remote host instead ("prod-01 › ssh"), without
# the user.
# TAB_CONTEXT=1

# 1 adds the pane's checked-out Git branch to the context. The plugin reads it
# from .git without running git. The repository's default branch is left out,
# and so is a branch that repeats the workspace or directory name. A branch
# longer than MAX_BRANCH_LEN is shortened to its issue key
# ("bugfix-asa-cpanel-uapi-mc-13675" becomes "MC-13675"), or else to the part
# after the last "/", cut at a whole word.
# SHOW_BRANCH=1

# Longest branch shown, in characters. 0 hides branches, the same as
# SHOW_BRANCH=0. An issue key is always shown whole.
# MAX_BRANCH_LEN=12

# Branches treated as the trunk when the repository records no default of its
# own (no origin/HEAD). A repository that does record one is trusted over this
# list. TRUNK_BRANCHES=() shows every branch in such a repository.
# TRUNK_BRANCHES=(main master develop trunk)

# Longest directory shown, in characters.
# MAX_CONTEXT_LEN=12

# What joins the parts of a label. The default is U+203A with a space on each
# side.
# CONTEXT_SEP=' › '

# 1 shows a program's full command line ("psql -h db"). 0 shows its name
# ("psql"). NAME_ONLY_PROGRAMS always show the name.
# SHOW_PROGRAM_ARGS=0

# Longest program name shown, in characters. Each part of a label has its own
# limit (MAX_CONTEXT_LEN, MAX_BRANCH_LEN, MAX_TITLE_LEN).
# MAX_NAME_LEN=20

# 1 names an agent tab after the task in its terminal title ("Squash merge
# command") instead of the program ("claude"). Titles that name the agent (see
# TITLE_IGNORE), match the pane's directory, or are just a number are refused,
# and the tab falls back to the program name. 0 names every agent tab after its
# program.
# AGENT_TITLES=1

# What an agent tab shows once it has a task. "task" shows the task alone.
# "name_and_task" puts the agent in front, "claude:auth-flow" or "cc:auth-flow"
# through PROGRAM_ALIASES. This helps when you run several kinds of agents,
# since herdr gives them all the same glyph.
#
# The name counts against MAX_TITLE_LEN. If the limit cannot fit the name, a
# colon, and MIN_TASK_LEN characters of task, the name is dropped and the task
# stays. An alias that contains a space is never used as a prefix.
# TITLE_STYLE=task

# Fewest task characters that must fit beside the name for
# TITLE_STYLE=name_and_task.
# MIN_TASK_LEN=7

# 1 names an untitled Claude Code tab from its session transcript on disk: the
# title Claude Code generated, or else your first prompt. This covers sessions
# started with a slash command, which Claude Code never titles. It needs `herdr
# integration install claude`. Only Claude Code is read. Set 0 if you do not
# want the plugin to read transcripts.
# AGENT_TRANSCRIPT=1

# Longest title shown, in characters, cut at a word boundary when possible.
# Defaults to MAX_NAME_LEN + 8, so lowering MAX_NAME_LEN lowers this too.
# MAX_TITLE_LEN=28

# Titles that name the agent instead of the task, matched against the whole
# title and ignoring ASCII case. Agents set these at startup or after a session
# is cleared. The agent's own kind, that kind plus "code", the pane's directory,
# and a bare number are always refused. TITLE_IGNORE=() keeps only those.
# TITLE_IGNORE=("claude code" "codex cli" "gemini cli" "opencode" "amp code" "cursor agent" "new session" "untitled")

# Brands an agent puts at the front of every title, as "<herdr agent
# kind>=<brand>" pairs. oh-my-pi writes "π ⠋ Fix the parser", so without this
# entry the status glyph after the brand would reach the tab. A brand is removed
# only at the start and only when a non-alphanumeric character or the end of the
# title follows it, ignoring ASCII case. "opencode=OC" would strip opencode's
# "OC | " brand, but it would also turn "OC-192 incident" into "192 incident",
# so it is not a default.
# TITLE_BRANDS=("pi=π" "omp=π")

# 1 condenses a title to its keywords instead of cutting off its end.
# "Investigate why the nightly ETL job drops rows" becomes
# "nightly-ETL-job-drops-rows" instead of "Investigate why the nightly". It
# drops a leading verb (TITLE_LEAD_VERBS) and filler words (TITLE_FILLER_WORDS),
# keeps the rest in order, and joins them with TITLE_WORD_SEPARATOR. The title
# stays a sentence when nothing is left, when the result would be longer, or
# when it would start like a tab number ("[12]").
# TITLE_CONDENSE=0

# Verbs dropped when a title starts with one. Only the first word is checked, so
# "the auth rewrite needs review" keeps "review". The match is by spelling, so
# "Plan needs approval" becomes "needs-approval". Two titles can collapse to the
# same label: "Review flashcard generation" and "Implement flashcard generation"
# both become "flashcard-generation".
# TITLE_LEAD_VERBS=(review adjust add fix update create make check investigate debug refactor implement write set setup configure explore improve build test run clean remove delete migrate rename draft plan research diagnose audit analyze troubleshoot optimize show)

# Words dropped anywhere in a condensed title.
# TITLE_FILLER_WORDS=(a an the to for of on in at and or with from into via why how what that if whether is are be it its this up out off down over back)

# What joins condensed words. " " reads as a phrase. Its length counts against
# MAX_TITLE_LEN. Whitespace and control characters are squeezed to one space.
# TITLE_WORD_SEPARATOR=-

# Casing of condensed words. "fold" lowercases every word except all-caps
# identifiers like "ETL". "lower" lowercases those too. "keep" leaves the
# agent's casing. Only ASCII letters change.
# TITLE_CASE=fold

# Name shown at a shell prompt. Defaults to the basename of $SHELL.
# SHELL_NAME=zsh

# 1 leaves the label empty for a shell tab (a prompt, a shell, an
# IGNORED_PROGRAMS command, or SHELL_NAME), so herdr shows its own tab number.
# With numbering on, the label is just the number ("[3]"). Other programs are
# named as usual.
# HIDE_SHELL=0

# Programs that count as a shell prompt.
# SHELLS=(zsh bash sh fish dash ksh)

# Programs always shown by name, without arguments. The default covers editors,
# Git tools, and every agent herdr detects.
# NAME_ONLY_PROGRAMS=(nvim vim vi view gvim git lazygit gitui lazydocker claude codex aider pi gemini cursor cursor-agent devin agy antigravity cline omp mastracode opencode copilot kimi kiro kiro-cli droid amp grok hermes kilo qodercli qwen maki muse muse-cli muse-code)

# Short-lived commands that do not rename the tab. While one runs, the tab keeps
# the shell name so it does not flicker.
# IGNORED_PROGRAMS=(ls eza ll la cd z zoxide cat bat less more echo pwd clear which man head tail wc cp mv rm mkdir touch fzf sudo doas)

# Runtimes that launch an agent for you, such as `node` for an npm-installed
# agent. When one of these is in the foreground of a pane where herdr detected
# an agent, the tab takes the agent's name ("codex", not "node"). A plain `node
# server.js` tab keeps "node". Add your interpreter if it has a versioned name
# (python3.12).
# WRAPPER_PROGRAMS=(node bun deno npx bunx npm pnpm yarn python python3 uv uvx pipx ruby)

# Rename programs on the tab, as "<program>=<label>" pairs. An alias wins over
# every rule except the shell name at a prompt. Agents whose executable differs
# from herdr's id for them (cursor-agent and "cursor", kiro-cli and "kiro",
# muse-cli and muse-code and "muse") match either spelling. Muse's versioned
# binary counts as "muse". Empty by default.
# PROGRAM_ALIASES=(
#   "lazygit=lg"
#   "clx=hn"
# )

# Ordered `sed -E` rewrites for the program name or command line a tab shows.
# They do not touch the directory, branch, agent title, or workspace name. These
# two are the default.
# SUBSTITUTE_SETS=(
#   's|.*ipython([32])|ipython\1|'
#   's|.*poetry shell.*|poetry|'
# )

# 1 puts a Nerd Font glyph in front of the name (needs a Nerd Font). ICON_STYLE
# is name_and_icon, name, or icon.
# ICONS_ENABLED=0
# ICON_STYLE=name_and_icon

# Glyph for a program missing from the built-in map (about 170 programs, from
# tmux-nerd-font-window-name). Empty by default, so such a program shows its
# plain name. Under ICON_STYLE=icon the fallback counts as no glyph, so the name
# shows instead. Shell labels never get an icon.
# ICON_FALLBACK='?'

# Per-program glyphs, as "<program>=<glyph>" pairs. They win over the built-in
# map and the fallback. Empty by default.
# ICON_MAP=(
#   "claude=󰚩"
#   "lazygit=󰊢"
# )
