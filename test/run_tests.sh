#!/bin/bash

# Use the environment VIMPRG or the Vim of MacVim
VIMPRG="${VIMPRG:-/Applications/MacVim.app/Contents/MacOS/Vim}"

if [[ ! -x "$VIMPRG" ]]; then
  echo "ERROR: vim ($VIMPRG) not found or not executable.  Install MacVim from https://github.com/macvim-dev/macvim/releases."
  exit 1
fi

# Stop at once when Vim is too old, rather than with failing tests
VIMPRG="$VIMPRG" "$(dirname "$0")/check_vim_version.sh" || exit 1

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
# Run the tests in the GUI when LSP_TEST_GUI is set, in the terminal otherwise.
# "-f" keeps the GUI in the foreground, so that this script waits for it.
if [[ -n "$LSP_TEST_GUI" ]]; then
  VIM_CMD="$VIMPRG -g -f -u NONE -U NONE -i NONE --noplugin -N"
else
  VIM_CMD="$VIMPRG -u NONE -U NONE -i NONE --noplugin -N --not-a-term"
fi

# Kill Vim when the tests in one file take longer than this many seconds, as
# when Vim waits for a key at a prompt, which the input below never gives it.
TEST_TIMEOUT="${LSP_TEST_TIMEOUT:-600}"

# Vim in the terminal checks its input for typed keys while a test waits
# (":sleep", complete_check()) and exits when the input is at end of file, as
# when stdin is /dev/null.  Give Vim an input that never has anything to read:
# a pipe that this script keeps open for writing on file descriptor 3.
STDIN_DIR=$(mktemp -d) || exit 1
mkfifo "$STDIN_DIR/stdin" || exit 1
exec 3<>"$STDIN_DIR/stdin" || exit 1
rm -r "$STDIN_DIR"

# The test files in two groups: the ones that need clangd, and the others,
# which need the other language servers.  CI runs the groups in parallel jobs
# that install only what each group needs.
CLANGD_TESTS=(
  "clangd_tests.vim"
  "clangd_offsetencoding.vim"
)
OTHER_TESTS=(
  "tsserver_tests.vim"
  "gopls_tests.vim"
  "rust_tests.vim"
  "stub_lspserver_tests.vim"
  "not_lspserver_related_tests.vim"
  "markdown_tests.vim"
)

# Run the test files and groups given as arguments, or all the test files
if (( $# == 0 )); then
  set -- clangd others
fi
TESTS_TO_RUN=()
for arg in "$@"; do
  case "$arg" in
    clangd) TESTS_TO_RUN+=("${CLANGD_TESTS[@]}") ;;
    others) TESTS_TO_RUN+=("${OTHER_TESTS[@]}") ;;
    *) TESTS_TO_RUN+=("$arg") ;;
  esac
done

TOTAL_PASSED=0

# Run the tests in one file and check its results.  Returns 0 when the file's
# tests all passed or the file was skipped on purpose, 2 when there are no
# results or no tests ran, 3 when a test failed, and 4 when Vim exited early.
RunTestsInFile() {
  local testfile=$1
  local encoding=${2:-"utf-8"}

  # Use a unique results file name to allow potential parallel runs later
  local res_file="results_${testfile}_${encoding}.txt"
  local screen_file="screen_${testfile}_${encoding}.log"
  rm -f "$res_file" "$screen_file"

  echo "===> Running: $testfile (Encoding: $encoding)"

  export LSP_OFFSET_ENCODING="$encoding"

  # Vim in the terminal draws its screen on stdout, which is only noise in the
  # output of the run.  Keep it in a file, to see where Vim was when a test
  # failed.
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
    return 4
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

# clangd_offsetencoding.vim runs once for each offset encoding, the others
# once with UTF-8.
for testfile in "${TESTS_TO_RUN[@]}"; do
  encodings=("utf-8")
  if [[ "$testfile" == "clangd_offsetencoding.vim" ]]; then
    encodings=("utf-8" "utf-16" "utf-32")
  fi
  for encoding in "${encodings[@]}"; do
    RunTestsInFile "$testfile" "$encoding" || exit $?
  done
done

echo "---------------------------------------"
if (( TOTAL_PASSED == 0 )); then
  echo "ERROR: No tests ran."
  exit 2
fi

echo "SUCCESS: All $TOTAL_PASSED specified tests passed."
exit 0

# vim: tabstop=2 shiftwidth=2 softtabstop=2 expandtab
