#!/bin/bash

# Check that runner.vim keeps the results of a test file whose test pass hooks
# fail, reports each failure naming the hook and the test pass, stops the
# language server after a failed start and goes on with the next test pass.
# The test file, runner_selftest_fixture.vim, runs through run_tests.sh like
# any other.

cd "$(dirname "$0")" || exit 1

FIXTURE=runner_selftest_fixture.vim
RES_FILE="results_${FIXTURE}_utf-8.txt"
SCREEN_FILE="screen_${FIXTURE}_utf-8.log"
TIMEOUT_SECS=60

# Where a "timeout" command is available, a runner that hangs fails after
# TIMEOUT_SECS.  It has to be killed: Vim turns SIGTERM into an interrupt while
# it runs runner.vim, which then goes on with the next test.
TIMEOUT_CMD=()
for cmd in timeout gtimeout; do
  if command -v "$cmd" > /dev/null; then
    TIMEOUT_CMD=("$cmd" -s KILL "$TIMEOUT_SECS")
    break
  fi
done

output=$("${TIMEOUT_CMD[@]}" ./run_tests.sh "$FIXTURE" 2>&1)
status=$?

# timeout returns 124 when the command timed out, or 137 as it kills itself
# together with the command.
if [[ ${#TIMEOUT_CMD[@]} -gt 0 && ($status -eq 124 || $status -eq 137) ]]; then
  echo "$output"
  echo "FAIL: run_tests.sh did not finish within $TIMEOUT_SECS seconds."
  echo "The results so far:"
  cat results.txt
  rm -f results.txt
  exit 1
fi

# The exception messages end with " at {throwpoint}", which is left out.
expected="[setup]
FAIL: g:LSPTest_setupPass() threw in the test pass setup: setup failed
[start]
FAIL: g:StartLangServer() threw in the test pass start: start failed
[notready]
FAIL: Not able to start the language server in the test pass notready
[stop]
Test_First: pass
Test_Second: pass
FAIL: g:StopLangServer() threw in the test pass stop: stop failed
[none]
Test_First: pass
Test_Second: pass"
actual=$(sed 's/ at .*//' "$RES_FILE" 2>/dev/null)
rm -f "$RES_FILE" "$SCREEN_FILE"

errors=()
# run_tests.sh returns 3 when a test failed.
if [[ $status -ne 3 ]]; then
  errors+=("run_tests.sh returned $status instead of 3")
fi
if [[ "$actual" != "$expected" ]]; then
  errors+=("unexpected results:
$(diff <(echo "$expected") <(echo "$actual"))")
fi

if (( ${#errors[@]} > 0 )); then
  echo "$output"
  printf 'FAIL: %s\n' "${errors[@]}"
  exit 1
fi

echo "SUCCESS: The test runner reported the failing hooks."
exit 0

# vim: tabstop=2 shiftwidth=2 softtabstop=2 expandtab
