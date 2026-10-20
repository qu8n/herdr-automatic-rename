# Architecture

## 1. Project structure

A few bash files, one job each. Only `automatic-rename.sh` talks to herdr.

```text
herdr-plugin.toml     manifest: events, startup hook, three actions
automatic-rename.sh   engine: dispatch, reconcile, state, lock, fast path
naming.sh             pure naming rules, strings in and strings out
icons.sh              icon settings and glyph map
git.sh                branch lookup from .git files
transcript.sh         task title from a Claude Code transcript
shell/hook.*          zsh, bash, and fish hooks for live renames
config.example.sh     every setting with its default
install.sh            installs the plugin and wires the hook
tests/                one test_<area>.sh per area, fake herdr in mocks/
```

Every function uses the `ar_` prefix.

## 2. High-level system diagram

```text
 herdr event or action           shell hook (preexec, precmd)
            |                                |
            v                                v
      ar_run full   <--- shared lock --->  ar_run fast
      ar_reconcile                         ar_fast_once
      (one herdr snapshot)                 ($PWD + command line)
            |                                |
            +---------> ar_label <-----------+
                   (naming.sh, pure)
                          |
                          v
       rename only what is wrong, record it in state.json
```

## 3. Core components

**Engine (`automatic-rename.sh`).** `ar_main` switches on `argv[1]`. Events and actions run a full reconcile, which reads everything once, computes every label, and renames only the wrong ones. Hooks run the fast path, which names one tab with no snapshot. The engine also numbers workspaces, tabs, and agents, and tracks which names it owns.

**Naming (`naming.sh`, `icons.sh`).** `ar_label` builds a label from a context (directory, branch, or ssh host) and an activity (program or agent task). It never calls herdr or reads files, so every rule is unit testable.

**Readers (`git.sh`, `transcript.sh`).** The only modules that read files. `git.sh` reads `.git` directly instead of running git. `transcript.sh` supplies a title for a Claude Code pane that has none.

**Shell hooks (`shell/`).** Each hook finds the engine next to its own file and calls it on every command and prompt. herdr has no "foreground command changed" event, so the hooks make renames instant.

### Design decisions

- **One idempotent pass.** Every event runs the same reconcile, and a rename happens only when a label is wrong. Re-running is always safe, and herdr re-firing `tab.renamed` cannot loop.
- **Hand renames win.** herdr has no auto/manual flag. The plugin records each name it sets. A label that does not match the record was typed by a person, so the plugin stops naming that item until `reset`.
- **Record only what landed.** A name is recorded only after the rename succeeds. Otherwise a failed rename would look like a hand rename and opt the tab out.
- **One worker per burst.** A `mkdir` lock with a rerun flag collapses a burst of events into one pass. Actions wait for the lock, since their request cannot be handed to another process.
- **Borders get a title, not a name.** An agent's name reaches its pane border as display-only metadata tied to the agent's kind, so the pane's own name stays the user's, herdr drops the title when the agent exits, and no record is kept. The trade-off: the plugin compares against the title herdr shows from any source, so another title reporter on an agent pane costs a no-op clear per pass, or the two overwrite each other.
- **Pure naming.** Rules live apart from herdr and the filesystem so tests can check them as strings.
- **Mirror herdr, don't guess.** Numbers follow what `alt+N` reaches, so the plugin copies herdr's sidebar rules, including collapse. Where herdr's order is unreadable (agent views, `priority` sort), the plugin strips numbers instead of guessing.
- **Gate features at runtime.** `min_herdr_version` stays at 0.7.1 and newer features check the version when they run, because a version requirement that is too high stops the plugin from loading at all.

## 4. Data stores

Local files only.

| Store | Path | Contents |
| --- | --- | --- |
| Config | `~/.config/herdr-automatic-rename/config.sh` | bash variables (see `config.example.sh`) |
| State | `~/.local/state/herdr-automatic-rename/`, under `sessions/<name>/` for a named session | `state.json`, the lock, the rerun flag, `trace.log` |
| herdr files (read only) | herdr's state dir | `session.json` and the client file, for workspace directories and sidebar collapse |

`state.json` holds one record per `tab_id` and per `ws:<workspace_id>`: the last name set, and whether naming is on. The paths are fixed because the shell hooks run outside herdr and never see `HERDR_PLUGIN_*` variables.

## 5. External integrations

- **herdr CLI:** the only API. It reads with `api snapshot` (per-list calls on older herdr) and writes with the `rename` commands, plus `pane report-metadata` for the display-only pane border titles. `herdr-plugin.toml` lists the events.
- **jq:** parses every JSON reply and cleans every string herdr returns.
- **git:** read from `.git` files. The git binary is never run.
- **Claude Code:** transcripts in `~/.claude/projects`, read only when needed. `AGENT_TRANSCRIPT=0` turns this off.

## 6. Deployment and infrastructure

There is no server. The plugin runs as short-lived bash processes.

- **Install:** `herdr plugin install`, or `install.sh`, which also wires the hook.
- **CI:** the test suite on Ubuntu and macOS (bash 3.2), plus syntax checks, pinned shellcheck, and markdownlint.
- **Release:** a `v*` tag publishes a GitHub Release, with notes from `CHANGELOG.md`.
- **Debugging:** the `doctor` action explains one tab's name. `AR_TRACE=1` logs each pass.

## 7. Security considerations

- No network and no credentials. The plugin only talks to the local herdr socket.
- The transcript reader sees what the user typed to their agent. It reads only that pane's session and can be turned off.
- Session ids must look like UUIDs before they become part of a path.
- Control characters are removed from herdr strings before they reach the shell.
- CI pins actions by commit, checks the shellcheck download by sha256, and uses a read-only token.

## 8. Development and testing environment

- **Needs:** bash 3.2 or newer, `jq`, and herdr.
- **Test:** `make test`. Unit tests check naming strings. Integration tests run the engine against `tests/mocks/herdr`, which serves fixture JSON and logs each rename.
- **Lint:** `make lint` and `make syntax`. `make hooks` installs a pre-commit hook that runs the same checks as CI.
- **Rules:** [CONTRIBUTING.md](../CONTRIBUTING.md).

## 9. Future considerations

These gaps wait on herdr:

- No event fires on sidebar collapse or on `cd`, so some numbers and names update on the next event.
- Agent numbering could return on herdr 0.9.0 through `--display-agent`, but only as an opt-in, since agent views hide the order.
- One rare lock race remains. Fixing it would need a second lock with the same staleness problem.

## 10. Glossary

| Term | Meaning |
| --- | --- |
| Reconcile | A full pass that fixes every wrong label. |
| Fast path | The hook pass that names one tab without a snapshot. |
| Label, base | What herdr shows, and that label without its `[N] ` prefix. |
| Context, activity | The two halves of a label: where the work is and what runs there. |
| Owned | Named by the plugin. Anything else counts as a hand rename. |
| Space | A group of workspaces in herdr's sidebar that can collapse. |
