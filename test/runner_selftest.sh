#!/bin/bash

# Check that the test runner keeps going and reports the failure when a test
# can't:
# - runner_selftest_fixture.vim: runner.vim keeps the results of a test file
#   whose test pass hooks fail, reports each failure naming the hook and the
#   test pass, stops the language server after a failed start, goes on with the
#   next test pass, reports a failed test with the messages given while it ran,
#   and reports an error while quitting Vim instead of stopping at the
#   hit-enter prompt.
# - runner_selftest_timeout.vim: run_tests.sh kills Vim when a test waits for a
#   key, and keeps the results so far.
# - runner_selftest_notrun.vim: runner.vim reports each declared test that is
#   not a global function after sourcing the file, such as one nested in
#   another test by a misplaced "enddef", and runs legacy test functions.
# - run_tests.sh stops at once, before any test, with a Vim that is older than
#   check_vim_version.sh asks for.
# The test files run through run_tests.sh like any other.

cd "$(dirname "$0")" || exit 1

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

FAILED=0

# Run the test file "fixture" through run_tests.sh, which kills Vim after
# "vim_timeout" seconds, and check that run_tests.sh returns "expected_status",
# prints a line "expected_line" and that the results file has the lines
# "expected_results", without the " at {throwpoint}" that ends the exception
# messages.  Sets FAILED to 1 when a check fails.
CheckRun() {
  local fixture=$1
  local vim_timeout=$2
  local expected_status=$3
  local expected_line=$4
  local expected_results=$5

  local res_file="results_${fixture}_utf-8.txt"
  local screen_file="screen_${fixture}_utf-8.log"

  local output status
  output=$(LSP_TEST_TIMEOUT=$vim_timeout "${TIMEOUT_CMD[@]}" ./run_tests.sh "$fixture" 2>&1)
  status=$?

  # timeout returns 124 when the command timed out, or 137 as it kills itself
  # together with the command.
  if [[ ${#TIMEOUT_CMD[@]} -gt 0 && ($status -eq 124 || $status -eq 137) ]]; then
    echo "$output"
    echo "FAIL: run_tests.sh $fixture did not finish within $TIMEOUT_SECS seconds."
    echo "The results so far:"
    cat results.txt
    rm -f results.txt
    FAILED=1
    return
  fi

  local actual
  actual=$(sed 's/ at .*//' "$res_file" 2>/dev/null)
  rm -f "$res_file" "$screen_file"

  local errors=()
  if [[ $status -ne $expected_status ]]; then
    errors+=("run_tests.sh $fixture returned $status instead of $expected_status")
  fi
  if ! grep -qxF "$expected_line" <<< "$output"; then
    errors+=("run_tests.sh $fixture did not print \"$expected_line\"")
  fi
  if [[ "$actual" != "$expected_results" ]]; then
    errors+=("unexpected results of $fixture:
$(diff <(echo "$expected_results") <(echo "$actual"))")
  fi

  if (( ${#errors[@]} > 0 )); then
    echo "$output"
    printf 'FAIL: %s\n' "${errors[@]}"
    FAILED=1
  fi
}

# run_tests.sh returns 3 when a test failed.
CheckRun runner_selftest_fixture.vim 30 3 \
  "RESULT: Some tests in runner_selftest_fixture.vim FAILED." \
  "[setup]
FAIL: g:LSPTest_setupPass() threw in the test pass setup: setup failed
[start]
FAIL: g:StartLangServer() threw in the test pass start: start failed
[notready]
FAIL: Not able to start the language server in the test pass notready
[stop]
Failed
MESSAGE: A message of the failing test
Test_Failing: FAIL
Test_First: pass
Test_Second: pass
FAIL: g:StopLangServer() threw in the test pass stop: stop failed
[none]
Failed
MESSAGE: A message of the failing test
Test_Failing: FAIL
Test_First: pass
Test_Second: pass
FAIL: Error while quitting Vim: E605: Exception not caught: quit failed"

CheckRun runner_selftest_notrun.vim 30 3 \
  "RESULT: Some tests in runner_selftest_notrun.vim FAILED." \
  "FAIL: Test_Nested is declared in runner_selftest_notrun.vim but is not a global function after sourcing it, so it does not run
FAIL: Test_ScriptLocal is declared in runner_selftest_notrun.vim but is not a global function after sourcing it, so it does not run
Test_First: pass
Test_Legacy: pass"

# run_tests.sh returns 2 when Vim did not finish.
CheckRun runner_selftest_timeout.vim 5 2 \
  "RESULT: Vim timed out while running runner_selftest_timeout.vim." \
  "Test_First: pass"

# run_tests.sh stops before any test runs, with status 1, when Vim is older
# than the patch that the plugin needs, and names that patch and the Vim.
output=$(MIN_VIM_PATCH=99999 ./run_tests.sh runner_selftest_fixture.vim 2>&1)
status=$?
if [[ $status -ne 1 ]] \
    || ! grep -qF "ERROR: The tests need Vim 9.2.99999 or later" <<< "$output" \
    || ! grep -q "^Included patches:" <<< "$output" \
    || grep -q "Running:" <<< "$output"; then
  echo "$output"
  echo "FAIL: run_tests.sh returned $status instead of stopping at once with an old Vim"
  FAILED=1
fi

if (( FAILED )); then
  exit 1
fi

echo "SUCCESS: The test runner reported the failures."
exit 0

# vim: tabstop=2 shiftwidth=2 softtabstop=2 expandtab
