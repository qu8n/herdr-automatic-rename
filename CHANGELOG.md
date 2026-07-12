# Changelog

All notable changes to herdr-automatic-rename are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project uses
[semantic versioning](https://semver.org/).

## [Unreleased]

## [0.1.1] - 2026-07-12

### Fixed

- Calling a shell function (or builtin, reserved word, or mistyped command) no
  longer flashes that word onto the tab before the prompt reverts it. The hooks
  now classify the command word; anything that is not an external command makes
  the engine name the tab by the pane's real foreground process, sampled after
  a short settle. A function that wraps a long-running program now names the
  tab after that program instead of the function.

## [0.1.0]

First public release.

### Added

- Tab naming (`NAME_TABS`): each tab is named after its foreground program, or
  the shell name at a bare prompt. A hand rename opts the tab out.
- Jump-key numbering (`AUTO_INDEX`): workspaces, tabs, and agents are prefixed
  with the `1-9` number of the keybind that jumps to them.
- Live per-command naming through zsh, bash, and fish shell hooks that resolve
  the engine relative to their own location.
- `reset` and `clear` plugin actions.
- Configuration via `~/.config/herdr-automatic-rename/config.sh` (or
  `$HERDR_AUTOMATIC_RENAME_CONFIG`), with a documented `config.example.sh`.
- A self-contained test suite (bash + jq only) covering naming, prefix helpers,
  the state machine, the shell hooks, and a full reconcile against a fake herdr.
