# herdr-automatic-rename: live per-command tab auto-naming (fish).
#
# herdr has no "foreground command changed" event, so this hook drives the
# real-time updates via fish's native events: fish_preexec fires right before a
# command runs (with the command line in $argv[1]), fish_postexec fires when
# back at the prompt. Everything else (tab switches, numbering, agents) comes
# from the plugin's herdr [[events]].
#
# Source this from your fish config (~/.config/fish/config.fish):
#   source /path/to/herdr-automatic-rename/shell/hook.fish
#
# No-ops outside a herdr pane ($HERDR_PANE_ID) and when the engine is not found.
# Runs are backgrounded so the prompt never blocks on herdr.

# Resolve the engine next to this file and stash it in a GLOBAL: fish function
# bodies do not close over sourcing-time locals, but they do see globals at call
# time. `status current-filename` is this sourced file's path.
set -g _har_bin (dirname (dirname (status current-filename)))/automatic-rename.sh

if test -n "$HERDR_PANE_ID"; and test -x "$_har_bin"
    # preexec: name the tab after the command that is starting ($argv[1]).
    #
    # The first word only names a program when `type --type` says "file" (a
    # real executable). fish hands us the raw line, fish aliases ARE functions,
    # and fish itself wraps some externals in functions (`ls`, `cd`), so
    # functions, builtins, and typos all arrive unresolved; naming the tab
    # after such a word flashes a bogus name on every instant construct
    # (preexec renames, postexec snaps it back). Anything that is not a file
    # gets a "shell" marker telling the engine to sample the pane's real
    # foreground process instead.
    function _har_preexec --on-event fish_preexec
        set -l word (string split -m 1 ' ' -- $argv[1])[1]
        set -l kind (type --type -- $word 2>/dev/null)
        if test "$kind" = file
            command "$_har_bin" preexec "$argv[1]" >/dev/null 2>&1 &
        else
            command "$_har_bin" preexec "$argv[1]" shell >/dev/null 2>&1 &
        end
        disown 2>/dev/null
    end

    # postexec (back at the prompt): name the tab after the shell ("fish") so a
    # bare prompt reads "fish" regardless of the login shell.
    function _har_precmd --on-event fish_postexec
        command "$_har_bin" precmd fish >/dev/null 2>&1 &
        disown 2>/dev/null
    end
end
