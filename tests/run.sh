#!/usr/bin/env bash
# Runs the WhoDis compatibility tests. From the repo root:
#   bash tests/run.sh                 # uses `lua` (5.1 matches the game)
#   LUA=lua5.4 bash tests/run.sh      # any other Lua interpreter
#   VERBOSE=1 bash tests/run.sh       # also show what WhoDis printed
set -u
LUA="${LUA:-lua}"
cd "$(dirname "$0")/.." || exit 1

failed=0
for test in tests/test_*.lua; do
    echo "== ${test}"
    if ! $LUA "$test"; then
        failed=$((failed + 1))
    fi
done

if [ "$failed" -ne 0 ]; then
    echo "${failed} test file(s) failed"
    exit 1
fi
echo "all test files passed"
