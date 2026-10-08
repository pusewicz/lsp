vim9script
# Unit tests for Vim Language Server Protocol (LSP) for various functionality 

import '../autoload/lsp/completion.vim' as completion
import '../autoload/lsp/buffer.vim' as buf
import '../autoload/lsp/capabilities.vim' as capabilities
import '../autoload/lsp/documentlink.vim' as documentlink
import '../autoload/lsp/util.vim' as util
import '../autoload/lsp/options.vim' as opt

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
    posEncoding: 32,
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

# The menu shows CompletionItem.detail also when the documentation is resolved
# lazily.
def g:Test_Completion_Detail_LazyDoc()
  g:LspOptionsSet({condensedCompletionMenu: false})

  silent! edit XCompletionDetailLazyDoc.vim
  setline(1, ['fo'])
  cursor(1, 3)

  var lspserver = {
    name: 'test',
    omniCompletePending: true,
    completionLazyDoc: true,
    completeItems: [],
    completeItemsIsIncomplete: false,
  }

  completion.CompletionReply(lspserver, [{label: 'foo', detail: 'bool'}], {})

  var item = lspserver.completeItems[0]
  assert_equal('bool', item.menu)
  assert_equal('Resolving completion...', item.info)

  :%bw!
enddef

# Returns a fake language server for calling completion.CompletionReply()
# directly.
def MakeCompletionReplyServer(lazyDoc: bool): dict<any>
  return {
    name: 'test',
    omniCompletePending: true,
    completionLazyDoc: lazyDoc,
    completeItems: [],
    completeItemsIsIncomplete: false,
  }
enddef

# Returns the completion item for "word" in the reply stored in "lspserver".
def CompletionItemFor(lspserver: dict<any>, word: string): dict<any>
  return lspserver.completeItems->copy()->filter((_, v) => v.word == word)[0]
enddef

# A label longer than "completionLabelMaxWidth" is cut with an ellipsis and the
# full label moves to the top of the info popup.  The kind and the detail stay.
def g:Test_Completion_LabelMaxWidth()
  silent! edit XCompletionLabelMaxWidth.vim
  var lspserver = MakeCompletionReplyServer(false)
  var cItems = [
    {
      label: 'SDL_UploadToGPUBuffer',
      labelDetails: {detail: '(SDL_GPUCopyPass *copy_pass, bool cycle)'},
      kind: 3,
      detail: 'void',
      documentation: {kind: 'markdown', value: 'Uploads data.'},
    },
    {label: 'SDL_Quit', kind: 3, detail: 'void'},
    {label: 'SDL_GetError', kind: 3, detail: 'const char *'},
  ]
  g:LspOptionsSet({completionLabelMaxWidth: 12})
  try
    completion.CompletionReply(lspserver, cItems, {})
  finally
    g:LspOptionsSet({completionLabelMaxWidth: 0})
  endtry

  var ellipsis = &encoding == 'utf-8' ? '…' : '...'
  var full = 'SDL_UploadToGPUBuffer(SDL_GPUCopyPass *copy_pass, bool cycle)'
  var item = CompletionItemFor(lspserver, 'SDL_UploadToGPUBuffer')
  assert_equal(full->strpart(0, 12 - ellipsis->strdisplaywidth()) .. ellipsis,
	       item.abbr)
  assert_equal(12, item.abbr->strdisplaywidth())
  assert_equal('f', item.kind)
  assert_equal('void', item.menu)
  assert_equal($"    {full}\n- - -\nUploads data.", item.info)

  item = CompletionItemFor(lspserver, 'SDL_Quit')
  assert_equal('SDL_Quit', item.abbr)
  assert_false(item->has_key('info'))

  # A label exactly as wide as the limit is not cut.
  item = CompletionItemFor(lspserver, 'SDL_GetError')
  assert_equal('SDL_GetError', item.abbr)
  assert_false(item->has_key('info'))

  :%bw!
enddef

# The label is cut by screen cells: a double-width character that does not fit
# before the ellipsis is left out.
def g:Test_Completion_LabelMaxWidth_WideChars()
  if &encoding != 'utf-8'
    return
  endif
  silent! edit XCompletionLabelMaxWidthWide.vim
  var lspserver = MakeCompletionReplyServer(false)
  g:LspOptionsSet({completionLabelMaxWidth: 6})
  try
    completion.CompletionReply(lspserver, [{label: 'あいうえお'}], {})
  finally
    g:LspOptionsSet({completionLabelMaxWidth: 0})
  endtry

  assert_equal('あい…', lspserver.completeItems[0].abbr)
  assert_equal("    あいうえお", lspserver.completeItems[0].info)

  :%bw!
enddef

# Overloads whose labels differ only in the part that is cut off are not
# filtered out as duplicates.  With lazily resolved documentation the info
# text is left for the resolve reply.
def g:Test_Completion_LabelMaxWidth_KeepsOverloads()
  silent! edit XCompletionLabelMaxWidthOverloads.vim
  var lspserver = MakeCompletionReplyServer(true)
  var cItems = [
    {label: 'foo', labelDetails: {detail: '(int a, int b)'}, sortText: '1'},
    {label: 'foo', labelDetails: {detail: '(int a, char *b)'}, sortText: '1'},
  ]
  g:LspOptionsSet({completionLabelMaxWidth: 8,
		   filterCompletionDuplicates: true})
  try
    completion.CompletionReply(lspserver, cItems, {})
  finally
    g:LspOptionsSet({completionLabelMaxWidth: 0,
		     filterCompletionDuplicates: false})
  endtry

  var items = lspserver.completeItems
  assert_equal(2, items->len())
  assert_equal(items[0].abbr, items[1].abbr)
  assert_equal(['Resolving completion...', 'Resolving completion...'],
	       items->mapnew((_, v) => v.info))

  :%bw!
enddef

# Item resolved by Test_Completion_LabelMaxWidth_LazyDocInfo().
var lazyDocItem: dict<any> = {
  label: 'foo',
  labelDetails: {detail: '(int first, int second)'},
  detail: 'void',
  documentation: 'Does foo.',
}

# Shows lazyDocItem, with its label cut, as the selected item of the
# completion menu.
def ShowLazyDocItemMenu()
  complete(col('.'), [{
    word: 'foo',
    abbr: 'foo(int f…',
    info: 'Resolving completion...',
    user_data: lazyDocItem,
  }])
enddef

# Passes the resolved lazyDocItem to the completion code and stores the lines
# of the info popup in b:info.
def ResolveLazyDocItem()
  completion.CompletionResolveReply({}, lazyDocItem)
  b:info = popup_findinfo()->winbufnr()->getbufline(1, '$')
enddef

# With lazily resolved documentation the info popup still starts with the
# full label of an item whose label the menu cuts.
def g:Test_Completion_LabelMaxWidth_LazyDocInfo()
  silent! edit XCompletionLabelMaxWidthLazyDoc.vim
  setlocal completeopt=menuone,popuphidden
  inoremap <buffer> <F2> <ScriptCmd>ShowLazyDocItemMenu()<CR>
  inoremap <buffer> <F3> <ScriptCmd>ResolveLazyDocItem()<CR>
  g:LspOptionsSet({completionLabelMaxWidth: 10})
  try
    feedkeys("i\<F2>\<F3>\<Esc>", 'tx!')
  finally
    g:LspOptionsSet({completionLabelMaxWidth: 0})
  endtry

  assert_equal(['    foo(int first, int second)', '- - -', 'void', '- - -',
		'Does foo.'], b:info)

  :%bw!
enddef

# condensedCompletionMenu moves the label details and the detail to the info
# popup, in front of the documentation.
def g:Test_Completion_CondensedMenu()
  silent! edit XCompletionCondensedMenu.vim
  var lspserver = MakeCompletionReplyServer(false)
  var cItems = [{
    label: 'foo',
    labelDetails: {detail: '(x)'},
    detail: 'int',
    documentation: 'Does foo.',
  }]
  g:LspOptionsSet({condensedCompletionMenu: true})
  try
    completion.CompletionReply(lspserver, cItems, {})
  finally
    g:LspOptionsSet({condensedCompletionMenu: false})
  endtry

  var item = lspserver.completeItems[0]
  assert_equal('foo', item.abbr)
  assert_equal('', item.menu)
  assert_equal("    foo(x)\n- - -\n    int\n- - -\nDoes foo.", item.info)

  :%bw!
enddef

# The kind of a completion item is shown with the configured kind text and,
# when Vim supports it, highlighted with the "LspCompletionKind{Name}" group.
def g:Test_Completion_Kind()
  completion.InitOnce()
  assert_equal('Function', hlget('LspCompletionKindFunction')[0].linksto)
  assert_equal('Type', hlget('LspCompletionKindStruct')[0].linksto)

  silent! edit XCompletionKind.vim
  setline(1, ['fo'])
  cursor(1, 3)

  var lspserver = {
    name: 'test',
    omniCompletePending: true,
    completionLazyDoc: false,
    completeItems: [],
    completeItemsIsIncomplete: false,
  }

  var cItems = [
    {label: 'foo1', kind: 3},
    {label: 'foo2', kind: 22},
    {label: 'foo3', kind: 0},
    {label: 'foo4', kind: 99},
    {label: 'foo5'},
  ]
  g:LspOptionsSet({customCompletionKinds: true,
                   completionKinds: {Struct: ""}})
  try
    completion.CompletionReply(lspserver, cItems, {})
  finally
    g:LspOptionsSet({customCompletionKinds: false, completionKinds: {}})
  endtry

  var items = lspserver.completeItems
  assert_equal(['f', "", '', ''],
               items[0 : 3]->mapnew((_, v) => v.kind))
  assert_false(items[4]->has_key('kind'))
  if has('patch-9.1.0690')
    assert_equal('LspCompletionKindFunction', items[0].kind_hlgroup)
    assert_equal('LspCompletionKindStruct', items[1].kind_hlgroup)
  else
    assert_false(items[0]->has_key('kind_hlgroup'))
  endif
  assert_false(items[2]->has_key('kind_hlgroup'))
  assert_false(items[3]->has_key('kind_hlgroup'))

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
  # 'autocomplete' is global before patch 9.1.1779, so ":setlocal" sets it for
  # the following tests too.
  if exists('+autocomplete')
    set noautocomplete
  endif
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

# Returns a fake completion server whose single item is documented in markdown
# by "doc", sent in the completion reply.  Without "lazyDoc" it is like clangd,
# which doesn't support completionItem/resolve.
def MakeMarkdownDocServer(doc: string, lazyDoc: bool = false): dict<any>
  var lspserver: dict<any> = {
    id: 9004,
    name: 'test',
    running: true,
    ready: true,
    isCompletionProvider: true,
    completionLazyDoc: lazyDoc,
    completionTriggerChars: [],
    omniCompletePending: false,
    completeItems: [],
    completeItemsIsIncomplete: false,
    features: {completion: true},
    featureEnabled: (_) => true,
    resolveCompletion: (item, _) => item,
  }
  var items = [{
    label: 'SDL_Log',
    documentation: {kind: 'markdown', value: doc},
  }]
  lspserver.getCompletion = (_, _) => {
    completion.CompletionReply(lspserver, items->deepcopy(), {})
  }
  return lspserver
enddef

# Returns the 'filetype', the lines and the number of syntax highlighted code
# blocks of buffer "bnr" showing completion documentation.
def DocBufferState(bnr: number): dict<any>
  return {
    ft: bnr->getbufvar('&ft'),
    text: bnr->getbufline(1, '$'),
    codeBlocks: bnr->getbufvar('lsp_syntax', [])->len(),
  }
enddef

# Returns the DocBufferState() of the info popup when it is visible.
def VisibleInfoPopupState(): dict<any>
  var id = popup_findinfo()
  if id == 0 || !id->popup_getpos().visible
    return {}
  endif
  return id->winbufnr()->DocBufferState()
enddef

# Selects the completion item of "lspserver", a MakeMarkdownDocServer(), with
# 'completeopt' set to "completeopt".  Returns the DocBufferState() of the info
# popup ("popup") and of the preview window ("preview") showing its
# documentation, or an empty dict for one that doesn't.
def SelectMarkdownDocItem(lspserver: dict<any>,
			  completeopt: string): dict<dict<any>>
  # Find the lspgfm ftplugin and syntax files that render markdown
  var rtp = &rtp
  &rtp = $"{fnamemodify('..', ':p')},{&rtp}"
  silent! edit XCompletionMarkdownDoc.c
  buf.BufLspServerSet(bufnr(), lspserver)
  completion.BufferInit(lspserver, bufnr(), 'c')
  &l:complete = 'Fg:LspCompleteSource'
  &l:completeopt = completeopt
  test_override('char_avail', 1)
  # Vim reuses the info popup of an earlier completion, 'filetype' included
  popup_findinfo()->popup_close()
  b:popupState = {}
  # The preview window 'filetype' is set from a timer, which runs in the wait
  inoremap <buffer> <F2> <ScriptCmd>sleep 20m<CR>
  inoremap <buffer> <F3> <ScriptCmd>b:popupState = VisibleInfoPopupState()<CR>
  var state: dict<dict<any>> = {popup: {}, preview: {}}
  try
    feedkeys("SSDL_Lo\<C-N>\<F2>\<F3>\<Esc>", 'tx!')
    state.popup = b:popupState
    for w in range(1, winnr('$'))
      if getwinvar(w, '&previewwindow')
	state.preview = w->winbufnr()->DocBufferState()
      endif
    endfor
  finally
    test_override('char_avail', 0)
    buf.BufLspServerRemove(bufnr(), lspserver)
    :pclose
    :%bw!
    &rtp = rtp
  endtry
  return state
enddef

const sdlLogDoc = "Log a message with SDL\\_LOG\\_PRIORITY\\_INFO.\n\n\\\\param fmt"
const sdlLogDocRendered = {
  ft: 'lspgfm',
  text: ['Log a message with SDL_LOG_PRIORITY_INFO.', '', '\param fmt'],
  codeBlocks: 0,
}

# The documentation of an item that is not resolved lazily is rendered as
# markdown in the info popup, which overrides the preview window even with
# completionInPreview (that sets 'completeopt' only for autoComplete).
def g:Test_Completion_MarkdownDoc_InfoPopup()
  if !exists('+autocomplete')
    return
  endif
  g:LspOptionsSet({autoComplete: false, omniComplete: true})
  try
    for inPreview in [false, true]
      g:LspOptionsSet({completionInPreview: inPreview})
      assert_equal({popup: sdlLogDocRendered, preview: {}},
		   SelectMarkdownDocItem(MakeMarkdownDocServer(sdlLogDoc),
					 'menuone,popup,preview'))
    endfor
  finally
    g:LspOptionsSet({autoComplete: true, omniComplete: null,
		     completionInPreview: false})
  endtry
enddef

# Without "popup" in 'completeopt' the documentation is shown and rendered as
# markdown in the preview window.
def g:Test_Completion_MarkdownDoc_PreviewWindow()
  if !exists('+autocomplete')
    return
  endif
  g:LspOptionsSet({autoComplete: false, omniComplete: true,
		   closePreviewOnComplete: false})
  try
    assert_equal({popup: {}, preview: sdlLogDocRendered},
		 SelectMarkdownDocItem(MakeMarkdownDocServer(sdlLogDoc),
				       'menuone,preview'))
  finally
    g:LspOptionsSet({autoComplete: true, omniComplete: null,
		     closePreviewOnComplete: true})
  endtry
enddef

# Documentation that a server supporting completionItem/resolve sent in the
# completion reply is rendered as markdown only once, which keeps the syntax
# highlighting of its code blocks.
def g:Test_Completion_MarkdownDoc_LazyDocRenderedOnce()
  if !exists('+autocomplete')
    return
  endif
  g:LspOptionsSet({autoComplete: false, omniComplete: true})
  try
    assert_equal({
	popup: {ft: 'lspgfm', text: ['int x;'], codeBlocks: 1},
	preview: {},
      }, SelectMarkdownDocItem(MakeMarkdownDocServer("```c\nint x;\n```", true),
			       'menuone,popup'))
  finally
    g:LspOptionsSet({autoComplete: true, omniComplete: null})
  endtry
enddef

# Same without "popup" in 'completeopt': the documentation is shown and
# rendered in the preview window.
def g:Test_Completion_MarkdownDoc_LazyDocPreviewWindow()
  if !exists('+autocomplete')
    return
  endif
  g:LspOptionsSet({autoComplete: false, omniComplete: true,
		   closePreviewOnComplete: false})
  try
    assert_equal({
	popup: {},
	preview: {ft: 'lspgfm', text: ['int x;'], codeBlocks: 1},
      }, SelectMarkdownDocItem(MakeMarkdownDocServer("```c\nint x;\n```", true),
			       'menuone,preview'))
  finally
    g:LspOptionsSet({autoComplete: true, omniComplete: null,
		     closePreviewOnComplete: true})
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

# Returns the LSP range from character "start" to "end" on the first line.
def FirstLineRange(start: number, end: number): dict<any>
  return {start: {line: 0, character: start}, end: {line: 0, character: end}}
enddef

# Completions of TypeScript object properties as typescript-language-server
# (with TypeScript 4.9) and TypeScript 7 ("tsc --lsp") send them.  They
# complete an optional property ("address?: Address") with optional chaining
# and a property that isn't an identifier ("'my-key'?: number") with bracket
# notation, using a text edit that replaces the "." before the keyword.
# Completing "text" (followed by "after"), accepting the "pick"-th match and
# typing "|" results in "expected".
def TextEditCompletionCases(): list<dict<any>>
  var tsgoOptional = [{
    label: 'state?', insertText: '?.state', filterText: '.state',
    textEdit: {range: FirstLineRange(11, 12), newText: '?.state'},
  }, {
    label: 'town?', insertText: '?.town', filterText: '.town',
    textEdit: {range: FirstLineRange(11, 12), newText: '?.town'},
  }]
  var ts49Member = [{
    label: 'address?', filterText: '.address',
    textEdit: {range: FirstLineRange(3, 4), newText: '.address'},
  }, {
    label: 'my-key?', filterText: '.["my-key"]',
    textEdit: {range: FirstLineRange(3, 4), newText: '["my-key"]'},
  }]
  var multibyteItem = {
    label: 'state?', insertText: '?.state', filterText: '.state',
    textEdit: {newText: '?.state'},
  }

  return [{
    name: 'tsgo optional chaining',
    text: 'foo.address.',
    items: tsgoOptional,
    pick: 2,
    expected: 'foo.address?.town|',
  }, {
    name: 'tsgo optional chaining after a keyword',
    text: 'foo.address.st',
    items: [tsgoOptional[0]->deepcopy()->extend({
      textEdit: {range: FirstLineRange(11, 14), newText: '?.state'}}),
      tsgoOptional[1]],
    pick: 1,
    expected: 'foo.address?.state|',
  }, {
    name: 'TS 4.9 optional chaining',
    text: 'foo.address.',
    items: [{
      label: 'state?', filterText: '.?.state',
      textEdit: {range: FirstLineRange(11, 12), newText: '?.state'},
    }, {
      label: 'town?', filterText: '.?.town',
      textEdit: {range: FirstLineRange(11, 12), newText: '?.town'},
    }],
    pick: 1,
    expected: 'foo.address?.state|',
  }, {
    name: 'TS 4.9 optional chaining after a keyword',
    text: 'foo.address.to',
    items: [{
      label: 'state?', filterText: '?.state',
      textEdit: {range: FirstLineRange(11, 12), newText: '?.state'},
    }, {
      label: 'town?', filterText: '?.town',
      textEdit: {range: FirstLineRange(11, 14), newText: '?.town'},
    }],
    pick: 1,
    expected: 'foo.address?.town|',
  }, {
    name: 'TS 4.9 member access',
    text: 'foo.',
    items: ts49Member,
    pick: 1,
    expected: 'foo.address|',
  }, {
    name: 'TS 4.9 bracket notation',
    text: 'foo.',
    items: ts49Member,
    pick: 2,
    expected: 'foo["my-key"]|',
  }, {
    name: 'tsgo bracket notation after a keyword',
    text: 'foo.my',
    items: [{
      label: 'name?', filterText: 'name',
      textEdit: {insert: FirstLineRange(4, 6), replace: FirstLineRange(4, 6),
		 newText: 'name'},
    }, {
      label: 'my-key?', insertText: '["my-key"]', filterText: '.my-key',
      textEdit: {range: FirstLineRange(3, 6), newText: '["my-key"]'},
    }],
    pick: 1,
    expected: 'foo["my-key"]|',
  }, {
    name: 'UTF-16 position offsets',
    text: '/* 😀 */ foo.address.',
    posEncoding: 16,
    items: [multibyteItem->deepcopy()->extend({
      textEdit: {range: FirstLineRange(20, 21), newText: '?.state'}})],
    pick: 1,
    expected: '/* 😀 */ foo.address?.state|',
  }, {
    name: 'UTF-8 position offsets',
    text: '/* 😀 */ foo.address.',
    posEncoding: 8,
    items: [multibyteItem->deepcopy()->extend({
      textEdit: {range: FirstLineRange(22, 23), newText: '?.state'}})],
    pick: 1,
    expected: '/* 😀 */ foo.address?.state|',
  }, {
    name: 'InsertReplace edit',
    text: 'foo.na',
    after: 'x;',
    items: [{
      label: 'name?', filterText: 'name',
      textEdit: {insert: FirstLineRange(4, 6), replace: FirstLineRange(4, 7),
		 newText: 'name'},
    }],
    pick: 1,
    expected: 'foo.name|;',
  }]
enddef

# Returns a fake completion server, not supporting completionItem/resolve,
# that replies to every completion request with the items of "testCase" (see
# TextEditCompletionCases()).
def MakeTextEditServer(testCase: dict<any>): dict<any>
  var lspserver: dict<any> = {
    id: 9004,
    name: 'test',
    running: true,
    ready: true,
    isCompletionProvider: true,
    completionLazyDoc: false,
    completionTriggerChars: ['.'],
    omniCompletePending: false,
    completeItems: [],
    completeItemsIsIncomplete: false,
    features: {completion: true},
    featureEnabled: (_) => true,
    posEncoding: testCase->get('posEncoding', 32),
  }
  lspserver.getCompletion = (_, _) => {
    completion.CompletionReply(lspserver, testCase.items->deepcopy(), {})
  }
  lspserver.resolveCompletion = (_, _) => ({})
  return lspserver
enddef

# Completes "testCase" (see TextEditCompletionCases()) with omni completion
# when "omni" is true and with auto-completion otherwise.  Returns the
# completed line.
def CompleteTextEditCase(testCase: dict<any>, omni: bool): string
  silent! edit XCompletionTextEdit.ts
  setline(1, testCase.text .. testCase->get('after', ''))
  var lspserver = MakeTextEditServer(testCase)
  buf.BufLspServerSet(bufnr(), lspserver)
  completion.OmniComplSet(&filetype, omni)
  var completedLine = ''
  try
    completion.BufferInit(lspserver, bufnr(), &filetype)
    setlocal completeopt=menuone,noinsert,noselect
    inoremap <buffer> <F5> <ScriptCmd>completion.LspComplete(true)<CR>
    cursor(1, testCase.text->len())
    feedkeys('a' .. (omni ? "\<C-X>\<C-O>" : "\<F5>")
	     .. repeat("\<C-N>", testCase.pick) .. "\<C-Y>|\<Esc>", 'xt')
    completedLine = getline(1)
  finally
    completion.OmniComplSet(&filetype, false)
    buf.BufLspServerRemove(bufnr(), lspserver)
    :%bw!
  endtry
  return completedLine
enddef

# Completes "TextEditCompletionCases()" with every completion matcher, with
# omni completion when "omni" is true and with auto-completion otherwise.
def CheckTextEditCompletion(omni: bool)
  var saveAutoComplete = g:LspOptionsGet().autoComplete
  var saveCompleteopt = &g:completeopt
  g:LspOptionsSet({autoComplete: !omni})
  try
    for matcher in ['case', 'icase', 'fuzzy']
      g:LspOptionsSet({completionMatcher: matcher})
      for testCase in TextEditCompletionCases()
	if testCase->get('posEncoding', 32) != 32 && !has('patch-9.0.1629')
	  continue
	endif
	assert_equal(testCase.expected, CompleteTextEditCase(testCase, omni),
		     $'{testCase.name} with the "{matcher}" matcher')
      endfor
    endfor
  finally
    g:LspOptionsSet({completionMatcher: 'case',
		     autoComplete: saveAutoComplete})
    &g:completeopt = saveCompleteopt
  endtry
enddef

# A completion item's text edit, including one that replaces text before the
# keyword being completed, is applied with every completion matcher.
def g:Test_Completion_TextEdit_OmniComplete()
  CheckTextEditCompletion(true)
enddef

def g:Test_Completion_TextEdit_AutoComplete()
  CheckTextEditCompletion(false)
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

const popupTypes: list<string> = ['CodeAction', 'Completion', 'Diag', 'Hover',
  'Peek', 'SignatureHelp', 'SymbolMenu', 'SymbolMenuInput', 'TypeHierarchy']

# Return the "opacity" attribute PopupConfigure() sets for each popup type,
# leaving out the types it sets none for.
def PopupOpacities(): dict<number>
  var opacities: dict<number> = {}
  for type in popupTypes
    var attrs = opt.PopupConfigure(type, {})
    if attrs->has_key('opacity')
      opacities[type] = attrs.opacity
    endif
  endfor
  return opacities
enddef

# Drop the per-type popup opacity overrides and restore the default opacity.
def ResetPopupOpacityOptions()
  opt.lspOptions->filter((key, _) => key !~ '^popupOpacity.')
  g:LspOptionsSet({popupOpacity: 100})
enddef

# By default popups are not given an opacity at all.
def g:Test_PopupConfigure_Opacity_Default()
  assert_equal({}, PopupOpacities())
enddef

# popupOpacity applies to every popup type unless overridden per type.
def g:Test_PopupConfigure_Opacity_Overrides()
  try
    g:LspOptionsSet({popupOpacity: 70, popupOpacityHover: 0,
		     popupOpacityDiag: 100})
    if has('patch-9.2.0017')
      assert_equal({CodeAction: 70, Completion: 70, Hover: 0, Peek: 70,
		    SignatureHelp: 70, SymbolMenu: 70, SymbolMenuInput: 70,
		    TypeHierarchy: 70}, PopupOpacities())
    else
      assert_equal({}, PopupOpacities())
    endif
  finally
    ResetPopupOpacityOptions()
  endtry
enddef

# Out of range and non-number opacity values leave popups opaque.
def g:Test_PopupConfigure_Opacity_InvalidValues()
  try
    g:LspOptionsSet({popupOpacity: 150, popupOpacityHover: -1,
		     popupOpacityDiag: '50', popupOpacityPeek: 50.0,
		     popupOpacityCompletion: 40})
    if has('patch-9.2.0017')
      assert_equal({Completion: 40}, PopupOpacities())
    else
      assert_equal({}, PopupOpacities())
    endif
  finally
    ResetPopupOpacityOptions()
  endtry
enddef

# The opacity reaches a new popup and an existing popup updated with
# popup_setoptions(), as is done for the completion documentation popup.
def g:Test_PopupConfigure_Opacity_AppliedToPopup()
  if !has('patch-9.2.0017')
    return
  endif
  try
    g:LspOptionsSet({popupOpacity: 60, popupOpacityCompletion: 30})
    var winid = popup_create('hover', opt.PopupConfigure('Hover', {}))
    assert_equal(60, winid->popup_getoptions().opacity)

    var infoid = popup_create('info', {})
    assert_equal(100, infoid->popup_getoptions().opacity)
    infoid->popup_setoptions(opt.PopupConfigure('Completion', {}))
    assert_equal(30, infoid->popup_getoptions().opacity)
  finally
    popup_clear()
    ResetPopupOpacityOptions()
  endtry
enddef

# Test for the documentLinkProvider server capability and the documentLink
# client capability
def g:Test_DocumentLinkCapability()
  var lspserver: dict<any> = {caps: {}, forceOffsetEncoding: ''}
  capabilities.ProcessServerCaps(lspserver, lspserver.caps)
  assert_false(lspserver.isDocumentLinkProvider)
  assert_false(lspserver.isDocumentLinkResolveProvider)

  lspserver.caps = {documentLinkProvider: {resolveProvider: true}}
  capabilities.ProcessServerCaps(lspserver, lspserver.caps)
  assert_true(lspserver.isDocumentLinkProvider)
  assert_true(lspserver.isDocumentLinkResolveProvider)

  assert_true(capabilities.GetClientCaps().textDocument.documentLink.tooltipSupport)
enddef

# Test for parsing the line and column fragment in a document link file URI
def g:Test_DocumentLink_ParseFileUri()
  var uri = 'file:///tmp/a%20b.c'
  assert_equal([uri, 1, 1], documentlink.ParseFileUri(uri))
  assert_equal([uri, 10, 1], documentlink.ParseFileUri($'{uri}#L10'))
  assert_equal([uri, 10, 5], documentlink.ParseFileUri($'{uri}#L10,5'))
  assert_equal([uri, 10, 5], documentlink.ParseFileUri($'{uri}#10,5'))
  assert_equal([uri, 3, 2], documentlink.ParseFileUri($'{uri}#L3,2-L4,1'))
  assert_equal([uri, 1, 1], documentlink.ParseFileUri($'{uri}#L0'))
  assert_equal([uri, 1, 1], documentlink.ParseFileUri($'{uri}#section'))
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
