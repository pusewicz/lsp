vim9script
# Test file for runner_selftest.sh, not part of the test suite.  Two of the
# tests it declares are not global functions after sourcing it, so they don't
# run.

# Pretend to start a language server.
def g:StartLangServer(): bool
  return true
enddef

# A test that passes.  Its "enddef" comes after the next test, as a conflict
# resolution can leave it, which nests that test in this one.
def g:Test_First()
# A test that is defined only when Test_First runs.
def g:Test_Nested()
enddef
enddef

# A test without "g:", which makes it script-local.
def Test_ScriptLocal()
enddef

# A legacy test function, which runs.
function g:Test_Legacy()
endfunction

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
