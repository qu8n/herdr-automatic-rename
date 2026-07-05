# herdr-automatic-rename: live per-command tab auto-naming (zsh).
#
# herdr has no "foreground command changed" event, so these zsh hooks give the
# real-time updates: preexec renames the tab after the command that is starting,
# precmd renames it after the shell name once back at the prompt. The plugin's
# herdr [[events]] handle everything else (tab switches, new tabs, agents,
# numbering). A lock in the engine keeps the hook and events from racing, and the
# engine honors the NAME_TABS toggle (this hook stays dumb).
#
# Source this from your zsh startup (point at wherever the plugin lives):
#   source /path/to/herdr-automatic-rename/shell/hook.zsh
#
# No-ops outside a herdr pane (herdr injects $HERDR_PANE_ID/$HERDR_TAB_ID) and
# when the engine is not found next to this file. Runs are backgrounded so the
# prompt never blocks on herdr.

# Resolve the engine next to this file, so the hook works no matter where the
# plugin is installed (herdr's hashed github dir, a manual clone, a symlink).
# ${(%):-%N} is the zsh-standard way to read the sourced file's own path and is
# immune to FUNCTION_ARGZERO being toggled, unlike $0.
_har_self="${(%):-%N}"
_har_bin="${_har_self:A:h:h}/automatic-rename.sh"
unset _har_self

if [[ -n ${HERDR_PANE_ID:-} && -x $_har_bin ]]; then
  # Background in a subshell so the interactive shell never prints the
  # "[1] <pid>" job-start line (& disown only hides the completion notice).
  #
  # zsh hands preexec three forms of the command: $1 is what the user typed
  # (aliases NOT expanded), $2 is a single-line alias-expanded version, and $3
  # is the full expanded text. Pass $2 so an alias like `..` (-> `cd ..`) names
  # the tab by its real program, matching a typed `cd ..`, instead of showing
  # the literal `..`. Fall back to $1 when history is off and $2 is empty.
  #
  # precmd passes the shell name ("zsh") so a bare prompt names the tab "zsh"
  # regardless of the login shell.
  _har_preexec() { ("$_har_bin" preexec "${2:-$1}" >/dev/null 2>&1 &); }
  _har_precmd()  { ("$_har_bin" precmd zsh         >/dev/null 2>&1 &); }

  autoload -Uz add-zsh-hook
  add-zsh-hook preexec _har_preexec   # add-zsh-hook is idempotent on re-source
  add-zsh-hook precmd  _har_precmd
fi
