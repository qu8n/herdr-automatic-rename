# Architecture

For usage, see the [README](../README.md).

## One reconcile, one entry point

`automatic-rename.sh` runs for every herdr event, both plugin actions, and the shell hooks' fast path. It routes through `ar_run` and dispatches on `argv[1]`. A full reconcile pulls workspaces, tabs, panes, and agents from one `herdr api snapshot` (a single socket call, herdr >= 0.7.2), computes the label every item should have, and issues one rename per item whose label is wrong. Older herdr with no `api snapshot` falls back to `workspace list`, `pane list`, and `agent list` once each plus `tab list` per workspace. Either way, foreground detection stays one `pane process-info` per named tab, since the snapshot carries panes but not each pane's foreground process.

Computing a tab's name and its `[N]` prefix in the same pass is what settles a brand-new tab at `[3] zsh` in a single rename. Every rename is skip-if-correct, so re-firing the pass (herdr's own rename re-emits `tab.renamed`) changes nothing and cannot loop.

## Naming lives in a pure module

`naming.sh` turns `(program, cmdline, title)` into a display name and touches neither herdr nor the filesystem, which keeps the rules (shells, name-only programs, ignored programs, aliases, substitutions, agent titles, truncation, icons) unit testable. The icon knobs, glyph map, and lookup live in `icons.sh` (sourced by `naming.sh`) so the 100+ arm case statement stays out of the naming logic. The engine calls `ar_label` across that seam, which is the module's one entry point for "what should this tab be called": it turns the pane's directory into a context, the program into an activity, and joins them. Every function in these files uses the `ar_` prefix.

## Rows carry values, not escapes

Every `jq` that hands a herdr string to a shell variable runs it through the one `clean` definition (`AR_JQ_CLEAN`) and joins its row on a literal separator. `@tsv` keeps a row parseable by escaping what breaks it, and those escapes are the bug: a tab out of `argv` arrives as the two printable characters `\t`, which nothing downstream can tell from typed text, and every backslash gets doubled, so numbering a tab called `C:\temp` used to rewrite it as `C:\\temp`. Dropping the control characters instead makes the row unambiguous and leaves everything a user can see untouched. `ar_pane_program` returns its two values one per line, which is sound for the same reason.

The delimiter is the ASCII unit separator, not a tab, because bash counts a tab as IFS whitespace: `read` collapses a run of them, so one empty field shifts every field after it. A tab with no label (what `HIDE_SHELL` leaves) used to parse its pane count as its label and was never named again. `clean` is what makes the separator safe, since no value can contain a character in that class.

## Why config and state sit at fixed paths

State (`~/.local/state/herdr-automatic-rename/`) and config (`~/.config/herdr-automatic-rename/config.sh`) use fixed paths, not `$HERDR_PLUGIN_STATE_DIR` / `$HERDR_PLUGIN_CONFIG_DIR`. The live shell hooks run `preexec`/`precmd` under your shell, not under herdr, so they never receive the `HERDR_PLUGIN_*` variables. The herdr-invoked pass and the shell-invoked fast path must share one config and one state store, which forces a path both can name without herdr's help. `$HERDR_AUTOMATIC_RENAME_CONFIG` overrides the config location.

The state path is fixed per session, not per machine. herdr numbers every session's tabs from `w1:t1`, so two servers on one `state.json` overwrite each other's records and prune each other's tabs as closed, and a tab whose record is gone opts out of naming. A named session keeps its socket under `sessions/<name>/`, and `$HERDR_SOCKET_PATH` is the one variable the herdr-invoked pass and the shell hooks both receive, so the engine reads the session name off it and keeps that session's store, lock, and rerun flag under `sessions/<name>/` in the state directory. The default session has no such directory and keeps the store at the root.

herdr exposes no per-tab metadata and no auto/manual flag, so the manual-rename opt-out lives in a small JSON state file keyed by `tab_id`: the last base the plugin set, and whether auto-naming is still on for that tab.

That recorded base is the plugin's only evidence of what it named a tab, so it is written only for a name the tab actually **carries**: the label already matches, or the `rename` reported success. A base recorded for a rename that never landed is indistinguishable, one pass later, from a name typed by hand, so the tab opts out of naming and only `reset` brings it back.

A state file `jq` cannot parse is read as an empty one rather than a reason to fail, and the check slurps and insists on exactly one object because `jq` reads top-level values as a stream: a file holding two of them parses, and writers handed the pair would update each document and write both back, leaving it broken for good. Every writer starts from what is on disk, so an unreadable file used to fail every write for as long as it sat there. The tab lost its record, read as hand-renamed on the next pass, and `reset` could not re-adopt it either, because that is another write. Naming was dead for the session with nothing said about it.

Healing the file does not hand a tab back its name, and cannot. A tab whose record went with the file has a label matching nothing state knows, which is indistinguishable from a hand rename, so the pass that heals the file also opts that tab out. What changes is that the opt-out is recorded and `reset` works again. Re-adopting a tab because its label happens to match the computed name is the one thing the opt-out exists to refuse.

## Locking

A `mkdir` lock (atomic, ownership-token stamped, 30-second steal window) plus a rerun flag coalesces a burst of events into one worker. Contenders raise the rerun flag and exit; the holder loops until no new work arrives. A fast-path run that loses the lock still lands, because the holder's re-pass recomputes names itself.

Stealing an abandoned lock is four steps in a fixed order: read the age a second time, `mv` the directory aside, `mkdir` the lock path straight back to reserve it, and only then ask whether what was moved was really stale. Each step earns its place:

- The three-step steal this replaced (remove the owner, `rmdir`, `mkdir`) let a second contender empty and take the lock the first had just created.
- The `mv` alone still let a contender that measured the age before the winner's `mkdir` move that live lock away, because the age was measured on a directory the `mv` no longer moves.
- Deciding before reserving left the lock path empty for as long as the decision took, which a third contender's plain `mkdir` wins. Reserving first shuts that window to one syscall.

A moved lock that turns out to be live gets its owner token copied into the reserved directory, so its holder's own `ar_unlock` still releases it. The directory is never `mv`d back: `mv` onto an existing name moves the source INSIDE it, nesting one lock in another where nothing can ever `rmdir` it. Get any of this wrong and two passes run at once, both writing the whole state file over each other, costing a tab the ownership record that keeps it named.

None of it is a proof, since no POSIX shell primitive can check a lock's age and claim it in one operation, so the measure is a stress test. Six contenders against one abandoned lock: the second age read takes two holders from roughly a third of bursts down to somewhere between none and one in a hundred, depending on the harness.

One chain survives, named here so nobody rediscovers it. A contender passes its second age read, somebody else steals and rebuilds the lock in the moment before its `mv`, so it moves a live lock; a third contender then wins the free name inside the one fork between that `mv` and the reservation. Two passes reconcile. Both links are one process spawn wide, and two harnesses disagree on how often it lands: one saw none in 350 trials, another about one burst in a hundred. Rare enough to argue about, not rare enough to call gone. Serializing every steal behind a second `mkdir` mutex would close it and was rejected: a stealer killed while holding that mutex leaves it behind, and then nothing is ever stealable again. The mutex would need its own staleness rule, which is this same problem one level down.

A fifth guard was written and removed, worth recording because it read as working. The fast path was to refuse a free lock name while a recent `*.stale.*` copy said a steal was mid-flight. It could never fire: `mv` is a rename, a rename leaves the moved directory's mtime alone, and only directories already proven older than the window reach the move, so "recently moved" is not something mtime can answer. Rebuilt to work, by carrying the timestamp in the copy's name, it changed nothing measurable over 200 trials and cost three of them a round where every contender stood down.

There is a second thing to measure, and missing it is how three rewrites of this function each looked like progress. Counting double holders says nothing about a lock left behind that nothing can release: `ar_unlock` releases only a lock carrying its own token, and no contender may steal one whose mtime is fresh, so a lock stamped with nobody stops every event for the length of the window. One version scored zero double holders and left that lock behind in 70 bursts out of 100. Both numbers belong in any future comparison. The cause: the hand-back wrote the victim's token with `cat old > new`, which truncates the destination before reading the source, so a victim that had not stamped itself yet got an empty owner file parked on the name, and a victim that stamped into the directory the thief had reserved had it erased. Reading the token first and letting the name go when there is none takes both to zero.

The same class, one layer up: a lock is granted only when its token is on disk. The shell reports a failed redirection, not `printf`, so the `2>/dev/null` that once sat on that line silenced nothing and hid a caller told it held a lock it could never release. `ar_lock_stamp` checks.

One narrow case is accepted rather than fixed. A steal that reserves the name and finds it moved a live lock hands that holder's token back, and if the holder exits between its own stamp and that hand-back, nothing will release the lock the token names. It ages out of the steal window and the next event takes it, so the cost is a pause rather than a lock held forever, the same recovery a holder killed at any other moment gets. A `*.stale.*` copy left by a killed steal is litter for the same reason and nothing sweeps it. That is affordable because no copy but its own is ever read, and a steal clears its own destination before moving anything into it: a lock nested by `mv` is invisible to the token read that follows, so it reads as unclaimed and the cleanup destroys a live holder's lock. Only residue from a dead run holding the same token can put something there, and the token is weaker than it looks, since a fresh `$RANDOM` moves by a fixed step per pid.

An **action** cannot defer that way. Deferring works because every pass computes the same thing, and an action's request lives in the contender's own process rather than in the state the holder reads: which tab to re-adopt, or whether to strip. So `reset` and `clear` wait for the lock (bounded, since a pass runs in well under a second) and report that they are waiting rather than handing the job to a pass that knows nothing about it. Exiting there is what used to make a reset pressed during a burst of events do nothing, and say nothing either.

A reset's force is spent by the pass that consumes it. The holder can loop its reconcile when events land while it runs, and a tab still forced on a later loop is a tab whose opt-out check is still bypassed: rename it by hand inside that window and the loop would take the name back, which is the one promise this plugin makes.

## The shell hooks find their own engine

herdr installs a github plugin to a content-hashed directory, so the hooks cannot hard-code the engine path. Each hook resolves `automatic-rename.sh` relative to its own sourced-file location: zsh via `${(%):-%N}`, bash via `BASH_SOURCE[0]`, fish via `status current-filename` captured into a global. The bash hook never overwrites a `DEBUG` trap another tool already set, and cooperates with `bash-preexec` / `ble.sh` / `atuin` when present.

## Shell constructs are sampled, not trusted

The preexec fast path names the tab by the first word of the command line, which is only honest when that word resolves to an external program. zsh expands aliases in preexec's `$2` but never functions, and bash and fish hand over the raw line, so a function `l`, a builtin, a reserved word, or a typo arrives verbatim. No program list can match those words (`IGNORED_PROGRAMS` holds `eza`, not the function `l` that calls it), so trusting them renamed the tab and let precmd snap it back: a flicker on every instant construct.

Each hook classifies the command word (`whence -w` in zsh, `type -t` in bash, `type --type` in fish). External commands keep the instant rename. Everything else gets a `shell` marker, and the engine sleeps 0.2 s (before taking the lock), then names the tab by the pane's actual foreground process via `pane process-info`. An instant construct has exited by then, so the leader is the shell again and nothing is renamed. A construct that wraps a long-running program gets that program's real name, which the typed word never was. When sampling fails the engine renames nothing rather than guess.

## Numbering caveats

- **Tabs** are numbered by array order, not the non-contiguous `.number` field.
- **Workspaces** are numbered by herdr's visible sidebar order, not the raw `workspace list` order. `alt+N` resolves through herdr's own `workspace_at_visible_position`, so a row the sidebar does not render is a row no keybind reaches, and a collapsed space both hides rows and moves the ones below it. `ar_workspace_positions` mirrors herdr's `workspace_list_entries_inner` and owns the rules (which workspaces nest, which member heads a space, what a collapsed one still renders); its header comment is the copy to keep in sync with upstream. Hidden rows come back as position 0 and drop their prefix like 10+.
- **Agents** are numbered only on herdr `< 0.7.5`, and there only when `agent_panel_sort` is grouped (`spaces`).
  - herdr `0.7.5` added `valid_agent_name` (`^[a-z][a-z0-9_-]{0,31}$`, `src/app/agents.rs`) and answers `invalid_agent_name` to anything else, so `[N] claude` is not a name that release can hold. `ar_agent_prefix_ok` gates on the version, and an unreadable version counts as restricted, because declining to number is recoverable and firing renames herdr rejects is not. The same release also stopped resolving `terminal_id` as an agent target (`resolve_agent_target`, `src/app/terminal_targets.rs`), so renames target `.pane_id`, the one form every supported version accepts.
  - Where it does apply, `priority` sort still opts out: the panel reorders behind an order the CLI never exposes, so the plugin strips agent numbers rather than guess wrong, and renumbers when you switch back.
  - Stripping runs on the restricted versions too, which is what unsticks an `[N] claude` written by an older herdr and older plugin. Nothing else can: that name fails every rename a newer herdr accepts, including `--clear` aimed at a `terminal_id`.
  - Numbering keeps its two-phase park (park at a unique temp, then finalize) to dodge herdr's duplicate-name rejection when several agents share a base like `claude`. It is reachable only on herdr `< 0.7.5`.
  - `agent.view.set` (herdr `0.7.5`) is a further reason the feature stops there. An active view redefines the order `focus_agent` follows, by sort or by filtering rows out, and `apply_agent_view` bypasses `agent_panel_sort` entirely. No event announces a view and no request reads one back, so a plugin cannot even detect the drift.
- Nothing numbers past 9, since no keybind reaches a 10th item.

## Collapse is readable, but only from session.json

herdr publishes sidebar collapse nowhere in its API: no field on `workspace list` or `api snapshot`, no request method, and none of the events a plugin can subscribe to (checked against protocol 17). Toggling a space flips `collapsed_space_keys` in memory and marks the session dirty, which leaves one readable copy: the top-level `collapsed_space_keys` array in that session's `session.json`. `ar_collapsed_spaces` reads it, at the path `ar_herdr_session_dir` derives by stripping the filename off `$HERDR_SOCKET_PATH`. herdr keeps a session's socket, `session.json`, and `config.toml` in one directory and exports that variable into plugin commands and pane environments both, so the herdr-invoked pass and the shell hooks resolve the same files, in a named session as well as the default one. `ar_agent_sort` reads its `config.toml` through the same helper.

Two consequences. The file is written atomically (temp plus rename, so no torn reads) on a 5-second debounce, so a pass that runs right after the click reads the old value and corrects itself on a later event. And because the toggle emits no event, nothing wakes the plugin when collapse changes: the numbers settle on whatever event arrives next, usually seconds away in an active session (`pane.agent_status_changed` fires constantly). So the first `alt+N` after a collapse can still jump by the old numbering. Upstream support, either an event or a `collapsed` field on `WorkspaceInfo`, is what would close that window.

## A numbered workspace still follows its directory

herdr names a workspace after `identity_cwd`, its own tracked directory: the repository that directory belongs to, or the directory itself outside a repo. The first `workspace rename` freezes that name for good. herdr goes on updating `identity_cwd` as panes `cd`, and never labels from it again, so a plugin that numbers a workspace stops its name tracking anything. That was [#13](https://github.com/qu8n/herdr-automatic-rename/issues/13). The label kept whatever the workspace was called when it opened, and no smaller rename would have helped, because there is no rename that leaves the derivation alive.

So the base comes from `identity_cwd` rather than from the label the last pass wrote. `ar_workspace_identities` reads it out of the same `session.json` `ar_collapsed_spaces` reads, and inherits the same two caveats. The value is in no API response (no field on `workspace list` or `api snapshot`, protocol 17), and herdr saves the file on a 5-second debounce, so a `cd` reaches the label an event or two later rather than instantly. No session file, or an older herdr without the field, yields no rows and the pass falls back to recycling the label, which is what it did before.

A workspace herdr has not persisted yet reads its directory off its panes instead. session.json is saved on a 5-second debounce, so a workspace created inside that window is in no copy of the file, and every new workspace passes through that state: the numbering rename lands first, and by the time herdr writes the file the label it wrote is the stale one, which read as a name somebody typed and opted the workspace out for good. `ar_workspace_pane_dirs` covers it from the panes the pass already holds, where at creation the label and the pane agree. It is a stand-in and not a second source of truth. herdr moves `identity_cwd` with the workspace's active pane, and answering which pane that is takes the layout, so a workspace whose split panes sit in different directories is where a guess disagrees with herdr's own label. This one cost a live session to find, with the suite green.

One thing this does not fix: a `cd` emits no event the plugin subscribes to, so the new name lands on whatever event arrives next, the same way collapse does. `workspace.updated` (herdr 0.8) looks like the event that would close it, and is not subscribed here because a hook naming an event an older herdr does not know is untested against 0.7.x.

`ar_project_base` turns that directory into the base. It walks up for a `.git` instead of asking git, because a linked worktree's `.git` is a file and herdr names such a workspace after the checkout's own directory, which is the first hit up the chain. It costs no process. Measured against herdr 0.8.2, both arms: a pane that `cd`s from a repo root into `tests/` keeps the repo's name, and a pane that `cd`s between plain directories takes the new directory's name.

Which workspaces this applies to is the ownership question the tabs already answer, so `ar_ws_track_eligible` answers it the same way, keyed `ws:<workspace_id>` in the same state file. A label that already is herdr's derivation gets adopted, which covers a workspace seen for the first time. A label that is what we last wrote goes on being tracked, and that is the case a `cd` depends on: herdr's derivation has moved and ours has not, so only the record tells that apart from a name somebody typed. Anything else is somebody's name, gets recorded as opted out, and is only ever numbered. Renaming a workspace back to what herdr would call it hands tracking back, which is the whole recovery path, since `reset` takes a tab and a workspace has no equivalent.

Both kinds of record live in one state file, which is why `ar_state_prune` selects `ws:` keys through. A keep list of tab ids never names a workspace, so pruning on it alone dropped every workspace record on the pass after it was written. Each workspace then read as first-seen against a label that was no longer herdr's derivation, and opted itself straight out. That is the same bug this section is about, one layer down, and it stayed green in the suite until a live session showed it.

## An agent tab is named from its terminal title

Five agent panes named after their foreground program give five tabs reading `claude`, the one thing the program-name rule cannot fix. The task tells them apart, and a coding agent already publishes it: it sets its terminal title to a description of the work and keeps that current as the work moves. So where herdr reports an agent for the pane, `ar_tab_name` prefers the title over the program name (`AGENT_TITLES`, default on).

Reading it is free. herdr publishes the title on the pane object itself, beside the detection result, so `ar_pane_facts` lifts the agent, the title, and the pane's directory out of the `AR_PANES_JSON` the reconcile already fetched: one jq over cached JSON, no herdr call on any version. A title that lands also ends the computation, so such a tab skips the `pane process-info` call the program path needs, which leaves an agent-heavy session making fewer herdr round-trips than before. The local cost is a wash rather than a saving: the reply that used to be parsed is simply not fetched, and the values come off the tab row instead. Refreshes ride `pane.agent_status_changed`, an event the plugin already subscribes to for agent numbering, so the label follows the work with nothing polling.

`ar_title_clean` decides whether a title says anything. It refuses:

- the agent naming itself: its herdr kind (`claude`), that kind followed by `code` (`Claude Code`), or a `TITLE_IGNORE` entry, which is what an agent titles a session it has no task for yet;
- the directory the pane sits in, which is what claude falls back to at startup;
- a bare number, which is herdr's own generated tab label handed back through the title.

Each refusal returns the empty string, and naming carries on to the program, `PROGRAM_ALIASES` and the `WRAPPER_PROGRAMS` unwrapping included. A title that survives replaces the program name outright, alias and all: `AGENT_TITLES` is the request for the task, and an alias shortening `claude` to `cl` is not a request to hide the work. The program still supplies the icon, and the label gets its own budget, `MAX_TITLE_LEN` (28) rather than `MAX_NAME_LEN` (20), cut at a word boundary when that leaves at least half of it. A title is a sentence, and `Investigate` says more than `I` does.

The first thing `ar_title_clean` does is drop the leading run of non-alphanumerics. herdr keeps an ANSI-stripped copy of the title (`terminal_title_stripped`) and stripped means exactly that: the spinner glyph an agent parks in front of its title while it works is still on it, and claude cycles four of them. Without the strip the label would flip between `Task` and `<glyph> Task` on every status event, and each flip is a rename.

An agent that brands its own titles puts something in front of that glyph, and the strip stops on the brand rather than reaching past it. oh-my-pi writes `π ⠋ Task` while it works, `π > Task` when the turn is yours and `π ! Task` when it wants you, so every status change arrived as a different label with the glyph on show. `TITLE_BRANDS` names the brand per herdr agent kind, and `debrand` takes it off before the strip runs, at the very front only and only with a non-alphanumeric behind it, so `πcalc rewrite` keeps its first letter. What is left of a title that was nothing but brand and glyph is nothing, which is the same "no task yet" answer the refusals give, so the tab falls back to the program name.

`jq` does that strip, and the case-folding both sides of the comparisons need, in one call. Its character classes know Unicode; a byte-wise strip would eat the first letter of a title that opens with a non-ASCII word, and herdr may launch a plugin with no `LC_*` at all. Reaching for jq keeps the function inside the module's rule rather than bending it, and `ar_format` next door already calls it to truncate on codepoint boundaries for the same reason.

## The context half of a label

A tab used to say only what was running in it. `nvim` in three checkouts gave three tabs reading `nvim`, and an agent tab reading `claude` said no more. The context is the other half: the directory the pane sits in, in front of the program, joined by `CONTEXT_SEP` (`ar_compose`). It is `TAB_CONTEXT`, default on.

The directory is refused when it says nothing a tab bar has room for: a relative path (herdr reports absolute ones, so this is a value that arrived broken), the filesystem root, and the home directory, which is where a shell sits when it is nowhere in particular.

A directory too long for `MAX_CONTEXT_LEN` is reduced the way a branch is (`ar_shorten`) rather than cut through the middle: worktrees and branches are named the same way by the same people, so `bugfix-proj-482-fix-rev-discrepancy` reads as `PROJ-482` where a plain cut gives `bugfix-proj-`, which identifies nothing.

**The workspace name is not repeated.** herdr shows the workspace above its tabs, so a tab in the workspace named after its own directory would spend half its width on what is already on screen. `ar_reconcile_tabs` carries each workspace's own label down with its id, strips the `[N]` prefix (what it is compared against is a directory name, and `[1] api` is not one) and hands it to `ar_tab_name`, which passes it to `ar_context_dir`. The compare folds ASCII case. It also treats a worktree as the same place as its workspace: herdr names one after the branch with the convention in front of it stripped, so the directory ends with the workspace's name (`bugfix-proj-482-fix` under `proj-482-fix`). A separator has to sit before the match, or a workspace called `api` would swallow a tab that really is in `legacy-api`. Otherwise the compare is exact, so a tab whose directory has left its workspace behind is exactly the one that keeps saying where it is.

Each part carries its own budget rather than sharing one: the directory is cut to `MAX_CONTEXT_LEN` (12), the program keeps `MAX_NAME_LEN` (20), an agent's task keeps `MAX_TITLE_LEN` (28). The whole is then bounded by construction and there is no second number to keep in step. An empty activity still empties the whole label, because that is `HIDE_SHELL` asking for no name at all and half a name is not what it asked for.

### The branch

`git.sh` is the one module that reads the filesystem, which is why it is neither in `naming.sh` (strings) nor `icons.sh` (a table). It reads `.git` directly and never runs git: `git rev-parse` is a process, `HEAD` is one open, and this runs per named tab on every event and again on every shell prompt. Its answers come back in `AR_GIT_*` globals, because a command substitution is exactly the fork the file exists to avoid. Nothing is cached: a fresh read costs less than remembering a stale answer, and a checkout shows up at the next event rather than whenever a cache expires.

It follows the `gitdir:` line of a linked worktree or submodule to the directory holding that checkout's own `HEAD`, and its `commondir` to the shared refs the default branch lives in. Agents run in worktrees, so that is not the exotic layout. Relative paths inside those files are left relative, since every use is opening a file under them and the kernel resolves `..` perfectly well.

A rebase is the one detached HEAD that keeps its name: it records the branch it set aside, and that is still where the user is, so the tab does not take a new hash on every step. Any other detached HEAD shows the short hash, because that is where commits get lost and silence there cannot be told from sitting on the trunk.

`ar_branch_label` (in `naming.sh`, so it is testable as a string rule) decides what the branch contributes. The repository's own default contributes nothing, compared exactly because git refs are exact. A repository that records no default at all — cloned without an `origin/HEAD`, or never cloned — falls back to the conventional trunk names in `TRUNK_BRANCHES`, because otherwise every tab of it carries `main` alike, which is the column of noise the rule exists to prevent; a repository that does record one is believed over the list. A branch that repeats what the reader can already see is dropped too (`ar_branch_new`): a worktree named after its branch would say one thing three times, since the workspace above the tabs says it once already. A name that fits is left whole, so `feat/oauth` keeps the namespace that tells it from `fix/oauth`. Only a name over `MAX_BRANCH_LEN` is reduced, and then an issue key wins outright and is the one value allowed past the budget, because half a key identifies nothing.

### The machine, for a remote pane

A pane running `ssh` is about the machine on the other end, so the host takes the context and the local directory and branch are dropped: both describe where the user was standing when they left, and a branch printed beside `prod-01` reads as that machine's. The `ssh` mark stays in the activity, which is where the program rules would have put it anyway, so nothing has to be invented to keep the tab saying it is remote.

The destination is parsed rather than guessed at, because the first word after `ssh` is as often an option's value as a host: `ar_ssh_host` skips options, gives the ones whose value is a separate argument their word, stops at the first bare argument, and drops the user, the port and the path from it. Everything after the destination is the remote command, which the remote's own terminal title is what reports.

The whole of it hangs off the program name being `ssh`, in `ar_label`, so no other pane pays for the parse -- and both naming paths get it for free, including the shell hook, which is the only thing that can name such a tab the moment the command starts.

### The two paths have to agree

The reconcile is not the only thing that names a tab. The shell hook's fast path renames on every command, so a hook that dropped the context would flip the tab between `api › nvim` and `nvim` on every prompt -- the same flicker the fast path exists to avoid.

It gets both halves without a herdr call. The directory is the hook's own `$PWD`: the hook backgrounds the engine from the pane, so it arrives for free, and a `cd` shows up at the next prompt rather than waiting for an unrelated herdr event. The workspace name to dedupe against is recorded on the tab, in the `ws` field of its state record, by whichever reconcile last named it -- asking herdr for it would be a socket round-trip on every command. A workspace renamed since then leaves that field stale for one pass, and the pass that notices is the one that changes the label anyway, since a dedupe that flips changes what the label should be.

### A session with no title

`ar_title_clean` refusing a title is common and not an error: Claude Code derives its terminal title from what the user typed, so a session opened with a slash command and answered by the agent alone is never given one. That tab read `claude` for as long as it ran.

`transcript.sh` answers there. herdr's own integration hook (`herdr integration install claude`) reports the session id through `pane.report_agent_session`, and it arrives on the pane as `agent_session.value` — no extra request. The transcript is then read from disk: the last `ai-title` line, which is the title Claude Code generated and keeps current, or failing that the first prompt the user actually typed, which is what Claude Code's own session list shows for an untitled session. A prompt that is a slash command yields the command and its arguments, since the argument is usually what tells one run of a command from the next.

Three things bound it. It runs only where a pane has an agent that is Claude Code, has a session id, and produced no usable terminal title, so a titled agent pays nothing and another agent's pane is never read from Claude's tree — a pane can carry a session value a claude left behind in it, and reading that would put one agent's prompts on another agent's tab. Each read takes the end of the file it needs — the tail for the title, the head for the opening — rather than the file, because a long session's transcript runs to megabytes. And the session id becomes part of a path, so it is refused unless it is shaped like a UUID rather than cleaned.

Telling the user's own prompt from the rest is not cosmetic: a slash command expands into the conversation as further user messages, a tool answers with its output, and a resumed session opens with a caveat the tool wrote. Naming a tab after any of those names it after the plumbing. Newer transcripts mark what the user typed with `origin.kind`; older ones mark nothing, and there a message whose content is a plain string is the same thing by another road, since everything the tool injects arrives as blocks.

Two costs are worth stating plainly. It reads what the user said to their agent, which is why `AGENT_TRANSCRIPT=0` exists and why nothing else in this plugin reads a file it was not pointed at. And the format is undocumented: `ai-title` and `origin.kind` are Claude Code internals and can change in any release, so a transcript that no longer carries them yields nothing and the tab is named as it was before this existed — the failure mode to have.

## Which pane names a tab

A tab's name comes from one of its panes, so the pass has to pick that pane. The snapshot's `layouts` array makes the choice possible: one entry per tab, each carrying the `focused_pane_id` of that tab's own focus. It holds for tabs nobody is looking at, which the pane list cannot report (no pane of a background tab carries `.focused`), and it is per-tab, so it never picks up the globally focused pane, which belongs to whichever client moved focus last and may sit in another tab entirely (herdr supports several clients and remote attach).

Focus alone is not the whole answer for a tab with several panes. A split with an agent in one pane and a shell in the other is about the agent, and while the agent works focus sits in the shell, so naming by focus alone advertised the shell. The reshape picks, in order:

1. the tab's own focused pane, when herdr reports an agent running in it;
2. any pane of the tab holding an agent whose status is `working` or `blocked`;
3. the tab's own focused pane.

Rule 2 asks for a status on purpose. An idle agent has nothing to say about a tab you have moved on to, and naming that tab after it would take the label away from the pane you are reading.

That is per-tab data, so it travels with the tab: the reshape that slices the snapshot joins the pane it picked onto each tab row as `_name_pane`, along with that pane's agent, task title and directory, and the tab loop reads all of it off the row it already has. `ar_resolve_pane` holds only the inference for rows where the column is empty, which costs the loop nothing on either path.

Those lifted facts describe **the pane the reshape picked** and nothing else, so naming uses them only when the pane it resolved is that pane. Where the column came back empty the pane came from the pane list instead, and its facts have still to be read: taking the row's empty fields for that pane cost such a tab both its title and the runtime unwrap, so a `node`-fronted agent read `node` again.

Older herdr, and the per-list fallback path, ship no layouts. Rules 1 and 3 both ask for the tab's own focused pane, so neither can be answered there. Rule 2 asks only for an agent at work among the tab's panes, so it still can, and it still does: a no-layout snapshot names such a tab after that agent. That is deliberate, since a split with an agent working in it is the case the rule exists for, and the rule never needed a layout to see it. Everything else falls to the inference in `ar_resolve_pane`: the sole pane of a single-pane tab, else the tab's own focused pane, else nothing. So a background multi-pane tab keeps whatever name it has unless an agent is working in it.

The per-list path is narrower. With no snapshot there is no reshape at all, so rule 2 never runs either and that inference is the whole of it.

## The placeholder rule

herdr labels a fresh tab with a small integer. When naming is on but the tab's foreground program cannot be read yet (no pane resolves, or `process-info` answers nothing), the pass counts the tab's position but defers its rename, so no throwaway `[3] 3` flashes before the real name arrives. When naming is off, the integer is numbered as-is, since nothing else will ever name it.

## An empty name is a name (HIDE_SHELL)

`HIDE_SHELL=1` labels a shell tab with the empty string, the only way to get herdr's own tab number back on screen: herdr renders the number whenever a tab has no label, and there is no API to ask for it directly.

The empty string is now a name the engine has to carry around, so the invariant is: **a name is returned on stdout, and "cannot compute one" is reported only through exit status, never as empty output.** Every site that could confuse the two follows from it:

- `ar_tab_name` reports failure through its exit status instead of an empty string, and `ar_reconcile_tabs` branches on that status rather than on the string it got back.
- The `[N] ` prefix helpers accept a bare `[3]`, the numbered form of an empty base. Without that, a hidden tab would read its own label back as a hand-typed name and opt itself out of naming permanently.
- `ar_desired` numbers an empty base as `[3]` rather than `[3] `, since herdr drops the trailing space anyway and the bare form round-trips back through `ar_strip_prefix`.
- The opt-out state machine keeps a tab whose recorded name is empty even when the label reads as herdr's integer again, which is what a restored session and herdr's own relabeling look like from here.
- `ar_reconcile_tabs` writes an empty base when the emptiness is deliberate, and skips the tab only when herdr has not labeled it at all.
- The fast path is the one exception: it calls `ar_label` directly rather than through `ar_tab_name`, so it has no status to read and tests `HIDE_SHELL` itself to decide whether an empty label is an answer.

The placeholder rule above is unaffected: it defers a tab whose name is not computable *yet*, while an empty name is computed and final.

## Testing

`tests/` runs on bash and jq alone (no bats). It covers the pure naming rules, the `[N]` prefix helpers, the JSON state store and opt-out state machine, the cross-invocation lock, the shell hooks, and a full reconcile driven against a fake `herdr` (`tests/mocks/herdr`) that serves fixture JSON and records every rename the engine issues. Sourcing `automatic-rename.sh` defines its functions but runs nothing (guarded by `BASH_SOURCE[0] == $0`), so the helpers can be exercised directly.
