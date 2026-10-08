vim9script
# Test file for runner_selftest.sh, not part of the test suite.  Each test pass
# is named after the hook that fails in it.  The language server only pretends
# to run, and a test pass that finds it still running fails.

g:LSPTest_passes = ['setup', 'start', 'notready', 'stop', 'none']

var curPass: string
var serverRunning: bool = false

# Throw when "hook" is the hook that fails in the current test pass.
def ThrowIn(hook: string)
  if curPass == hook
    throw $'{hook} failed'
  endif
enddef

# Start the test pass "pass" and record its name in "results", followed by a
# failure when the language server of the previous test pass still runs.
def g:LSPTest_setupPass(pass: string, results: list<string>): bool
  curPass = pass
  results->add($'[{pass}]')
  if serverRunning
    results->add('FAIL: The language server of the previous pass still runs')
  endif
  ThrowIn('setup')
  return true
enddef

# Pretend to start a language server, which doesn't get ready in the
# "notready" test pass.
def g:StartLangServer(): bool
  serverRunning = true
  ThrowIn('start')
  return curPass != 'notready'
enddef

# Pretend to stop the language server.
def g:StopLangServer()
  serverRunning = false
  ThrowIn('stop')
enddef

# A test that passes.
def g:Test_First()
enddef

# Another test that passes.
def g:Test_Second()
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
