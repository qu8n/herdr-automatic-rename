# herdr-automatic-rename: live per-command tab auto-naming (bash).
#
# herdr has no "foreground command changed" event, so this hook drives the
# real-time updates: preexec names the tab after the starting command, precmd
# names it after the shell once back at the prompt. Everything else (tab
# switches, numbering, agents) comes from the plugin's herdr [[events]].
#
# bash has no native preexec, and the DEBUG trap + PROMPT_COMMAND are SHARED,
# exclusive resources that tools like atuin, bash-preexec, ble.sh and starship
# rely on. Overwriting either silently breaks them, so we cooperate:
#   * If preexec_functions / precmd_functions already exist (the bash-preexec /
#     atuin convention), just register into them -- that framework owns the trap
#     and calls us with the command line as $1. Nothing to clobber.
#   * Otherwise drive precmd from PROMPT_COMMAND and preexec from a DEBUG trap,
#     but install the DEBUG trap ONLY if no other tool has one (checked via
#     `trap -p DEBUG`). If one exists we leave it alone and skip live preexec;
#     precmd still runs.
#
# Source this AFTER your prompt / history tools so their arrays already exist:
#   source /path/to/herdr-automatic-rename/shell/hook.bash
#
# No-ops outside a herdr pane and when the engine is not found. Needs bash 3.1+.

# Resolve the engine next to this file so the hook works wherever the plugin
# lives. BASH_SOURCE[0] is the sourced file even inside the functions below
# (bash 3.0+); resolve to an absolute, symlink-safe dir so a later `cd` in the
# shell can't invalidate the path.
_har_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
_har_bin="$_har_root/automatic-rename.sh"

# The _har_installed latch makes re-sourcing (e.g. `source ~/.bashrc`) a no-op,
# so PROMPT_COMMAND never grows a second entry and we never double-register.
if [[ -n ${HERDR_PANE_ID:-} && -x $_har_bin && -z ${_har_installed:-} ]]; then
  _har_installed=1

  # Background in a subshell so bash never prints a "[1] <pid>" job-start line.
  # preexec's $1 is the command line; precmd passes the shell name ("bash") so a
  # bare prompt names the tab "bash" regardless of the login shell.
  _har_preexec() { ("$_har_bin" preexec "$1"   >/dev/null 2>&1 &); }
  _har_precmd()  { ("$_har_bin" precmd  bash    >/dev/null 2>&1 &); }

  if declare -p preexec_functions >/dev/null 2>&1 || declare -p precmd_functions >/dev/null 2>&1; then
    # A preexec framework (bash-preexec / ble.sh / atuin) owns the trap; just
    # register and let it dispatch us. Detect the arrays with `declare -p`, not
    # ${arr+x}: bash-preexec declares them EMPTY, and ${arr+x} tests element 0
    # (unset for an empty array) so it would miss them. The case guards are
    # belt-and-suspenders on top of the _har_installed latch.
    case " ${preexec_functions[*]} " in *" _har_preexec "*) : ;; *) preexec_functions+=(_har_preexec) ;; esac
    case " ${precmd_functions[*]} "  in *" _har_precmd "*)  : ;; *) precmd_functions+=(_har_precmd)   ;; esac
  else
    # Standalone: no preexec framework present. Drive precmd from PROMPT_COMMAND
    # and preexec from a DEBUG trap -- but NEVER clobber a DEBUG trap another
    # tool already installed (e.g. starship on bash < 4.4). If `trap -p DEBUG`
    # reports one, skip installing ours: live per-command naming is disabled,
    # precmd still runs. (On bash 3.2 a source-time `trap ... DEBUG` cannot
    # override an existing trap and `trap -p DEBUG` reads empty from a sourced
    # file, so both paths agree: do no harm.)
    #
    # Latch: fire preexec only for the FIRST command after a prompt. Start
    # DISARMED (=1) so the trap fires neither on this hook's own trailing lines
    # nor on a pre-existing PROMPT_COMMAND entry before our wrap first runs; each
    # precmd re-arms it (=0), firing disarms it. DEBUG is not inherited by
    # functions (functrace off, the default) so the wrap's internals never
    # re-trigger it -- the same assumption bash-preexec makes.
    _har_fired=1
    _har_debug() {
      [[ -n ${COMP_LINE:-} ]] && return            # programmable completion
      [[ ${BASH_SUBSHELL:-0} -gt 0 ]] && return    # command substitutions etc.
      [[ $_har_fired == 1 ]] && return             # already fired this prompt
      case "$BASH_COMMAND" in _har_*) return ;; esac
      _har_fired=1
      _har_preexec "$BASH_COMMAND"
    }

    # Append our wrap LAST in PROMPT_COMMAND so re-arming happens after every
    # other precmd entry; preserve $? for anything downstream that reads it.
    _har_precmd_wrap() {
      local _har_st=$?
      _har_fired=0
      _har_precmd
      return $_har_st
    }
    PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}_har_precmd_wrap"

    # Own the DEBUG trap only when nothing else holds it. Installed LAST: nothing
    # in this hook runs at top level afterward, so the trap has no trailing setup
    # line of ours to fire on.
    if [[ -z $(trap -p DEBUG 2>/dev/null) ]]; then
      trap '_har_debug' DEBUG
    fi
  fi
fi
