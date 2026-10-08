#!/bin/bash
# Entry point of the image built from test/docker/Dockerfile.
#
# Copies the plugin source mounted read-only at /src to the directory
# actions/checkout uses in CI and runs test/run_tests.sh there, passing on
# the arguments.  Working on a copy lets several containers run the tests at
# the same time without sharing the files the tests write, and keeps those
# files out of the checkout.  With --shell, starts a shell there instead.

set -euo pipefail

src=/src
work=$HOME/work/lsp/lsp

if [[ ! -d $src/test ]]; then
  echo "ERROR: mount the plugin source at $src: docker run -v \"\$PWD:$src:ro\" ..." >&2
  exit 1
fi

mkdir -p "$work"
# tar exits with 1 when a file changes while it is copied, like the swap file
# of a file being edited.
status=0
tar -C "$src" --exclude=./.git --exclude=./test/docker/logs \
  --warning=no-file-changed -cf - . | tar -C "$work" -xf - || status=$?
if [[ $status -gt 1 ]]; then
  exit "$status"
fi
# "cargo new", run by the Rust tests, creates a git repository unless it is
# inside one, as the CI checkout is.
git -C "$work" -c init.defaultBranch=main init -q
# Like the CI checkout, leave out the ignored files, such as what earlier
# runs of the tests left behind.
git -C "$work" clean -dfqX

cd "$work/test"

if [[ ${1-} == --shell ]]; then
  exec bash
fi

uname -a
rust-analyzer --version
"$VIMPRG" --version

status=0
./run_tests.sh "$@" || status=$?

if [[ $status -ne 0 ]]; then
  # run_tests.sh keeps the results of the test file that failed.
  echo
  echo "==> Failures"
  grep -hv ': pass$' results_*.txt 2>/dev/null || true
fi

exit $status
