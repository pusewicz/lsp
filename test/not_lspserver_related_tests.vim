vim9script
# Unit tests for Vim Language Server Protocol (LSP) for various functionality 

import '../autoload/lsp/completion.vim' as completion
import '../autoload/lsp/buffer.vim' as buf
import '../autoload/lsp/capabilities.vim' as capabilities
import '../autoload/lsp/util.vim' as util

# Test for no duplicates in helptags
def g:Test_Helptags()
  :helptags ../doc
enddef

# Regression test for CompletionList.itemDefaults support.
def g:Test_CompletionList_ItemDefaults_EditRange()
  silent! edit XCompletionItemDefaults.vim
  setline(1, ['fo'])
  cursor(1, 3)

  var lspserver = {
    name: 'test',
    omniCompletePending: true,
    completionLazyDoc: false,
    completeItems: [],
    completeItemsIsIncomplete: false,
  }

  var cItems = {
    isIncomplete: false,
    itemDefaults: {
      editRange: {
        start: {line: 0, character: 0},
        end: {line: 0, character: 2},
      },
      insertTextFormat: 1,
      insertTextMode: 2,
      data: {source: 'default'},
    },
    items: [{
      label: 'foobar',
    }],
  }

  completion.CompletionReply(lspserver, cItems, {})

  assert_false(lspserver.omniCompletePending)
  assert_equal(1, lspserver.completeItems->len())

  var item = lspserver.completeItems[0]
  assert_equal('foobar', item.word)
  assert_true(item.user_data->has_key('textEdit'))
  assert_equal('foobar', item.user_data.textEdit.newText)
  assert_equal(2, item.user_data.insertTextMode)
  assert_equal({source: 'default'}, item.user_data.data)
  assert_equal(0, item.user_data.textEdit.range.start.line)
  assert_equal(0, item.user_data.textEdit.range.start.character)
  assert_equal(0, item.user_data.textEdit.range.end.line)
  assert_equal(2, item.user_data.textEdit.range.end.character)

  :%bw!
enddef

# Regression test for CompletionItem.insertTextMode handling.
def g:Test_Completion_InsertTextMode_AdjustIndentation()
  silent! edit XCompletionInsertTextMode.vim
  setline(1, ['    f'])
  cursor(1, 6)

  var lspserver = {
    name: 'test',
    omniCompletePending: true,
    completionLazyDoc: false,
    completeItems: [],
    completeItemsIsIncomplete: false,
  }

  var cItems = [{
    label: 'foo',
    insertText: "foo\n  bar",
    insertTextFormat: 1,
    insertTextMode: 2,
  }]

  completion.CompletionReply(lspserver, cItems, {})

  assert_false(lspserver.omniCompletePending)
  assert_equal(1, lspserver.completeItems->len())
  assert_equal("foo\n    bar", lspserver.completeItems[0].word)

  :%bw!
enddef

def g:Test_Completion_InsertTextMode_AsIs()
  silent! edit XCompletionInsertTextModeAsIs.vim
  setline(1, ['    f'])
  cursor(1, 6)

  var lspserver = {
    name: 'test',
    omniCompletePending: true,
    completionLazyDoc: false,
    completeItems: [],
    completeItemsIsIncomplete: false,
  }

  var cItems = [{
    label: 'foo',
    insertText: "foo\n  bar",
    insertTextFormat: 1,
    insertTextMode: 1,
  }]

  completion.CompletionReply(lspserver, cItems, {})

  assert_false(lspserver.omniCompletePending)
  assert_equal(1, lspserver.completeItems->len())
  assert_equal("foo\n  bar", lspserver.completeItems[0].word)

  :%bw!
enddef

# Regression test for CompletionItem.labelDetails rendering.
def g:Test_Completion_LabelDetails_Rendering()
  g:LspOptionsSet({condensedCompletionMenu: false})

  silent! edit XCompletionLabelDetails.vim
  setline(1, ['fo'])
  cursor(1, 3)

  var lspserver = {
    name: 'test',
    omniCompletePending: true,
    completionLazyDoc: false,
    completeItems: [],
    completeItemsIsIncomplete: false,
  }

  var cItems = [{
    label: 'foo',
    labelDetails: {
      detail: '(x: number)',
      description: 'pkg.module',
    },
    detail: 'legacy detail',
  }]

  completion.CompletionReply(lspserver, cItems, {})

  assert_false(lspserver.omniCompletePending)
  assert_equal(1, lspserver.completeItems->len())

  var item = lspserver.completeItems[0]
  assert_equal('foo(x: number)', item.abbr)
  assert_equal('pkg.module | legacy detail', item.menu)

  :%bw!
enddef

# Regression test for CompletionTriggerKind=3 retrigger on incomplete lists.
def g:Test_Completion_RetriggerKind_IncompleteList()
  silent! edit XCompletionRetriggerKind.vim
  setline(1, ['foo'])
  cursor(1, 4)

  var calls: list<list<any>> = []
  var lspserver = {
    id: 9001,
    name: 'test',
    running: true,
    ready: true,
    isCompletionProvider: true,
    completeItemsIsIncomplete: true,
    features: {completion: true},
    featureEnabled: (_) => true,
    getCompletion: (kind: number, ch: string) => calls->add([kind, ch]),
  }

  buf.BufLspServerSet(bufnr(), lspserver)
  completion.LspComplete()

  assert_equal(1, calls->len())
  assert_equal(3, calls[0][0])
  assert_equal('', calls[0][1])

  buf.BufLspServerRemove(bufnr(), lspserver)
  :%bw!
enddef

def g:Test_Completion_TriggerKind_Initial()
  silent! edit XCompletionTriggerKindInitial.vim
  setline(1, ['foo'])
  cursor(1, 4)

  var calls: list<list<any>> = []
  var lspserver = {
    id: 9002,
    name: 'test',
    running: true,
    ready: true,
    isCompletionProvider: true,
    completeItemsIsIncomplete: false,
    features: {completion: true},
    featureEnabled: (_) => true,
    getCompletion: (kind: number, ch: string) => calls->add([kind, ch]),
  }

  buf.BufLspServerSet(bufnr(), lspserver)
  completion.LspComplete()

  assert_equal(1, calls->len())
  assert_equal(1, calls[0][0])
  assert_equal('', calls[0][1])

  buf.BufLspServerRemove(bufnr(), lspserver)
  :%bw!
enddef

# Labels served by MakeTruncatingServer(), in the server's relevance order.
const truncatingServerLabels = ['SDL_ClaimWindowForGPUDevice',
  'SDL_CreateGPUDevice', 'SDL_CreateGPUShader', 'SDL_CreateGPUTexture',
  'SDL_CreateWindow']

def TruncatedReply(prefix: string, limit: number): dict<any>
  var labels = truncatingServerLabels->copy()
    ->filter((_, label) => label->stridx(prefix) == 0)
  return {
    isIncomplete: labels->len() > limit,
    items: labels->slice(0, limit)->mapnew((_, label) => ({label: label})),
  }
enddef

# Returns a fake completion server that, like clangd, filters its labels on
# the keyword before the cursor and replies with at most "limit" items,
# setting "isIncomplete" when it truncated the list.  delays[n] is the reply
# delay in milliseconds for the n-th request; later requests reply at once.
def MakeTruncatingServer(limit: number, delays: list<number> = []): dict<any>
  var lspserver: dict<any> = {
    id: 9003,
    name: 'test',
    running: true,
    ready: true,
    isCompletionProvider: true,
    completionLazyDoc: false,
    completionTriggerChars: [],
    omniCompletePending: false,
    completeItems: [],
    completeItemsIsIncomplete: false,
    features: {completion: true},
    featureEnabled: (_) => true,
    requests: [],
    replies: 0,
    timers: [],
  }
  lspserver.getCompletion = (_, _) => {
    var prefix = getline('.')->strpart(0, col('.') - 1)->matchstr('\k*$')
    lspserver.requests->add(prefix)
    var reply = TruncatedReply(prefix, limit)
    var Reply = (_) => {
      lspserver.replies += 1
      completion.CompletionReply(lspserver, reply, {})
    }
    var delay = delays->get(lspserver.requests->len() - 1, 0)
    if delay > 0
      lspserver.timers->add(timer_start(delay, Reply))
    else
      Reply(0)
    endif
  }
  return lspserver
enddef

# Opens a buffer holding "text" with the cursor just after it and attaches a
# MakeTruncatingServer() to it.  <F2> in insert mode stores the words in the
# completion menu in b:matches.
def SetupTruncatingServerBuffer(text: string, limit: number,
				delays: list<number> = []): dict<any>
  silent! edit XOmniCompleteTruncating.vim
  # The trailing space lets the cursor sit just after "text" in Normal mode.
  setline(1, [$'{text} '])
  cursor(1, text->len() + 1)
  inoremap <buffer> <F2> <ScriptCmd>b:matches = complete_info(['matches']).matches->mapnew((_, v) => v.word)<CR>
  var lspserver = MakeTruncatingServer(limit, delays)
  buf.BufLspServerSet(bufnr(), lspserver)
  return lspserver
enddef

def TeardownTruncatingServerBuffer(lspserver: dict<any>)
  for timer in lspserver.timers
    timer_stop(timer)
  endfor
  test_override('char_avail', 0)
  buf.BufLspServerRemove(bufnr(), lspserver)
  :%bw!
enddef

# Returns the result of a completion function call with each match reduced to
# its word.
def WordsOf(result: any): any
  if result->type() == v:t_dict
    return result->extendnew({words: result.words->mapnew((_, v) => v.word)})
  endif
  return result->mapnew((_, v) => v.word)
enddef

# Lets feedkeys() drive keyword completion in the current buffer with
# g:LspCompleteSource() as the only source, until
# TeardownTruncatingServerBuffer().
def SetupFeedkeysCompletion()
  setlocal complete=Fg:LspCompleteSource completeopt=menuone,noselect
  # Let the source wait for replies although keys are in the typeahead.
  test_override('char_avail', 1)
enddef

# When the server returns an incomplete list, g:LspCompleteSource() asks Vim to
# call it again whenever the typed text changes.
def g:Test_CompleteSource_IncompleteList_RequestsRefresh()
  var lspserver = SetupTruncatingServerBuffer('SDL_C', 2)
  try
    assert_equal(0, g:LspCompleteSource(1, ''))
    assert_equal({
	words: ['SDL_ClaimWindowForGPUDevice', 'SDL_CreateGPUDevice'],
	refresh: 'always',
      }, g:LspCompleteSource(0, 'SDL_C')->WordsOf())
  finally
    TeardownTruncatingServerBuffer(lspserver)
  endtry
enddef

def g:Test_CompleteSource_CompleteList_ReturnsList()
  var lspserver = SetupTruncatingServerBuffer('SDL_C', 10)
  try
    assert_equal(0, g:LspCompleteSource(1, ''))
    assert_equal(truncatingServerLabels,
		 g:LspCompleteSource(0, 'SDL_C')->WordsOf())
  finally
    TeardownTruncatingServerBuffer(lspserver)
  endtry
enddef

# 'complete' sources are used in every buffer, so g:LspCompleteSource() skips
# a buffer without a usable language server instead of reporting an error.
def g:Test_CompleteSource_NoServer_SkipsSilently()
  :messages clear
  silent! edit XCompleteSourceNoServer.vim
  assert_equal(-2, g:LspCompleteSource(1, ''))
  assert_equal([], g:LspCompleteSource(0, ''))

  var lspserver = SetupTruncatingServerBuffer('', 2)
  try
    lspserver.ready = false
    assert_equal(-2, g:LspCompleteSource(1, ''))
    lspserver.ready = true
    lspserver.running = false
    assert_equal(-2, g:LspCompleteSource(1, ''))
  finally
    TeardownTruncatingServerBuffer(lspserver)
  endtry

  assert_equal([], execute('messages')->split("\n")
			    ->filter((_, msg) => msg =~ '^Error'))
enddef

# 'complete' sources are used in every buffer, so g:LspCompleteSource() skips
# a buffer without a usable language server instead of reporting an error.
def g:Test_CompleteSource_NoServer_SkipsSilently()
  :messages clear
  silent! edit XCompleteSourceNoServer.vim
  assert_equal(-2, g:LspCompleteSource(1, ''))
  assert_equal([], g:LspCompleteSource(0, ''))

  var lspserver = SetupTruncatingServerBuffer('', 2)
  defer TeardownTruncatingServerBuffer(lspserver)
  lspserver.ready = false
  assert_equal(-2, g:LspCompleteSource(1, ''))
  lspserver.ready = true
  lspserver.running = false
  assert_equal(-2, g:LspCompleteSource(1, ''))

  assert_equal([], execute('messages')->split("\n")
			    ->filter((_, msg) => msg =~ '^Error'))
enddef

# g:LspOmniFunc() is the 'omnifunc' and external completion engines call it
# directly expecting a list of matches, so it never returns the refresh dict.
def g:Test_OmniFunc_IncompleteList_ReturnsList()
  var lspserver = SetupTruncatingServerBuffer('SDL_C', 2)
  try
    assert_equal(0, g:LspOmniFunc(1, ''))
    assert_equal(['SDL_ClaimWindowForGPUDevice', 'SDL_CreateGPUDevice'],
		 g:LspOmniFunc(0, 'SDL_C')->WordsOf())
  finally
    TeardownTruncatingServerBuffer(lspserver)
  endtry
enddef

# Typing after CTRL-N must reach a match the server left out of its first,
# truncated reply.
def g:Test_CompleteSource_CtrlN_IncompleteList()
  if !exists('+autocomplete')
    return
  endif
  var lspserver = SetupTruncatingServerBuffer('', 2)
  try
    SetupFeedkeysCompletion()
    feedkeys("SSDL_C\<C-N>reateGPUTe\<F2>\<Esc>", 'tx!')
    assert_equal(['SDL_CreateGPUTexture'], b:matches)
    assert_equal('SDL_C', lspserver.requests[0])
    # Once a reply is complete, Vim filters it without asking again.
    assert_equal('SDL_CreateGPUT', lspserver.requests[-1])
  finally
    TeardownTruncatingServerBuffer(lspserver)
  endtry
enddef

# Same with Vim's 'autocomplete', which calls the source from the first typed
# character.
def g:Test_CompleteSource_Autocomplete_IncompleteList()
  if !exists('+autocomplete')
    return
  endif
  var lspserver = SetupTruncatingServerBuffer('', 2)
  try
    SetupFeedkeysCompletion()
    setlocal autocomplete
    feedkeys("SSDL_CreateGPUTe\<F2>\<Esc>", 'tx!')
    assert_equal(['SDL_CreateGPUTexture'], b:matches)
    assert_equal('S', lspserver.requests[0])
    assert_equal('SDL_CreateGPUT', lspserver.requests[-1])
  finally
    TeardownTruncatingServerBuffer(lspserver)
  endtry
enddef

# 'autocomplete' gives a function source 300 ms.  When the first reply is slower
# than that, Vim interrupts the source and calls it again on the next
# keystroke, from where refreshing must carry on.
def g:Test_CompleteSource_Autocomplete_SlowFirstReply()
  if !exists('+autocomplete')
    return
  endif
  var lspserver = SetupTruncatingServerBuffer('', 2, [600])
  try
    SetupFeedkeysCompletion()
    setlocal autocomplete
    feedkeys("SSDL_CreateGPUTe\<F2>\<Esc>", 'tx!')
    assert_equal(['SDL_CreateGPUTexture'], b:matches)
  finally
    TeardownTruncatingServerBuffer(lspserver)
  endtry
enddef

# Regression test for CompletionItem.preselect ordering.
def g:Test_Completion_Preselect_ItemFirst()
  silent! edit XCompletionPreselect.vim
  setline(1, ['f'])
  cursor(1, 2)

  var lspserver = {
    name: 'test',
    omniCompletePending: true,
    completionLazyDoc: false,
    completeItems: [],
    completeItemsIsIncomplete: false,
  }

  var cItems = [{
    label: 'alpha',
    sortText: 'a',
  }, {
    label: 'beta',
    sortText: 'b',
  }, {
    label: 'gamma',
    sortText: 'c',
    preselect: true,
  }]

  completion.CompletionReply(lspserver, cItems, {})

  assert_false(lspserver.omniCompletePending)
  assert_equal(3, lspserver.completeItems->len())
  assert_equal('gamma', lspserver.completeItems[0].word)
  assert_equal('alpha', lspserver.completeItems[1].word)
  assert_equal('beta', lspserver.completeItems[2].word)

  :%bw!
enddef

def g:Test_Completion_Preselect_NoopWithoutPreselect()
  silent! edit XCompletionPreselectNoop.vim
  setline(1, ['f'])
  cursor(1, 2)

  var lspserver = {
    name: 'test',
    omniCompletePending: true,
    completionLazyDoc: false,
    completeItems: [],
    completeItemsIsIncomplete: false,
  }

  var cItems = [{
    label: 'alpha',
    sortText: 'a',
  }, {
    label: 'beta',
    sortText: 'b',
  }, {
    label: 'gamma',
    sortText: 'c',
  }]

  completion.CompletionReply(lspserver, cItems, {})

  assert_false(lspserver.omniCompletePending)
  assert_equal(3, lspserver.completeItems->len())
  assert_equal('alpha', lspserver.completeItems[0].word)
  assert_equal('beta', lspserver.completeItems[1].word)
  assert_equal('gamma', lspserver.completeItems[2].word)

  :%bw!
enddef

# Regression test for documentOnTypeFormattingProvider trigger char capture.
def g:Test_OnTypeFormattingCapability()
  var lspserver = {
    caps: {
      documentOnTypeFormattingProvider: {
        firstTriggerCharacter: '}',
        moreTriggerCharacter: [';', "\n"],
      }
    },
    forceOffsetEncoding: '',
  }

  capabilities.ProcessServerCaps(lspserver, lspserver.caps)

  assert_true(lspserver.isDocumentOnTypeFormattingProvider)
  assert_equal(['}', ';', "\n"], lspserver.onTypeFormattingTriggers)
enddef

# Only here to because the test runner needs it
def g:StartLangServer(): bool
  return true
enddef

# Regression test for $HOME as workspace root being ignored
def g:Test_WorkspaceIgnoredPaths_HomeRoot()
  var ignored: list<string> = [$"{$HOME}"]
  var root: string = $HOME
  assert_true(util.IsIgnoredRoot(root, ignored))
enddef

# Glob pattern matches children even under a symlink
def g:Test_WorkspaceIgnoredPaths_GlobSymlink()
  var tmpdir: string = tempname()
  var real: string = $'{tmpdir}/real'
  var link: string = $'{tmpdir}/link'
  mkdir($'{real}/.cargo/registry/src/index', 'p')
  system($'ln -s {shellescape(real)} {shellescape(link)}')
  assert_equal(0, v:shell_error)
  var ignored: list<string> = [$'{link}/.cargo/**']
  var root: string = $'{real}/.cargo/registry/src/index/package'
  try
    assert_true(util.IsIgnoredRoot(root, ignored))
  finally
    delete(tmpdir, 'rf')
  endtry
enddef

# Root not ignored if it doesn't exist in the list
def g:Test_WorkspaceIgnoredPaths_NormalRoot()
  var ignored: list<string> = [$"{$HOME}"]
  var root: string = $"{$HOME}/project"
  assert_false(util.IsIgnoredRoot(root, ignored))
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
