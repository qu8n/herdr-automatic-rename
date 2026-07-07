#!/usr/bin/env bash
# Run every tests/test_*.sh and aggregate. Exit non-zero if any file fails.
#
#   ./tests/run.sh            # run all
#   ./tests/run.sh naming     # run only files matching *naming*
#
# No dependencies beyond bash and jq (same as the plugin itself).

here=$(cd "$(dirname "$0")" && pwd)
filter="${1:-}"
fail=0
ran=0

for t in "$here"/test_*.sh; do
  [ -f "$t" ] || continue
  case "$(basename "$t")" in
    *"$filter"*) ;;
    *) continue ;;
  esac
  ran=$(( ran + 1 ))
  printf '\n# ==== %s ====\n' "$(basename "$t")"
  if bash "$t"; then :; else fail=1; fi
done

printf '\n'
if [ "$ran" -eq 0 ]; then
  echo "# no test files matched '$filter'"
  exit 1
fi
if [ "$fail" -eq 0 ]; then
  echo "# ALL TESTS PASSED"
else
  echo "# SOME TESTS FAILED"
fi
exit "$fail"
