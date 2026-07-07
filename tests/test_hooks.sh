#!/usr/bin/env bash
# Behavior tests for the shell hooks. bash is always exercised; zsh and fish are
# exercised only when installed (skipped, not failed, otherwise). Each hook is
# sourced against the real repo layout, so we verify it resolves the engine next
# to itself rather than at any hard-coded path.

here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
REPO=$(cd "$here/.." && pwd)

# ---- bash ----
got=$(HERDR_PANE_ID=x HAL_HOOK="$REPO/shell/hook.bash" /bin/bash -c 'source "$HAL_HOOK"; echo "$_har_bin"')
check "bash: self-locates engine next to hook" "$REPO/automatic-rename.sh" "$got"

got=$(HERDR_PANE_ID=x HAL_HOOK="$REPO/shell/hook.bash" /bin/bash -c \
  'source "$HAL_HOOK"; source "$HAL_HOOK"; printf "%s\n" "$PROMPT_COMMAND" | grep -c _har_precmd_wrap')
check "bash: double-source adds PROMPT_COMMAND once" "1" "$got"

# Trap behavior only makes sense in an interactive shell (the only place a hook
# is sourced). Non-interactive `bash -c` has different DEBUG-trap scoping, so we
# simulate a real .bashrc: set a DEBUG trap, source the hook after it, then run a
# command. The pre-existing trap must still fire (proof it was not clobbered).
_rc=$(mktemp "${TMPDIR:-/tmp}/hal-rc.XXXXXX")
cat >"$_rc" <<EOF
trap 'echo KEEP_FIRED' DEBUG
source "$REPO/shell/hook.bash"
EOF
got=$(printf 'true\nexit\n' | HERDR_PANE_ID=x /bin/bash --rcfile "$_rc" -i 2>&1)
rm -f "$_rc"
check_contains "bash: never clobbers a pre-existing DEBUG trap" "$got" "KEEP_FIRED"

got=$(HERDR_PANE_ID=x HAL_HOOK="$REPO/shell/hook.bash" /bin/bash -c \
  'preexec_functions=(); source "$HAL_HOOK"; printf "%s " "${preexec_functions[@]}"')
check_contains "bash: cooperates with a preexec framework" "$got" "_har_preexec"

got=$(HAL_HOOK="$REPO/shell/hook.bash" /bin/bash -c 'unset HERDR_PANE_ID; source "$HAL_HOOK"; echo "${_har_installed:-unset}"')
check "bash: no-ops outside a herdr pane" "unset" "$got"

# ---- zsh (if present) ----
if command -v zsh >/dev/null 2>&1; then
  got=$(HERDR_PANE_ID=x HAL_HOOK="$REPO/shell/hook.zsh" zsh -c 'source "$HAL_HOOK"; echo "$_har_bin"')
  check "zsh: self-locates engine next to hook" "$REPO/automatic-rename.sh" "$got"
  got=$(HERDR_PANE_ID=x HAL_HOOK="$REPO/shell/hook.zsh" zsh -c 'source "$HAL_HOOK"; echo ${preexec_functions[(r)_har_preexec]}')
  check "zsh: registers a preexec hook" "_har_preexec" "$got"
else
  echo "# skip: zsh not installed"
fi

# ---- fish (if present): at minimum, it must parse ----
if command -v fish >/dev/null 2>&1; then
  if fish -n "$REPO/shell/hook.fish" >/dev/null 2>&1; then rc=0; else rc=1; fi
  check_rc "fish: hook parses" 0 "$rc"
else
  echo "# skip: fish not installed"
fi

t_summary
