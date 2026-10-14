vim9script
# Test file for runner_selftest.sh, not part of the test suite.  A test waits
# for a key, as Vim does at a prompt, which run_tests.sh never gives it.

# Pretend to start a language server.
def g:StartLangServer(): bool
  return true
enddef

# A test that passes.
def g:Test_First()
enddef

# A test that waits for a key.
def g:Test_Second()
  getchar()
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
