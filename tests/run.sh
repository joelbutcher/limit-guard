#!/bin/bash
# Minimal test runner: every function named test_* in tests/test_*.sh runs in its own subshell
# with a fresh environment. Usage: tests/run.sh [filter]
cd "$(dirname "$0")" || exit 1
filter="${1:-}"
pass=0; failed=0; failed_names=''
for file in test_*.sh; do
  for t in $(grep -oE '^test_[a-zA-Z0-9_]+' "$file"); do
    [ -n "$filter" ] && case "$t" in *"$filter"*) ;; *) continue ;; esac
    out="$(
      . ./helpers.sh
      . "./$file"
      setup_env
      "$t"
      rc=$FAILS
      teardown_env
      exit "$rc"
    )"
    if [ $? -eq 0 ]; then
      pass=$((pass + 1)); echo "  ✓ $t"
    else
      failed=$((failed + 1)); failed_names="$failed_names $t"; echo "  ✗ $t"; printf '%s\n' "$out"
    fi
  done
done
echo
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ] || { echo "failed:$failed_names"; exit 1; }
