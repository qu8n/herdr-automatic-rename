# Changelog

All notable changes to herdr-automatic-rename are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project uses [semantic versioning](https://semver.org/). Each entry is one to three sentences, which `make lint-md` enforces.

## [Unreleased]

## [0.14.0] - 2026-10-20

### Added

- `NAME_PANES` shows each agent's herdr name (`herdr agent start <name>`, `herdr agent rename`) on its pane border, on by default. Panes you named yourself and names that only repeat the agent kind are left alone, and `NAME_PANES=0` takes the names back off ([#29](https://github.com/qu8n/herdr-automatic-rename/issues/29), thanks @freivokh).

## [0.13.1] - 2026-10-17

### Fixed

- Tabs mirrored by [herdr-mirror](https://github.com/nikok6/herdr-mirror) keep the label the remote machine gives them. The local plugin used to name, number and host-tag them, and herdr-mirror pushed that label to the remote, where it opted the tab out ([#26](https://github.com/qu8n/herdr-automatic-rename/issues/26), thanks @paidem).
- The shell hook line now finds the plugin under herdr 0.9.5's `github-installations/` folder, and picks it over an old `github/` copy that `herdr plugin update` leaves behind. Before, a fresh install never loaded the hook, so tabs were not renamed when a command started. If you added the hook before this fix, re-run the installer to print the new line, then swap it in by hand ([#27](https://github.com/qu8n/herdr-automatic-rename/issues/27), thanks @paidem).
- The bash hook no longer turns itself off when `cd` is an alias or function, or when `CDPATH` is set ([#28](https://github.com/qu8n/herdr-automatic-rename/issues/28), thanks @paidem). It used to lose track of its own folder and stop renaming tabs without any error.

## [0.13.0] - 2026-09-29

### Changed

- With `ICONS_ENABLED=1`, a program missing from the icon map now shows its plain name instead of `? name`. The `?` looked like an error, while a tab with no glyph already marks an unmapped program. Set `ICON_FALLBACK='?'` to get the old look back.

### Fixed

- Letta tabs are named like other agents. `letta` and `letta-code` now get the robot glyph and show only the program name under `SHOW_PROGRAM_ARGS=1`.

## [0.12.0] - 2026-09-25

### Added

- `HOST_PREFIX` puts the machine's hostname in front of each workspace's first tab (`HPmini: [1] api › nvim`). `HOST_PREFIX_SEP` sets the separator and `HOST_PREFIX_STRIP` trims the hostname. Turning it off removes the tag only from tabs the plugin tagged, so a hand-typed name is never touched ([#24](https://github.com/qu8n/herdr-automatic-rename/pull/24), thanks @farangkao).

## [0.11.1] - 2026-09-14

### Fixed

- A tab no longer repeats its workspace name when the two differ only by separator, such as `feature/fh-10390` and `feature-fh-10390`. Name comparisons now treat `-`, `_`, `.` and `/` as the same character.

## [0.11.0] - 2026-09-10

### Added

- `WORKSPACE_SUBSTITUTE_SETS` rewrites workspace labels with `sed -E` rules, so `'s|^worktree-|wt-|'` shows `worktree-feature` as `wt-feature`. Only names herdr derived from the directory are rewritten, never one you typed. `clear` restores the derived name ([#15](https://github.com/qu8n/herdr-automatic-rename/pull/15), thanks @engineersamuel).

## [0.10.0] - 2026-09-10

### Added

- `install.sh` installs the plugin and wires the shell hook in one command: `curl -fsSL .../install.sh | bash`. It detects zsh, bash, or fish, and a re-run changes nothing, so it also works as the upgrade path.
- A `doctor` action prints the versions, state record, and every naming decision for the current tab, so a tab that does nothing can say why. `AR_TRACE=1` writes the same trace for every pass to `trace.log`.

### Fixed

- Ownership records survive a pass that could not read everything. A failed tab list, an empty keep list, one bad key, or a crashed `jq` used to wipe records and opt tabs out of naming for good.
- The shell hook scrubs control characters from the workspace name it derives from `$PWD`. Before, such a name opted the workspace out of directory tracking.
- An inline comment after `agent_panel_sort` in `config.toml` is no longer read as part of the value.
- Docs describe `SUBSTITUTE_SETS`, transcript naming, and `MAX_TITLE_LEN` correctly.

### Changed

- Each event spawns fewer processes. State is read once per pass, `herdr --version` once per process, and the plugin's own renames no longer trigger a second pass.
- Tests run in parallel, about 20 seconds instead of 45. CI pins its actions by commit and checks the shellcheck download against a digest.

## [0.9.1] - 2026-09-09

### Fixed

- Workspace numbers follow collapsed spaces again on herdr 0.9.0, which moved collapse state out of `session.json` into a per-client file. The plugin now reads that file when it exists and reacts to a click at once instead of after a 5-second delay.
- Muse tabs are named `muse` instead of `muse-bin-<version>`, and `muse`, `muse-cli` and `muse-code` get the agent glyph.

## [0.9.0] - 2026-09-08

### Added

- `TITLE_CONDENSE=1` shortens an agent's title to its keywords instead of cutting off the end, so "Investigate why the nightly ETL job drops rows" becomes "nightly-ETL-job-drops-rows". `TITLE_LEAD_VERBS`, `TITLE_FILLER_WORDS`, `TITLE_WORD_SEPARATOR` and `TITLE_CASE` tune it. Off by default ([#17](https://github.com/qu8n/herdr-automatic-rename/pull/17), thanks @cspipaon).
- `TITLE_STYLE=name_and_task` shows the agent next to its task, such as `cc:auth-flow`, which tells apart tabs running different agents. The prefix fits inside `MAX_TITLE_LEN`. Off by default ([#18](https://github.com/qu8n/herdr-automatic-rename/pull/18), thanks @cspipaon).

### Fixed

- The workspace name follows the shell's directory after a `cd` ([#20](https://github.com/qu8n/herdr-automatic-rename/issues/20)). The shell hook now renames the workspace at the next prompt, using the same rules as a full reconcile.
- One `PROGRAM_ALIASES` entry now covers both spellings of `cursor-agent`/`cursor` and `kiro-cli`/`kiro` ([#19](https://github.com/qu8n/herdr-automatic-rename/issues/19)).
- Two herdr sessions no longer share one state store ([#22](https://github.com/qu8n/herdr-automatic-rename/issues/22), [#21](https://github.com/qu8n/herdr-automatic-rename/pull/21), thanks @gillesdandrea). Each named session keeps its own under `sessions/<name>/`, so one session no longer prunes the other's tabs and freezes their names.
- A label that fits its budget is no longer shortened when herdr runs the plugin under a C locale ([#16](https://github.com/qu8n/herdr-automatic-rename/pull/16), thanks @cspipaon).

## [0.8.0] - 2026-08-28

### Added

- Tab labels show where the work is: `[N] <directory> › <branch> › <activity>`. Each part drops out when it adds nothing, and long directory names shrink to a ticket ID like `PROJ-482`. `TAB_CONTEXT=0` turns this off.
- The checked-out branch is read from `.git` files without running git, and the repo's default branch is hidden. Worktrees, submodules, and rebases are handled, and `SHOW_BRANCH=0` turns branches off.
- An `ssh` pane is named after the host it reached, such as `prod-01 › ssh`.
- An untitled Claude Code session is named from its transcript, using the generated title or the first prompt. `AGENT_TRANSCRIPT=0` turns this off.

### Fixed

- A numbered workspace keeps following its directory ([#13](https://github.com/qu8n/herdr-automatic-rename/issues/13)). Numbering used to freeze the name, and a workspace named by hand is still only numbered.

## [0.7.3] - 2026-08-22

### Fixed

- Tab naming no longer stops for a session or stalls for 30 seconds because of a lock race. Two passes could both steal an abandoned lock, and some failures left a lock nobody could release.
- An unreadable `state.json` no longer ends tab naming for the session. It is now treated as missing, so writes and `reset` work again.

### Changed

- `make lint` and `make lint-md` fail on real findings instead of printing "not installed". CI runs shellcheck and checks the syntax of every bash file.

## [0.7.2] - 2026-08-20

### Fixed

- oh-my-pi tabs no longer show a spinner or rename on every status change ([#12](https://github.com/qu8n/herdr-automatic-rename/issues/12)). `TITLE_BRANDS` strips the agent's brand glyph from the front of its title.

## [0.7.1] - 2026-08-19

### Fixed

- Qwen Code and `maki` tabs get the agent glyph and show only the program name under `SHOW_PROGRAM_ARGS=1`.

### Documentation

- The README covers herdr 0.8.2's `ui.window_title`, which can show the tab name in the outer terminal's title.
- The README notes that herdr 0.8.2's Session Navigator searches the tab names this plugin writes.

## [0.7.0] - 2026-08-18

Upgrade note: `AGENT_TITLES` is on by default, so agent tabs show the task instead of `claude`. Set `AGENT_TITLES=0` to keep the program name.

### Added

- A tab running a coding agent is named after the task the agent reports (`AGENT_TITLES`). Titles that name only the agent or the directory are ignored, and `MAX_TITLE_LEN` (28) and `TITLE_IGNORE` tune the result.
- A tab with several panes is named after the one that matters: the focused agent, then a busy agent, then the focused pane.
- `reset` and `clear` report what they did as a herdr notification, and they wait for the lock instead of dropping the request.

### Fixed

- Running the test suite inside herdr no longer renames that session's tabs.
- A tab whose rename herdr rejected is named again on the next pass instead of opting out.
- A background tab with several panes is named from its own focused pane, not the last single pane it had.
- With a second client attached, the focused tab is no longer named from another tab's pane.
- A pane is named on Linux setups where herdr sees no foreground process group but reports one process.
- Control characters in labels are replaced, and whitespace is collapsed.
- A tab with an empty label can be named again, since rows are now split on a character bash does not collapse.
- A label the plugin owns is rewritten until it matches exactly.
- A backslash in a tab name is no longer doubled.

## [0.6.1] - 2026-08-14

### Fixed

- An agent installed through npm or pip is named after the agent, not `node` or `python`. When the foreground program is in `WRAPPER_PROGRAMS` and herdr detected an agent in the pane, the plugin uses herdr's answer ([#9](https://github.com/qu8n/herdr-automatic-rename/pull/9), thanks @cspipaon).

## [0.6.0] - 2026-08-13

### Added

- `AUTO_INDEX_WORKSPACES`, `AUTO_INDEX_TABS` and `AUTO_INDEX_AGENTS` turn `[N]` numbering on or off per kind, overriding `AUTO_INDEX` ([#8](https://github.com/qu8n/herdr-automatic-rename/issues/8)). Existing configs are unaffected.

### Changed

- Setting one of these to `0` strips the existing `[N]` from those rows at the next event. Only all-digit brackets are touched, so `[wip] deploy` is safe.

## [0.5.0] - 2026-08-07

Upgrade note: with `ICONS_ENABLED=1`, programs outside the icon map now show `?`. Set `ICON_FALLBACK=''` to keep them text-only.

### Added

- The icon map moved to `icons.sh` and grew from 9 to about 170 programs, taken from `tmux-nerd-font-window-name` ([#7](https://github.com/qu8n/herdr-automatic-rename/pull/7), thanks @MuntasirSZN).
- `ICON_FALLBACK` (default `?`) sets the glyph for programs the map does not know.
- `ICON_MAP` overrides icons per program, such as `ICON_MAP=("claude=󰚩")`.
- Shell labels get no icon, so an idle tab does not flip between `zsh` and a glyph.

### Fixed

- `HIDE_SHELL` now blanks login shells outside the built-in list, such as nu or tcsh.
- The login shell is recognized by program, so it gets the same label with `SHOW_PROGRAM_ARGS=1`.

## [0.4.0] - 2026-08-05

### Added

- `HIDE_SHELL=1` leaves shell tabs unnamed, so herdr shows its own tab number and only busy tabs carry a name (#5).
- With `AUTO_INDEX=1`, a hidden tab keeps only its number (`[3]`) and is not mistaken for a hand rename.

## [0.3.0] - 2026-08-04

### Fixed

- Agent numbering works again after herdr 0.7.5 changed how agents are renamed. Below 0.7.5 agents are numbered, and at or above it stale `[N]` prefixes are stripped, since herdr no longer allows them.
- Dragging a worktree group renumbers workspaces at once, via herdr 0.8.0's `workspace.reordered` event.

### Added

- A `[[startup]]` hook (herdr 0.7.5 or newer) reconciles as soon as a session is restored.
- Every agent herdr 0.8.0 detects is recognized by name and gets the robot glyph.

### Documentation

- The README explains that tab naming does nothing on Linux runtimes without a visible foreground process group, and points to `HERDR_PROCESS_DETECTION=child-groups`.
- `docs/ARCHITECTURE.md` covers the agent-name restriction and why herdr 0.7.5's agent views make agent numbers unreliable.

## [0.2.3] - 2026-08-02

### Fixed

- A wrapped program on NixOS is named after what you typed, so `nh os switch` reads `nh` instead of `.nh-wrapped` ([#6](https://github.com/qu8n/herdr-automatic-rename/issues/6)).

## [0.2.2] - 2026-07-29

### Fixed

- `ICONS_ENABLED=1` now shows a Nerd Font glyph. The glyphs were missing from every release up to 0.2.1 ([#3](https://github.com/qu8n/herdr-automatic-rename/issues/3)).
- The lock works on NixOS, where `stat` is a bash builtin, and the tests run without `/bin/bash` ([#4](https://github.com/qu8n/herdr-automatic-rename/pull/4), thanks @MuntasirSZN).

## [0.2.1] - 2026-07-26

### Fixed

- Collapsing a worktree space removes the hidden members' numbers, and the rows below move up.
- A space takes its number from its main checkout, matching the row herdr shows.
- Two linked worktrees with no main workspace open are numbered as separate rows, as herdr shows them.

## [0.2.0] - 2026-07-17

### Added

- Subscribe to `pane.created`, so a split renames the tab even when focus does not move.

### Changed

- A full reconcile reads everything from one `herdr api snapshot` call on herdr 0.7.2 or newer. Older herdr falls back to per-list queries.

## [0.1.1] - 2026-07-12

### Fixed

- Running a shell function, builtin, or typo no longer flashes that word on the tab. A function that wraps a long-running program names the tab after that program.

## [0.1.0] - 2026-07-11

First public release.

### Added

- Tab naming (`NAME_TABS`): each tab is named after its foreground program, or the shell name at a prompt. A hand rename opts the tab out.
- Jump-key numbering (`AUTO_INDEX`): workspaces, tabs, and agents get the `1-9` number of the key that jumps to them.
- Live per-command naming through zsh, bash, and fish shell hooks.
- `reset` and `clear` plugin actions.
- Configuration via `~/.config/herdr-automatic-rename/config.sh` (or `$HERDR_AUTOMATIC_RENAME_CONFIG`), with a documented `config.example.sh`.
- A self-contained test suite (bash and jq only).

[Unreleased]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.14.0...HEAD
[0.14.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.13.1...v0.14.0
[0.13.1]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.11.1...v0.12.0
[0.11.1]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.11.0...v0.11.1
[0.11.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.7.3...v0.8.0
[0.7.3]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.7.2...v0.7.3
[0.7.2]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/qu8n/herdr-automatic-rename/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/qu8n/herdr-automatic-rename/releases/tag/v0.1.0
