# Architecture

This documents the non-obvious decisions in herdr-automatic-rename. For usage, see the
[README](../README.md).

## One reconcile, one entry point

`automatic-rename.sh` is invoked for every herdr event, both plugin actions, and the
shell hooks' fast path. It routes through `ar_run` and dispatches on `argv[1]`.
A full reconcile reads `workspace list`, `pane list`, and `agent list` once
each, plus `tab list` per workspace, then computes the label every item should
have and issues one rename per item whose label is wrong.

Computing a tab's name and its `[N]` prefix in the same pass is what lets a
brand-new tab settle at `[3] zsh` in a single rename. Every rename is
skip-if-correct, so re-firing the pass (herdr's own rename re-emits
`tab.renamed`) changes nothing and cannot loop.

## Naming lives in a pure module

`naming.sh` turns `(program, cmdline)` into a display name and touches neither
herdr nor the filesystem. That keeps the naming rules (shells, name-only
programs, ignored programs, aliases, substitutions, truncation, icons) unit
testable in isolation. The engine calls `ar_format` across that seam. Every
function in both files uses the `ar_` prefix.

## Why config and state sit at fixed paths

State (`~/.local/state/herdr-automatic-rename/`) and config
(`~/.config/herdr-automatic-rename/config.sh`) use fixed paths, not
`$HERDR_PLUGIN_STATE_DIR` / `$HERDR_PLUGIN_CONFIG_DIR`. The live shell hooks run
`preexec`/`precmd`, launched by your shell, not by herdr, so they never receive
the `HERDR_PLUGIN_*` variables. The herdr-invoked pass and the shell-invoked
fast path must share one config and one state store, which forces a path both
can name without herdr's help. `$HERDR_AUTOMATIC_RENAME_CONFIG` overrides the config
location.

herdr exposes no per-tab metadata and no auto/manual flag, so the manual-rename
opt-out is tracked in a small JSON state file keyed by `tab_id`: the last base
the plugin set, and whether auto-naming is still enabled for that tab.

## Locking

A `mkdir` lock (atomic, ownership-token stamped, 30-second steal window) plus a
rerun flag coalesces a burst of events into one worker. Contenders raise the
rerun flag and exit; the holder loops until no new work arrives. A fast-path run
that loses the lock still lands, because the holder's re-pass is a full reconcile
that recomputes names itself.

## The shell hooks find their own engine

herdr installs a github plugin to a content-hashed directory, so the hooks
cannot hard-code the engine path. Each hook resolves `automatic-rename.sh` relative to
its own sourced-file location: zsh via `${(%):-%N}`, bash via `BASH_SOURCE[0]`,
fish via `status current-filename` captured into a global. The bash hook never
overwrites a `DEBUG` trap another tool already set, and cooperates with
`bash-preexec` / `ble.sh` / `atuin` when present.

## Numbering caveats

- **Tabs** are numbered by array order, not the non-contiguous `.number` field.
- **Workspaces** are numbered by herdr's grouped sidebar order, not the raw
  `workspace list` order. Same-repo workspaces nest into one "space" keyed by
  `.worktree.repo_key`, and `alt+N` follows the sidebar, so `ar_renumber_workspaces`
  rebuilds that visible order before numbering.
- **Agents** are numbered only when `agent_panel_sort` is grouped (`spaces`). In
  `priority` sort the panel reorders behind an order the CLI never exposes, so
  the plugin strips agent numbers there rather than guess wrong, and renumbers
  when you switch back. Agent renames use a two-phase park to dodge herdr's
  duplicate-name rejection when several agents share a base like `claude`.
- Nothing numbers past 9, since no keybind reaches a 10th item.

## The placeholder rule

herdr labels a fresh tab with a small integer. When naming is on but the tab's
foreground program cannot be read yet (a background multi-pane tab exposes no
active pane), the pass counts the tab's position but defers its rename, so no
throwaway `[3] 3` flashes before the real name arrives. When naming is off, the
integer is numbered as-is, since nothing else will ever name it.

## Testing

`tests/` runs on bash and jq alone (no bats). It covers the pure naming rules,
the `[N]` prefix helpers, the JSON state store and opt-out state machine, the
shell hooks, and a full reconcile driven against a fake `herdr` (`tests/mocks/herdr`)
that serves fixture JSON and records every rename the engine issues. Sourcing
`automatic-rename.sh` defines its functions but runs nothing (guarded by
`BASH_SOURCE[0] == $0`), so the helpers can be exercised directly.
