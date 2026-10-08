vim9script

# Script to run language server unit tests
# The global variable TestName should be set to the name of the file
# containing the tests.

source common.vim

# An absolute path, as a test can change the current directory.
const resultsFile: string = $'{getcwd()}/results.txt'

# Append "lines" to results.txt.  Results are written as soon as they are
# known, so that the ones recorded before an exception or an early exit of Vim
# are kept.
def AddResults(lines: list<string>)
  writefile(lines, resultsFile, 'a')
enddef

# Return a FAIL line for the exception being handled, which "hook" threw.
# "inPass" names the test pass, if any.
def HookException(hook: string, inPass: string): string
  return $'FAIL: {hook} threw{inPass}: {v:exception} at {v:throwpoint}'
enddef

# Run the test function "f" and append its "pass" or "FAIL" line to
# results.txt, after the errors it reported.
def RunTest(f: string)
  v:errors = []
  v:errmsg = ''
  try
    # ISOLATION: Clear hidden buffers and reset options that might leak
    # silent! %bwipeout! is good, but we also ensure no leftover windows
    silent! :%bwipeout!

    # Execute the test function
    exe $'call {f}()'
  catch
    add(v:errors, $'EXCEPTION: {f} -> {v:exception} at {v:throwpoint}')
  endtry

  # Check for both v:errors (assertions) and v:errmsg (Vim core errors).
  # Before patch 9.2.1015, compiling a :def line that starts with a
  # "name.member(" call continued on the next line can set v:errmsg
  # although nothing is wrong, e.g. to E697 when a List is left open at
  # the end of the line (vim/vim#21168); build such a List in a variable
  # first.
  if v:errmsg != ''
    add(v:errors, $'ERROR: {f} generated {v:errmsg}')
  endif

  if !v:errors->empty()
    AddResults(v:errors + [$'{f}: FAIL'])
  else
    AddResults([$'{f}: pass'])
  endif
enddef

# Run every global Test_ function defined by the sourced test file and append
# one "pass" or "FAIL" line per test to results.txt.  A test file that cannot
# run in this environment sets g:LSPTest_skip to the reason and gets a single
# "SKIP" line instead.  Running no tests for any other reason is a failure.
# An exception thrown by g:LSPTest_setupPass(), g:StartLangServer() or
# g:StopLangServer() is a failure of the test pass, and the run goes on with
# the next one.  g:StopLangServer() runs even when the language server didn't
# start, so that a half-started one doesn't run into the next test pass.
def LspRunTests()
  :set nomore
  :set debug=beep

  if exists('g:LSPTest_skip')
    AddResults([$'SKIP: {g:TestName}: {g:LSPTest_skip}'])
    return
  endif

  # ROBUST DISCOVERY: Capture functions defined in the sourced test file
  # The regex is tightened to handle compiled vs non-compiled function headers
  var fns: list<string> = execute('function /^Test_')
    ->split("\n")
    ->map((_, v) => v->substitute('^\(def\|func\)\s\+\(Test_\w\+\).*', '\2', ''))
    ->filter((_, v) => v =~ '^Test_')
    ->sort()

  if fns->empty()
    AddResults([$'FAIL: No tests found in {g:TestName}'])
    return
  endif

  var passes: list<any> = exists('g:LSPTest_passes')
        ? g:LSPTest_passes : [v:null]
  for pass in passes
    var inPass: string = pass == v:null ? '' : $' in the test pass {pass}'
    if pass != v:null && exists('*g:LSPTest_setupPass')
      var setupResults: list<string> = []
      var ready: bool = false
      try
        ready = g:LSPTest_setupPass(pass, setupResults)
        if !ready
          setupResults->add($'FAIL: Could not set up the test pass {pass}')
        endif
      catch
        setupResults->add(HookException('g:LSPTest_setupPass()', inPass))
      endtry
      AddResults(setupResults)
      if !ready
        continue
      endif
    endif

    var started: bool = false
    try
      started = g:StartLangServer()
      if !started
        AddResults([$'FAIL: Not able to start the language server{inPass}'])
      endif
    catch
      AddResults([HookException('g:StartLangServer()', inPass)])
    endtry

    if started
      for f in fns
        RunTest(f)
      endfor
    endif

    if exists('*g:StopLangServer')
      try
        g:StopLangServer()
      catch
        AddResults([HookException('g:StopLangServer()', inPass)])
      endtry
    endif
  endfor
enddef

# --- Main Execution Flow ---
# A swap file left behind by a crashed run would otherwise block every later
# run at the E325 "ATTENTION" prompt.
:set noswapfile

try
  # Ensure results.txt is empty before starting
  writefile([], resultsFile)

  g:LoadLspPlugin()

  if filereadable(g:TestName)
    exe $'source {g:TestName}'
    LspRunTests()
  else
    AddResults([$'FAIL: Test file "{g:TestName}" not found'])
  endif
catch
  AddResults([$'FAIL: Global exception in {g:TestName}: {v:exception} at {v:throwpoint}'])
endtry

qall!

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
