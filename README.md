# herdr-automatic-rename

[![tests](https://github.com/qu8n/herdr-automatic-rename/actions/workflows/ci.yml/badge.svg)](https://github.com/qu8n/herdr-automatic-rename/actions/workflows/ci.yml) [![release](https://img.shields.io/github/v/release/qu8n/herdr-automatic-rename)](https://github.com/qu8n/herdr-automatic-rename/releases) [![herdr](https://img.shields.io/badge/dynamic/toml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fqu8n%2Fherdr-automatic-rename%2Fmain%2Fherdr-plugin.toml&query=%24.min_herdr_version&prefix=%3E%3D%20&label=herdr)](https://github.com/qu8n/herdr) [![license](https://img.shields.io/github/license/qu8n/herdr-automatic-rename)](LICENSE)

## Features

No more having to manually name your new tabs or deal with plain numbered tabs:

`‎ 1 `‎‎‎‎ ‎ `‎ 2 `‎ ‎‎ `‎ 3 `‎‎‎ ‎ ‎ +

This plugin automatically names them either after their foreground process (inspired by [tmux](https://github.com/tmux/tmux)'s `automatic-rename`):

`‎ [1] zsh `‎‎‎ ‎ `‎ [2] nvim ` ‎  ‎‎`‎ [3] ssh `‎‎‎ ‎ ‎ +

Or after the agent session context:

`‎ [1] Debug transient issue `‎ ‎ ‎ ‎‎`‎ [2] Improve test suite `‎‎‎ ‎ ‎ +

The naming mechanism is highly configurable. See the Configuration section below for more info.

## Quick start

### Requirements

- herdr `>= 0.7.1`
- `jq`
- bash
- Linux or macOS

### Install or update

```sh
curl -fsSL https://raw.githubusercontent.com/qu8n/herdr-automatic-rename/main/install.sh | bash
```

This script installs the latest version of the plugin and adds our shell hook, which makes the renaming mechanism happen immediately when a command starts. It picks the hook for your login shell out of zsh, bash, and fish, and writes it to that shell's startup file.

<details>
<summary>Alternative, manual setup instructions</summary>

#### 1. Install the plugin

```sh
herdr plugin install qu8n/herdr-automatic-rename --yes
```

#### 2. Add the hook for your shell

This hook makes the renaming mechanism happen immediately when a command starts. To figure out what your shell is, run `echo $SHELL`.

##### zsh

```zsh
# ~/.zshrc
for _f in ${HOME}/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.zsh(N); do
  source $_f; break
done
```

##### bash

```bash
# ~/.bashrc
for _f in "$HOME"/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.bash; do
  [ -r "$_f" ] && { source "$_f"; break; }
done
```

##### fish

```fish
# ~/.config/fish/config.fish
for _f in $HOME/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.fish
    test -r "$_f"; and source "$_f"; and break
end
```

</details>

### Recommended herdr configs

**1. Turn off herdr's new-tab name prompt.**

```toml
# ~/.config/herdr/config.toml
[ui]
prompt_new_tab_name = false
```

When you create a new tab, herdr prompts you to give it a name. Custom tab names are respected by this plugin. For the best UX, disable this feature to let the plugin do the naming for you by default.

**2. Install herdr integrations for your coding agents.**

See [herdr's integrations docs](https://herdr.dev/docs/integrations/) for installation details. This lets herdr detect an agent natively instead of by reading the screen, which makes for agent tab naming more effective.

## Configuration (optional)

To customize, create your config file at `~/.config/herdr-automatic-rename/config.sh` (or point `HERDR_AUTOMATIC_RENAME_CONFIG` elsewhere). See [config.example.sh](config.example.sh) for the full configuration details. Every setting has a default, so you only need to set what you'd like to change.

## Actions

- **reset**: When you manually name a tab, the plugin respects that name and doesn't touch it. This action lets the plugin take over renaming that tab.

- **doctor**: This action prints why the plugin named the current tab the way it did for troubleshooting purposes.

To invoke an action, either run it from the CLI:

```sh
herdr plugin action invoke herdr-automatic-rename.reset
```

Or bind it in `config.toml` as a `plugin_action`, like this:

```toml
[[keys.command]]
key = "prefix+a" # a for "automatic"
type = "plugin_action"
command = "herdr-automatic-rename.reset"
description = "hand this tab's name back to automatic naming"
```

## Caveats

- Prefix numbering stops at 9 since herdr only allows keybindings up until that number.
- An untitled Claude Code tab gets its name from the session transcript on disk. Set `AGENT_TRANSCRIPT=0` in `config.sh` to stop that.
- Some Linux containers and sandboxes hide the foreground process from herdr, so naming stops (numbering still works). On herdr `>= 0.8.0`, set `HERDR_PROCESS_DETECTION=child-groups` in herdr's environment.
- Below herdr `0.7.4`, a new name only shows at the next redraw, such as a focus change.

## Uninstall

```sh
bash "$(herdr plugin list --json \
  | jq -r '.result.plugins[]|select(.plugin_id=="herdr-automatic-rename").source.managed_path')/automatic-rename.sh" --clear
herdr plugin uninstall herdr-automatic-rename
```

Then delete `~/.local/state/herdr-automatic-rename/`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License

MIT.
