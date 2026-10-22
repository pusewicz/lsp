#!/bin/bash

# Fail unless the Vim that runs the tests has the patches the plugin uses.
# run_tests.sh runs this first, and CI right after installing MacVim, so that
# an old Vim fails at once with a clear message instead of failing tests, or
# hanging, later.
#
# Patch 9.2.1116 is needed for the following, and includes all that is needed
# by the patches before it:
# - 9.2.0970: listener_add() with the "text" option, and 9.2.1102: the text of
#   a line joined with "J" in it, for the changes sent to an incremental sync
#   server.
# - 9.2.1116: 'tagfunc' is used to complete tag names.
MIN_VIM_PATCH="${MIN_VIM_PATCH:-1116}"

VIMPRG="${VIMPRG:-/Applications/MacVim.app/Contents/MacOS/Vim}"

if [[ ! -x "$VIMPRG" ]]; then
  echo "ERROR: vim ($VIMPRG) not found or not executable."
  exit 1
fi

if ! "$VIMPRG" -u NONE -U NONE -i NONE -N -es \
    -c "if !has('patch-9.2.$MIN_VIM_PATCH') | cquit | endif" -c quit; then
  echo "ERROR: The tests need Vim 9.2.$MIN_VIM_PATCH or later, but $VIMPRG is:"
  "$VIMPRG" --version | sed -n '1p;/^Included patches:/p'
  exit 1
fi

"$VIMPRG" --version | sed -n '1p;/^Included patches:/p'
