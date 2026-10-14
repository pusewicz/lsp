#!/bin/bash

# Use the environment VIMPRG or the Vim of MacVim
VIMPRG="${VIMPRG:-/Applications/MacVim.app/Contents/MacOS/Vim}"

if [[ ! -x "$VIMPRG" ]]; then
  echo "ERROR: vim ($VIMPRG) not found or not executable.  Install MacVim with \`brew install --cask macvim-app\`."
  exit 1
fi

# GNU coreutils' "timeout", installed without or with the "g" prefix
TIMEOUT_CMD=""
for cmd in timeout gtimeout; do
  if command -v "$cmd" > /dev/null; then
    TIMEOUT_CMD=$cmd
    break
  fi
done
if [[ -z "$TIMEOUT_CMD" ]]; then
  echo "ERROR: timeout not found.  Install GNU coreutils with \`brew install coreutils\`."
  exit 1
fi

# Clean up results from a previous crashed run
rm -f results.txt

# --- Configuration ---
VIM_CMD="$VIMPRG -u NONE -U NONE -i NONE --noplugin -N --not-a-term"

# Kill Vim when the tests in one file take longer than this many seconds, as
# when Vim waits for a key at a prompt, which the input below never gives it.
TEST_TIMEOUT="${LSP_TEST_TIMEOUT:-600}"

# Vim checks its input for typed keys while a test waits (":sleep",
# complete_check()) and exits when the input is at end of file, as when stdin
# is /dev/null.  Give Vim an input that never has anything to read: a pipe
# that this script keeps open for writing on file descriptor 3.
STDIN_DIR=$(mktemp -d) || exit 1
mkfifo "$STDIN_DIR/stdin" || exit 1
exec 3<>"$STDIN_DIR/stdin" || exit 1
rm -r "$STDIN_DIR"

# Use arguments if provided, otherwise run the full suite
ALL_TESTS=(
  "clangd_tests.vim"
  "tsserver_tests.vim"
  "gopls_tests.vim"
  "rust_tests.vim"
  "stub_lspserver_tests.vim"
  "not_lspserver_related_tests.vim"
  "markdown_tests.vim"
)
if (( $# > 0 )); then
  TESTS_TO_RUN=("$@")
else
  TESTS_TO_RUN=("${ALL_TESTS[@]}")
fi

TOTAL_PASSED=0

# Run the tests in one file and check its results.  Returns 0 when the file's
# tests all passed or the file was skipped on purpose, 2 when Vim did not
# finish or no tests ran, and 3 when a test failed.
RunTestsInFile() {
  local testfile=$1
  local encoding=${2:-"utf-8"}

  # Use a unique results file name to allow potential parallel runs later
  local res_file="results_${testfile}_${encoding}.txt"
  local screen_file="screen_${testfile}_${encoding}.log"
  rm -f "$res_file" "$screen_file"

  echo "===> Running: $testfile (Encoding: $encoding)"

  export LSP_OFFSET_ENCODING="$encoding"

  # Vim draws its screen on stdout, which is only noise in the output of the
  # run.  Keep it in a file, to see where Vim was when a test failed.
  # While Vim runs a test it turns the other signals into an interrupt, which
  # only fails that test, so it has to be killed.  "--foreground" keeps Vim in
  # the foreground process group, where a CTRL-C typed in a terminal reaches
  # it.
  "$TIMEOUT_CMD" --foreground -s KILL "$TEST_TIMEOUT" \
    $VIM_CMD -c "let g:TestName='$testfile'" -S runner.vim <&3 > "$screen_file"
  local vim_status=$?

  # Standardizing the results file name if runner.vim always outputs 'results.txt'
  if [[ -f results.txt ]]; then
    mv results.txt "$res_file"
  fi

  # timeout returns 128 + 9 when it killed Vim.  The results so far tell which
  # test Vim got stuck in.
  if [[ $vim_status -eq 137 ]]; then
    if [[ -f "$res_file" ]]; then
      cat "$res_file"
    fi
    echo "RESULT: Vim timed out while running $testfile."
    return 2
  fi

  if [[ ! -f "$res_file" ]]; then
    echo "ERROR: Test results file '$res_file' not found."
    return 2
  fi

  cat "$res_file"

  # runner.vim always ends with ":qall!", so any other exit means that Vim
  # stopped before running all the tests.
  if [[ $vim_status -ne 0 ]]; then
    echo "RESULT: Vim exited with status $vim_status while running $testfile."
    return 2
  fi

  if grep -qw "FAIL" "$res_file"; then
    echo "RESULT: Some tests in $testfile FAILED."
    return 3
  fi

  if grep -q "^SKIP:" "$res_file"; then
    echo "RESULT: $testfile SKIPPED."
    echo ""
    rm "$res_file" "$screen_file"
    return 0
  fi

  local passed
  passed=$(grep -c "^Test_[[:alnum:]_]*: pass$" "$res_file")
  if (( passed == 0 )); then
    echo "ERROR: No tests ran in $testfile."
    return 2
  fi

  echo "RESULT: All $passed tests in $testfile PASSED."
  echo ""
  rm "$res_file" "$screen_file"
  TOTAL_PASSED=$((TOTAL_PASSED + passed))
}

# --- Main Execution ---

# 1. Standard Suite
for testfile in "${TESTS_TO_RUN[@]}"; do
  RunTestsInFile "$testfile" || exit $?
done

# 2. Clangd Encoding Specific Suite
# Only run if we are running all tests or specifically clangd tests
if [[ "$*" == "" || "$*" == *"clangd"* ]]; then
  for encoding in "utf-8" "utf-16" "utf-32"; do
    RunTestsInFile "clangd_offsetencoding.vim" "$encoding" || exit $?
  done
fi

echo "---------------------------------------"
if (( TOTAL_PASSED == 0 )); then
  echo "ERROR: No tests ran."
  exit 2
fi

echo "SUCCESS: All $TOTAL_PASSED specified tests passed."
exit 0

# vim: tabstop=2 shiftwidth=2 softtabstop=2 expandtab
