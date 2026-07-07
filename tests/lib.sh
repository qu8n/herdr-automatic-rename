# tests/lib.sh -- tiny TAP-ish assertion helpers.
#
# No bats or other dependency: just bash 3.2 and the tools the plugin already
# needs (jq). Each test file sources this, calls check/check_rc, and ends with
# `t_summary` (which sets the file's exit status). tests/run.sh runs every
# test_*.sh and aggregates.

_t_n=0
_t_fail=0

# check <name> <expected> <actual> -- string equality.
check() {
  _t_n=$(( _t_n + 1 ))
  if [ "$2" = "$3" ]; then
    printf 'ok %d - %s\n' "$_t_n" "$1"
  else
    _t_fail=$(( _t_fail + 1 ))
    printf 'not ok %d - %s\n' "$_t_n" "$1"
    printf '#   expected: [%s]\n' "$2"
    printf '#   actual:   [%s]\n' "$3"
  fi
}

# check_rc <name> <expected-rc> <actual-rc> -- exit-status equality.
check_rc() {
  _t_n=$(( _t_n + 1 ))
  if [ "$2" = "$3" ]; then
    printf 'ok %d - %s\n' "$_t_n" "$1"
  else
    _t_fail=$(( _t_fail + 1 ))
    printf 'not ok %d - %s\n' "$_t_n" "$1"
    printf '#   expected rc: %s\n' "$2"
    printf '#   actual rc:   %s\n' "$3"
  fi
}

# check_contains <name> <haystack> <needle> -- substring match.
check_contains() {
  _t_n=$(( _t_n + 1 ))
  case "$2" in
    *"$3"*)
      printf 'ok %d - %s\n' "$_t_n" "$1" ;;
    *)
      _t_fail=$(( _t_fail + 1 ))
      printf 'not ok %d - %s\n' "$_t_n" "$1"
      printf '#   expected to contain: [%s]\n' "$3"
      printf '#   in: [%s]\n' "$2" ;;
  esac
}

# check_absent <name> <haystack> <needle> -- substring must NOT appear.
check_absent() {
  _t_n=$(( _t_n + 1 ))
  case "$2" in
    *"$3"*)
      _t_fail=$(( _t_fail + 1 ))
      printf 'not ok %d - %s\n' "$_t_n" "$1"
      printf '#   expected NOT to contain: [%s]\n' "$3"
      printf '#   in: [%s]\n' "$2" ;;
    *)
      printf 'ok %d - %s\n' "$_t_n" "$1" ;;
  esac
}

t_summary() {
  printf '# %d tests, %d failed\n' "$_t_n" "$_t_fail"
  [ "$_t_fail" -eq 0 ]
}
