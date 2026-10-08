#!/bin/bash
# Entry point of the image built from test/docker/Dockerfile.
#
# Copies the plugin source, mounted read-only at the working directory as
# test/docker/run_tests.sh does:
#
#   docker run -v "$PWD:$PWD:ro" -w "$PWD" lsp-tests:vim-nightly
#
# to $HOME/work/NAME/NAME, where actions/checkout puts a repository NAME in
# CI, and runs test/run_tests.sh there, passing on the arguments.  Working on
# a copy lets several containers run the tests at the same time without
# sharing the files the tests write, and keeps those files out of the
# checkout.  With --shell, starts a shell there instead.

set -euo pipefail

src=$PWD
name=${src##*/}
work=$HOME/work/$name/$name

if [[ ! -d $src/test ]]; then
  echo "ERROR: mount the plugin source at the working directory: docker run -v \"\$PWD:\$PWD:ro\" -w \"\$PWD\" ..." >&2
  exit 1
fi
if [[ $src == "$work" ]]; then
  echo "ERROR: the plugin source is mounted at $work, where its copy goes" >&2
  exit 1
fi

mkdir -p "$work"
# tar exits with 1 when a file changes while it is copied, like the swap file
# of a file being edited.
status=0
tar -C "$src" --exclude=./.git --exclude=./test/docker/logs --exclude=./test/node_modules \
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

# The "Install the TypeScript language server" step of the workflow.
if [[ -f package-lock.json ]]; then
  npm ci --prefer-offline --no-audit --no-fund
fi

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
