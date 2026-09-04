# herdr-automatic-rename

[![tests](https://github.com/qu8n/herdr-automatic-rename/actions/workflows/ci.yml/badge.svg)](https://github.com/qu8n/herdr-automatic-rename/actions/workflows/ci.yml)

<img width="1200" height="520" alt="Tab bars before and after the plugin names tabs" src="docs/readme-demo.jpg" />

herdr labels tabs `1`, `2`, `3`. This plugin names them after what is in them. Every workspace and tab also carries the `1-9` key that jumps to it.

Examples:

```text
[1] zsh                                 a plain shell
[2] api › feat/oauth › nvim             current directory › branch › program
[3] prod-01 › ssh                       a machine you reached over ssh
[4] PROJ-482 › Fix the revenue query    current branch › what an agent is doing
```

This plugin is highly configurable. See the Configuration section below for more info. For example:

`NAME_TABS=0` turns off the naming, `AUTO_INDEX=0` the numbering, `TAB_CONTEXT=0` the `<where>` half.

## Requirements

herdr `>= 0.7.1`, `jq`, and bash, on Linux or macOS. On herdr below `0.7.4` a new name lands but shows only on the next redraw, such as a focus change.

Run `herdr integration install claude` too if you use Claude Code. It tells herdr which session each pane holds, so a session you opened with a slash command and never titled still gets a name.

## Install

### 1. Install the plugin

```sh
herdr plugin install qu8n/herdr-automatic-rename --yes
```

It triggers at the next herdr event.

### 2. Add the shell hook

The hook renames a tab the instant a command starts. Without it, a new name waits for the next focus or tab event.

**zsh** (`~/.zshrc`):

```zsh
for _f in ${HOME}/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.zsh(N); do
  source $_f; break
done
```

**bash** (`~/.bashrc`, after any prompt or history tool like starship or atuin):

```bash
for _f in "$HOME"/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.bash; do
  [ -r "$_f" ] && { source "$_f"; break; }
done
```

**fish** (`~/.config/fish/config.fish`):

```fish
for _f in $HOME/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.fish
    test -r "$_f"; and source "$_f"; and break
end
```

### 3. Turn off herdr's new-tab name prompt

herdr asks each new tab for a name (`prompt_new_tab_name`, on by default). A name typed there counts as a hand rename, which opts the tab out until you `reset` it, so turn the prompt off:

```toml
# ~/.config/herdr/config.toml
[ui]
prompt_new_tab_name = false
```

Keep `prompt_new_workspace_name` if you use it. A name typed there is a name the plugin leaves alone, prefix aside.

## Configuration

Every setting has a working default, so you don't need a config file to get started. To customize something, write to `~/.config/herdr-automatic-rename/config.sh` (or point `HERDR_AUTOMATIC_RENAME_CONFIG` elsewhere).

See [config.example.sh](config.example.sh) to see the entire configurate suite of settings.

## Actions

- `reset` re-adopts a tab you renamed by hand.
- `clear` strips every `[N]`, restores base names, and reverts agents to detection.

Run one from the CLI, or bind it in `config.toml` as a `plugin_action`:

```sh
herdr plugin action invoke herdr-automatic-rename.reset
```

## Uninstall

Strip the labels first, else `clear`'s renames re-fire the hooks. The strip reaches one herdr session, the one the shell it runs in belongs to, so run it once per session before removing the plugin:

```sh
bash "$(herdr plugin list --json \
  | jq -r '.result.plugins[]|select(.plugin_id=="herdr-automatic-rename").source.managed_path')/automatic-rename.sh" --clear
herdr plugin uninstall herdr-automatic-rename
```

## Good to know

- **Manual renames win.** Rename a tab yourself and naming leaves it alone, though numbering still applies. Run `reset` to hand it back.
- **Numbering stops at 9.** No binding reaches a 10th row, so the rest keep their plain names.
- **Naming needs a foreground process.** Some Linux container and sandbox setups leave herdr unable to see one, so tab naming stops while numbering keeps working. On herdr `>= 0.8.0`, set `HERDR_PROCESS_DETECTION=child-groups` in its environment.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers the tests and the ground rules, and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) covers the non-obvious decisions.

## License

MIT. See [LICENSE](LICENSE).
