vim9script
# Unit tests using a stub language server

import '../autoload/lsp/lspserver.vim' as lserver
import '../autoload/lsp/lsp.vim' as lsp
import '../autoload/lsp/codeaction.vim' as codeaction
import '../autoload/lsp/signature.vim' as signature
import '../autoload/lsp/completion.vim' as completion
import '../autoload/lsp/handlers.vim' as handlers
import '../autoload/lsp/diag.vim' as diag
import '../autoload/lsp/symbol.vim' as symbol
import '../autoload/lsp/util.vim' as util
import '../autoload/lsp/buffer.vim' as buf
import '../autoload/lsp/ontypeformat.vim' as ontypeformat
import '../autoload/lsp/textedit.vim' as textedit
import '../autoload/lsp/hover.vim' as hover
import '../autoload/lsp/options.vim' as opt

def CaptureNotification(notifications: list<dict<any>>, method: string,
			params: any = {}): void
  notifications->add({method: method, params: params->deepcopy()})
enddef

def StubDiagHandler(diags: list<dict<any>>): list<dict<any>>
  return diags
enddef

def MakeTestLspServer(notifications: list<dict<any>>): dict<any>
  var lspserver = lserver.NewLspServer({
	name: 'test',
	path: 'test-lsp',
	args: [],
	customNotificationHandlers: {},
	customRequestHandlers: {},
	debug: false,
	features: {},
	forceOffsetEncoding: '',
	initializationOptions: {},
	languageId: '',
	processDiagHandler: StubDiagHandler,
	rootSearch: [],
	runIfSearch: [],
	runUnlessSearch: [],
	syncInit: false,
	traceLevel: 'off',
	workspaceConfig: {}
      })
  lspserver.textDocumentSync = 2
  # Not set by NewLspServer() -- only assigned while processing the
  # "initialize" response -- but the incremental-sync code path needs it.
  lspserver.posEncoding = 32
  lspserver.sendNotification = function(CaptureNotification, [notifications])
  return lspserver
enddef

def MakeCodeActionServer(name: string, actions: list<dict<any>>,
		execCmds: list<string>): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.name = name
  lspserver.running = true
  lspserver.ready = true
  lspserver.isCodeActionProvider = true
  lspserver.featureEnabled = (_feature: string): bool => true
  lspserver.codeActionAsync = (_, _, _, query, Cbfunc) => {
    Cbfunc(lspserver, actions->deepcopy(), query, {})
  }
  lspserver.executeCommand = (cmd: dict<any>) => {
    execCmds->add(cmd->get('command', ''))
  }
  return lspserver
enddef

def SeedBufferDiagnostics(diags: list<dict<any>>): void
  g:LspOptionsSet({autoHighlightDiags: false})
  var diagSrv = MakeTestLspServer([])
  diagSrv.features = {diagnostics: true}
  diagSrv.featureEnabled = (_) => true
  diag.DiagNotification(diagSrv, util.LspBufnrToUri(bufnr()), diags, 'push')
enddef

def ClearBufferDiagnostics(): void
  diag.DiagRemoveFile(bufnr())
  g:LspOptionsSet({autoHighlightDiags: true})
enddef

def CaptureResponse(responses: list<dict<any>>, request: dict<any>,
      result: any, error: dict<any>): void
  responses->add({id: request.id, result: result, error: error->deepcopy()})
enddef

def CaptureMessage(messages: list<dict<any>>, msg: dict<any>): void
  messages->add(msg->deepcopy())
enddef

def MakeRequestTestLspServer(responses: list<dict<any>>): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.sendResponse = function(CaptureResponse, [responses])
  return lspserver
enddef

def AssertRequestError(lspserver: dict<any>, responses: list<dict<any>>,
          request: dict<any>, code: number)
  responses->filter('0')
  lspserver.processRequest(request)
  assert_equal(1, responses->len())
  assert_equal(request.id, responses[0].id)
  assert_equal(code, responses[0].error.code)
enddef

def g:Test_RequestValidation_InvalidRequest()
  var responses: list<dict<any>> = []
  var lspserver = MakeRequestTestLspServer(responses)

  # -32600 InvalidRequest: object params are required but missing.
  AssertRequestError(lspserver, responses,
    {id: 1, method: 'workspace/applyEdit'}, -32600)
  AssertRequestError(lspserver, responses,
    {id: 2, method: 'workspace/configuration'}, -32600)
  AssertRequestError(lspserver, responses,
    {id: 3, method: 'window/showMessageRequest'}, -32600)

  AssertRequestError(lspserver, responses,
    {id: 4, method: 'client/registerCapability'}, -32600)
  AssertRequestError(lspserver, responses,
    {id: 5, method: 'client/unregisterCapability'}, -32600)
  AssertRequestError(lspserver, responses,
    {id: 6, method: 'window/workDoneProgress/create'}, -32600)
enddef

def g:Test_RequestValidation_InvalidParamsAndMethodNotFound()
  var responses: list<dict<any>> = []
  var lspserver = MakeRequestTestLspServer(responses)

  # -32602 InvalidParams: params type/shape is invalid.
  AssertRequestError(lspserver, responses,
    {id: 10, method: 'workspace/applyEdit', params: []}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 11, method: 'workspace/applyEdit', params: {}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 12, method: 'workspace/configuration', params: {}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 13, method: 'workspace/configuration', params: {items: {}}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 14, method: 'window/showMessageRequest', params: {}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 15, method: 'window/showMessageRequest', params: {message: 99}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 16, method: 'window/showMessageRequest', params: {message: 'Pick', actions: {}}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 17, method: 'window/showMessageRequest', params: {message: 'Pick', actions: [{}]}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 18, method: 'window/showMessageRequest', params: {message: 'Pick', actions: [{title: 1}]}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 19, method: 'workspace/workspaceFolders', params: {foo: 1}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 20, method: 'workspace/diagnostic/refresh', params: {foo: 1}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 21, method: 'client/registerCapability', params: {}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 22, method: 'client/registerCapability', params: {registrations: {}}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 23, method: 'client/unregisterCapability', params: {}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 24, method: 'client/unregisterCapability', params: {unregisterations: {}}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 25, method: 'window/workDoneProgress/create', params: {}}, -32602)

  # Unknown method should return MethodNotFound.
  AssertRequestError(lspserver, responses,
    {id: 26, method: 'workspace/notARealMethod', params: {}}, -32601)
enddef

def g:Test_ProcessRequest_CustomHandlerException_ReturnsInternalError()
  var responses: list<dict<any>> = []
  var lspserver = MakeRequestTestLspServer(responses)
  lspserver.customRequestHandlers = {
    'custom/fail': (_, _) => {
      throw 'forced failure'
    }
  }

  AssertRequestError(lspserver, responses,
    {id: 27, method: 'custom/fail', params: {}}, -32603)
enddef

def AssertIgnoredUnknownResponse(lspserver: dict<any>, payload: dict<any>, id: string)
  var traceMsgs: list<string> = []
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.processRequest = (_, _) => assert_report('unexpected request dispatch')
  lspserver.processNotif = (_, _) => assert_report('unexpected notification dispatch')

  var beforeMessages = execute('messages')
  lspserver.data = payload
  lspserver.processMessage()

  assert_equal(1, traceMsgs->len())
  assert_match('Ignored response with unknown id from LSP server:', traceMsgs[0])

  var afterMessages = execute('messages')
  assert_equal(-1, afterMessages->stridx($'Unrecognized id in reponse received from LSP server: {id}'))
  assert_equal(beforeMessages, afterMessages)
enddef

def g:Test_ProcessMessages_IgnoreUnknownResponseId_Result()
  var lspserver = MakeTestLspServer([])
  var unknownId = 'X-unknown-response-id-result'
  AssertIgnoredUnknownResponse(lspserver,
    {
      jsonrpc: '2.0',
      id: unknownId,
      result: {}
    }, unknownId)
enddef

# Test that a reply to a waiting synchronous request is passed back to it
# instead of being ignored.
def g:Test_ProcessMessages_PassesBackSyncRpcReply()
  var lspserver = MakeTestLspServer([])
  var traceMsgs: list<string> = []
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.syncRpcReplies[1000000005] = {}

  var reply = {jsonrpc: '2.0', id: 1000000005, result: {name: 'f1'}}
  lspserver.data = reply
  lspserver.processMessage()

  assert_equal({1000000005: reply}, lspserver.syncRpcReplies)
  assert_equal([], traceMsgs)
enddef

# Start a job that stands in for a language server: it sends "messages" and
# then reads what it is sent without ever replying.
def StartStubServerJob(messages: list<dict<any>>, jobOpts: dict<any> = {}): job
  var output = messages->mapnew((_, msg) => {
    var body = msg->json_encode()
    return $"Content-Length: {body->len()}\r\n\r\n{body}"
  })->join('')
  return job_start(['sh', '-c', 'printf "%s" "$1"; exec cat >/dev/null', 'sh',
		    output],
		   {in_mode: 'lsp', out_mode: 'lsp', noblock: 1}->extend(jobOpts))
enddef

# Test that a synchronous request is cancelled when its reply doesn't arrive
# in time.
def g:Test_Rpc_CancelsTimedOutRequest()
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.job = StartStubServerJob([])
  try
    var id = lspserver.nextSyncRpcId

    assert_equal({}, lspserver.rpc('test/noReply', {}, {timeout: 50}))
    assert_equal([{method: '$/cancelRequest', params: {id: id}}], notifications)
    assert_equal({}, lspserver.syncRpcReplies)
  finally
    job_stop(lspserver.job)
  endtry
enddef

# Test that CTRL-C while waiting for the reply to a synchronous request
# cancels the request and still interrupts the command.
def g:Test_Rpc_CancelsInterruptedRequest()
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  # The channel callback is invoked for the notification while the reply is
  # waited for, and interrupt() acts like typing CTRL-C.
  lspserver.job = StartStubServerJob(
    [{jsonrpc: '2.0', method: 'test/notification', params: {}}],
    {out_cb: (_, _) => {
      interrupt()
    }})
  try
    var id = lspserver.nextSyncRpcId

    var interrupted = false
    try
      lspserver.rpc('test/noReply', {}, {timeout: 5000})
    catch /^Vim:Interrupt$/
      interrupted = true
    endtry
    assert_true(interrupted)
    assert_equal([{method: '$/cancelRequest', params: {id: id}}], notifications)
    assert_equal({}, lspserver.syncRpcReplies)
  finally
    job_stop(lspserver.job)
  endtry
enddef

# Test that a reply saying that the request was cancelled, by the client or by
# the server, or that the content it was about was modified, is not reported
# as an error, and that the callback of an asynchronous request then gets no
# result.
def g:Test_Rpc_StaleRequestReplyIsNotAnError()
  # Send the asynchronous requests asynchronously, as outside the tests.
  g:LSPTest = false
  try
    for code in [-32800, -32801, -32802]
      var notifications: list<dict<any>> = []
      var lspserver = MakeTestLspServer(notifications)
      var syncId = lspserver.nextSyncRpcId
      var stale = {code: code, message: 'stale'}
      # Vim numbers the asynchronous requests on a new channel from 1.
      lspserver.job = StartStubServerJob([
	{jsonrpc: '2.0', id: 1, error: stale},
	{jsonrpc: '2.0', id: syncId, error: stale}
      ])
      var beforeMessages = execute('messages')

      var replies: list<list<any>> = []
      assert_equal(1, lspserver.rpc_a('test/stale', {},
	(_, reply, error) => {
	  replies->add([reply, error])
	}))
      assert_equal({}, lspserver.rpc('test/stale', {}))
      g:WaitForAssert(() => assert_equal([[v:null, {}]], replies))
      job_stop(lspserver.job)

      assert_equal(beforeMessages, execute('messages'))
      assert_equal([], notifications)
    endfor
  finally
    g:LSPTest = true
  endtry
enddef

# Test that the maps and lists in the server dict that grow with the number of
# open documents, pending requests and messages keep their type when they are
# emptied.  Before patch 9.2.1144, Vim goes through all the values of one that
# has no type on every server method call.
def g:Test_ServerState_StaysTyped()
  var types = {
    messages: 'list<string>',
    syncRpcReplies: 'dict<dict<any>>',
    supersedableRequests: 'dict<dict<number>>',
    diagnosticResultIds: 'dict<string>',
    pendingPullBufnrs: 'dict<bool>',
    workDoneProgressTokens: 'dict<bool>',
    cachedBufferContent: 'dict<list<string>>',
    cachedBufferEol: 'dict<bool>',
    docVersions: 'dict<number>',
    docBufnrs: 'dict<number>'
  }
  # typename() gives the type of an empty dict or list only when it has one.
  var AssertTyped = (lspserver: dict<any>, when: string) => {
    for [key, type] in types->items()
      assert_equal(type, typename(lspserver[key]), $'{key} {when}')
    endfor
  }

  var lspserver = MakeTestLspServer([])
  AssertTyped(lspserver, 'when created')

  silent! edit XServerStateTyped.txt
  setline(1, ['text'])
  var bnr = bufnr()
  lspserver.textdocDidOpen(bnr, 'text')
  lspserver.textdocDidClose(bnr)

  for i in range(700)
    lspserver.addMessage('Log', $'message {i}')
  endfor
  assert_equal(500, lspserver.messages->len())
  assert_match('message 699$', lspserver.messages[-1])
  lspserver.messages->remove(0, -1)

  lspserver.running = true
  lspserver.ready = true
  lspserver.isDiagnosticsProvider = true
  var pulled: list<number> = []
  lspserver.pullDiagnostics = (pullBnr: number) => {
    pulled->add(pullBnr)
  }
  buf.BufLspServerSet(bnr, lspserver)
  try
    lspserver.queuePullDiagnostics(bnr)
    g:WaitForAssert(() => assert_equal([bnr], pulled))
  finally
    buf.BufLspServerRemove(bnr, lspserver)
  endtry
  AssertTyped(lspserver, 'after a document was closed and the queued pulls were sent')

  # Start the server asynchronously, as outside the tests, and let it exit.
  lspserver.running = false
  lspserver.path = 'sh'
  lspserver.args = ['-c', 'exec cat >/dev/null']
  g:LSPTest = false
  try
    lspserver.startServer(bnr)
    job_stop(lspserver.job)
    g:WaitForAssert(() => assert_false(lspserver.running))
  finally
    g:LSPTest = true
  endtry
  AssertTyped(lspserver, 'after the server was started and exited')
  :%bw!
enddef

# Test that a message from the server isn't kept in the server dict once it is
# processed, as Vim may go through all of it on every server method call.
def g:Test_ProcessMessage_DoesNotKeepMessage()
  var lspserver = MakeTestLspServer([])
  var notifs: list<dict<any>> = []
  lspserver.processNotif = (msg: dict<any>) => {
    notifs->add(msg)
  }
  var notif = {jsonrpc: '2.0', method: 'test/notification', params: {}}
  lspserver.data = notif
  lspserver.processMessage()
  assert_equal([notif], notifs)
  assert_equal('', lspserver.data)
enddef

# Returns a running test language server that records the notifications and
# the requests it is sent in "messages", in the order they are sent.
def MakeRecordingLspServer(messages: list<dict<any>>): dict<any>
  var lspserver = MakeTestLspServer(messages)
  lspserver.running = true
  lspserver.ready = true
  lspserver.debug = true
  lspserver.traceLog = (msg: string) => {
    var request = msg->matchstr('^Sent request \zs.*')
    if !request->empty()
      messages->add(request->json_decode())
    endif
  }
  return lspserver
enddef

# Edit two buffers in split windows and open their documents on a recording
# test language server, with a listener sending the changes of each, as
# attaching a buffer does.  The server replies to the first synchronous
# requests with "results".  Returns [lspserver, bufnrs, listenerIds].
def OpenTwoTestDocuments(messages: list<dict<any>>,
			 results: list<any>): list<any>
  silent! edit XPendingChanges1.txt
  setline(1, ['one'])
  silent! new XPendingChanges2.txt
  setline(1, ['two'])
  var bufnrs = [bufnr('XPendingChanges1.txt'), bufnr('XPendingChanges2.txt')]
  var lspserver = MakeRecordingLspServer(messages)
  lspserver.isDocumentFormattingProvider = true
  lspserver.job = StartStubServerJob(results->mapnew((i, result) => ({
    jsonrpc: '2.0', id: lspserver.nextSyncRpcId + i, result: result})))
  var listenerIds: list<number> = []
  for bnr in bufnrs
    buf.BufLspServerSet(bnr, lspserver)
    lspserver.textdocDidOpen(bnr, 'text')
    listenerIds->add(listener_add((changedBnr, _, _, _, _) => {
      lspserver.textdocDidChange(changedBnr)
    }, bnr))
  endfor
  return [lspserver, bufnrs, listenerIds]
enddef

# Undo OpenTwoTestDocuments().
def CloseTwoTestDocuments(lspserver: dict<any>, bufnrs: list<number>,
			  listenerIds: list<number>)
  for id in listenerIds
    listener_remove(id)
  endfor
  job_stop(lspserver.job)
  for bnr in bufnrs
    buf.BufLspServerRemove(bnr, lspserver)
  endfor
  :%bw!
enddef

# Test that a request made right after a change, before Vim passes the change
# to the listeners (e.g. in a mapping or an autocmd), is sent after the
# change, so that the formatting is for the new text.  Only the change to the
# document that the request is about is sent first.
def g:Test_Rpc_SendsPendingChangesOfItsDocumentFirst()
  var messages: list<dict<any>> = []
  var [lspserver, bufnrs, listenerIds] = OpenTwoTestDocuments(messages, [[]])
  try
    setbufline(bufnrs[0], 1, 'ONE')
    setbufline(bufnrs[1], 1, 'TWO')
    lspserver.textDocFormat(bufnrs[0]->bufname(), false, 0, 0)

    assert_equal(['textDocument/didChange', 'textDocument/formatting'],
		 messages->mapnew((_, msg) => msg.method))
    assert_equal(util.LspBufnrToUri(bufnrs[0]),
		 messages[0].params.textDocument.uri)
    assert_equal([{text: "ONE\n"}], messages[0].params.contentChanges)
  finally
    CloseTwoTestDocuments(lspserver, bufnrs, listenerIds)
  endtry
enddef

# Test that a request whose reply can refer to other documents, like the
# references, is sent after the pending changes of all the open documents.
def g:Test_Rpc_SendsPendingChangesOfAllDocumentsForReferences()
  var messages: list<dict<any>> = []
  var [lspserver, bufnrs, listenerIds] = OpenTwoTestDocuments(messages, [[]])
  try
    setbufline(bufnrs[1], 1, 'TWO')
    lspserver.rpc('textDocument/references', {
      textDocument: {uri: util.LspBufnrToUri(bufnrs[0])},
      position: {line: 0, character: 0},
      context: {includeDeclaration: true}
    })

    assert_equal(['textDocument/didChange', 'textDocument/references'],
		 messages->mapnew((_, msg) => msg.method))
    assert_equal(util.LspBufnrToUri(bufnrs[1]),
		 messages[0].params.textDocument.uri)
    assert_equal([{text: "TWO\n"}], messages[0].params.contentChanges)
  finally
    CloseTwoTestDocuments(lspserver, bufnrs, listenerIds)
  endtry
enddef

# Test that an asynchronous request that doesn't name a document is sent
# after the pending changes of all the open documents.
def g:Test_AsyncRpc_SendsPendingChangesOfAllDocumentsForWorkspaceRequest()
  var messages: list<dict<any>> = []
  var [lspserver, bufnrs, listenerIds] = OpenTwoTestDocuments(messages, [])
  # Send the request asynchronously, as outside the tests
  g:LSPTest = false
  try
    setbufline(bufnrs[0], 1, 'ONE')
    lspserver.rpc_a('workspace/symbol', {query: ''}, (_, _, _) => {
    })

    assert_equal(['textDocument/didChange', 'workspace/symbol'],
		 messages->mapnew((_, msg) => msg.method))
    assert_equal(util.LspBufnrToUri(bufnrs[0]),
		 messages[0].params.textDocument.uri)
    assert_equal([{text: "ONE\n"}], messages[0].params.contentChanges)
  finally
    g:LSPTest = true
    CloseTwoTestDocuments(lspserver, bufnrs, listenerIds)
  endtry
enddef

# Test that the reply to a semantic tokens request saying that the content was
# modified leaves the semantic highlighting as it is, without an error.
def g:Test_SemanticHighlightUpdate_ContentModifiedIsNotAnError()
  silent! edit XSemanticTokensContentModified.txt
  setbufvar(bufnr(), 'LspSemanticResultId', 'previous')
  var lspserver = MakeTestLspServer([])
  lspserver.isSemanticTokensProvider = true
  lspserver.semanticTokensDelta = false
  var errors: list<string> = []
  lspserver.errorLog = (msg: string) => {
    errors->add(msg)
  }
  # Send the request asynchronously, as outside the tests.
  g:LSPTest = false
  # Vim numbers the asynchronous requests on a new channel from 1.
  lspserver.job = StartStubServerJob([{jsonrpc: '2.0', id: 1,
    error: {code: -32801, message: 'content modified'}}])
  try
    var beforeMessages = execute('messages')
    lspserver.semanticHighlightUpdate(bufnr())
    g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
    assert_equal(beforeMessages, execute('messages'))
    assert_equal([], errors)
    assert_equal('previous', getbufvar(bufnr(), 'LspSemanticResultId'))
  finally
    g:LSPTest = true
    job_stop(lspserver.job)
  endtry
  :%bw!
enddef

# Test that the reply to a hover request saying that the content was modified
# is not cached, so that hovering again at the same position asks the server
# again, while an empty hover result is still cached.
def g:Test_ShowHoverInfo_ContentModifiedIsNotCached()
  silent! edit XHoverContentModified.txt
  var lspserver = MakeTestLspServer([])
  lspserver.isHoverProvider = true
  # Send the request asynchronously, as outside the tests.
  g:LSPTest = false
  # Vim numbers the asynchronous requests on a new channel from 1.
  lspserver.job = StartStubServerJob([{jsonrpc: '2.0', id: 1,
    error: {code: -32801, message: 'content modified'}}])
  try
    var beforeMessages = execute('messages')
    lspserver.hover('silent')
    g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
    assert_equal(beforeMessages, execute('messages'))
    var reqctx = hover.HoverRequestContextGet(lspserver)
    assert_false(hover.HoverShowCached(reqctx, lspserver, 'silent'))

    hover.HoverReply(lspserver, {contents: ''}, {}, 'silent', reqctx)
    assert_true(hover.HoverShowCached(reqctx, lspserver, 'silent'))
  finally
    g:LSPTest = true
    job_stop(lspserver.job)
  endtry
  :%bw!
enddef

# Returns the last message in the message history.
def LastMessage(): string
  return execute('messages')->split("\n")[-1]
enddef

# Test that a synchronous request whose caller handles the errors returns the
# reply with the error, which is not reported, while for the other callers the
# error is reported and an empty Dict is returned.
def g:Test_Rpc_ReturnsErrorToCallerHandlingIt()
  var lspserver = MakeTestLspServer([])
  for code in [-32603, -32801]
    var syncId = lspserver.nextSyncRpcId
    var failed = {code: code, message: 'failed'}
    lspserver.job = StartStubServerJob(
      [{jsonrpc: '2.0', id: syncId, error: failed}])
    try
      var beforeMessages = execute('messages')
      assert_equal({jsonrpc: '2.0', id: syncId, error: failed},
		   lspserver.rpc('test/fails', {}, {handleError: false}))
      assert_equal(beforeMessages, execute('messages'))
    finally
      job_stop(lspserver.job)
    endtry
  endfor

  lspserver.job = StartStubServerJob([{jsonrpc: '2.0',
    id: lspserver.nextSyncRpcId, error: {code: -32603, message: 'failed'}}])
  try
    assert_equal({}, lspserver.rpc('test/fails', {}))
    assert_equal('Error: request test/fails failed (failed, error = InternalError)',
		 LastMessage())
  finally
    job_stop(lspserver.job)
  endtry
enddef

# Test that jumping to a definition and looking up a tag treat an error reply
# like a reply without a location.
def g:Test_GotoDefinitionAndTagFunc_ErrorReplyFindsNothing()
  silent! edit XGotoDefinitionError.txt
  var lspserver = MakeTestLspServer([])
  lspserver.isDefinitionProvider = true
  lspserver.isWorkspaceSymbolProvider = true
  var lookups: list<func> = [
    () => {
      lspserver.gotoDefinition(false, '', 0)
    },
    () => {
      assert_equal(null, lspserver.tagFunc('XNoSuchTag', '', {}))
    }
  ]
  for Lookup in lookups
    lspserver.job = StartStubServerJob([{jsonrpc: '2.0',
      id: lspserver.nextSyncRpcId, error: {code: -32603, message: 'failed'}}])
    try
      Lookup()
    finally
      job_stop(lspserver.job)
    endtry
  endfor
  assert_equal('Warn: symbol definition is not found', LastMessage())
  :%bw!
enddef

# Test that a "$/cancelRequest" notification from the server is accepted
# quietly.
def g:Test_ProcessNotif_CancelRequestIsIgnored()
  var lspserver = MakeTestLspServer([])
  var traceMsgs: list<string> = []
  lspserver.traceLog = (msg) => traceMsgs->add(msg)

  handlers.ProcessNotif(lspserver,
    {jsonrpc: '2.0', method: '$/cancelRequest', params: {id: 3}})

  assert_equal([], traceMsgs)
enddef

# Test that a document highlight request supersedes only the pending request
# for the same buffer.
def g:Test_DocHighlight_CancelsSupersededRequestForSameBuffer()
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.isDocumentHighlightProvider = true
  var lastId = 0
  lspserver.rpc_a = (_, _, _) => {
    lastId += 1
    return lastId
  }

  silent! edit XDocHighlightSuperseded1.txt
  lspserver.docHighlight(bufnr(), 'silent')
  silent! edit XDocHighlightSuperseded2.txt
  lspserver.docHighlight(bufnr(), 'silent')
  assert_equal([], notifications)

  lspserver.docHighlight(bufnr(), 'silent')
  assert_equal([{method: '$/cancelRequest', params: {id: 2}}], notifications)
  :%bw!
enddef

# Test that a request whose reply was processed before rpc_a() returned, as in
# tests, is not cancelled by the next request.
def g:Test_GetCompletion_DoesNotCancelAnsweredRequest()
  silent! edit XGetCompletionAnswered.txt
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.isCompletionProvider = true
  lspserver.completionLazyDoc = false
  var lastId = 0
  lspserver.rpc_a = (_, _, Cb) => {
    lastId += 1
    Cb(lspserver, [], {})
    return lastId
  }

  lspserver.getCompletion(1, '')
  lspserver.getCompletion(1, '')

  assert_equal(2, lastId)
  assert_equal([], notifications)
  assert_equal({}, lspserver.supersedableRequests)
  :%bw!
enddef

# Test that the inlay hints request covers the whole buffer: its range ends at
# the end of the last line, in the negotiated position encoding, when the last
# line has composing characters and ends in a character outside the BMP.
def g:Test_InlayHintsShow_RangeEndsAtEndOfBuffer()
  silent! edit XInlayHintsRange.txt
  setline(1, ['int x;', "á 😊"])
  var lspserver = MakeTestLspServer([])
  lspserver.isInlayHintProvider = true
  lspserver.isClangdInlayHintsProvider = false
  var ranges: list<dict<any>> = []
  lspserver.rpc_a = (_, params, _) => {
    ranges->add(params.range->deepcopy())
    return 0
  }

  for posEncoding in [8, 16, 32]
    lspserver.posEncoding = posEncoding
    lspserver.inlayHintsShow(bufnr())
  endfor
  append('$', '')
  lspserver.inlayHintsShow(bufnr())

  # The second line is 8 bytes, 5 UTF-16 code units and 4 characters long
  var start: dict<number> = {line: 0, character: 0}
  var expected: list<dict<any>> = [
    {start: start, end: {line: 1, character: 8}},
    {start: start, end: {line: 1, character: 5}},
    {start: start, end: {line: 1, character: 4}},
    {start: start, end: {line: 2, character: 0}}
  ]
  assert_equal(expected, ranges)
  :%bw!
enddef

def g:Test_ProcessMessages_IgnoreUnknownResponseId_Error()
  var lspserver = MakeTestLspServer([])
  var unknownId = 'X-unknown-response-id-error'
  AssertIgnoredUnknownResponse(lspserver,
    {
      jsonrpc: '2.0',
      id: unknownId,
      error: {
        code: -32601,
        message: 'Method not found'
      }
    }, unknownId)
enddef

def g:Test_ProcessMessages_RejectsMessageMissingJsonRpc()
  var lspserver = MakeTestLspServer([])
  var traceMsgs: list<string> = []
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.processRequest = (_, _) => assert_report('unexpected request dispatch')
  lspserver.processNotif = (_, _) => assert_report('unexpected notification dispatch')

  # Message without jsonrpc field should be dropped
  lspserver.data = {
    id: 1,
    method: 'test/method'
  }
  lspserver.processMessage()

  assert_equal(1, traceMsgs->len())
  assert_match('Dropping message missing jsonrpc field:', traceMsgs[0])
enddef

def g:Test_ProcessMessages_RejectsMessageWithInvalidJsonRpcVersion()
  var lspserver = MakeTestLspServer([])
  var traceMsgs: list<string> = []
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.processRequest = (_, _) => assert_report('unexpected request dispatch')
  lspserver.processNotif = (_, _) => assert_report('unexpected notification dispatch')

  # Message with wrong jsonrpc version should be dropped
  lspserver.data = {
    jsonrpc: '1.0',
    id: 1,
    method: 'test/method'
  }
  lspserver.processMessage()

  assert_equal(1, traceMsgs->len())
  assert_match('Dropping message with invalid jsonrpc version: 1.0', traceMsgs[0])
enddef

def g:Test_ProcessMessages_AcceptsValidJsonRpcVersion()
  var lspserver = MakeTestLspServer([])
  var traceMsgs: list<string> = []
  var requestsProcessed: number = 0
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.processRequest = (_) => {
    requestsProcessed += 1
  }
  lspserver.processNotif = (_, _) => assert_report('unexpected notification dispatch')

  # Message with correct jsonrpc version should be processed
  lspserver.data = {
    jsonrpc: '2.0',
    id: 1,
    method: 'test/method'
  }
  lspserver.processMessage()

  assert_equal(1, requestsProcessed)
  assert_equal(0, traceMsgs->len())
enddef

# Pull the diagnostics for the current buffer from a stand-in for a language
# server that replies with "error".  Returns the buffers for which another
# pull was queued.
def PullDiagnosticsWithError(error: dict<any>): list<number>
  var lspserver = MakeTestLspServer([])
  lspserver.isDiagnosticsProvider = true
  var queued: list<number> = []
  lspserver.queuePullDiagnostics = (bnr: number) => {
    queued->add(bnr)
  }
  lspserver.job = StartStubServerJob(
    [{jsonrpc: '2.0', id: lspserver.nextSyncRpcId, error: error}])
  try
    lspserver.pullDiagnostics(bufnr())
  finally
    job_stop(lspserver.job)
  endtry
  return queued
enddef

# Test that the pull diagnostics request is sent again, without reporting an
# error, when the server cancels it and asks for it to be retriggered, or when
# the content was modified.
def g:Test_PullDiagnostics_RetriesStaleRequest()
  silent! edit XPullDiagnosticsRetry.rs
  var beforeMessages = execute('messages')

  assert_equal([bufnr()], PullDiagnosticsWithError({code: -32802,
    message: 'server cancelled', data: {retriggerRequest: true}}))
  assert_equal([bufnr()], PullDiagnosticsWithError({code: -32801,
    message: 'content modified'}))
  assert_equal([], PullDiagnosticsWithError({code: -32802,
    message: 'server cancelled', data: {retriggerRequest: false}}))
  assert_equal(beforeMessages, execute('messages'))

  assert_equal([], PullDiagnosticsWithError({code: -32603,
    message: 'failed'}))
  assert_equal(
    'Error: request textDocument/diagnostic failed (failed, error = InternalError)',
    LastMessage())
  :%bw!
enddef

# Returns a running test language server providing pull diagnostics, which
# adds the buffer number of each document it pulls the diagnostics of to
# "pulled".
def MakePullDiagnosticsTestLspServer(pulled: list<number>): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isDiagnosticsProvider = true
  lspserver.sendResponse = (_, _, _) => {
  }
  lspserver.pullDiagnostics = (bnr: number) => {
    pulled->add(bnr)
  }
  return lspserver
enddef

# Test that a "workspace/diagnostic/refresh" request, and the end of the work
# of the server, pull the diagnostics of every document open on that server.
# Not of a buffer attached to it whose document isn't open yet, and not of a
# document open on another server only.
def g:Test_DiagnosticRefresh_PullsDocumentsOpenOnTheServer()
  var bufnrs: list<number> = []
  for i in range(4)
    exe $'silent! new XDiagRefresh{i}.txt'
    bufnrs->add(bufnr())
  endfor
  var pulled: list<number> = []
  var otherPulled: list<number> = []
  var lspserver = MakePullDiagnosticsTestLspServer(pulled)
  var otherServer = MakePullDiagnosticsTestLspServer(otherPulled)
  for bnr in bufnrs[0 : 2]
    buf.BufLspServerSet(bnr, lspserver)
  endfor
  lspserver.textdocDidOpen(bufnrs[0], 'text')
  lspserver.textdocDidOpen(bufnrs[1], 'text')
  for bnr in [bufnrs[0], bufnrs[3]]
    buf.BufLspServerSet(bnr, otherServer)
    otherServer.textdocDidOpen(bnr, 'text')
  endfor
  try
    lspserver.processRequest({jsonrpc: '2.0', id: 1,
			      method: 'workspace/diagnostic/refresh'})
    assert_equal(bufnrs[0 : 1], pulled->sort('n'))
    assert_equal([], otherPulled)

    lspserver.queuePullDiagnosticsAllBuffers()
    assert_equal(bufnrs[0 : 1],
		 lspserver.pendingPullBufnrs->keys()->map((_, k) => str2nr(k))
		 ->sort('n'))
  finally
    if lspserver.diagnosticPullTimer != -1
      timer_stop(lspserver.diagnosticPullTimer)
    endif
    for bnr in bufnrs
      buf.BufLspServerRemove(bnr, lspserver)
      buf.BufLspServerRemove(bnr, otherServer)
    endfor
    :%bw!
  endtry
enddef

def g:Test_DiagNotification_PushAndPull_AreBothRetained()
  g:LspOptionsSet({autoHighlightDiags: false})
  silent! edit XPushPullDiagnosticsRetained.rs
  setline(1, ['fn main() {}'])

  var lspserver = MakeTestLspServer([])
  lspserver.features = {diagnostics: true}
  lspserver.featureEnabled = (_) => true

  var uri = util.LspBufnrToUri(bufnr())
  var pullDiag = {
    range: {
      start: {line: 0, character: 0},
      end: {line: 0, character: 2}
    },
    code: 'E001',
    message: 'pull diagnostic'
  }
  var pushDiag = {
    range: {
      start: {line: 0, character: 5},
      end: {line: 0, character: 7}
    },
    code: 'W001',
    message: 'push diagnostic'
  }

  diag.DiagNotification(lspserver, uri, [pullDiag], 'pull')
  diag.DiagNotification(lspserver, uri, [pushDiag], 'push')

  var allDiags = diag.GetDiagsForBuf(bufnr())
  assert_equal(2, allDiags->len())
  assert_equal('pull diagnostic', allDiags[0].message)
  assert_equal('push diagnostic', allDiags[1].message)

  # Clearing push diagnostics must not clear previously pulled diagnostics.
  diag.DiagNotification(lspserver, uri, [], 'push')
  allDiags = diag.GetDiagsForBuf(bufnr())
  assert_equal(1, allDiags->len())
  assert_equal('pull diagnostic', allDiags[0].message)

  diag.DiagRemoveFile(bufnr())
  g:LspOptionsSet({autoHighlightDiags: true})
  :%bw!
enddef

def g:Test_DiagNotification_DeduplicatesAcrossPushAndPull()
  g:LspOptionsSet({autoHighlightDiags: false})
  silent! edit XPushPullDiagnosticsDedup.rs
  setline(1, ['fn main() {}'])

  var lspserver = MakeTestLspServer([])
  lspserver.features = {diagnostics: true}
  lspserver.featureEnabled = (_) => true

  var uri = util.LspBufnrToUri(bufnr())
  var sharedDiag = {
    range: {
      start: {line: 0, character: 1},
      end: {line: 0, character: 3}
    },
    code: 'DUP',
    message: 'duplicate across channels'
  }
  var pushOnlyDiag = {
    range: {
      start: {line: 0, character: 8},
      end: {line: 0, character: 10}
    },
    code: 'PUSH',
    message: 'push only'
  }

  diag.DiagNotification(lspserver, uri, [sharedDiag], 'pull')
  diag.DiagNotification(lspserver, uri, [sharedDiag, pushOnlyDiag], 'push')

  var allDiags = diag.GetDiagsForBuf(bufnr())
  assert_equal(2, allDiags->len())
  assert_equal('duplicate across channels', allDiags[0].message)
  assert_equal('push only', allDiags[1].message)

  diag.DiagRemoveFile(bufnr())
  g:LspOptionsSet({autoHighlightDiags: true})
  :%bw!
enddef

def g:Test_ProcessNotif_PublishDiagnostics_NotIgnoredForPullCapableServer()
  g:LspOptionsSet({autoHighlightDiags: false})
  silent! edit XPushDiagnosticsForPullServer.rs
  setline(1, ['fn main() {}'])

  var lspserver = MakeTestLspServer([])
  lspserver.isDiagnosticsProvider = true
  lspserver.features = {diagnostics: true}
  lspserver.featureEnabled = (_) => true

  var uri = util.LspBufnrToUri(bufnr())
  var reply = {
    method: 'textDocument/publishDiagnostics',
    params: {
      uri: uri,
      diagnostics: [{
        range: {
          start: {line: 0, character: 0},
          end: {line: 0, character: 2}
        },
        code: 'PUSH',
        message: 'publish diagnostics processed'
      }]
    }
  }

  handlers.ProcessNotif(lspserver, reply)

  var allDiags = diag.GetDiagsForBuf(bufnr())
  assert_equal(1, allDiags->len())
  assert_equal('publish diagnostics processed', allDiags[0].message)

  diag.DiagRemoveFile(bufnr())
  g:LspOptionsSet({autoHighlightDiags: true})
  :%bw!
enddef

# Return a textDocument/publishDiagnostics notification for "uri" with a
# diagnostic on the first line for each of "messages".
def PublishDiagsNotif(uri: string, messages: list<string>): dict<any>
  return {
    jsonrpc: '2.0',
    method: 'textDocument/publishDiagnostics',
    params: {
      uri: uri,
      diagnostics: messages->mapnew((_, msg) => MakeLineDiag(0, msg))
    }
  }
enddef

# Test that the diagnostics published for a document open on the language
# server reach its buffer through the URI it was opened with, also when the
# server escapes that URI differently, without looking up a buffer by its
# file name.  The URIs name a file without a buffer, so that only the
# documents open on the server lead to the buffer.
def g:Test_PublishDiagnostics_FoundByOpenDocumentUri()
  g:LspOptionsSet({autoHighlightDiags: false})
  silent! edit XDiagOpenDocument.c
  var bnr = bufnr()
  var lspserver = MakeDiagServer('srv')
  var fname = '/XDiagNoSuchDir/a+b[1] c.c'
  var uri = util.LspFileToUri(fname)
  lspserver.docBufnrs[uri] = bnr

  for publishedUri in [uri, 'file:///XDiagNoSuchDir/a+b%5b1%5d%20c.c']
    handlers.ProcessNotif(lspserver,
      PublishDiagsNotif(publishedUri, [publishedUri]))
    assert_equal([publishedUri], DiagMsgs(diag.GetDiagsForBuf(bnr)))
  endfor
  assert_false(fname->bufexists())

  diag.DiagRemoveFile(bnr)
  g:LspOptionsSet({autoHighlightDiags: true})
  :%bw!
enddef

# Test that the diagnostics published for a document that isn't open on the
# language server reach the buffer with its file name: a document never
# opened, a closed document (a server clears the diagnostics of a document
# when it is closed) and one whose buffer in the open documents is gone.  The
# diagnostics for a file without a buffer are dropped, without adding one.
def g:Test_PublishDiagnostics_UnopenedDocumentFoundByFileName()
  g:LspOptionsSet({autoHighlightDiags: false})
  var lspserver = MakeDiagServer('srv')

  silent! edit XDiagNotOpened.c
  var notOpened = bufnr()
  var notOpenedUri = util.LspBufnrToUri(notOpened)
  handlers.ProcessNotif(lspserver,
    PublishDiagsNotif(notOpenedUri, ['not opened']))
  assert_equal(['not opened'], DiagMsgs(diag.GetDiagsForBuf(notOpened)))

  silent! edit XDiagClosed.c
  var closed = bufnr()
  var closedUri = util.LspBufnrToUri(closed)
  lspserver.textdocDidOpen(closed, 'c')
  handlers.ProcessNotif(lspserver, PublishDiagsNotif(closedUri, ['open']))
  assert_equal(['open'], DiagMsgs(diag.GetDiagsForBuf(closed)))
  lspserver.textdocDidClose(closed)
  assert_false(lspserver.docBufnrs->has_key(closedUri))
  handlers.ProcessNotif(lspserver, PublishDiagsNotif(closedUri, []))
  assert_equal([], diag.GetDiagsForBuf(closed))

  silent! edit XDiagWipedOut.c
  var wipedOut = bufnr()
  :bwipeout!
  lspserver.docBufnrs[notOpenedUri] = wipedOut
  handlers.ProcessNotif(lspserver,
    PublishDiagsNotif(notOpenedUri, ['stale open document']))
  assert_equal(['stale open document'],
    DiagMsgs(diag.GetDiagsForBuf(notOpened)))

  var noBuffer = 'XDiagNoBuffer.c'->fnamemodify(':p')
  handlers.ProcessNotif(lspserver,
    PublishDiagsNotif(util.LspFileToUri(noBuffer), ['no buffer']))
  assert_false(noBuffer->bufexists())

  diag.DiagRemoveFile(notOpened)
  diag.DiagRemoveFile(closed)
  g:LspOptionsSet({autoHighlightDiags: true})
  :%bw!
enddef

# Publish the diagnostics with "messages" for buffer "bnr" from "lspserver".
def PublishBufDiags(lspserver: dict<any>, bnr: number, messages: list<string>)
  handlers.ProcessNotif(lspserver,
    PublishDiagsNotif(util.LspBufnrToUri(bnr), messages))
enddef

# Returns the texts of the items of each diagnostics location list in the
# location list stack of window "winid".
def DiagLocListTexts(winid: number): list<list<string>>
  return range(1, getloclist(winid, {nr: '$'}).nr)
    ->mapnew((_, nr) => getloclist(winid, {nr: nr, title: 0, items: 0}))
    ->filter((_, qfl) => qfl.title == 'Language Server Diagnostics')
    ->mapnew((_, qfl) => qfl.items->mapnew((_, item) => item.text))
enddef

# Returns the number of the current location list of window "winid" and all
# the properties of every location list in its stack, to check that the
# location lists of the window are left untouched.
def LocListStack(winid: number): list<any>
  return [getloclist(winid, {nr: 0}).nr,
	  range(1, getloclist(winid, {nr: '$'}).nr)
	    ->mapnew((_, nr) => getloclist(winid, {nr: nr, all: 0}))]
enddef

# Remove the diagnostics of the buffers in "bufnrs", free the location lists
# of all the windows, restore the diagnostics options changed by a location
# list test and close its windows and tab pages.  An Ex command run while an
# exception is pending aborts the function, so it comes last.
def DiagLocListTestCleanup(bufnrs: list<number>)
  for bnr in bufnrs
    diag.DiagRemoveFile(bnr)
  endfor
  for wininfo in getwininfo()
    if !wininfo.quickfix
      setloclist(wininfo.winid, [], 'f')
    endif
  endfor
  g:LspOptionsSet({autoHighlightDiags: true, autoPopulateDiags: false})
  :%bw!
enddef

# Test that the diagnostics published for a buffer displayed in a window that
# isn't the current one update the location list of that window, not the one
# of the current window.
def g:Test_DiagLocList_NonCurrentWindow()
  g:LspOptionsSet({autoHighlightDiags: false, autoPopulateDiags: true})
  var lspserver = MakeDiagServer('srv')
  silent! edit XDiagLocListA.c
  var aBnr = bufnr()
  var aWin = win_getid()
  :new XDiagLocListB.c
  var bBnr = bufnr()
  var bWin = win_getid()
  try
    var bStack = LocListStack(bWin)
    PublishBufDiags(lspserver, aBnr, ['a1', 'a2'])
    assert_equal([['a1', 'a2']], DiagLocListTexts(aWin))
    assert_equal([aBnr, aBnr], getloclist(aWin)->mapnew((_, v) => v.bufnr))
    assert_equal(bStack, LocListStack(bWin))

    PublishBufDiags(lspserver, bBnr, ['b1'])
    assert_equal([['b1']], DiagLocListTexts(bWin))
    assert_equal([['a1', 'a2']], DiagLocListTexts(aWin))

    bStack = LocListStack(bWin)
    PublishBufDiags(lspserver, aBnr, [])
    assert_equal([[]], DiagLocListTexts(aWin))
    assert_equal(bStack, LocListStack(bWin))
    assert_equal(bWin, win_getid())
  finally
    DiagLocListTestCleanup([aBnr, bBnr])
  endtry
enddef

# Test that the diagnostics published for a buffer update the location list
# of every window displaying it, also in another tab page and in a window
# split after the list was created, and no other window.
def g:Test_DiagLocList_AllWindowsOfBuffer()
  g:LspOptionsSet({autoHighlightDiags: false, autoPopulateDiags: true})
  var lspserver = MakeDiagServer('srv')
  silent! edit XDiagLocListShared.c
  var bnr = bufnr()
  var win1 = win_getid()
  :split
  var win2 = win_getid()
  :tab split
  var win3 = win_getid()
  :new XDiagLocListOther.c
  var otherBnr = bufnr()
  var otherWin = win_getid()
  try
    var otherStack = LocListStack(otherWin)
    PublishBufDiags(lspserver, bnr, ['s1'])
    for winid in [win1, win2, win3]
      assert_equal([['s1']], DiagLocListTexts(winid))
    endfor
    assert_equal(otherStack, LocListStack(otherWin))

    # Splitting a window copies its location lists with new IDs
    win_gotoid(win1)
    :split
    var win4 = win_getid()
    win_gotoid(otherWin)
    PublishBufDiags(lspserver, bnr, ['s2', 's3'])
    for winid in [win1, win2, win3, win4]
      assert_equal([['s2', 's3']], DiagLocListTexts(winid))
      assert_equal(1, getloclist(winid, {nr: '$'}).nr)
    endfor
    assert_equal(otherStack, LocListStack(otherWin))
  finally
    DiagLocListTestCleanup([bnr, otherBnr])
  endtry
enddef

# Test that the location lists of a window that aren't the diagnostics list
# are kept: the diagnostics list is added after them, and is then updated in
# place without becoming the current list again.  The location lists of a
# window displaying another buffer are left untouched.
def g:Test_DiagLocList_KeepsUserLocList()
  g:LspOptionsSet({autoHighlightDiags: false})
  var lspserver = MakeDiagServer('srv')
  silent! edit XDiagLocListUserA.c
  var aBnr = bufnr()
  var aWin = win_getid()
  setloclist(aWin, [], ' ', {title: 'user A',
    items: [{bufnr: aBnr, lnum: 1, text: 'user A'}]})
  :new XDiagLocListUserC.c
  var cBnr = bufnr()
  var cWin = win_getid()
  setloclist(cWin, [], ' ', {title: 'user C',
    items: [{bufnr: cBnr, lnum: 1, text: 'user C'}]})
  try
    var aStack = LocListStack(aWin)
    var cStack = LocListStack(cWin)
    var userList: dict<any> = getloclist(aWin, {nr: 1, all: 0})
    PublishBufDiags(lspserver, aBnr, ['a1'])
    assert_equal(aStack, LocListStack(aWin))
    assert_equal(cStack, LocListStack(cWin))

    g:LspOptionsSet({autoPopulateDiags: true})
    PublishBufDiags(lspserver, aBnr, ['a2'])
    assert_equal(2, getloclist(aWin, {nr: '$'}).nr)
    assert_equal(2, getloclist(aWin, {nr: 0}).nr)
    assert_equal(userList, getloclist(aWin, {nr: 1, all: 0}))
    assert_equal([['a2']], DiagLocListTexts(aWin))
    assert_equal(cStack, LocListStack(cWin))

    win_execute(aWin, 'lolder')
    PublishBufDiags(lspserver, aBnr, ['a3'])
    assert_equal(1, getloclist(aWin, {nr: 0}).nr)
    assert_equal(userList, getloclist(aWin, {nr: 1, all: 0}))
    assert_equal([['a3']], DiagLocListTexts(aWin))
    assert_equal(cStack, LocListStack(cWin))
  finally
    DiagLocListTestCleanup([aBnr, cBnr])
  endtry
enddef

# Test that the diagnostics published for a hidden buffer don't change any
# location list, and that the diagnostics location list of a window is set to
# the diagnostics of the buffer displayed in it.
def g:Test_DiagLocList_HiddenBufferShownLater()
  g:LspOptionsSet({autoHighlightDiags: false, autoPopulateDiags: true})
  var lspserver = MakeDiagServer('srv')
  silent! edit XDiagLocListHiddenB.c
  setlocal bufhidden=hide
  var bBnr = bufnr()
  silent! edit XDiagLocListShownA.c
  setlocal bufhidden=hide
  var aBnr = bufnr()
  var win = win_getid()
  try
    assert_true(bBnr->bufloaded())
    assert_equal([], bBnr->win_findbuf())
    var stack = LocListStack(win)
    PublishBufDiags(lspserver, bBnr, ['b1', 'b2'])
    assert_equal(stack, LocListStack(win))

    execute $'buffer {bBnr}'
    assert_equal([['b1', 'b2']], DiagLocListTexts(win))
    assert_equal([bBnr, bBnr], getloclist(win)->mapnew((_, v) => v.bufnr))

    stack = LocListStack(win)
    PublishBufDiags(lspserver, aBnr, ['a1'])
    assert_equal(stack, LocListStack(win))
    execute $'buffer {aBnr}'
    assert_equal([['a1']], DiagLocListTexts(win))

    # A buffer without diagnostics empties the list
    :enew
    assert_equal([[]], DiagLocListTexts(win))

    # Without "autoPopulateDiags", displaying a buffer doesn't add a list
    g:LspOptionsSet({autoPopulateDiags: false})
    setloclist(win, [], 'f')
    execute $'buffer {aBnr}'
    assert_equal([], DiagLocListTexts(win))
  finally
    DiagLocListTestCleanup([aBnr, bBnr])
  endtry
enddef

# Test that ":LspDiag show" sets the diagnostics location list of the current
# window only, that without "autoPopulateDiags" only the windows with a
# diagnostics list are updated, and that a location list window is never
# given a list of its own.
def g:Test_LspDiagShow_CurrentWindowOnly()
  g:LspOptionsSet({autoHighlightDiags: false})
  var lspserver = MakeDiagServer('srv')
  silent! edit XDiagLocListShow.c
  var bnr = bufnr()
  var win1 = win_getid()
  :split
  var win2 = win_getid()
  try
    PublishBufDiags(lspserver, bnr, ['d1', 'd2'])
    assert_equal([], DiagLocListTexts(win1))
    assert_equal([], DiagLocListTexts(win2))

    :LspDiag show
    assert_equal('loclist', win_gettype())
    assert_equal(win2, getloclist(0, {filewinid: 0}).filewinid)
    assert_equal([['d1', 'd2']], DiagLocListTexts(win2))
    assert_equal([], DiagLocListTexts(win1))

    PublishBufDiags(lspserver, bnr, ['d3'])
    assert_equal([['d3']], DiagLocListTexts(win2))
    assert_equal([], DiagLocListTexts(win1))
    assert_equal(1, line('$'))
    assert_match(' d3$', getline(1))

    # From the location list window
    assert_match('Warn: No diagnostic messages found for',
		 execute('LspDiag show')->split("\n")[0])
    assert_equal([['d3']], DiagLocListTexts(win2))
  finally
    DiagLocListTestCleanup([bnr])
  endtry
enddef

# Define stub ALE "other source" functions that record their calls in
# g:LspTestAleCalls, and send the diagnostics to them.  Returns the directory
# to pass to RemoveAleStub().
def InstallAleStub(): string
  var root = tempname()
  mkdir($'{root}/autoload/ale', 'p')
  var fname = $'{root}/autoload/ale/other_source.vim'
  writefile([
    'function ale#other_source#StartChecking(buffer, linter_name) abort',
    '  call add(g:LspTestAleCalls, ["start", a:buffer, a:linter_name])',
    'endfunction',
    'function ale#other_source#ShowResults(buffer, linter_name, loclist) abort',
    '  call add(g:LspTestAleCalls,',
    '        \ ["show", a:buffer, a:linter_name, map(copy(a:loclist), "v:val.text"),',
    '        \  deepcopy(a:loclist)])',
    'endfunction'
  ], fname)
  execute 'source' fnameescape(fname)
  g:LspTestAleCalls = []
  g:LspOptionsSet({aleSupport: true, autoHighlightDiags: false})
  return root
enddef

# Remove the stub ALE functions defined by InstallAleStub() and restore the
# default diagnostics options.
def RemoveAleStub(root: string)
  g:LspOptionsSet({aleSupport: false, autoHighlightDiags: true})
  unlet g:LspTestAleCalls
  delfunction ale#other_source#StartChecking
  delfunction ale#other_source#ShowResults
  delete(root, 'rf')
enddef

# Return a test language server named "name" that accepts diagnostics.
def MakeDiagServer(name: string): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.name = name
  lspserver.features = {diagnostics: true}
  lspserver.featureEnabled = (_) => true
  return lspserver
enddef

# Return a diagnostic with "message" at the start of line "lnum" (0-based).
def MakeLineDiag(lnum: number, message: string): dict<any>
  return {
    range: {
      start: {line: lnum, character: 0},
      end: {line: lnum, character: 1}
    },
    severity: 1,
    message: message
  }
enddef

# Return the most recent diagnostic texts sent to the stub ALE for each
# linter name.
def AleResultsByLinter(): dict<list<string>>
  var results: dict<list<string>> = {}
  for call in g:LspTestAleCalls
    if call[0] == 'show'
      results[call[2]] = call[3]
    endif
  endfor
  return results
enddef

# Each language server's diagnostics are sent to ALE under the server name,
# and are cleared when the buffer is detached from the servers.
def g:Test_AleSupport_DiagsSentPerServer()
  var aleStub = InstallAleStub()
  silent! edit XAleSupportPerServer.c
  setline(1, ['int a;', 'int b;'])
  var bnr = bufnr()
  var uri = util.LspBufnrToUri(bnr)
  var clangd = MakeDiagServer('clangd')
  var tidy = MakeDiagServer('tidy')
  var quiet = MakeDiagServer('quiet')
  buf.BufLspServerSet(bnr, clangd)
  buf.BufLspServerSet(bnr, tidy)
  buf.BufLspServerSet(bnr, quiet)

  diag.DiagNotification(clangd, uri, [MakeLineDiag(0, 'clangd diag')], 'push')
  diag.DiagNotification(tidy, uri, [MakeLineDiag(1, 'tidy diag')], 'push')
  assert_equal({clangd: ['clangd diag'], tidy: ['tidy diag'], quiet: []},
	       AleResultsByLinter())

  g:LspTestAleCalls = []
  g:ale_buffer_info = {[bnr]: {}}
  lsp.RemoveFile(bnr)
  assert_equal({clangd: [], tidy: [], quiet: []}, AleResultsByLinter())

  unlet g:ale_buffer_info
  RemoveAleStub(aleStub)
  :%bw!
enddef

# The diagnostics of a buffer that ALE no longer tracks (it drops a deleted
# buffer before the buffer is detached from the servers) are not cleared in
# ALE, which would make ALE track the buffer again.
def g:Test_AleSupport_DeletedBufferNotSentToAle()
  var aleStub = InstallAleStub()
  silent! edit XAleSupportDeleted.c
  setline(1, ['int a;'])
  var bnr = bufnr()
  var clangd = MakeDiagServer('clangd')
  buf.BufLspServerSet(bnr, clangd)
  diag.DiagNotification(clangd, util.LspBufnrToUri(bnr),
			[MakeLineDiag(0, 'clangd diag')], 'push')

  g:LspTestAleCalls = []
  lsp.RemoveFile(bnr)
  assert_equal([], g:LspTestAleCalls)

  RemoveAleStub(aleStub)
  :%bw!
enddef

# When ALE asks for results, a check is started for every attached server
# name, and the results of servers sharing a name are sent together.  A
# buffer without a language server is not checked.
def g:Test_AleSupport_AleHookChecksEveryServer()
  var aleStub = InstallAleStub()
  silent! edit XAleSupportNoServer.txt
  var noServerBnr = bufnr()
  silent! edit XAleSupportHook.rb
  setline(1, ['a = 1', 'b = 2'])
  var bnr = bufnr()
  var uri = util.LspBufnrToUri(bnr)
  var rubyLsp = MakeDiagServer('ruby-lsp')
  var rubyLspTwin = MakeDiagServer('ruby-lsp')
  var steep = MakeDiagServer('steep')
  buf.BufLspServerSet(bnr, rubyLsp)
  buf.BufLspServerSet(bnr, rubyLspTwin)
  buf.BufLspServerSet(bnr, steep)
  diag.DiagNotification(rubyLsp, uri, [MakeLineDiag(0, 'first')], 'push')
  diag.DiagNotification(rubyLspTwin, uri, [MakeLineDiag(1, 'second')], 'push')

  g:LspTestAleCalls = []
  diag.AleHook(noServerBnr)
  diag.AleHook(bnr)
  assert_equal([['start', bnr, 'ruby-lsp'], ['start', bnr, 'steep']],
	       g:LspTestAleCalls)
  g:WaitForAssert(() => assert_equal({'ruby-lsp': ['first', 'second'],
				      steep: []}, AleResultsByLinter()))
  assert_equal(4, g:LspTestAleCalls->len())

  diag.DiagRemoveFile(bnr)
  buf.BufLspServerRemove(bnr, rubyLsp)
  buf.BufLspServerRemove(bnr, rubyLspTwin)
  buf.BufLspServerRemove(bnr, steep)
  RemoveAleStub(aleStub)
  :%bw!
enddef

# In insert mode, diagnostics are sent to ALE only when ALE lints while text
# is changed in insert mode ("g:ale_lint_on_text_changed").
def g:Test_AleSupport_InsertModeFollowsAleLintOnTextChanged()
  var aleStub = InstallAleStub()
  silent! edit XAleSupportInsertMode.c
  setline(1, ['int a;'])
  var bnr = bufnr()
  var clangd = MakeDiagServer('clangd')
  buf.BufLspServerSet(bnr, clangd)
  var uri = util.LspBufnrToUri(bnr)
  g:LspTestPublishDiags = () => {
    diag.DiagNotification(clangd, uri, [MakeLineDiag(0, 'clangd diag')],
			  'push')
  }

  var cases: list<list<any>> = [
    ['never', false], ['normal', false], [0, false], ['0', false],
    [false, false], ['insert', true], ['Insert', true], ['always', true],
    ['ALWAYS', true], [1, true], ['1', true], [true, true]
  ]
  for [lintOnTextChanged, sent] in cases
    g:ale_lint_on_text_changed = lintOnTextChanged
    g:LspTestAleCalls = []
    feedkeys("i\<Cmd>call g:LspTestPublishDiags()\<CR>\<Esc>", 'xt')
    assert_equal(sent, !g:LspTestAleCalls->empty(),
		 $'g:ale_lint_on_text_changed = {string(lintOnTextChanged)}')
  endfor

  unlet g:ale_lint_on_text_changed
  g:LspTestAleCalls = []
  feedkeys("i\<Cmd>call g:LspTestPublishDiags()\<CR>\<Esc>", 'xt')
  assert_equal([], g:LspTestAleCalls)

  # Outside insert mode the diagnostics are always sent.
  g:LspTestPublishDiags()
  assert_equal({clangd: ['clangd diag']}, AleResultsByLinter())

  unlet g:LspTestPublishDiags
  diag.DiagRemoveFile(bnr)
  buf.BufLspServerRemove(bnr, clangd)
  RemoveAleStub(aleStub)
  :%bw!
enddef

# ALE highlights a diagnostic up to and including its end column, so the
# exclusive end of a diagnostic range is sent to ALE as the position of the
# last byte in the range, kept within the buffer.
def g:Test_AleSupport_InclusiveEndColumn()
  var aleStub = InstallAleStub()
  silent! edit XAleSupportEndCol.c
  setline(1, ['int abc;', "x = éé;", 'int b;', '', "ééé"])
  var bnr = bufnr()
  var uri = util.LspBufnrToUri(bnr)
  var clangd = MakeDiagServer('clangd')
  buf.BufLspServerSet(bnr, clangd)

  # [description, LSP [start line, start char, end line, end char],
  #  ALE [lnum, col, end_lnum, end_col]]
  var cases: list<list<any>> = [
    ['single line', [0, 4, 0, 7], [1, 5, 1, 7]],
    ['multibyte last character', [1, 4, 1, 6], [2, 5, 2, 8]],
    ['multiple lines', [0, 4, 1, 5], [1, 5, 2, 6]],
    ['zero width', [0, 4, 0, 4], [1, 5, 1, 5]],
    ['zero width on an empty line', [3, 0, 3, 0], [4, 1, 4, 1]],
    ['end at the start of the next line', [1, 4, 2, 0], [2, 5, 2, 9]],
    ['whole line', [2, 0, 3, 0], [3, 1, 3, 6]],
    ['newline only', [0, 8, 1, 0], [1, 9, 1, 9]],
    ['end past the end of the line', [0, 4, 0, 20], [1, 5, 1, 8]],
    ['multibyte end past the end of the line', [4, 1, 4, 4], [5, 3, 5, 6]],
    ['end past the end of the buffer', [2, 0, 9, 0], [3, 1, 5, 6]]
  ]
  for [desc, lspRange, aleRange] in cases
    var d = {
      range: {
	start: {line: lspRange[0], character: lspRange[1]},
	end: {line: lspRange[2], character: lspRange[3]}
      },
      severity: 1,
      message: desc
    }
    g:LspTestAleCalls = []
    diag.DiagNotification(clangd, uri, [d], 'push')
    assert_equal([aleRange], g:LspTestAleCalls[-1][4]->mapnew((_, v) =>
		   [v.lnum, v.col, v.end_lnum, v.end_col]), desc)
  endfor

  diag.DiagRemoveFile(bnr)
  buf.BufLspServerRemove(bnr, clangd)
  RemoveAleStub(aleStub)
  :%bw!
enddef

# Define the diagnostic signs and text property types, which are otherwise
# defined only when the first language server is started.
def DiagInitOnce()
  if prop_type_get('LspDiagVirtualTextError')->empty()
    diag.InitOnce()
  endif
enddef

# Return a diagnostic for "message" starting at the zero-based "startLine" and
# "startChar" with "severity", or without a severity if it is 0.
def MakeDiag(startLine: number, startChar: number, severity: number,
	message: string): dict<any>
  var d: dict<any> = {
    range: {
      start: {line: startLine, character: startChar},
      end: {line: startLine, character: startChar + 3}
    },
    message: message
  }
  if severity > 0
    d.severity = severity
  endif
  return d
enddef

# Return the [lnum, type, text, align] of the diagnostic virtual text placed in
# the current buffer.
def DiagVirtualTexts(): list<list<any>>
  return prop_list(1, {end_lnum: line('$')})
    ->filter((_, p) => p.type =~ '^LspDiagVirtualText')
    ->mapnew((_, p) => [p.lnum, p.type, p.text, p->get('text_align', 'after')])
enddef

# Return the number of text properties of the types matching "pattern" placed
# in the current buffer.
def PropCount(pattern: string): number
  return prop_list(1, {end_lnum: line('$')})
    ->filter((_, p) => p.type =~ pattern)
    ->len()
enddef

# With "diagVirtualTextMostSevere" set, only the most severe diagnostic on
# each line, across all the servers, gets virtual text.  Signs and inline
# highlights are still placed for every diagnostic.
def g:Test_DiagVirtualTextMostSevere()
  DiagInitOnce()
  silent! edit XDiagVirtualTextMostSevere.txt
  setline(1, ['int alpha = beta + gamma;', 'int delta = epsilon;',
	      'int zeta;', 'int eta;'])
  var bnr = bufnr()
  var uri = util.LspBufnrToUri(bnr)
  g:LspOptionsSet({showDiagWithVirtualText: true,
		   diagVirtualTextMostSevere: true})

  var srvA = MakeDiagServer('srvA')
  var srvB = MakeDiagServer('srvB')
  var diagsA = [
    MakeDiag(0, 0, 4, 'hint on line 1'),
    MakeDiag(0, 12, 2, 'warning on line 1'),
    MakeDiag(1, 12, 2, 'right warning on line 2'),
    MakeDiag(2, 4, 3, 'info on line 3'),
    MakeDiag(3, 0, 4, 'hint on line 4')
  ]
  var diagsB = [
    MakeDiag(0, 19, 1, 'error on line 1'),
    MakeDiag(1, 4, 2, 'left warning on line 2'),
    MakeDiag(3, 4, 0, 'no severity on line 4')
  ]
  diag.DiagNotification(srvA, uri, diagsA, 'push')
  diag.DiagNotification(srvB, uri, diagsB, 'push')

  for [align, sym] in [['above', ['┌─', '┌─', '┌─']],
		       ['below', ['└─', '└─', '└─']],
		       ['after', ['E>', 'W>', 'I>']]]
    g:LspOptionsSet({diagVirtualTextAlign: align})
    assert_equal([
	[1, 'LspDiagVirtualTextError', $'{sym[0]} error on line 1', align],
	[2, 'LspDiagVirtualTextWarning', $'{sym[1]} left warning on line 2',
	  align],
	[3, 'LspDiagVirtualTextInfo', $'{sym[2]} info on line 3', align],
	[4, 'LspDiagVirtualTextError', $'{sym[0]} no severity on line 4', align]
      ], DiagVirtualTexts(), $'diagVirtualTextAlign: {align}')
    assert_equal(8, sign_getplaced(bnr, {group: 'LSPDiag'})[0].signs->len())
    assert_equal(8, PropCount('^LspDiagInline'))
  endfor

  # Changing the option takes effect without waiting for new diagnostics
  g:LspOptionsSet({diagVirtualTextMostSevere: false})
  assert_equal([1, 1, 1, 2, 2, 3, 4, 4],
	       DiagVirtualTexts()->mapnew((_, v) => v[0])->sort('n'))
  assert_equal(8, sign_getplaced(bnr, {group: 'LSPDiag'})[0].signs->len())
  assert_equal(8, PropCount('^LspDiagInline'))
  g:LspOptionsSet({diagVirtualTextMostSevere: true})
  assert_equal([1, 2, 3, 4], DiagVirtualTexts()->mapnew((_, v) => v[0]))

  g:LspOptionsSet({showDiagWithVirtualText: false,
		   diagVirtualTextMostSevere: false,
		   diagVirtualTextAlign: 'above'})
  assert_equal([], DiagVirtualTexts())
  diag.DiagRemoveFile(bnr)
  :%bw!
enddef

# Seed the current buffer with a diagnostic spanning lines 1-3, a diagnostic
# nested inside it on line 2, and a diagnostic on line 4 whose range ends at
# the start of line 5.  Returns the server that reported them.
def SeedMultiLineDiags(): dict<any>
  g:LspOptionsSet({autoHighlightDiags: false})
  setline(1, repeat(['abcdefghij'], 5))

  var lspserver = MakeTestLspServer([])
  lspserver.features = {diagnostics: true}
  lspserver.featureEnabled = (_) => true

  var diags = [
    {range: {start: {line: 0, character: 4}, end: {line: 2, character: 2}},
     message: 'multi'},
    {range: {start: {line: 1, character: 3}, end: {line: 1, character: 6}},
     message: 'single'},
    {range: {start: {line: 3, character: 5}, end: {line: 4, character: 0}},
     message: 'eol'}
  ]
  diag.DiagNotification(lspserver, util.LspBufnrToUri(bufnr()), diags, 'push')
  return lspserver
enddef

# Return the messages of the diagnostics in "diags"
def DiagMsgs(diags: list<dict<any>>): list<string>
  return diags->mapnew((_, d) => d.message)
enddef

def g:Test_GetDiagsByLine_MultiLineDiagnostic()
  silent! edit XMultiLineDiagsByLine.txt
  var lspserver = SeedMultiLineDiags()
  var bnr = bufnr()

  assert_equal(['multi'], DiagMsgs(diag.GetDiagsByLine(bnr, 1)))
  assert_equal(['multi', 'single'], DiagMsgs(diag.GetDiagsByLine(bnr, 2)))
  assert_equal(['multi'], DiagMsgs(diag.GetDiagsByLine(bnr, 3)))
  assert_equal(['eol'], DiagMsgs(diag.GetDiagsByLine(bnr, 4)))
  assert_equal([], DiagMsgs(diag.GetDiagsByLine(bnr, 5)))

  assert_equal(['multi'], DiagMsgs(diag.GetDiagsByLine(bnr, 3, lspserver)))
  assert_equal([], diag.GetDiagsByLine(bnr, 3, MakeTestLspServer([])))

  assert_equal(['multi', 'single'],
	       DiagMsgs(diag.GetDiagsInLineRange(bnr, 2, 3)))
  assert_equal(['multi', 'single', 'eol'],
	       DiagMsgs(diag.GetDiagsInLineRange(bnr, 1, 5)))
  assert_equal(['eol'], DiagMsgs(diag.GetDiagsInLineRange(bnr, 4, 5)))

  # The returned list must not alias the stored diagnostics
  diag.GetDiagsByLine(bnr, 2, lspserver)->add({message: 'extra'})
  assert_equal(['multi', 'single'],
	       DiagMsgs(diag.GetDiagsByLine(bnr, 2, lspserver)))

  ClearBufferDiagnostics()
  :%bw!
enddef

def g:Test_GetDiagByPos_MultiLineDiagnostic()
  silent! edit XMultiLineDiagByPos.txt
  SeedMultiLineDiags()
  var bnr = bufnr()

  var MsgAt = (lnum: number, col: number, atPos: bool): string =>
    diag.GetDiagByPos(bnr, lnum, col, atPos)->get('message', '')

  # Innermost diagnostic whose range contains the position
  assert_equal('', MsgAt(1, 4, true))
  assert_equal('multi', MsgAt(1, 5, true))
  assert_equal('multi', MsgAt(2, 1, true))
  assert_equal('single', MsgAt(2, 4, true))
  assert_equal('single', MsgAt(2, 6, true))
  assert_equal('multi', MsgAt(2, 7, true))
  assert_equal('multi', MsgAt(3, 2, true))
  assert_equal('', MsgAt(3, 3, true))
  assert_equal('', MsgAt(4, 5, true))
  assert_equal('eol', MsgAt(4, 6, true))
  assert_equal('eol', MsgAt(4, 10, true))
  assert_equal('', MsgAt(5, 1, true))

  # First diagnostic starting at or after the position, else the last one
  assert_equal('multi', MsgAt(1, 1, false))
  assert_equal('multi', MsgAt(1, 9, false))
  assert_equal('single', MsgAt(2, 1, false))
  assert_equal('single', MsgAt(2, 8, false))
  assert_equal('multi', MsgAt(3, 5, false))
  assert_equal('', MsgAt(5, 1, false))

  ClearBufferDiagnostics()
  :%bw!
enddef

def g:Test_LspDiagCurrent_MultiLineDiagnostic()
  silent! edit XMultiLineDiagCurrent.txt
  SeedMultiLineDiags()

  g:LspOptionsSet({showDiagInPopup: false})
  cursor(3, 1)
  assert_equal(['multi'], execute('LspDiag current')->split("\n"))
  assert_equal(['multi'], execute('LspDiag! current')->split("\n"))
  cursor(3, 3)
  assert_equal(['Warn: No diagnostic messages found for current position'],
	       execute('LspDiag! current')->split("\n"))
  cursor(2, 5)
  assert_equal(['single'], execute('LspDiag! current')->split("\n"))
  g:LspOptionsSet({showDiagInPopup: true})

  # The popup for a diagnostic starting on a previous line is displayed below
  # the cursor line
  cursor(3, 2)
  :redraw
  :LspDiag current
  var ids = popup_list()
  assert_equal(1, ids->len())
  assert_equal(['multi'], getbufline(ids[0]->winbufnr(), 1, '$'))
  assert_equal(screenpos(0, 3, 1).row + 1, ids[0]->popup_getpos().line)
  popup_clear()

  # The v:beval_* variables can't be set, so only check that the balloon
  # expression compiles and finds nothing outside of a balloon
  assert_equal('', g:LspDiagExpr())

  ClearBufferDiagnostics()
  :%bw!
enddef

def g:Test_CodeActionContext_MultiLineDiagnostic()
  silent! edit XMultiLineDiagCodeAction.txt
  var lspserver = SeedMultiLineDiags()
  lspserver.isCodeActionProvider = true
  var sentDiags: list<list<string>> = []
  lspserver.rpc_a = (_, params, _) => {
    sentDiags->add(DiagMsgs(params.context.diagnostics))
    return 1
  }

  cursor(3, 1)
  lspserver.codeActionAsync(@%, 3, 3, '', (_, _, _, _) => 0)
  lspserver.codeActionAsync(@%, 2, 3, '', (_, _, _, _) => 0)
  lspserver.codeActionAsync(@%, 1, 5, '', (_, _, _, _) => 0)
  lspserver.codeActionAsync(@%, 5, 5, '', (_, _, _, _) => 0)
  assert_equal([['multi'], ['multi', 'single'], ['multi', 'single', 'eol'],
		[]], sentDiags)

  ClearBufferDiagnostics()
  :%bw!
enddef

# Return the [lnum, text, align, wrap] of the diagnostic virtual text placed in
# the current buffer.
def DiagVirtualTextLayout(): list<list<any>>
  return prop_list(1, {end_lnum: line('$')})
    ->filter((_, p) => p.type =~ '^LspDiagVirtualText')
    ->mapnew((_, p) => [p.lnum, p.text, p->get('text_align', 'after'),
			p->get('text_wrap', 'truncate')])
enddef

# Return the number of diagnostic signs placed in the current buffer.
def DiagSignCount(): number
  return sign_getplaced(bufnr(), {group: 'LSPDiag'})[0].signs->len()
enddef

# Changing the alignment or the wrapping of the diagnostic virtual text
# re-places the virtual text without waiting for new diagnostics.
def g:Test_DiagOptionsChanged_VirtualTextAlignAndWrap()
  DiagInitOnce()
  silent! edit XDiagOptionsVirtualText.txt
  setline(1, ['int alpha;', 'int beta;'])
  var bnr = bufnr()
  g:LspOptionsSet({showDiagWithVirtualText: true})
  var diags = [MakeDiag(0, 4, 1, 'error'), MakeDiag(1, 4, 2, 'warning')]
  diag.DiagNotification(MakeDiagServer('srv'), util.LspBufnrToUri(bnr), diags,
			'push')
  assert_equal([[1, '┌─ error', 'above', 'truncate'],
		[2, '┌─ warning', 'above', 'truncate']], DiagVirtualTextLayout())

  var steps: list<list<any>> = [
    [{diagVirtualTextAlign: 'below'}, '└─', '└─', 'below', 'truncate'],
    [{diagVirtualTextWrap: 'wrap'}, '└─', '└─', 'below', 'wrap'],
    [{diagVirtualTextAlign: 'after'}, 'E>', 'W>', 'after', 'wrap'],
    [{diagVirtualTextWrap: 'truncate'}, 'E>', 'W>', 'after', 'truncate'],
    [{diagVirtualTextWrap: 'default'}, 'E>', 'W>', 'after', 'wrap'],
    [{diagVirtualTextAlign: 'above'}, '┌─', '┌─', 'above', 'truncate']
  ]
  for [opts, errSym, warnSym, align, wrap] in steps
    g:LspOptionsSet(opts)
    assert_equal([[1, $'{errSym} error', align, wrap],
		  [2, $'{warnSym} warning', align, wrap]],
		 DiagVirtualTextLayout(), string(opts))
  endfor

  g:LspOptionsSet({showDiagWithVirtualText: false})
  assert_equal([], DiagVirtualTextLayout())
  diag.DiagRemoveFile(bnr)
  :%bw!
enddef

# Return the [lnum, left padding] of the diagnostic virtual text placed in
# buffer "bnr".
def DiagVirtualTextPadding(bnr: number): list<list<number>>
  return prop_list(1, {bufnr: bnr, end_lnum: -1})
    ->filter((_, p) => p.type =~ '^LspDiagVirtualText')
    ->mapnew((_, p) => [p.lnum, p->get('text_padding_left', 0)])
enddef

# The virtual text placed above or below a line in a buffer that is not the
# current one is indented to the diagnostic column of that buffer's line,
# with tabs expanded with that buffer's 'tabstop' and 'vartabstop'.
def g:Test_DiagVirtualTextPadding_NonCurrentBuffer()
  DiagInitOnce()
  var saveHidden = &hidden
  :set hidden
  silent! edit XDiagPaddingTarget.txt
  setline(1, ["\t\tint alpha;", "\t\t\tint beta;"])
  :setlocal tabstop=4
  var bnr = bufnr()
  g:LspOptionsSet({showDiagWithVirtualText: true,
		   diagVirtualTextAlign: 'below'})
  var diags = [MakeDiag(0, 6, 1, 'error'), MakeDiag(1, 7, 2, 'warning')]
  diag.DiagNotification(MakeDiagServer('srv'), util.LspBufnrToUri(bnr), diags,
			'push')
  assert_equal([[1, 12], [2, 16]], DiagVirtualTextPadding(bnr))

  silent! edit XDiagPaddingCurrent.txt
  setline(1, ['x'])
  :setlocal tabstop=8
  g:LspOptionsSet({diagVirtualTextAlign: 'above'})
  assert_equal([[1, 12], [2, 16]], DiagVirtualTextPadding(bnr))

  if has('vartabs')
    setbufvar(bnr, '&vartabstop', '2,3')
    g:LspOptionsSet({diagVirtualTextAlign: 'below'})
    assert_equal([[1, 9], [2, 12]], DiagVirtualTextPadding(bnr))
  endif

  g:LspOptionsSet({showDiagWithVirtualText: false,
		   diagVirtualTextAlign: 'above'})
  diag.DiagRemoveFile(bnr)
  &hidden = saveHidden
  :%bw!
enddef

# Changing the diagnostic sign texts updates the placed signs and the symbols
# of the virtual text placed after a line.
def g:Test_DiagOptionsChanged_SignText()
  DiagInitOnce()
  silent! edit XDiagOptionsSignText.txt
  setline(1, ['int alpha;', 'int beta;', 'int gamma;', 'int delta;'])
  var bnr = bufnr()
  g:LspOptionsSet({showDiagWithVirtualText: true,
		   diagVirtualTextAlign: 'after'})
  var diags = [MakeDiag(0, 4, 1, 'error'), MakeDiag(1, 4, 2, 'warning'),
	       MakeDiag(2, 4, 3, 'info'), MakeDiag(3, 4, 4, 'hint')]
  diag.DiagNotification(MakeDiagServer('srv'), util.LspBufnrToUri(bnr), diags,
			'push')

  g:LspOptionsSet({diagSignErrorText: 'e!', diagSignWarningText: 'w!',
		   diagSignInfoText: 'i!', diagSignHintText: 'h!'})
  assert_equal(['e!', 'w!', 'i!', 'h!'],
	       ['LspDiagError', 'LspDiagWarning', 'LspDiagInfo', 'LspDiagHint']
		 ->mapnew((_, name) => sign_getdefined(name)[0].text))
  assert_equal(4, DiagSignCount())
  assert_equal(['e! error', 'w! warning', 'i! info', 'h! hint'],
	       DiagVirtualTextLayout()->mapnew((_, v) => v[1]))

  g:LspOptionsSet({diagSignErrorText: 'E>', diagSignWarningText: 'W>',
		   diagSignInfoText: 'I>', diagSignHintText: 'H>',
		   showDiagWithVirtualText: false,
		   diagVirtualTextAlign: 'above'})
  assert_equal('E>', sign_getdefined('LspDiagError')[0].text)
  diag.DiagRemoveFile(bnr)
  :%bw!
enddef

# Turning a diagnostics display option off removes what it placed, and turning
# it on places it, without waiting for new diagnostics.
def g:Test_DiagOptionsChanged_ShowAndHide()
  DiagInitOnce()
  silent! edit XDiagOptionsShowAndHide.txt
  setline(1, ['int alpha;', 'int beta;'])
  var bnr = bufnr()
  var diags = [MakeDiag(0, 4, 1, 'error'), MakeDiag(1, 4, 2, 'warning')]
  diag.DiagNotification(MakeDiagServer('srv'), util.LspBufnrToUri(bnr), diags,
			'push')
  assert_equal(2, DiagSignCount())
  assert_equal(2, PropCount('^LspDiagInline'))

  g:LspOptionsSet({showDiagWithSign: false})
  assert_equal(0, DiagSignCount())
  g:LspOptionsSet({showDiagWithSign: true})
  assert_equal(2, DiagSignCount())

  g:LspOptionsSet({highlightDiagInline: false})
  assert_equal(0, PropCount('^LspDiagInline'))
  g:LspOptionsSet({highlightDiagInline: true})
  assert_equal(2, PropCount('^LspDiagInline'))

  g:LspOptionsSet({showDiagWithVirtualText: true})
  assert_equal(2, PropCount('^LspDiagVirtualText'))
  g:LspOptionsSet({showDiagWithVirtualText: false})
  assert_equal(0, PropCount('^LspDiagVirtualText'))

  g:LspOptionsSet({autoHighlightDiags: false})
  assert_equal([0, 0], [DiagSignCount(), PropCount('^LspDiag')])
  g:LspOptionsSet({autoHighlightDiags: true})
  assert_equal([2, 2], [DiagSignCount(), PropCount('^LspDiag')])

  # Turning off the diagnostics highlighting and a feature at once
  g:LspOptionsSet({autoHighlightDiags: false, showDiagWithSign: false})
  assert_equal([0, 0], [DiagSignCount(), PropCount('^LspDiag')])
  g:LspOptionsSet({autoHighlightDiags: true})
  assert_equal([0, 2], [DiagSignCount(), PropCount('^LspDiag')])
  g:LspOptionsSet({showDiagWithSign: true})
  assert_equal(2, DiagSignCount())

  # A number instead of a boolean value
  g:LspOptionsSet({showDiagWithSign: 0})
  assert_equal(0, DiagSignCount())
  g:LspOptionsSet({showDiagWithSign: 1})
  assert_equal(2, DiagSignCount())
  g:LspOptionsSet({showDiagWithSign: true})
  assert_equal(2, DiagSignCount())

  # ":LspDiag highlight disable" and "enable", followed by option changes
  diag.DiagsHighlightDisable()
  assert_equal([0, 0], [DiagSignCount(), PropCount('^LspDiag')])
  g:LspOptionsSet({autoHighlightDiags: true})
  assert_equal([2, 2], [DiagSignCount(), PropCount('^LspDiag')])
  g:LspOptionsSet({autoHighlightDiags: false})
  diag.DiagsHighlightEnable()
  assert_equal([2, 2], [DiagSignCount(), PropCount('^LspDiag')])

  diag.DiagRemoveFile(bnr)
  :%bw!
enddef

# Turning the diagnostic balloon or the diagnostic message on the status line
# on or off applies to the buffers that already have a language server.
def g:Test_DiagOptionsChanged_BalloonAndStatusLine()
  DiagInitOnce()
  var saveBalloonEval = &ballooneval
  var saveBalloonEvalTerm = &balloonevalterm
  :set noballooneval noballoonevalterm
  g:LspOptionsSet({showDiagInBalloon: false})
  silent! edit XDiagOptionsBalloon.txt
  setline(1, ['int alpha;'])
  var bnr = bufnr()
  var srv = MakeDiagServer('srv')
  buf.BufLspServerSet(bnr, srv)
  diag.BufferInit(srv, bnr)
  diag.DiagNotification(srv, util.LspBufnrToUri(bnr),
			[MakeDiag(0, 4, 1, 'status line diag')], 'push')
  var statusLineAcmd = $'#LspDiagStatusLine#CursorMoved#<buffer={bnr}>'

  assert_equal('', &balloonexpr)
  g:LspOptionsSet({showDiagInBalloon: true})
  assert_equal('g:LspDiagExpr()', &balloonexpr)
  assert_equal(has('balloon_eval'), &ballooneval ? 1 : 0)
  assert_equal(has('balloon_eval_term'), &balloonevalterm ? 1 : 0)
  g:LspOptionsSet({showDiagInBalloon: false})
  assert_equal('', &balloonexpr)

  assert_false(exists(statusLineAcmd))
  g:LspOptionsSet({showDiagOnStatusLine: true})
  assert_true(exists(statusLineAcmd))
  assert_match('status line diag', execute('doautocmd <nomodeline> CursorMoved'))
  # Initializing the buffer for another language server doesn't show the
  # message twice
  diag.BufferInit(srv, bnr)
  assert_equal(1, autocmd_get({group: 'LspDiagStatusLine'})->len())
  g:LspOptionsSet({showDiagOnStatusLine: false})
  assert_false(exists(statusLineAcmd))
  assert_notmatch('status line diag',
		  execute('doautocmd <nomodeline> CursorMoved'))

  # Detaching the buffer from the language servers removes the message
  g:LspOptionsSet({showDiagOnStatusLine: true})
  assert_true(exists(statusLineAcmd))
  lsp.RemoveFile(bnr)
  assert_false(exists(statusLineAcmd))

  g:LspOptionsSet({showDiagInBalloon: true, showDiagOnStatusLine: false})
  &ballooneval = saveBalloonEval
  &balloonevalterm = saveBalloonEvalTerm
  :%bw!
enddef

def g:Test_ProcessMessages_InvalidRequest_NonStringMethod_WithId()
  var lspserver = MakeTestLspServer([])
  var outMessages: list<dict<any>> = []
  var traceMsgs: list<string> = []
  lspserver.sendMessage = (msg) => CaptureMessage(outMessages, msg)
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.processRequest = (_, _) => assert_report('unexpected request dispatch')
  lspserver.processNotif = (_, _) => assert_report('unexpected notification dispatch')

  lspserver.data = {
    jsonrpc: '2.0',
    id: 99,
    method: 1
  }
  lspserver.processMessage()

  assert_equal(1, outMessages->len())
  assert_equal('2.0', outMessages[0].jsonrpc)
  assert_equal(99, outMessages[0].id)
  assert_equal(-32600, outMessages[0].error.code)
  assert_equal('Invalid request', outMessages[0].error.message)
  assert_match('Dropping malformed message with non-string method:', traceMsgs[0])
enddef

def g:Test_ProcessMessages_InvalidRequest_InvalidIdType_RespondsWithNullId()
  var lspserver = MakeTestLspServer([])
  var outMessages: list<dict<any>> = []
  var traceMsgs: list<string> = []
  lspserver.sendMessage = (msg) => CaptureMessage(outMessages, msg)
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.processRequest = (_, _) => assert_report('unexpected request dispatch')
  lspserver.processNotif = (_, _) => assert_report('unexpected notification dispatch')

  lspserver.data = {
    jsonrpc: '2.0',
    id: {},
    method: 'workspace/configuration'
  }
  lspserver.processMessage()

  assert_equal(1, outMessages->len())
  assert_equal(null, outMessages[0].id)
  assert_equal(-32600, outMessages[0].error.code)
  assert_match('Dropping malformed request with invalid id type:', traceMsgs[0])
enddef

def g:Test_ProcessMessages_InvalidRequest_MissingMethod_WithId()
  var lspserver = MakeTestLspServer([])
  var outMessages: list<dict<any>> = []
  var traceMsgs: list<string> = []
  lspserver.sendMessage = (msg) => CaptureMessage(outMessages, msg)
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.processRequest = (_, _) => assert_report('unexpected request dispatch')
  lspserver.processNotif = (_, _) => assert_report('unexpected notification dispatch')

  lspserver.data = {
    jsonrpc: '2.0',
    id: 'abc'
  }
  lspserver.processMessage()

  assert_equal(1, outMessages->len())
  assert_equal('abc', outMessages[0].id)
  assert_equal(-32600, outMessages[0].error.code)
  assert_match('Dropping malformed message missing method:', traceMsgs[0])
enddef

def g:Test_ProcessMessages_MalformedNotification_NoResponseSent()
  var lspserver = MakeTestLspServer([])
  var outMessages: list<dict<any>> = []
  var traceMsgs: list<string> = []
  lspserver.sendMessage = (msg) => CaptureMessage(outMessages, msg)
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.processRequest = (_, _) => assert_report('unexpected request dispatch')
  lspserver.processNotif = (_, _) => assert_report('unexpected notification dispatch')

  lspserver.data = {
    jsonrpc: '2.0',
    method: {}
  }
  lspserver.processMessage()

  assert_equal(0, outMessages->len())
  assert_match('Dropping malformed message with non-string method:', traceMsgs[0])
enddef

def g:Test_ProcessMessages_MalformedResponse_BothResultAndError_Dropped()
  var lspserver = MakeTestLspServer([])
  var traceMsgs: list<string> = []
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.processRequest = (_, _) => assert_report('unexpected request dispatch')
  lspserver.processNotif = (_, _) => assert_report('unexpected notification dispatch')

  lspserver.data = {
    jsonrpc: '2.0',
    id: 1,
    result: {},
    error: {code: -32603, message: 'Internal error'}
  }
  lspserver.processMessage()

  assert_equal(1, traceMsgs->len())
  assert_match('Dropping malformed response message:', traceMsgs[0])
enddef

def g:Test_LspAttached_AutocmdContextSingleServer()
  silent! edit XLspAttachedSingleServer.txt
  setline(1, ['single'])

  g:attachEvents = 0
  g:attachedFile = ''
  g:attachedBufnr = -1
  g:attachedServers = []
  var expectedFile = expand('%:p')
  var expectedBufnr = bufnr()
  augroup LspAttachedTest
    autocmd!
    autocmd User LspAttached {
      g:attachEvents += 1
      g:attachedFile = get(g:, 'LspAttachedContext', {})->get('file', '')
      g:attachedBufnr = get(g:, 'LspAttachedContext', {})->get('bufnr', -1)
      g:attachedServers = get(g:, 'LspAttachedContext', {})->get('servers', [])->copy()
    }
  augroup END

  var srv = MakeTestLspServer([])
  buf.BufLspServerSet(bufnr(), srv)

  lsp.FireLspAttachedAutocmd(bufnr())

  assert_equal(1, g:attachEvents)
  assert_equal(expectedFile, g:attachedFile)
  assert_equal(expectedBufnr, g:attachedBufnr)
  assert_equal(['test'], g:attachedServers)

  buf.BufLspServerRemove(bufnr(), srv)
  augroup LspAttachedTest
    autocmd!
  augroup END
  unlet g:attachEvents
  unlet g:attachedFile
  unlet g:attachedBufnr
  unlet g:attachedServers
  :bw!
enddef

def g:Test_LspAttached_AutocmdContextMultipleServers()
  silent! edit XLspAttachedMultipleServers.txt
  setline(1, ['multiple'])

  g:attachEvents = 0
  g:attachedFile = ''
  g:attachedBufnr = -1
  g:attachedServers = []
  var expectedFile = expand('%:p')
  var expectedBufnr = bufnr()
  augroup LspAttachedTest
    autocmd!
    autocmd User LspAttached {
      g:attachEvents += 1
      g:attachedFile = get(g:, 'LspAttachedContext', {})->get('file', '')
      g:attachedBufnr = get(g:, 'LspAttachedContext', {})->get('bufnr', -1)
      g:attachedServers = get(g:, 'LspAttachedContext', {})->get('servers', [])->copy()
    }
  augroup END

  var srv1 = MakeTestLspServer([])
  var srv2 = MakeTestLspServer([])
  buf.BufLspServerSet(bufnr(), srv1)
  buf.BufLspServerSet(bufnr(), srv2)

  lsp.FireLspAttachedAutocmd(bufnr())

  assert_equal(1, g:attachEvents)
  assert_equal(expectedFile, g:attachedFile)
  assert_equal(expectedBufnr, g:attachedBufnr)
  assert_equal(['test', 'test'], g:attachedServers)

  buf.BufLspServerRemove(bufnr(), srv1)
  buf.BufLspServerRemove(bufnr(), srv2)
  augroup LspAttachedTest
    autocmd!
  augroup END
  unlet g:attachEvents
  unlet g:attachedFile
  unlet g:attachedBufnr
  unlet g:attachedServers
  :bw!
enddef

def g:Test_LspDetached_AutocmdFiresForSingleServer()
  silent! edit XLspDetachedSingleServer.txt
  setline(1, ['single'])

  g:detachEvents = 0
  g:detachedFile = ''
  g:detachedBufnr = -1
  g:detachedServers = []
  var expectedFile = expand('%:p')
  var expectedBufnr = bufnr()
  augroup LspDetachedTest
    autocmd!
    autocmd User LspDetached {
      g:detachEvents += 1
      g:detachedFile = get(g:, 'LspDetachedContext', {})->get('file', '')
      g:detachedBufnr = get(g:, 'LspDetachedContext', {})->get('bufnr', -1)
      g:detachedServers = get(g:, 'LspDetachedContext', {})->get('servers', [])->copy()
    }
  augroup END

  var srv = MakeTestLspServer([])
  buf.BufLspServerSet(bufnr(), srv)

  lsp.RemoveFile(bufnr())

  assert_equal(1, g:detachEvents)
  assert_equal(expectedFile, g:detachedFile)
  assert_equal(expectedBufnr, g:detachedBufnr)
  assert_equal(['test'], g:detachedServers)

  augroup LspDetachedTest
    autocmd!
  augroup END
  unlet g:detachEvents g:detachedFile g:detachedBufnr g:detachedServers
  :bw!
enddef

def g:Test_LspDetached_AutocmdFiresOncePerBufferWithMultipleServers()
  silent! edit XLspDetachedMultipleServers.txt
  setline(1, ['multiple'])

  g:detachEvents = 0
  g:detachedFile = ''
  g:detachedBufnr = -1
  g:detachedServers = []
  var expectedFile = expand('%:p')
  var expectedBufnr = bufnr()
  augroup LspDetachedTest
    autocmd!
    autocmd User LspDetached {
      g:detachEvents += 1
      g:detachedFile = get(g:, 'LspDetachedContext', {})->get('file', '')
      g:detachedBufnr = get(g:, 'LspDetachedContext', {})->get('bufnr', -1)
      g:detachedServers = get(g:, 'LspDetachedContext', {})->get('servers', [])->copy()
    }
  augroup END

  var srv1 = MakeTestLspServer([])
  var srv2 = MakeTestLspServer([])
  buf.BufLspServerSet(bufnr(), srv1)
  buf.BufLspServerSet(bufnr(), srv2)

  lsp.RemoveFile(bufnr())

  assert_equal(1, g:detachEvents)
  assert_equal(expectedFile, g:detachedFile)
  assert_equal(expectedBufnr, g:detachedBufnr)
  assert_equal(['test', 'test'], g:detachedServers)

  augroup LspDetachedTest
    autocmd!
  augroup END
  unlet g:detachEvents g:detachedFile g:detachedBufnr g:detachedServers
  :bw!
enddef

# Test that detaching a buffer from its language servers removes the on-type
# formatting autocmds of the buffer.
def g:Test_LspDetached_RemovesOnTypeFormattingAutocmds()
  silent! edit XLspDetachedOnTypeFormatting.txt
  var bnr = bufnr()

  var srv = MakeTestLspServer([])
  srv.isDocumentOnTypeFormattingProvider = true
  buf.BufLspServerSet(bnr, srv)
  ontypeformat.BufferInit(srv, bnr)
  assert_notequal([], autocmd_get({group: 'LspOnTypeFormatting', bufnr: bnr}))

  lsp.RemoveFile(bnr)
  assert_equal([], autocmd_get({group: 'LspOnTypeFormatting', bufnr: bnr}))
  :bw!
enddef

def g:Test_LspDetached_AutocmdNotFiredWithoutAttachedServer()
  silent! edit XLspDetachedNoServer.txt
  setline(1, ['none'])

  g:detachEvents = 0
  augroup LspDetachedTest
    autocmd!
    autocmd User LspDetached g:detachEvents += 1
  augroup END

  lsp.RemoveFile(bufnr())

  assert_equal(0, g:detachEvents)

  augroup LspDetachedTest
    autocmd!
  augroup END
  unlet g:detachEvents
  :bw!
enddef

def g:Test_ProcessApplyEditReq_SuccesssfulEdit()
  var lspserver = MakeTestLspServer([])
  var responses: list<dict<any>> = []
  lspserver.sendResponse = (request, result, error) => CaptureResponse(responses, request, result, error)

  lspserver.data = {
    jsonrpc: '2.0',
    id: 1,
    method: 'workspace/applyEdit',
    params: {
      edit: {}
    }
  }
  lspserver.processMessage()

  assert_equal(1, responses->len())
  assert_equal({applied: true}, responses[0].result)
  assert_equal(1, responses[0].error->empty())
enddef

# The response to a workspace/applyEdit request whose edit fails tells which
# change failed and why.
def g:Test_ProcessApplyEditReq_FailedEdit()
  var responses: list<dict<any>> = []
  var lspserver = MakeRequestTestLspServer(responses)
  lspserver.data = {
    jsonrpc: '2.0',
    id: 1,
    method: 'workspace/applyEdit',
    params: {
      edit: {documentChanges: [{kind: 'copy'}]}
    }
  }
  lspserver.processMessage()

  assert_equal(1, responses->len())
  assert_equal({applied: false, failedChange: 0,
		failureReason: 'Unsupported change in workspace edit [copy]'},
	       responses[0].result)
  assert_true(responses[0].error->empty())
enddef

def g:Test_ProcessApplyEditReq_MissingEdit()
  var lspserver = MakeTestLspServer([])
  var responses: list<dict<any>> = []
  lspserver.sendResponse = (request, result, error) => CaptureResponse(responses, request, result, error)

  var request = {
    jsonrpc: '2.0',
    id: 1,
    method: 'workspace/applyEdit',
    params: {}
  }

  AssertRequestError(lspserver, responses, request, -32602)
enddef

def g:Test_ProcessShowMessageRequest_EmptyActions()
  var lspserver = MakeTestLspServer([])
  var responses: list<dict<any>> = []
  lspserver.sendResponse = (request, result, error) => CaptureResponse(responses, request, result, error)

  var request = {
    jsonrpc: '2.0',
    id: 1,
    method: 'window/showMessageRequest',
    params: {
      message: 'Test message',
      actions: []
    }
  }

  AssertRequestError(lspserver, responses, request, -32602)
enddef

def g:Test_ProcessShowMessageRequest_ValidMessage()
  var lspserver = MakeTestLspServer([])
  var responses: list<dict<any>> = []
  lspserver.sendResponse = (request, result, error) => CaptureResponse(responses, request, result, error)

  lspserver.data = {
    jsonrpc: '2.0',
    id: 1,
    method: 'window/showMessageRequest',
    params: {
      message: 'Test message'
    }
  }
  lspserver.processMessage()

  assert_equal(1, responses->len())
  assert_equal(null, responses[0].result)
  assert_equal(1, responses[0].error->empty())
enddef

# Test that the location list items built from LSP locations span the whole
# range, for ranges with multibyte and composing characters, ranges ending on a
# later line and locations in a file that is not loaded in a buffer.
def g:Test_ShowLocations_SetsEndPosition()
  var fname = 'XShowLocationsEnd.txt'
  writefile(["a\u0301b\u0301a\u0301b\u0301 \U0001F60A\U0001F60A tail", 'next'],
	    fname)
  var uri = util.LspFileToUri(fname)
  var locations = [
	{uri: uri, range: {start: {line: 0, character: 0},
			   end: {line: 0, character: 8}}},
	{uri: uri, range: {start: {line: 0, character: 9},
			   end: {line: 0, character: 11}}},
	{targetUri: uri,
	 targetRange: {start: {line: 0, character: 0},
		       end: {line: 1, character: 4}},
	 targetSelectionRange: {start: {line: 0, character: 12},
				end: {line: 1, character: 4}}}
  ]
  assert_false(fname->bufloaded())
  try
    symbol.ShowLocations({}, locations, false, 'Locations')
    assert_equal([[1, 1, 1, 13], [1, 14, 1, 22], [1, 23, 2, 5]],
		 getloclist(0)->mapnew((_, v) => [v.lnum, v.col, v.end_lnum, v.end_col]))
  finally
    :lclose
    setloclist(0, [], 'f')
    delete(fname)
  endtry
enddef

def g:Test_CodeActionMenu_ServerLabelOnlyForDuplicateTitles()
  g:LspOptionsSet({usePopupInCodeAction: true})

  var actions = [
    {
      title: 'Duplicate action',
      __lsp_server_id: 1,
      __lsp_server_name: 'srvA',
    },
    {
      title: 'Duplicate action',
      __lsp_server_id: 2,
      __lsp_server_name: 'srvB',
    },
    {
      title: 'Unique action',
      __lsp_server_id: 1,
      __lsp_server_name: 'srvA',
    }
  ]

  codeaction.ApplyCodeAction({}, actions, '')

  g:LspOptionsSet({codeActionPopupDetails: 'short'})

  var popups = popup_list()
  assert_equal(1, popups->len())
  var bnr = winbufnr(popups[0])
  assert_equal([
    ' 1. Duplicate action    [srvA] ',
    ' 2. Duplicate action    [srvB] ',
    ' 3. Unique action       [srvA] '
  ], getbufline(bnr, 1, '$'))

  popup_close(popups[0])
  g:LspOptionsSet({usePopupInCodeAction: false})
enddef

def g:Test_ApplyCodeAction_RoutesToOriginServer()
  silent! edit XCodeActionRouting.txt
  setline(1, ['test'])

  var execCmds1: list<string> = []
  var execCmds2: list<string> = []
  var srv1 = MakeTestLspServer([])
  var srv2 = MakeTestLspServer([])

  srv1.name = 'srv1'
  srv1.running = true
  srv1.ready = true
  srv1.executeCommand = (cmd: dict<any>) => {
    execCmds1->add(cmd->get('command', ''))
  }

  srv2.name = 'srv2'
  srv2.running = true
  srv2.ready = true
  srv2.executeCommand = (cmd: dict<any>) => {
    execCmds2->add(cmd->get('command', ''))
  }

  buf.BufLspServerSet(bufnr(), srv1)
  buf.BufLspServerSet(bufnr(), srv2)

  var actions = [
    {
      title: 'Same title',
      command: 'from-server-1',
      __lsp_server_id: srv1.id,
      __lsp_server_name: srv1.name,
    },
    {
      title: 'Same title',
      command: 'from-server-2',
      __lsp_server_id: srv2.id,
      __lsp_server_name: srv2.name,
    }
  ]

  codeaction.ApplyCodeAction({}, actions, '2')

  assert_equal([], execCmds1)
  assert_equal(['from-server-2'], execCmds2)

  buf.BufLspServerRemove(bufnr(), srv1)
  buf.BufLspServerRemove(bufnr(), srv2)
  :bw!
enddef

def g:Test_ApplyCodeAction_RoutesToOriginServer_AfterBufferSwitch()
  silent! edit XCodeActionRoutingOrigin.txt
  setline(1, ['origin'])
  var originBnr = bufnr()

  var execCmds1: list<string> = []
  var execCmds2: list<string> = []
  var srv1 = MakeTestLspServer([])
  var srv2 = MakeTestLspServer([])

  srv1.name = 'srv1'
  srv1.running = true
  srv1.ready = true
  srv1.executeCommand = (cmd: dict<any>) => {
    execCmds1->add(cmd->get('command', ''))
  }

  srv2.name = 'srv2'
  srv2.running = true
  srv2.ready = true
  srv2.executeCommand = (cmd: dict<any>) => {
    execCmds2->add(cmd->get('command', ''))
  }

  buf.BufLspServerSet(originBnr, srv1)
  buf.BufLspServerSet(originBnr, srv2)

  var actions = [
    {
      title: 'Same title',
      command: 'from-server-1',
      __lsp_server_id: srv1.id,
      __lsp_server_name: srv1.name,
      __lsp_bufnr: originBnr,
    },
    {
      title: 'Same title',
      command: 'from-server-2',
      __lsp_server_id: srv2.id,
      __lsp_server_name: srv2.name,
      __lsp_bufnr: originBnr,
    }
  ]

  silent! edit! XCodeActionRoutingOther.txt
  setline(1, ['other'])
  assert_notequal(originBnr, bufnr())

  codeaction.ApplyCodeAction({}, actions, '2')

  assert_equal([], execCmds1)
  assert_equal(['from-server-2'], execCmds2)

  buf.BufLspServerRemove(originBnr, srv1)
  buf.BufLspServerRemove(originBnr, srv2)
  :%bw!
enddef

def g:Test_LspAutoFix_AppliesSinglePreferredAction()
  silent! edit XLspAutoFixPreferred.txt
  set filetype=text
  setline(1, ['line'])
  cursor(1, 1)

  SeedBufferDiagnostics([
    {
      range: {
        start: {line: 0, character: 0},
        end: {line: 0, character: 1}
      },
      message: 'diag'
    }
  ])

  var execCmds: list<string> = []
  var actions = [
    {
      title: 'Apply preferred fix',
      isPreferred: true,
      command: 'preferred.fix',
    },
    {
      title: 'Apply fallback fix',
      command: 'fallback.fix',
    }
  ]
  var srv = MakeCodeActionServer('srv1', actions, execCmds)
  buf.BufLspServerSet(bufnr(), srv)

  lsp.AutoFix()

  assert_equal(['preferred.fix'], execCmds)
  assert_equal([], popup_list())

  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_PrefersPreferredActionForDiagnostic()
  silent! edit XLspAutoFixPreferredSelection.txt
  set filetype=text
  setline(1, ['line'])
  cursor(1, 1)

  SeedBufferDiagnostics([
    {
      range: {
        start: {line: 0, character: 0},
        end: {line: 0, character: 1}
      },
      message: 'diag'
    }
  ])

  var execCmds: list<string> = []
  var actions = [
    {
      title: 'Preferred one',
      isPreferred: true,
      command: 'preferred.one',
    },
    {
      title: 'Fallback',
      command: 'fallback',
    }
  ]
  var srv = MakeCodeActionServer('srv1', actions, execCmds)
  buf.BufLspServerSet(bufnr(), srv)

  lsp.AutoFix()

  assert_equal(['preferred.one'], execCmds)
  assert_equal([], popup_list())

  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_NoPreferredMultipleActionsSkipsDiagnostic()
  silent! edit XLspAutoFixNoPreferredMulti.txt
  set filetype=text
  setline(1, ['line'])
  cursor(1, 1)

  SeedBufferDiagnostics([
    {
      range: {
        start: {line: 0, character: 0},
        end: {line: 0, character: 1}
      },
      message: 'diag'
    }
  ])

  var execCmds: list<string> = []
  var actions = [
    {
      title: 'Fix A',
      command: 'fix.a',
    },
    {
      title: 'Fix B',
      command: 'fix.b',
    }
  ]
  var srv = MakeCodeActionServer('srv1', actions, execCmds)
  buf.BufLspServerSet(bufnr(), srv)

  lsp.AutoFix()

  assert_equal([], execCmds)
  assert_equal([], popup_list())

  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_NoDiagnosticsShowsMessage()
  silent! edit XLspAutoFixNoDiagnostics.txt
  set filetype=text
  setline(1, ['line'])
  cursor(1, 1)

  var execCmds: list<string> = []
  var srv = MakeCodeActionServer('srv1', [], execCmds)
  buf.BufLspServerSet(bufnr(), srv)

  var beforeMessages = execute('messages')
  lsp.AutoFix()
  var afterMessages = execute('messages')

  assert_true(afterMessages->len() >= beforeMessages->len())
  assert_true(afterMessages->stridx('No diagnostics found in the selected range') >= 0)
  assert_equal([], execCmds)

  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_Range_MultipleDiagnostics()
  silent! edit XLspAutoFixRange.txt
  set filetype=text
  setline(1, [
    'a',
    'b',
    'c',
    'd',
    'e',
  ])
  # Simulate diagnostics on lines 2, 3, 4 (descending order)
  var diags = [
    {'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 1}}, 'message': 'diag2'},
    {'range': {'start': {'line': 2, 'character': 0}, 'end': {'line': 2, 'character': 1}}, 'message': 'diag3'},
    {'range': {'start': {'line': 3, 'character': 0}, 'end': {'line': 3, 'character': 1}}, 'message': 'diag4'},
  ]
  SeedBufferDiagnostics(diags)

  # Each line's code action returns a preferred action for that diagnostic.
  var execCmds: list<string> = []
  var srv = MakeCodeActionServer('srv1', [], execCmds)
  srv.codeActionAsync = (_fname, line1, _line2, _query, Cbfunc) => {
    var idx = line1 - 1
    if idx >= 1 && idx <= 3
      var diagnum = idx + 1
      var acts = [{
        title: 'Fix diag' .. diagnum,
        isPreferred: true,
        command: 'fix.diag' .. diagnum,
        diagnostics: [{
          range: {
            start: {line: line1 - 1, character: 0},
            end: {line: line1 - 1, character: 1}}}]}]
      Cbfunc(srv, acts, '', {})
    else
      Cbfunc(srv, [], '', {})
    endif
  }
  buf.BufLspServerSet(bufnr(), srv)
  # Range: lines 2-4 (inclusive)
  lsp.AutoFix(2, 4)
  # Should apply fixes for diag4, diag3, diag2 (descending)
  assert_equal(['fix.diag4', 'fix.diag3', 'fix.diag2'], execCmds)

  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_Range_SkipNoPreferred()
  silent! edit XLspAutoFixSkipNoPreferred.txt
  set filetype=text
  setline(1, ['a', 'b'])
  var diags = [
    {'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'message': 'diag1'},
    {'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 1}}, 'message': 'diag2'},
  ]
  SeedBufferDiagnostics(diags)

  var execCmds: list<string> = []
  var srv = MakeCodeActionServer('srv1', [], execCmds)
  srv.codeActionAsync = (_fname, line1, _line2, _query, Cbfunc) => {
    if line1 == 1
      # No preferred for diag1
      Cbfunc(srv, [{'title': 'Not preferred', 'command': 'notpreferred'}], '', {})
    else
      # Preferred for diag2
      Cbfunc(srv, [{'title': 'Preferred', 'isPreferred': true, 'command': 'preferred', 'diagnostics': [{'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 1}}}]}], '', {})
    endif
  }
  buf.BufLspServerSet(bufnr(), srv)
  lsp.AutoFix(1, 2)
  # line 2 preferred fix is applied first, then the single non-preferred fix.
  assert_equal(['preferred', 'notpreferred'], execCmds)

  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_Range_MultiplePreferred_ShowsMenu()
  silent! edit XLspAutoFixRangePreferredMenu.txt
  set filetype=text
  setline(1, ['a'])
  g:LspOptionsSet({usePopupInCodeAction: true})

  var diags = [
    {'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'message': 'diag1'},
  ]
  SeedBufferDiagnostics(diags)

  var execCmds: list<string> = []
  var srv = MakeCodeActionServer('srv1', [], execCmds)
  srv.codeActionAsync = (_fname, line1, _line2, _query, Cbfunc) => {
    Cbfunc(srv, [
      {
        title: 'Preferred one',
        isPreferred: true,
        command: 'preferred.one',
        diagnostics: [{
          range: {
            start: {line: line1 - 1, character: 0},
            end: {line: line1 - 1, character: 1}}}]},
      {
        title: 'Preferred two',
        isPreferred: true,
        command: 'preferred.two',
        diagnostics: [{
          range: {
            start: {line: line1 - 1, character: 0},
            end: {line: line1 - 1, character: 1}}}]}
    ], '', {})
  }
  buf.BufLspServerSet(bufnr(), srv)

  lsp.AutoFix(1, 1)

  var popups = popup_list()
  assert_equal(1, popups->len())
  var bnr = winbufnr(popups[0])
  var lines = getbufline(bnr, 1, '$')
  assert_equal(2, lines->len())
  assert_match('Preferred one', lines[0])
  assert_match('Preferred two', lines[1])
  assert_equal([], execCmds)

  popup_close(popups[0])
  g:LspOptionsSet({usePopupInCodeAction: false})
  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_Range_PopupDefersNextDiagnostic()
  silent! edit XLspAutoFixPopupDefersNextDiag.txt
  set filetype=text
  setline(1, ['a', 'b'])
  g:LspOptionsSet({usePopupInCodeAction: true})

  var diags = [
    {'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'message': 'diag1'},
    {'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 1}}, 'message': 'diag2'},
  ]
  SeedBufferDiagnostics(diags)

  var execCmds: list<string> = []
  var srv = MakeCodeActionServer('srv1', [], execCmds)
  srv.codeActionAsync = (_fname, line1, _line2, _query, Cbfunc) => {
    if line1 == 1
      Cbfunc(srv, [
        {
          title: 'Preferred one',
          isPreferred: true,
          command: 'preferred.one',
          diagnostics: [{
            range: {
              start: {line: 0, character: 0},
              end: {line: 0, character: 1}}}]},
        {
          title: 'Preferred two',
          isPreferred: true,
          command: 'preferred.two',
          diagnostics: [{
            range: {
              start: {line: 0, character: 0},
              end: {line: 0, character: 1}}}]}
      ], '', {})
    else
      Cbfunc(srv, [{
        title: 'Second diag preferred',
        isPreferred: true,
        command: 'second.diag',
        diagnostics: [{
          range: {
            start: {line: 1, character: 0},
            end: {line: 1, character: 1}}}]}], '', {})
    endif
  }
  buf.BufLspServerSet(bufnr(), srv)

  lsp.AutoFix(1, 2)
  # AutoFix processes diagnostics bottom-to-top, so line 2 is applied before
  # the line 1 popup selection is shown.
  assert_equal(['second.diag'], execCmds)

  var popups = popup_list()
  assert_equal(1, popups->len())
  popup_close(popups[0], 1)

  assert_equal(['second.diag', 'preferred.one'], execCmds)

  g:LspOptionsSet({usePopupInCodeAction: false})
  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_Range_PopupCtrlCStopsNextDiagnostic()
  silent! edit XLspAutoFixPopupCtrlCStops.txt
  set filetype=text
  setline(1, ['a', 'b'])
  g:LspOptionsSet({usePopupInCodeAction: true})

  var diags = [
    {'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'message': 'diag1'},
    {'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 1}}, 'message': 'diag2'},
  ]
  SeedBufferDiagnostics(diags)

  var execCmds: list<string> = []
  var srv = MakeCodeActionServer('srv1', [], execCmds)
  srv.codeActionAsync = (_fname, line1, _line2, _query, Cbfunc) => {
    if line1 == 1
      Cbfunc(srv, [
        {
          title: 'Preferred one',
          isPreferred: true,
          command: 'preferred.one',
          diagnostics: [{
            range: {
              start: {line: 0, character: 0},
              end: {line: 0, character: 1}}}]},
        {
          title: 'Preferred two',
          isPreferred: true,
          command: 'preferred.two',
          diagnostics: [{
            range: {
              start: {line: 0, character: 0},
              end: {line: 0, character: 1}}}]}
      ], '', {})
    else
      Cbfunc(srv, [{
        title: 'Second diag preferred',
        isPreferred: true,
        command: 'second.diag',
        diagnostics: [{
          range: {
            start: {line: 1, character: 0},
            end: {line: 1, character: 1}}}]}], '', {})
    endif
  }
  buf.BufLspServerSet(bufnr(), srv)

  lsp.AutoFix(1, 2)
  assert_equal(['second.diag'], execCmds)

  var popups = popup_list()
  assert_equal(1, popups->len())
  # Simulate Ctrl-C hard cancel sentinel used by popup filter.
  popup_close(popups[0], -9)

  assert_equal(['second.diag'], execCmds)

  g:LspOptionsSet({usePopupInCodeAction: false})
  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_Range_PopupEscapeContinuesNextDiagnostic()
  silent! edit XLspAutoFixPopupEscapeContinues.txt
  set filetype=text
  setline(1, ['a', 'b'])
  g:LspOptionsSet({usePopupInCodeAction: true})

  var diags = [
    {'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'message': 'diag1'},
    {'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 1}}, 'message': 'diag2'},
  ]
  SeedBufferDiagnostics(diags)

  var execCmds: list<string> = []
  var srv = MakeCodeActionServer('srv1', [], execCmds)
  srv.codeActionAsync = (_fname, line1, _line2, _query, Cbfunc) => {
    if line1 == 1
      Cbfunc(srv, [
        {
          title: 'Preferred one',
          isPreferred: true,
          command: 'preferred.one',
          diagnostics: [{
            range: {
              start: {line: 0, character: 0},
              end: {line: 0, character: 1}}}]},
        {
          title: 'Preferred two',
          isPreferred: true,
          command: 'preferred.two',
          diagnostics: [{
            range: {
              start: {line: 0, character: 0},
              end: {line: 0, character: 1}}}]}
      ], '', {})
    else
      Cbfunc(srv, [{
        title: 'Second diag preferred',
        isPreferred: true,
        command: 'second.diag',
        diagnostics: [{
          range: {
            start: {line: 1, character: 0},
            end: {line: 1, character: 1}}}]}], '', {})
    endif
  }
  buf.BufLspServerSet(bufnr(), srv)

  lsp.AutoFix(1, 2)
  assert_equal(['second.diag'], execCmds)

  var popups = popup_list()
  assert_equal(1, popups->len())
  # Simulate Esc soft cancel result used by popup filter.
  popup_close(popups[0], -1)

  assert_equal(['second.diag'], execCmds)

  g:LspOptionsSet({usePopupInCodeAction: false})
  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_Range_ContinuesOnRpcError()
  silent! edit XLspAutoFixContinueOnRpcError.txt
  set filetype=text
  setline(1, ['a', 'b', 'c'])
  var diags = [
    {'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'message': 'diag1'},
    {'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 1}}, 'message': 'diag2'},
    {'range': {'start': {'line': 2, 'character': 0}, 'end': {'line': 2, 'character': 1}}, 'message': 'diag3'},
  ]
  SeedBufferDiagnostics(diags)

  var execCmds: list<string> = []
  var srv = MakeCodeActionServer('srv1', [], execCmds)
  srv.codeActionAsync = (_fname, line1, _line2, _query, Cbfunc) => {
    if line1 == 3
      Cbfunc(srv, [], '', {code: -32603, message: 'simulated rpc error'})
    else
      Cbfunc(srv, [{'title': 'Preferred', 'isPreferred': true, 'command': 'ok.' .. line1, 'diagnostics': [{'range': {'start': {'line': line1 - 1, 'character': 0}, 'end': {'line': line1 - 1, 'character': 1}}}]}], '', {})
    endif
  }
  buf.BufLspServerSet(bufnr(), srv)
  lsp.AutoFix(1, 3)
  assert_equal(['ok.2', 'ok.1'], execCmds)

  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srv)
  :bw!
enddef

def g:Test_LspAutoFix_Range_MultiServer_WaitsForAllReplies()
  silent! edit XLspAutoFixRangeMultiServer.txt
  set filetype=text
  setline(1, ['a', 'b'])
  var diags = [
    {'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 1}}, 'message': 'diag1'},
    {'range': {'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 1}}, 'message': 'diag2'},
  ]
  SeedBufferDiagnostics(diags)

  var execErr: list<string> = []
  var execOk: list<string> = []
  var srvErr = MakeCodeActionServer('srvErr', [], execErr)
  var srvOk = MakeCodeActionServer('srvOk', [], execOk)

  srvErr.codeActionAsync = (_fname, _line1, _line2, _query, Cbfunc) => {
    Cbfunc(srvErr, [], '', {code: -32603, message: 'simulated rpc error'})
  }
  srvOk.codeActionAsync = (_fname, line1, _line2, _query, Cbfunc) => {
    Cbfunc(srvOk, [{
      title: 'Preferred',
      isPreferred: true,
      command: 'ok.' .. line1,
      diagnostics: [{
        range: {
          start: {line: line1 - 1, character: 0},
          end: {line: line1 - 1, character: 1}}}]}], '', {})
  }

  buf.BufLspServerSet(bufnr(), srvErr)
  buf.BufLspServerSet(bufnr(), srvOk)

  lsp.AutoFix(1, 2)

  assert_equal([], execErr)
  assert_equal(['ok.2', 'ok.1'], execOk)

  ClearBufferDiagnostics()
  buf.BufLspServerRemove(bufnr(), srvErr)
  buf.BufLspServerRemove(bufnr(), srvOk)
  :bw!
enddef

def g:Test_TextdocDidChange_IncrementalSync_MultiHunkDeleteAppliesBottomUp()
  # Regression test for #836: deleting all the lines but an empty one
  # produces two diff hunks; emitting them top-down sends the second hunk's
  # range against a document already shrunk by the first, desyncing the
  # server.  (":%d" leaves no lines, which is sent as a full-text change.)
  if !opt.incrementalSyncSupported
    # incrementalSync needs diff(); options.OptionsSet() forces it back off
    # without it, same as the plugin itself falling back to full sync.
    return
  endif
  g:LspOptionsSet({incrementalSync: true})
  silent! edit XIncrementalMultiHunkDelete.c
  var oldLines = ['#include <stdio.h>', '', 'int main() {',
	'    printf("hello world\n");', '    return 0;', '}']
  setline(1, oldLines)

  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  var bnr = bufnr()
  lspserver.cachedBufferContent[bnr] = oldLines
  lspserver.cachedBufferEol[bnr] = true

  :3,$d
  :1d
  lspserver.textdocDidChange(bnr)

  assert_equal(1, notifications->len())
  assert_equal('textDocument/didChange', notifications[0].method)
  var changes = notifications[0].params.contentChanges
  assert_equal(2, changes->len())
  assert_equal({line: 2, character: 0}, changes[0].range.start)
  assert_equal({line: 6, character: 0}, changes[0].range.end)
  assert_equal('', changes[0].text)
  assert_equal({line: 0, character: 0}, changes[1].range.start)
  assert_equal({line: 1, character: 0}, changes[1].range.end)
  assert_equal('', changes[1].text)

  g:LspOptionsSet({incrementalSync: false})
  :%bw!
enddef

def g:Test_TextdocDidChange_IncrementalSync_MultiHunkInsertDescendingOrder()
  if !opt.incrementalSyncSupported
    return
  endif
  g:LspOptionsSet({incrementalSync: true})
  silent! edit XIncrementalMultiHunkInsert.txt
  var oldLines = ['one', 'two', 'three']
  setline(1, oldLines)

  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  var bnr = bufnr()
  lspserver.cachedBufferContent[bnr] = oldLines
  lspserver.cachedBufferEol[bnr] = true

  setline(1, ['zero', 'one', 'two', 'inserted', 'three'])
  lspserver.textdocDidChange(bnr)

  var changes = notifications[0].params.contentChanges
  assert_equal(2, changes->len())
  assert_equal({line: 2, character: 0}, changes[0].range.start)
  assert_equal({line: 2, character: 0}, changes[0].range.end)
  assert_equal("inserted\n", changes[0].text)
  assert_equal({line: 0, character: 0}, changes[1].range.start)
  assert_equal({line: 0, character: 0}, changes[1].range.end)
  assert_equal("zero\n", changes[1].text)

  g:LspOptionsSet({incrementalSync: false})
  :%bw!
enddef

def g:Test_TextdocDidChange_IncrementalSync_NoEolAnchorsToLastLineEnd()
  # Regression test: without a trailing newline, a hunk reaching the end of
  # the document must anchor to the end of the last line, not to a
  # {line: lineCount, character: 0} position that doesn't exist.
  if !opt.incrementalSyncSupported
    return
  endif
  g:LspOptionsSet({incrementalSync: true})
  silent! edit XIncrementalNoEol.txt
  var oldLines = ['abc', 'def', 'ghi']
  setline(1, oldLines)
  setlocal noeol nofixeol

  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  var bnr = bufnr()
  lspserver.cachedBufferContent[bnr] = oldLines
  lspserver.cachedBufferEol[bnr] = false

  :$d
  lspserver.textdocDidChange(bnr)

  var changes = notifications[0].params.contentChanges
  assert_equal(1, changes->len())
  assert_equal({line: 1, character: 3}, changes[0].range.start)
  assert_equal({line: 2, character: 3}, changes[0].range.end)
  assert_equal('', changes[0].text)

  g:LspOptionsSet({incrementalSync: false})
  :%bw!
enddef

# Without a trailing newline, a hunk whose new text is a single empty last
# line still adds a line break, so it must not be sent as an empty change.
def g:Test_TextdocDidChange_IncrementalSync_NoEolEmptyLastLine()
  if !opt.incrementalSyncSupported
    return
  endif
  g:LspOptionsSet({incrementalSync: true})
  silent! edit XIncrementalNoEolEmptyLine.txt
  setline(1, ['abc', 'def'])
  setlocal noeol nofixeol

  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  var bnr = bufnr()
  lspserver.cachedBufferContent[bnr] = ['abc', 'def']
  lspserver.cachedBufferEol[bnr] = false

  append('$', '')
  lspserver.textdocDidChange(bnr)
  assert_equal([{range: {start: {line: 1, character: 3},
			 end: {line: 1, character: 3}},
		 text: "\n"}],
	       notifications[-1].params.contentChanges)

  :$d
  setline(2, '')
  lspserver.cachedBufferContent[bnr] = ['abc', 'def']
  lspserver.textdocDidChange(bnr)
  assert_equal([{range: {start: {line: 0, character: 3},
			 end: {line: 1, character: 3}},
		 text: "\n"}],
	       notifications[-1].params.contentChanges)

  g:LspOptionsSet({incrementalSync: false})
  :%bw!
enddef

# The document sent to the server ends with a newline exactly when Vim ends
# the written file with one: 'endofline' is set, or 'fixendofline' is set and
# 'binary' is not.
def g:Test_TextdocDidOpen_TrailingNewlineFollowsWriteRule()
  silent! edit XDidOpenTrailingNewline.txt
  setline(1, ['abc', 'def'])
  var bnr = bufnr()
  var cases: list<list<any>> = [
    ['noeol fixeol nobinary', true],
    ['noeol nofixeol nobinary', false],
    ['noeol fixeol binary', false],
    ['eol nofixeol binary', true],
  ]
  for [opts, hasEol] in cases
    exe $'setlocal {opts}'
    var notifications: list<dict<any>> = []
    var lspserver = MakeTestLspServer(notifications)
    lspserver.supportsDidOpenClose = true
    lspserver.textdocDidOpen(bnr, 'text')
    assert_equal(hasEol ? "abc\ndef\n" : "abc\ndef",
		 notifications[0].params.textDocument.text, opts)
    assert_equal(hasEol, lspserver.cachedBufferEol[bnr], opts)
  endfor

  :%bw!
enddef

def g:Test_TextdocDidChange_FullSync_TrailingNewlineFollowsWriteRule()
  silent! edit XFullSyncTrailingNewline.txt
  setline(1, ['abc', 'def'])
  setlocal noeol fixeol nobinary

  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.textDocumentSync = 1
  var bnr = bufnr()

  lspserver.textdocDidChange(bnr)
  assert_equal([{text: "abc\ndef\n"}], notifications[-1].params.contentChanges)

  setlocal nofixeol
  lspserver.textdocDidChange(bnr)
  assert_equal([{text: "abc\ndef"}], notifications[-1].params.contentChanges)

  :%bw!
enddef

# A buffer read from a file without a trailing newline is still written with
# one when 'fixendofline' is set, so a line appended after the last one comes
# after that newline in the server's document.
def g:Test_TextdocDidChange_IncrementalSync_FixEolAppendLine()
  if !opt.incrementalSyncSupported
    return
  endif
  g:LspOptionsSet({incrementalSync: true})
  silent! edit XIncrementalFixEol.txt
  setline(1, ['abc', 'def'])
  setlocal noeol fixeol nobinary

  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.supportsDidOpenClose = true
  var bnr = bufnr()
  lspserver.textdocDidOpen(bnr, 'text')
  assert_equal("abc\ndef\n", notifications[-1].params.textDocument.text)

  append('$', '')
  lspserver.textdocDidChange(bnr)
  assert_equal([{range: {start: {line: 2, character: 0},
			 end: {line: 2, character: 0}},
		 text: "\n"}],
	       notifications[-1].params.contentChanges)

  g:LspOptionsSet({incrementalSync: false})
  :%bw!
enddef

# Changing 'fixendofline' or 'binary' changes whether the document ends with
# a newline without changing any line, so the next change resends the full
# text instead of a diff against the cached document.
def g:Test_TextdocDidChange_IncrementalSync_WriteRuleToggleSendsFullText()
  if !opt.incrementalSyncSupported
    return
  endif
  g:LspOptionsSet({incrementalSync: true})
  silent! edit XIncrementalEolToggle.txt
  setline(1, ['abc', 'def'])
  setlocal noeol fixeol nobinary

  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  var bnr = bufnr()
  lspserver.textdocDidOpen(bnr, 'text')
  assert_true(lspserver.cachedBufferEol[bnr])

  setlocal binary
  setline(1, 'xyz')
  lspserver.textdocDidChange(bnr)
  assert_equal([{text: "xyz\ndef"}], notifications[-1].params.contentChanges)
  assert_false(lspserver.cachedBufferEol[bnr])

  setlocal nobinary
  setline(2, 'ghi')
  lspserver.textdocDidChange(bnr)
  assert_equal([{text: "xyz\nghi\n"}], notifications[-1].params.contentChanges)
  assert_true(lspserver.cachedBufferEol[bnr])

  setlocal nofixeol
  setline(1, 'abc')
  lspserver.textdocDidChange(bnr)
  assert_equal([{text: "abc\nghi"}], notifications[-1].params.contentChanges)
  assert_false(lspserver.cachedBufferEol[bnr])

  g:LspOptionsSet({incrementalSync: false})
  :%bw!
enddef

# Setting 'endofline', 'fixendofline' or 'binary' can add or remove the
# newline at the end of the document without changing a line or
# 'changedtick', which the listener doesn't see, so the change is sent when
# the option is set, with a greater version.
def g:Test_EolOptionSet_SendsChange()
  for incrementalSync in (exists('*diff') ? [false, true] : [false])
    g:LspOptionsSet({incrementalSync: incrementalSync})
    silent! edit XEolOptionSet.txt
    setline(1, ['abc', 'def'])
    setlocal eol fixeol nobinary
    var bnr = bufnr()
    var notifications: list<dict<any>> = []
    var lspserver = MakeTestLspServer(notifications)
    lspserver.running = true
    lspserver.ready = true
    buf.BufLspServerSet(bnr, lspserver)
    lspserver.textdocDidOpen(bnr, 'text')
    var listenerId = listener_add((changedBnr, _, _, _, _) => {
      lspserver.textdocDidChange(changedBnr)
    }, bnr)
    var msg = $'incrementalSync: {incrementalSync}'
    # OptionSet is not triggered while Vim is starting
    test_override('starting', 1)
    try
      # 'fixendofline' still adds the newline
      setlocal noeol
      setglobal nofixeol
      assert_equal([], notifications, msg)

      setlocal nofixeol
      assert_equal(1, notifications->len(), msg)
      assert_equal([{text: "abc\ndef"}],
		   notifications[-1].params.contentChanges, msg)
      var version = notifications[-1].params.textDocument.version
      assert_equal(b:changedtick + 1, version, msg)

      # No newline without 'binary' either
      setlocal binary
      assert_equal(1, notifications->len(), msg)

      # A pending change is sent first, with the newline
      setline(1, 'xyz')
      setlocal eol
      listener_flush(bnr)
      assert_equal(2, notifications->len(), msg)
      assert_equal("xyz\ndef\n",
		   notifications[-1].params.contentChanges[-1].text, msg)
      assert_true(notifications[-1].params.textDocument.version > version,
		  msg)
      version = notifications[-1].params.textDocument.version

      # Set for the buffer in another window
      new
      setbufvar(bnr, '&endofline', false)
      assert_equal(3, notifications->len(), msg)
      assert_equal([{text: "xyz\ndef"}],
		   notifications[-1].params.contentChanges, msg)
      assert_equal(version + 1,
		   notifications[-1].params.textDocument.version, msg)
    finally
      test_override('starting', 0)
      setglobal fixeol
      listener_remove(listenerId)
      buf.BufLspServerRemove(bnr, lspserver)
      :%bw!
    endtry
  endfor
  g:LspOptionsSet({incrementalSync: false})
enddef

# A buffer without lines has no text, but getbufline() returns one empty line
# for it, like for a buffer with one empty line, which Vim writes as a
# newline.
def g:Test_TextdocDidOpen_BufferWithoutLines()
  silent! edit XDidOpenNoLines.txt
  var bnr = bufnr()
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.supportsDidOpenClose = true

  lspserver.textdocDidOpen(bnr, 'text')
  assert_equal('', notifications[-1].params.textDocument.text)

  setline(1, '')
  lspserver.textdocDidOpen(bnr, 'text')
  assert_equal("\n", notifications[-1].params.textDocument.text)

  setline(1, 'abc')
  :%d
  lspserver.textdocDidOpen(bnr, 'text')
  assert_equal('', notifications[-1].params.textDocument.text)

  # The buffer in another window
  new
  lspserver.textdocDidOpen(bnr, 'text')
  assert_equal('', notifications[-1].params.textDocument.text)
  setbufline(bnr, 1, '')
  lspserver.textdocDidOpen(bnr, 'text')
  assert_equal("\n", notifications[-1].params.textDocument.text)

  # The buffer in no window
  setbufvar(bnr, '&bufhidden', 'hide')
  :only
  assert_equal([], win_findbuf(bnr))
  lspserver.textdocDidOpen(bnr, 'text')
  assert_equal("\n", notifications[-1].params.textDocument.text)
  deletebufline(bnr, 1, '$')
  lspserver.textdocDidOpen(bnr, 'text')
  assert_equal('', notifications[-1].params.textDocument.text)

  :%bw!
enddef

def g:Test_TextdocDidChange_BufferWithoutLines()
  for incrementalSync in (exists('*diff') ? [false, true] : [false])
    g:LspOptionsSet({incrementalSync: incrementalSync})
    silent! edit XDidChangeNoLines.txt
    setline(1, ['abc', 'def'])
    var bnr = bufnr()
    var notifications: list<dict<any>> = []
    var lspserver = MakeTestLspServer(notifications)
    lspserver.textdocDidOpen(bnr, 'text')
    var msg = $'incrementalSync: {incrementalSync}'

    :%d
    lspserver.textdocDidChange(bnr)
    assert_equal([{text: ''}], notifications[-1].params.contentChanges, msg)

    setline(1, '')
    lspserver.textdocDidChange(bnr)
    assert_equal([{text: "\n"}], notifications[-1].params.contentChanges,
		 msg)

    :%d
    setlocal noeol nofixeol
    lspserver.textdocDidChange(bnr)
    assert_equal([{text: ''}], notifications[-1].params.contentChanges, msg)

    setline(1, 'abc')
    lspserver.textdocDidChange(bnr)
    assert_equal([{text: 'abc'}], notifications[-1].params.contentChanges,
		 msg)

    :%bw!
  endfor
  g:LspOptionsSet({incrementalSync: false})
enddef

# Text edits are relative to the server's document, which ends with a newline
# exactly when Vim writes one, so a range ending on the line after the last
# one covers the whole last line.
def g:Test_ApplyTextEdits_WholeDocumentFollowsWriteRule()
  silent! edit XApplyTextEditsEol.txt
  var bnr = bufnr()
  var withEol = {range: {start: {line: 0, character: 0},
			 end: {line: 2, character: 0}},
		 newText: "xxx\nyyy\n"}
  var withoutEol = {range: {start: {line: 0, character: 0},
			    end: {line: 1, character: 3}},
		    newText: "xxx\nyyy"}
  var cases: list<list<any>> = [
    ['noeol fixeol nobinary', withEol],
    ['eol nofixeol nobinary', withEol],
    ['eol fixeol binary', withEol],
    ['noeol nofixeol nobinary', withoutEol],
    ['noeol fixeol binary', withoutEol],
  ]
  for [opts, edit] in cases
    :%d
    setline(1, ['aaa', 'bbb'])
    exe $'setlocal {opts}'
    textedit.ApplyTextEdits(bnr, [edit])
    assert_equal(['xxx', 'yyy'], getline(1, '$'), opts)
  endfor

  :%bw!
enddef

# Returns a TextEdit that replaces the text from line "sline", character
# "schar" to line "eline", character "echar" with "text".
def MakeTextEdit(sline: number, schar: number, eline: number, echar: number,
		 text: string): dict<any>
  return {range: {start: {line: sline, character: schar},
		  end: {line: eline, character: echar}},
	  newText: text}
enddef

# Returns the text that Vim writes for the current buffer.
def WrittenText(): string
  var fname = 'XWrittenText.txt'
  exe $'silent noautocmd keepalt write! {fname}'
  var text = readfile(fname, 'b')->join("\n")
  delete(fname)
  return text
enddef

# getbufline() returns one empty line both for a buffer without lines and for
# a buffer with one empty line.  The first one is the empty document.  When
# Vim writes a newline at the end, the second one is the document "\n";
# otherwise it is the empty document too, and a newline inserted at its end
# leaves an empty last line.  Edits past the end of the empty document are
# for the document "\n".
def g:Test_ApplyTextEdits_EmptyBuffer()
  silent! edit XApplyTextEditsEmpty.txt
  var bnr = bufnr()
  # The edits, and the lines after them in a buffer without lines and in a
  # buffer with one empty line
  var withEol: list<list<any>> = [
    [[MakeTextEdit(0, 0, 0, 0, "foo\n")], ['foo'], ['foo', '']],
    [[MakeTextEdit(0, 0, 0, 0, 'foo')], ['foo'], ['foo']],
    [[MakeTextEdit(0, 0, 1, 0, "foo\n")], ['foo'], ['foo']],
    [[MakeTextEdit(0, 0, 1, 0, '')], [''], ['']],
    [[MakeTextEdit(1, 0, 1, 0, "foo\n")], ['', 'foo'], ['', 'foo']],
    [[MakeTextEdit(1, 0, 1, 0, 'foo')], ['', 'foo'], ['', 'foo']],
    [[MakeTextEdit(0, 0, 0, 0, "a\n"), MakeTextEdit(0, 0, 0, 0, "b\n")],
     ['a', 'b'], ['a', 'b', '']],
    [[MakeTextEdit(0, 0, 0, 0, 'a'), MakeTextEdit(1, 0, 1, 0, "b\n")],
     ['a', 'b'], ['a', 'b']],
  ]
  var withoutEol: list<list<any>> = [
    [[MakeTextEdit(0, 0, 0, 0, "foo\n")], ['foo', ''], ['foo', '']],
    [[MakeTextEdit(0, 0, 0, 0, 'foo')], ['foo'], ['foo']],
    [[MakeTextEdit(0, 0, 0, 0, "a\n"), MakeTextEdit(0, 0, 0, 0, "b\n")],
     ['a', 'b', ''], ['a', 'b', '']],
  ]
  var cases: list<list<any>> = [
    ['eol fixeol nobinary', withEol],
    ['noeol fixeol nobinary', withEol],
    ['eol nofixeol nobinary', withEol],
    ['eol fixeol binary', withEol],
    ['noeol nofixeol nobinary', withoutEol],
    ['noeol fixeol binary', withoutEol],
  ]
  for [opts, editCases] in cases
    for [textEdits, expectedNoLines, expectedOneEmptyLine] in editCases
      for oneEmptyLine in [false, true]
	:%d
	if oneEmptyLine
	  setline(1, '')
	endif
	exe $'setlocal {opts}'
	textedit.ApplyTextEdits(bnr, textEdits)
	assert_equal(oneEmptyLine ? expectedOneEmptyLine : expectedNoLines,
		     getline(1, '$'),
		     $'{opts}, one empty line: {oneEmptyLine}, {textEdits}')
      endfor
    endfor
  endfor

  :%bw!
enddef

# The empty last line of a buffer with lines ['abc', ''] is a line of the
# document, followed by the empty line after the newline that Vim writes at
# the end, if it writes one.  Edits at it, before it and replacing it apply
# to that document, with the text that Vim writes after them as expected.
def g:Test_ApplyTextEdits_EmptyLastLine()
  silent! edit XApplyTextEditsEmptyLast.txt
  var bnr = bufnr()
  # Document "abc\n\n"
  var withEol: list<list<any>> = [
    # Insert at the empty line
    [[MakeTextEdit(1, 0, 1, 0, "x\n")], "abc\nx\n\n"],
    [[MakeTextEdit(1, 0, 1, 0, 'x')], "abc\nx\n"],
    # Insert before it
    [[MakeTextEdit(0, 3, 0, 3, "\nx")], "abc\nx\n\n"],
    [[MakeTextEdit(0, 3, 1, 0, "\nx\n")], "abc\nx\n\n"],
    [[MakeTextEdit(0, 0, 1, 0, '')], "\n"],
    # Replace it
    [[MakeTextEdit(1, 0, 2, 0, "x\n")], "abc\nx\n"],
    [[MakeTextEdit(1, 0, 2, 0, '')], "abc\n"],
    [[MakeTextEdit(0, 3, 1, 0, '')], "abc\n"],
    # Span into the line after the newline at the end
    [[MakeTextEdit(0, 1, 2, 0, "x\ny\n")], "ax\ny\n"],
    [[MakeTextEdit(1, 0, 2, 0, "x\ny\n")], "abc\nx\ny\n"],
    [[MakeTextEdit(0, 0, 2, 0, "x\n\n")], "x\n\n"],
    [[MakeTextEdit(0, 0, 2, 0, '')], ''],
  ]
  # Document "abc\n"
  var withoutEol: list<list<any>> = [
    [[MakeTextEdit(1, 0, 1, 0, "x\n")], "abc\nx\n"],
    [[MakeTextEdit(1, 0, 1, 0, 'x')], "abc\nx"],
    [[MakeTextEdit(0, 3, 0, 3, "\nx")], "abc\nx\n"],
    [[MakeTextEdit(0, 3, 1, 0, "\nx\n")], "abc\nx\n"],
    [[MakeTextEdit(0, 3, 1, 0, '')], 'abc'],
    [[MakeTextEdit(0, 1, 1, 0, "x\ny\n")], "ax\ny\n"],
    [[MakeTextEdit(0, 0, 1, 0, '')], ''],
  ]
  var cases: list<list<any>> = [
    ['eol fixeol nobinary', withEol],
    ['noeol fixeol nobinary', withEol],
    ['eol nofixeol nobinary', withEol],
    ['eol fixeol binary', withEol],
    ['noeol nofixeol nobinary', withoutEol],
    ['noeol fixeol binary', withoutEol],
  ]
  for [opts, editCases] in cases
    for [textEdits, expected] in editCases
      :%d
      setline(1, ['abc', ''])
      exe $'setlocal {opts}'
      textedit.ApplyTextEdits(bnr, textEdits)
      assert_equal(expected, WrittenText(), $'{opts}, {textEdits}')
    endfor
  endfor

  :%bw!
enddef

# Edits past the end of the document are for the document with one more line
# break at its end, and a position on a later line is at the start of the
# line after that line break.  Checked for a buffer with line 'abc'.
def g:Test_ApplyTextEdits_PastEndOfDocument()
  silent! edit XApplyTextEditsPastEnd.txt
  var bnr = bufnr()
  # Document "abc\n"
  var withEol: list<list<any>> = [
    [[MakeTextEdit(2, 0, 2, 0, "x\n")], "abc\n\nx\n"],
    [[MakeTextEdit(5, 2, 5, 2, "x\n")], "abc\n\nx\n"],
    [[MakeTextEdit(0, 1, 3, 0, "x\n")], "ax\n"],
    [[MakeTextEdit(2, 0, 2, 0, 'x'), MakeTextEdit(2, 0, 2, 0, "y\n")],
     "abc\n\nxy\n"],
  ]
  # Document "abc"
  var withoutEol: list<list<any>> = [
    [[MakeTextEdit(1, 0, 1, 0, "x\n")], "abc\nx\n"],
    [[MakeTextEdit(1, 0, 1, 0, 'x')], "abc\nx"],
    [[MakeTextEdit(0, 0, 1, 0, "x\n")], "x\n"],
    [[MakeTextEdit(0, 1, 1, 0, 'x')], 'ax'],
    [[MakeTextEdit(1, 0, 1, 0, 'x'), MakeTextEdit(1, 0, 1, 0, 'y')],
     "abc\nxy"],
  ]
  var cases: list<list<any>> = [
    ['eol fixeol nobinary', withEol],
    ['noeol fixeol nobinary', withEol],
    ['eol nofixeol nobinary', withEol],
    ['eol fixeol binary', withEol],
    ['noeol nofixeol nobinary', withoutEol],
    ['noeol fixeol binary', withoutEol],
  ]
  for [opts, editCases] in cases
    for [textEdits, expected] in editCases
      :%d
      setline(1, 'abc')
      exe $'setlocal {opts}'
      textedit.ApplyTextEdits(bnr, textEdits)
      assert_equal(expected, WrittenText(), $'{opts}, {textEdits}')
    endfor
  endfor

  :%bw!
enddef

# When Vim writes a newline at the end, an edit can insert text on the empty
# line after it.
def g:Test_ApplyTextEdits_InsertAfterLastLine()
  silent! edit XApplyTextEditsAfterLast.txt
  var bnr = bufnr()
  var cases: list<list<any>> = [
    [['abc'], [MakeTextEdit(1, 0, 1, 0, "x\n")], ['abc', 'x']],
    [['abc'], [MakeTextEdit(1, 0, 1, 0, "x\ny\nz\n")], ['abc', 'x', 'y', 'z']],
    [['abc', ''], [MakeTextEdit(2, 0, 2, 0, "x\n")], ['abc', '', 'x']],
    [['abc', ''], [MakeTextEdit(1, 0, 1, 0, "x\n"),
		   MakeTextEdit(2, 0, 2, 0, "y\n")], ['abc', 'x', '', 'y']],
  ]
  for [text, textEdits, expected] in cases
    :%d
    setline(1, text)
    textedit.ApplyTextEdits(bnr, textEdits)
    assert_equal(expected, getline(1, '$'), $'{text}, {textEdits}')
  endfor

  :%bw!
enddef

# A workspace edit inserts text in an empty file that it creates first, or
# that exists but is not loaded.  The buffer is then loaded from the file,
# without a window.
def g:Test_ApplyWorkspaceEdit_EditsEmptyFile()
  var fname = 'XWorkspaceEditEmpty.txt'
  var uri = util.LspFileToUri(fname)
  var insert = MakeTextEdit(0, 0, 0, 0, "line1\nline2\n")
  try
    var createAndEdit = {documentChanges: [
      {kind: 'create', uri: uri},
      {textDocument: {uri: uri, version: v:null}, edits: [insert]}
    ]}
    textedit.ApplyWorkspaceEdit(createAndEdit)
    assert_equal([], win_findbuf(bufnr(fname)))
    assert_equal(['line1', 'line2'], getbufline(fname, 1, '$'))
    exe $'bwipe! {fname}'

    writefile([], fname)
    var changes = {changes: {[uri]: [insert]}}
    textedit.ApplyWorkspaceEdit(changes)
    assert_equal([], win_findbuf(bufnr(fname)))
    assert_equal(['line1', 'line2'], getbufline(fname, 1, '$'))
  finally
    exe $'silent! bwipe! {fname}'
    delete(fname)
  endtry
enddef

# Returns pairs of a file name and the name of a decoy file.  Used as a file
# pattern, like bufnr() and bufwinid() use a String, the file name matches the
# whole decoy file name or a part of it.
def PatternDecoys(): list<list<string>>
  return [
    ['XExactName[1].c', 'XExactName1.c'],
    ['XExactName*.c', 'XExactNameb.c'],
    ['XExactName.c', 'XExactName.c.orig']
  ]
enddef

# Returns "result" in a reply to a request.  Stands in for lspserver.rpc().
def StubRpcReply(result: any, method: string, params: any,
		 opts: dict<any> = {}): dict<any>
  return {result: result->deepcopy()}
enddef

# Returns a running and ready language server that replies "result" to every
# request.
def MakeReplyingLspServer(result: any): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.rpc = function(StubRpcReply, [result])
  return lspserver
enddef

# Test that the diagnostics for a file are stored for the buffer of the file,
# not for a buffer that the file name matches as a file pattern.
def g:Test_DiagNotification_FileNameIsNotAPattern()
  DiagInitOnce()
  for [target, decoy] in PatternDecoys()
    writefile(['int target;'], target)
    writefile(['int decoy;'], decoy)
    try
      exe $'edit {decoy->fnameescape()}'
      var decoyBnr = bufnr()
      # An unlisted buffer, like the buffer of a file changed by a workspace
      # edit
      var targetBnr = target->bufadd()
      targetBnr->bufload()

      diag.DiagNotification(MakeDiagServer('srv'), util.LspFileToUri(target),
			    [MakeLineDiag(0, 'target diag')], 'push')
      var targetMsgs = diag.GetDiagsForBuf(targetBnr)
	->mapnew((_, d) => d.message)
      assert_equal(['target diag'], targetMsgs, target)
      assert_equal([], diag.GetDiagsForBuf(decoyBnr), target)
      diag.DiagRemoveFile(targetBnr)
      diag.DiagRemoveFile(decoyBnr)
    finally
      :%bw!
      delete(target)
      delete(decoy)
    endtry
  endfor
enddef

# Test that ":LspGotoDefinition" jumps to the buffer of the file with the
# definition, not to a buffer that the file name matches as a file pattern.
def g:Test_LspGotoDefinition_FileNameIsNotAPattern()
  var pos = {line: 0, character: 4}
  for [target, decoy] in PatternDecoys()
    writefile(['int target;'], target)
    writefile(['int decoy;'], decoy)
    var lspserver = MakeReplyingLspServer(
      {uri: util.LspFileToUri(target), range: {start: pos, end: pos}})
    lspserver.isDefinitionProvider = true
    try
      exe $'edit {decoy->fnameescape()}'
      edit XGotoSource.c
      var srcBnr = bufnr()
      buf.BufLspServerSet(srcBnr, lspserver)
      :LspGotoDefinition
      buf.BufLspServerRemove(srcBnr, lspserver)
      assert_equal([target, 'int target;', [1, 5]],
		   [expand('%:t'), getline(1), getpos('.')[1 : 2]], target)
    finally
      :%bw!
      delete(target)
      delete(decoy)
    endtry
  endfor
enddef

# Test that ":LspFormat" changes the current buffer, not a buffer that the name
# of the current file matches as a file pattern.
def g:Test_LspFormat_FileNameIsNotAPattern()
  for [target, decoy] in PatternDecoys()
    writefile(['int  target;'], target)
    writefile(['int  decoy;'], decoy)
    var lspserver = MakeReplyingLspServer([MakeTextEdit(0, 3, 0, 4, '')])
    lspserver.isDocumentFormattingProvider = true
    try
      exe $'edit {decoy->fnameescape()}'
      var decoyBnr = bufnr()
      exe $'edit {target->fnameescape()}'
      buf.BufLspServerSet(bufnr(), lspserver)
      :LspFormat
      buf.BufLspServerRemove(bufnr(), lspserver)
      assert_equal(['int target;'], getline(1, '$'), target)
      assert_false(decoyBnr->getbufvar('&modified'), target)
    finally
      :%bw!
      delete(target)
      delete(decoy)
    endtry
  endfor
enddef

# Test that a workspace edit changes the buffer of the file it is for, not a
# buffer that the file name matches as a file pattern.
def g:Test_ApplyWorkspaceEdit_FileNameIsNotAPattern()
  for [target, decoy] in PatternDecoys()
    writefile(['int target;'], target)
    writefile(['int decoy;'], decoy)
    var uri = util.LspFileToUri(target)
    var changes = {changes: {[uri]: [MakeTextEdit(0, 4, 0, 10, 'edited')]}}
    var docEdit = {textDocument: {uri: uri, version: v:null},
		   edits: [MakeTextEdit(0, 0, 0, 3, 'long')]}
    try
      exe $'edit {decoy->fnameescape()}'
      var decoyBnr = bufnr()
      textedit.ApplyWorkspaceEdit(changes)
      textedit.ApplyWorkspaceEdit({documentChanges: [docEdit]})
      assert_equal(['long edited;'], target->bufadd()->getbufline(1, '$'),
		   target)
      assert_equal(['int decoy;'], decoyBnr->getbufline(1, '$'), target)
      assert_false(decoyBnr->getbufvar('&modified'), target)
    finally
      :%bw!
      delete(target)
      delete(decoy)
    endtry
  endfor
enddef

# Returns a TextDocumentEdit inserting "text" at the start of the document
# with URI "uri".
def MakeInsertEdit(uri: string, text: string): dict<any>
  return {textDocument: {uri: uri, version: v:null},
	  edits: [MakeTextEdit(0, 0, 0, 0, text)]}
enddef

# Applies a workspace edit made of the resource operation "op".
def ApplyResourceOp(op: dict<any>)
  textedit.ApplyWorkspaceEdit({documentChanges: [op]})
enddef

# Creating a file over an existing one that is loaded in a buffer empties the
# buffer too, so that the text edits that follow apply to the new, empty,
# document.  The buffer keeps its undo history.
def g:Test_ApplyWorkspaceEdit_CreateOverwritesLoadedBuffer()
  var fname = 'XWorkspaceEditCreate.txt'
  var uri = util.LspFileToUri(fname)
  var createAndEdit = {documentChanges: [
    {kind: 'create', uri: uri, options: {overwrite: true}},
    MakeInsertEdit(uri, "new\n")
  ]}
  try
    writefile(['old1', 'old2'], fname)
    var bnr = bufadd(fname)
    bufload(bnr)
    textedit.ApplyWorkspaceEdit(createAndEdit)
    assert_equal([], readfile(fname))
    assert_equal(['new'], getbufline(bnr, 1, '$'))
    exe $'bwipe! {bnr}'

    writefile(['old1', 'old2'], fname)
    exe $'edit {fname}'
    textedit.ApplyWorkspaceEdit(createAndEdit)
    assert_equal([], readfile(fname))
    assert_equal(['new'], getline(1, '$'))
    silent undo 0
    assert_equal(['old1', 'old2'], getline(1, '$'))
  finally
    delete(fname)
    :%bwipe!
  endtry
enddef

# Creating a file over one whose buffer has unsaved changes fails, and leaves
# both unchanged.
def g:Test_ApplyWorkspaceEdit_CreateKeepsModifiedBuffer()
  var fname = 'XWorkspaceEditCreateModified.txt'
  var uri = util.LspFileToUri(fname)
  try
    writefile(['old'], fname)
    var bnr = bufadd(fname)
    bufload(bnr)
    setbufline(bnr, 1, 'unsaved')
    ApplyResourceOp({kind: 'create', uri: uri, options: {overwrite: true}})
    assert_equal('Error: File create failed, '
		 .. $'{util.LspUriToFile(uri)} has unsaved changes', LastMessage())
    assert_equal(['old'], readfile(fname))
    assert_equal(['unsaved'], getbufline(bnr, 1, '$'))
    assert_true(getbufvar(bnr, '&modified'))
  finally
    delete(fname)
    :%bwipe!
  endtry
enddef

# Creating a file that exists fails, unless "overwrite" or "ignoreIfExists"
# is set.  A directory is never overwritten.
def g:Test_ApplyWorkspaceEdit_CreateExistingFile()
  var fname = 'XWorkspaceEditCreateExisting.txt'
  var dname = 'XWorkspaceEditCreateDir'
  var uri = util.LspFileToUri(fname)
  try
    writefile(['old'], fname)
    ApplyResourceOp({kind: 'create', uri: uri})
    assert_equal('Error: File create failed, '
		 .. $'{util.LspUriToFile(uri)} already exists', LastMessage())
    assert_equal(['old'], readfile(fname))

    var messages = execute('messages')
    ApplyResourceOp({kind: 'create', uri: uri,
		     options: {ignoreIfExists: true}})
    assert_equal(messages, execute('messages'))
    assert_equal(['old'], readfile(fname))

    ApplyResourceOp({kind: 'create', uri: uri,
		     options: {overwrite: true, ignoreIfExists: true}})
    assert_equal(messages, execute('messages'))
    assert_equal([], readfile(fname))

    mkdir(dname)
    var duri = util.LspFileToUri(dname)
    ApplyResourceOp({kind: 'create', uri: duri})
    assert_equal('Error: File create failed, '
		 .. $'{util.LspUriToFile(duri)} already exists', LastMessage())
    ApplyResourceOp({kind: 'create', uri: duri, options: {overwrite: true}})
    assert_equal('Error: File create failed, '
		 .. $'{util.LspUriToFile(duri)} is a directory', LastMessage())
    messages = execute('messages')
    ApplyResourceOp({kind: 'create', uri: duri,
		     options: {ignoreIfExists: true}})
    assert_equal(messages, execute('messages'))
    assert_true(isdirectory(dname))
  finally
    delete(fname)
    delete(dname, 'd')
    :%bwipe!
  endtry
enddef

# Returns a RenameFile operation renaming file "from" to "to".
def MakeRename(from: string, to: string, options: dict<bool> = {}): dict<any>
  return {kind: 'rename', oldUri: util.LspFileToUri(from),
	  newUri: util.LspFileToUri(to), options: options}
enddef

# Renaming a file renames its loaded buffer, which keeps its text and undo
# history, so that the text edits that follow apply to it.  The buffer can be
# written with ":write" without "!".
def g:Test_ApplyWorkspaceEdit_RenameLoadedBuffer()
  var from = 'XWorkspaceEditRenameFrom.txt'
  var to = 'XWorkspaceEditRenameTo.txt'
  var renameAndEdit = {documentChanges: [
    MakeRename(from, to),
    MakeInsertEdit(util.LspFileToUri(to), "new\n")
  ]}
  try
    writefile(['one'], from)
    exe $'edit {from}'
    var bnr = bufnr()
    setline(1, 'two')
    write
    textedit.ApplyWorkspaceEdit(renameAndEdit)
    assert_false(filereadable(from))
    assert_equal(['two'], readfile(to))
    assert_equal(bnr, bufnr())
    assert_equal(fnamemodify(to, ':p'), expand('%:p'))
    assert_false(bufexists(fnamemodify(from, ':p')))
    assert_equal(['new', 'two'], getline(1, '$'))
    write
    assert_equal(['new', 'two'], readfile(to))
    silent undo 0
    assert_equal(['one'], getline(1, '$'))
    :%bwipe!

    rename(to, from)
    bnr = bufadd(from)
    bufload(bnr)
    ApplyResourceOp(MakeRename(from, to))
    assert_equal(['new', 'two'], readfile(to))
    assert_equal(fnamemodify(to, ':p'), bnr->getbufinfo()[0].name)
    assert_true(bufloaded(bnr))
    assert_equal([], win_findbuf(bnr))
    assert_false(bufexists(fnamemodify(from, ':p')))
  finally
    delete(from)
    delete(to)
    :%bwipe!
  endtry
enddef

# The buffer of a renamed file keeps its unsaved changes, without writing
# them.
def g:Test_ApplyWorkspaceEdit_RenameModifiedBuffer()
  var from = 'XWorkspaceEditRenameModified.txt'
  var to = 'XWorkspaceEditRenameModifiedTo.txt'
  try
    writefile(['saved'], from)
    var bnr = bufadd(from)
    bufload(bnr)
    setbufline(bnr, 1, 'unsaved')
    ApplyResourceOp(MakeRename(from, to))
    assert_false(filereadable(from))
    assert_equal(['saved'], readfile(to))
    assert_equal(fnamemodify(to, ':p'), bnr->getbufinfo()[0].name)
    assert_equal(['unsaved'], getbufline(bnr, 1, '$'))
    assert_true(getbufvar(bnr, '&modified'))
  finally
    delete(from)
    delete(to)
    :%bwipe!
  endtry
enddef

# Renaming a file over one whose buffer is loaded replaces that buffer, in
# its windows too, unless the buffer has unsaved changes.
def g:Test_ApplyWorkspaceEdit_RenameOverLoadedBuffer()
  var from = 'XWorkspaceEditRenameOverFrom.txt'
  var to = 'XWorkspaceEditRenameOverTo.txt'
  var rename = MakeRename(from, to, {overwrite: true})
  try
    writefile(['from'], from)
    writefile(['to'], to)
    exe $'edit {to}'
    var tbnr = bufnr()
    setline(1, 'unsaved')
    ApplyResourceOp(rename)
    assert_equal('Error: File rename failed, '
		 .. $'{fnamemodify(to, ":p")} has unsaved changes', LastMessage())
    assert_equal(['from'], readfile(from))
    assert_equal(['to'], readfile(to))
    assert_equal(['unsaved'], getline(1, '$'))

    edit!
    ApplyResourceOp(rename)
    assert_false(filereadable(from))
    assert_equal(['from'], readfile(to))
    assert_false(bufexists(tbnr))
    assert_equal(1, winnr('$'))
    assert_equal(fnamemodify(to, ':p'), expand('%:p'))
    assert_equal(['from'], getline(1, '$'))
  finally
    delete(from)
    delete(to)
    :%bwipe!
  endtry
enddef

# Renaming a file to one that exists fails, unless "overwrite" or
# "ignoreIfExists" is set, and so does renaming a file that does not exist.
def g:Test_ApplyWorkspaceEdit_RenameExistingFile()
  var from = 'XWorkspaceEditRenameExistingFrom.txt'
  var to = 'XWorkspaceEditRenameExistingTo.txt'
  try
    writefile(['from'], from)
    writefile(['to'], to)
    ApplyResourceOp(MakeRename(from, to))
    assert_equal('Error: File rename failed, '
		 .. $'{fnamemodify(to, ":p")} already exists', LastMessage())
    assert_equal(['from'], readfile(from))
    assert_equal(['to'], readfile(to))

    var messages = execute('messages')
    ApplyResourceOp(MakeRename(from, to, {ignoreIfExists: true}))
    assert_equal(messages, execute('messages'))
    assert_equal(['from'], readfile(from))
    assert_equal(['to'], readfile(to))

    ApplyResourceOp(MakeRename(from, to,
			       {overwrite: true, ignoreIfExists: true}))
    assert_equal(messages, execute('messages'))
    assert_false(filereadable(from))
    assert_equal(['from'], readfile(to))

    ApplyResourceOp(MakeRename(from, to, {overwrite: true}))
    assert_equal('Error: File rename failed, '
		 .. $'{fnamemodify(from, ":p")} does not exist', LastMessage())
  finally
    delete(from)
    delete(to)
    :%bwipe!
  endtry
enddef

# Renaming a directory renames the buffers of the files in it.  The parent
# of the new directory is created if needed.
def g:Test_ApplyWorkspaceEdit_RenameDirectory()
  var from = 'XWorkspaceEditRenameDir'
  var parent = 'XWorkspaceEditRenameParent'
  var to = $'{parent}/Dir'
  try
    mkdir($'{from}/sub', 'p')
    writefile(['a'], $'{from}/sub/a.txt')
    writefile(['b'], $'{from}/b.txt')
    var abnr = bufadd($'{from}/sub/a.txt')
    bufload(abnr)
    var bbnr = bufadd($'{from}/b.txt')
    setbufvar(bbnr, '&buflisted', true)
    ApplyResourceOp(MakeRename(from, to))
    assert_false(isdirectory(from))
    assert_equal(['a'], readfile($'{to}/sub/a.txt'))
    assert_equal(['b'], readfile($'{to}/b.txt'))
    assert_equal(fnamemodify($'{to}/sub/a.txt', ':p'),
		 abnr->getbufinfo()[0].name)
    assert_equal(['a'], getbufline(abnr, 1, '$'))
    assert_false(bufexists(bbnr))
    assert_true(bufadd($'{to}/b.txt')->buflisted())
  finally
    delete(from, 'rf')
    delete(parent, 'rf')
    :%bwipe!
  endtry
enddef

# A buffer renamed with its file is detached from the language servers for
# its old name, which are notified that the document was closed.
def g:Test_ApplyWorkspaceEdit_RenameDetachesBuffer()
  var from = 'XWorkspaceEditRenameDetach.txt'
  var to = 'XWorkspaceEditRenameDetachTo.txt'
  var notifications: list<dict<any>> = []
  try
    writefile(['text'], from)
    exe $'edit {from}'
    var bnr = bufnr()
    var srv = MakeTestLspServer(notifications)
    srv.running = true
    srv.supportsDidOpenClose = true
    buf.BufLspServerSet(bnr, srv)
    ApplyResourceOp(MakeRename(from, to))
    assert_equal([{method: 'textDocument/didClose',
		   params: {textDocument: {uri: util.LspFileToUri(from)}}}],
		 notifications)
    assert_equal(0, buf.BufLspServersGet(bnr)->len())
  finally
    delete(from)
    delete(to)
    :%bwipe!
  endtry
enddef

# Returns what renaming a hidden buffer in a hidden popup window could change.
def RenameHiddenState(): dict<any>
  return {winid: win_getid(), layout: winlayout(), alt: bufnr('#'),
	  jumps: getjumplist(), curpos: getcurpos(), modified: &modified,
	  popups: popup_list()}
enddef

# A hidden buffer is renamed with its file in a hidden popup window that
# leaves no trace: only the autocommands for renaming the buffer are
# triggered, the buffer stays loaded whatever its 'bufhidden' is, and the
# windows, the alternate file, the jumps and the cursor stay as they are.
def g:Test_ApplyWorkspaceEdit_RenameHiddenBufferLeavesNoTrace()
  var from = 'XWorkspaceEditRenameHidden.txt'
  var to = 'XWorkspaceEditRenameHiddenTo.txt'
  silent! edit XWorkspaceEditRenameHiddenAlt.txt
  silent! edit XWorkspaceEditRenameHiddenCur.txt
  setline(1, ['a', 'b', 'c'])
  :normal! G
  g:RenameHiddenEvents = []
  augroup XRenameHidden
    for ev in ['BufAdd', 'BufNew', 'BufEnter', 'BufLeave', 'BufWinEnter',
	       'BufWinLeave', 'BufHidden', 'BufUnload', 'BufDelete',
	       'BufWipeout', 'BufReadPre', 'BufReadPost', 'BufWritePre',
	       'BufWritePost', 'BufFilePre', 'BufFilePost', 'WinNew',
	       'WinEnter', 'WinLeave', 'WinClosed', 'OptionSet', 'TextChanged',
	       'CursorMoved']
      exe $'autocmd {ev} * g:RenameHiddenEvents->add("{ev}")'
    endfor
  augroup END
  # OptionSet is not triggered while Vim is starting
  test_override('starting', 1)
  try
    for bufhidden in ['', 'hide', 'unload', 'delete', 'wipe']
      writefile(['text'], from)
      var bnr = bufadd(from)
      bnr->bufload()
      # Setting the option shows that the autocommands are triggered.
      g:RenameHiddenEvents = []
      setbufvar(bnr, '&bufhidden', bufhidden)
      assert_equal(['OptionSet'], g:RenameHiddenEvents)
      g:RenameHiddenEvents = []
      var before = RenameHiddenState()
      ApplyResourceOp(MakeRename(from, to))
      var msg = $'bufhidden={bufhidden}'
      assert_equal(['BufFilePre', 'BufNew', 'BufFilePost', 'BufWipeout'],
		   g:RenameHiddenEvents, msg)
      assert_equal(before, RenameHiddenState(), msg)
      assert_true(bnr->bufloaded(), msg)
      assert_equal(fnamemodify(to, ':p'), bnr->getbufinfo()[0].name, msg)
      assert_equal(['text'], getbufline(bnr, 1, '$'), msg)
      assert_equal(bufhidden, getbufvar(bnr, '&bufhidden'), msg)
      exe $'bwipe! {bnr}'
      delete(to)
    endfor
  finally
    test_override('starting', 0)
    autocmd_delete([{group: 'XRenameHidden'}])
    unlet g:RenameHiddenEvents
    delete(from)
    delete(to)
    :%bwipe!
  endtry
enddef

# Returns a DeleteFile operation deleting file "fname".
def MakeDelete(fname: string, options: dict<bool> = {}): dict<any>
  return {kind: 'delete', uri: util.LspFileToUri(fname), options: options}
enddef

# Deleting a file wipes out its buffer, in a window or hidden.
def g:Test_ApplyWorkspaceEdit_DeleteLoadedBuffer()
  var fname = 'XWorkspaceEditDelete.txt'
  try
    writefile(['text'], fname)
    exe $'edit {fname}'
    var bnr = bufnr()
    ApplyResourceOp(MakeDelete(fname))
    assert_false(filereadable(fname))
    assert_false(bufexists(bnr))

    writefile(['text'], fname)
    bnr = bufadd(fname)
    bufload(bnr)
    ApplyResourceOp(MakeDelete(fname))
    assert_false(filereadable(fname))
    assert_false(bufexists(bnr))
  finally
    delete(fname)
    :%bwipe!
  endtry
enddef

# Deleting a file whose buffer has unsaved changes fails, and leaves both
# unchanged.
def g:Test_ApplyWorkspaceEdit_DeleteKeepsModifiedBuffer()
  var fname = 'XWorkspaceEditDeleteModified.txt'
  try
    writefile(['saved'], fname)
    var bnr = bufadd(fname)
    bufload(bnr)
    setbufline(bnr, 1, 'unsaved')
    ApplyResourceOp(MakeDelete(fname))
    assert_equal('Error: File delete failed, '
		 .. $'{fnamemodify(fname, ":p")} has unsaved changes', LastMessage())
    assert_equal(['saved'], readfile(fname))
    assert_equal(['unsaved'], getbufline(bnr, 1, '$'))
    assert_true(getbufvar(bnr, '&modified'))
  finally
    delete(fname)
    :%bwipe!
  endtry
enddef

# Deleting a file that does not exist fails, unless "ignoreIfNotExists" is
# set.
def g:Test_ApplyWorkspaceEdit_DeleteMissingFile()
  var fname = 'XWorkspaceEditDeleteMissing.txt'
  ApplyResourceOp(MakeDelete(fname))
  assert_equal('Error: File delete failed, '
	       .. $'{fnamemodify(fname, ":p")} does not exist', LastMessage())
  var messages = execute('messages')
  ApplyResourceOp(MakeDelete(fname, {ignoreIfNotExists: true}))
  assert_equal(messages, execute('messages'))
  :%bwipe!
enddef

# Deleting a directory that is not empty fails, unless "recursive" is set.
# The buffers of the files in a deleted directory are wiped out, and none of
# them may have unsaved changes.
def g:Test_ApplyWorkspaceEdit_DeleteDirectory()
  var dname = 'XWorkspaceEditDeleteDir'
  var path = $'{getcwd()}/{dname}'
  try
    mkdir($'{dname}/sub', 'p')
    writefile(['a'], $'{dname}/sub/a.txt')
    var bnr = bufadd($'{dname}/sub/a.txt')
    bufload(bnr)
    ApplyResourceOp(MakeDelete(dname))
    assert_equal($'Error: File delete failed for {path}', LastMessage())
    assert_true(filereadable($'{dname}/sub/a.txt'))
    assert_true(bufloaded(bnr))

    setbufline(bnr, 1, 'unsaved')
    ApplyResourceOp(MakeDelete(dname, {recursive: true}))
    assert_equal('Error: File delete failed, '
		 .. $'{path}/sub/a.txt has unsaved changes', LastMessage())
    assert_true(filereadable($'{dname}/sub/a.txt'))
    assert_equal(['unsaved'], getbufline(bnr, 1, '$'))

    setbufvar(bnr, '&modified', false)
    ApplyResourceOp(MakeDelete(dname, {recursive: true}))
    assert_false(isdirectory(dname))
    assert_false(bufexists(bnr))

    mkdir(dname)
    ApplyResourceOp(MakeDelete(dname))
    assert_false(isdirectory(dname))
  finally
    delete(dname, 'rf')
    :%bwipe!
  endtry
enddef

# The changes of a workspace edit are applied in order up to the first one
# that fails, which is reported.  The result tells which change failed and
# why.
def g:Test_ApplyWorkspaceEdit_AbortsAtFailedChange()
  var created = 'XWorkspaceEditAbortCreated.txt'
  var existing = 'XWorkspaceEditAbortExisting.txt'
  var createdUri = util.LspFileToUri(created)
  var insert = MakeInsertEdit(createdUri, "text\n")
  var edit = {documentChanges: [
    {kind: 'create', uri: createdUri},
    {kind: 'create', uri: util.LspFileToUri(existing)},
    insert
  ]}
  try
    writefile(['old'], existing)
    var reason = 'File create failed, '
      .. $'{fnamemodify(existing, ":p")} already exists'
    assert_equal({applied: false, failureReason: reason, failedChange: 1},
		 textedit.ApplyWorkspaceEdit(edit))
    assert_equal($'Error: {reason}', LastMessage())
    assert_equal([], readfile(created))
    assert_equal(['old'], readfile(existing))

    edit = {documentChanges: [insert]}
    assert_equal({applied: true}, textedit.ApplyWorkspaceEdit(edit))
    assert_equal(['text'], getbufline(bufadd(created), 1, '$'))

    edit = {documentChanges: [{kind: 'copy'}]}
    reason = 'Unsupported change in workspace edit [copy]'
    assert_equal({applied: false, failureReason: reason, failedChange: 0},
		 textedit.ApplyWorkspaceEdit(edit))

    # A change that throws an error fails with the error.
    edit = {documentChanges: [
      {kind: 'create', uri: util.LspFileToUri($'{existing}/file.txt')}]}
    var result = textedit.ApplyWorkspaceEdit(edit)
    assert_equal([false, 0], [result.applied, result.failedChange])
    assert_match('E739:', result.failureReason)
  finally
    delete(created)
    delete(existing)
    :%bwipe!
  endtry
enddef

# A completion request supersedes the pending one, which is cancelled, so a
# late reply to it must not be taken as the reply to the latest one.
def g:Test_GetCompletion_CancelsSupersededRequest()
  silent! edit XGetCompletionSuperseded.txt
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.isCompletionProvider = true
  lspserver.completionLazyDoc = false
  var replyCbs: list<func> = []
  lspserver.rpc_a = (_, _, Cb) => {
    replyCbs->add(Cb)
    return replyCbs->len()
  }

  lspserver.omniCompletePending = true
  lspserver.completeItems = []
  lspserver.getCompletion(1, '')
  lspserver.getCompletion(1, '')
  assert_equal([{method: '$/cancelRequest', params: {id: 1}}], notifications)

  replyCbs[0](lspserver, [{label: 'stale'}], {})
  replyCbs[0](lspserver, v:null, {code: -32800, message: 'Request cancelled'})
  assert_true(lspserver.omniCompletePending)
  assert_equal([], lspserver.completeItems)

  replyCbs[1](lspserver, [{label: 'latest'}], {})
  assert_false(lspserver.omniCompletePending)
  assert_equal(['latest'], lspserver.completeItems->mapnew((_, v) => v.word))

  # The latest request got its reply, so the next one cancels nothing.
  lspserver.getCompletion(1, '')
  assert_equal(1, notifications->len())
  :%bw!
enddef

# When the omnifunc stops waiting for the reply to its completion request,
# because the reply doesn't come in time or a key is typed, the request is
# cancelled and its late reply is ignored.
def g:Test_OmniFunc_CancelsAbandonedRequest()
  silent! edit XOmniFuncAbandoned.vim
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.running = true
  lspserver.ready = true
  lspserver.isCompletionProvider = true
  lspserver.completionLazyDoc = false
  lspserver.completionTriggerChars = []
  var replyCbs: list<func> = []
  lspserver.rpc_a = (_, _, Cb) => {
    replyCbs->add(Cb)
    return replyCbs->len()
  }
  buf.BufLspServerSet(bufnr(), lspserver)
  setlocal omnifunc=g:LspOmniFunc

  try
    # The reply doesn't come in time.  The trailing space lets the cursor sit
    # just after "fo" in Normal mode.
    setline(1, 'fo ')
    cursor(1, 3)
    assert_equal(0, g:LspOmniFunc(1, ''))
    assert_true(g:LspOmniCompletePending())
    var start = reltime()
    assert_equal(v:none, g:LspOmniFunc(0, 'fo'))
    assert_true(start->reltime()->reltimefloat() >= 2.0)
    assert_equal([{method: '$/cancelRequest', params: {id: 1}}], notifications)
    assert_false(g:LspOmniCompletePending())
    assert_equal({}, lspserver.supersedableRequests)
    replyCbs[0](lspserver, [{label: 'foo'}], {})
    assert_equal([], lspserver.completeItems)

    # A key is typed while waiting for the reply
    setline(1, 'fo')
    feedkeys("A\<C-X>\<C-O>o\<Esc>", 'xt')
    assert_equal('foo', getline(1))
    assert_equal([{method: '$/cancelRequest', params: {id: 1}},
		  {method: '$/cancelRequest', params: {id: 2}}], notifications)
    assert_false(g:LspOmniCompletePending())
    assert_equal({}, lspserver.supersedableRequests)
    replyCbs[1](lspserver, [{label: 'foo'}], {})
    assert_equal([], lspserver.completeItems)
  finally
    buf.BufLspServerRemove(bufnr(), lspserver)
    :%bw!
  endtry
enddef

# Returns a stub language server that replies to "textDocument/documentLink"
# with "links" and to "documentLink/resolve" with "resolved".  The server is a
# resolve provider only if "resolved" is not empty.  The requests sent to the
# server are added to "requests".
def MakeDocumentLinkServer(links: list<dict<any>>, resolved: dict<any>,
			   requests: list<dict<any>>): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isDocumentLinkProvider = true
  lspserver.isDocumentLinkResolveProvider = !resolved->empty()
  lspserver.rpc = (method: string, params: any): dict<any> => {
    requests->add({method: method, params: params->deepcopy()})
    var result: any = method == 'documentLink/resolve' ? resolved : links
    return {result: result->deepcopy()}
  }
  return lspserver
enddef

# Test for listing document links with their targets and tooltips
def g:Test_DocumentLink_ListsTargetsAndTooltips()
  silent! edit XDocLinkList.txt
  setline(1, ['first https://example.com/doc', 'second ref'])
  var links = [
    {range: {start: {line: 1, character: 7}, end: {line: 1, character: 10}},
     tooltip: 'Go to ref'},
    {range: {start: {line: 0, character: 6}, end: {line: 0, character: 29}},
     target: 'https://example.com/doc', tooltip: 'Open docs'},
    {range: {start: {line: 0, character: 0}, end: {line: 0, character: 5}}}
  ]
  var requests: list<dict<any>> = []
  var srv = MakeDocumentLinkServer(links, {}, requests)
  buf.BufLspServerSet(bufnr(), srv)

  :LspDocumentLink
  assert_equal([[1, 1, 6, '(unresolved)'],
		[1, 7, 30, 'https://example.com/doc (Open docs)'],
		[2, 8, 11, 'Go to ref']],
	       getloclist(0)->mapnew((_, v) => [v.lnum, v.col, v.end_col, v.text]))
  :lclose

  # A link without a target is not resolved when the server is not a resolve
  # provider
  cursor(2, 9)
  assert_equal('Warn: Document link target is not found',
	       execute('LspDocumentLinkOpen')->split("\n")[0])
  assert_equal(['textDocument/documentLink', 'textDocument/documentLink'],
	       requests->mapnew((_, r) => r.method))

  buf.BufLspServerRemove(bufnr(), srv)
  :%bw!
enddef

# Test for resolving the target of the document link under the cursor and
# opening the file at the position in the target fragment
def g:Test_DocumentLinkOpen_ResolvesTarget()
  writefile(['one', 'two', 'three'], 'XDocLinkTarget.txt')
  silent! edit XDocLinkSource.txt
  setline(1, ['see the target'])
  setlocal nomodified
  var srcBnr = bufnr()
  var range = {start: {line: 0, character: 8}, end: {line: 0, character: 14}}
  var target = $'{util.LspFileToUri("XDocLinkTarget.txt")}#L2,3'
  var requests: list<dict<any>> = []
  var srv = MakeDocumentLinkServer([{range: range, data: 42}],
				   {range: range, target: target, data: 42},
				   requests)
  buf.BufLspServerSet(srcBnr, srv)

  cursor(1, 14)
  :LspDocumentLinkOpen
  assert_equal(['textDocument/documentLink', 'documentLink/resolve'],
	       requests->mapnew((_, r) => r.method))
  assert_equal(42, requests[1].params.data)
  assert_equal('XDocLinkTarget.txt', expand('%:t'))
  assert_equal([2, 3], [line('.'), col('.')])

  buf.BufLspServerRemove(srcBnr, srv)
  :%bw!
  delete('XDocLinkTarget.txt')
enddef

# Test for opening a document link target that is not a file with the opener
# from the Vim runtime.  The target must reach the opener unchanged.
def g:Test_DocumentLinkOpen_ExternalUri()
  var vim9Lib = globpath(&runtimepath, 'autoload/dist/vim9.vim', false, true)
  if !has('unix') || vim9Lib->empty()
      || vim9Lib[0]->readfile()->match('^export def Open(') == -1
    # The dist#vim9#Open() function is not available
    return
  endif

  writefile(['#!/bin/sh', 'printf "%s" "$1" > XDocLinkOpened'],
	    'XDocLinkOpener')
  setfperm('XDocLinkOpener', 'rwx------')
  g:Openprg = './XDocLinkOpener'
  var uri = "https://example.com/doc?a=1&b='2'$(touch XDocLinkPwned)"
  silent! edit XDocLinkExternal.txt
  setline(1, ['docs'])
  var range = {start: {line: 0, character: 0}, end: {line: 0, character: 4}}
  var srv = MakeDocumentLinkServer([{range: range, target: uri}], {}, [])
  buf.BufLspServerSet(bufnr(), srv)

  try
    :LspDocumentLinkOpen
    g:WaitFor(() => filereadable('XDocLinkOpened')
		      && readfile('XDocLinkOpened') == [uri])
    assert_false(filereadable('XDocLinkPwned'))
  finally
    buf.BufLspServerRemove(bufnr(), srv)
    :%bw!
    unlet g:Openprg
    delete('XDocLinkOpener')
    delete('XDocLinkOpened')
    delete('XDocLinkPwned')
  endtry
enddef

# Returns a running language server with the document symbols and the call
# hierarchy of the function in "XScratchSrc.c".
def MakeScratchServer(): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isDocumentSymbolProvider = true
  lspserver.isCallHierarchyProvider = true
  var range = {start: {line: 0, character: 5}, end: {line: 0, character: 17}}
  var item = {name: 'xScratchFunc', kind: 12, range: range,
	      selectionRange: range, uri: util.LspFileToUri('XScratchSrc.c')}
  lspserver.rpc_a = (method: string, params: any, Cbfunc: func): number => {
    Cbfunc(lspserver, [item->deepcopy()], {})
    return 1
  }
  lspserver.rpc = (method: string, params: any): dict<any> => {
    if method == 'textDocument/prepareCallHierarchy'
      return {result: [item->deepcopy()]}
    endif
    return {result: [{from: item->deepcopy(), fromRanges: []}]}
  }
  return lspserver
enddef

# Edits "XScratchSrc.c" in the current window, with the language server
# "lspserver" for it.  Returns the buffer number.
def ScratchSrcEdit(lspserver: dict<any>): number
  :silent edit XScratchSrc.c
  setline(1, 'void xScratchFunc(void) {}')
  :setlocal filetype=text
  buf.BufLspServerSet(bufnr(), lspserver)
  cursor(1, 6)
  return bufnr()
enddef

# Shows the hover text from "lspserver" in the preview window.
def ScratchHoverShow(lspserver: dict<any>)
  g:LspOptionsSet({hoverInPreview: true})
  try
    var hoverResult = {contents: {kind: 'plaintext', value: 'xScratchFunc doc'}}
    hover.HoverReply(lspserver, hoverResult, {})
  finally
    g:LspOptionsSet({hoverInPreview: false})
  endtry
enddef

# Returns each kind of scratch buffer of the plugin: its name, a line of its
# text, and a function that shows it when the cursor is in the window of
# "XScratchSrc.c" with the language server "lspserver".
def ScratchKinds(lspserver: dict<any>): list<dict<any>>
  return [
    {name: 'LSP-Outline', line: 'Function@',
     Open: () => execute('LspOutline')},
    {name: 'LSP-CallHierarchy', line: '# Incoming calls to "xScratchFunc"',
     Open: () => execute('LspIncomingCalls')},
    {name: 'Language-Servers', line: 'Filetype Information',
     Open: () => execute('LspShowAllServers')},
    {name: 'LangServer-Capabilities',
     line: "'test' Language Server Capabilities",
     Open: () => execute('LspServer show capabilities')},
    {name: 'LspHover', line: 'xScratchFunc doc',
     Open: function(ScratchHoverShow, [lspserver])}
  ]
enddef

# Returns the numbers of the buffers with 'buftype' "nofile" in the windows of
# the current tab page.
def ScratchBufsInTab(): list<number>
  return tabpagebuflist()
    ->filter((_, bnr) => getbufvar(bnr, '&buftype') == 'nofile')
    ->sort()
    ->uniq()
enddef

# Test that the scratch windows of the plugin show buffers of their own, not
# a buffer of the user with a name like the name of the scratch buffer or the
# same name, whether a window shows the buffer of the user or not.
def g:Test_ScratchWindow_KeepsUserBuffer()
  var lspserver = MakeScratchServer()
  for kind in ScratchKinds(lspserver)
    for decoy in [$'my-{kind.name}.txt', kind.name]
      for shown in [true, false]
	var ctx = $'{kind.name}, user buffer "{decoy}" shown: {shown}'
	var srcBnr = -1
	try
	  srcBnr = ScratchSrcEdit(lspserver)
	  var srcWinid = win_getid()
	  exe $'silent split {decoy->fnameescape()}'
	  setline(1, ['user text'])
	  var decoyBnr = bufnr()
	  if !shown
	    :hide
	  endif
	  srcWinid->win_gotoid()

	  kind.Open()

	  assert_equal([decoy, ['user text'], 1, ''],
	    [decoyBnr->bufname(), decoyBnr->getbufline(1, '$'),
	     getbufinfo(decoyBnr)[0].changed, getbufvar(decoyBnr, '&buftype')],
	    ctx)
	  var scratch = ScratchBufsInTab()
	  assert_equal(1, scratch->len(), ctx)
	  if !scratch->empty()
	    assert_notequal(-1, scratch[0]->getbufline(1, '$')->index(kind.line),
			    ctx)
	    if decoy != kind.name
	      assert_equal(kind.name, scratch[0]->bufname(), ctx)
	    endif
	  endif
	finally
	  buf.BufLspServerRemove(srcBnr, lspserver)
	  :%bw!
	endtry
      endfor
    endfor
  endfor
enddef

# Test that the scratch windows of the plugin are reused, and opened again,
# after a change of the current directory.
def g:Test_ScratchWindow_AfterCd()
  var lspserver = MakeScratchServer()
  var cwd = getcwd()
  mkdir('XScratchDir')
  try
    for kind in ScratchKinds(lspserver)
      var srcBnr = -1
      try
	srcBnr = ScratchSrcEdit(lspserver)
	var srcWinid = win_getid()
	kind.Open()
	var scratch = ScratchBufsInTab()
	var winCount = winnr('$')

	chdir('XScratchDir')
	srcWinid->win_gotoid()
	kind.Open()
	assert_equal([scratch, winCount], [ScratchBufsInTab(), winnr('$')],
		     kind.name)
	assert_notequal(-1, scratch[0]->getbufline(1, '$')->index(kind.line),
			kind.name)

	win_execute(scratch[0]->bufwinid(), 'close')
	srcWinid->win_gotoid()
	kind.Open()
	var newScratch = ScratchBufsInTab()
	assert_equal(1, newScratch->len(), kind.name)
	assert_notequal(scratch, newScratch, kind.name)
	assert_equal(kind.name, newScratch[0]->bufname(), kind.name)
	assert_notequal(-1, newScratch[0]->getbufline(1, '$')->index(kind.line),
			kind.name)
      finally
	chdir(cwd)
	buf.BufLspServerRemove(srcBnr, lspserver)
	:%bw!
      endtry
    endfor
  finally
    delete('XScratchDir', 'd')
  endtry
enddef

# Test that the scratch windows of the plugin open again after the user wipes
# out their buffers.
def g:Test_ScratchWindow_AfterWipeOut()
  var lspserver = MakeScratchServer()
  for kind in ScratchKinds(lspserver)
    var srcBnr = -1
    try
      srcBnr = ScratchSrcEdit(lspserver)
      var srcWinid = win_getid()
      kind.Open()
      var scratch = ScratchBufsInTab()
      exe $'bwipeout! {scratch[0]}'

      srcWinid->win_gotoid()
      kind.Open()
      var newScratch = ScratchBufsInTab()
      assert_equal(1, newScratch->len(), kind.name)
      assert_notequal(scratch, newScratch, kind.name)
      assert_equal(kind.name, newScratch[0]->bufname(), kind.name)
      assert_notequal(-1, newScratch[0]->getbufline(1, '$')->index(kind.line),
		      kind.name)
    finally
      buf.BufLspServerRemove(srcBnr, lspserver)
      :%bw!
    endtry
  endfor
enddef

# Test that a scratch window of the plugin opens in a second tab page and
# shows the same buffer there.
def g:Test_ScratchWindow_InTwoTabPages()
  var lspserver = MakeScratchServer()
  for kind in ScratchKinds(lspserver)
    var srcBnr = -1
    try
      srcBnr = ScratchSrcEdit(lspserver)
      var srcWinid = win_getid()
      kind.Open()
      var scratch = ScratchBufsInTab()

      srcWinid->win_gotoid()
      :tab split
      kind.Open()
      assert_equal([2, scratch], [tabpagenr(), ScratchBufsInTab()], kind.name)
      assert_notequal(-1, scratch[0]->getbufline(1, '$')->index(kind.line),
		      kind.name)
    finally
      buf.BufLspServerRemove(srcBnr, lspserver)
      :%bw!
    endtry
  endfor
enddef

# Test that ":LspOutline close" and ":LspOutline toggle" close the outline
# window, not the window of a buffer with a name like "LSP-Outline", and that
# unloading such a buffer keeps the outline autocmds.
def g:Test_LspOutline_KeepsBufferWithSimilarName()
  var lspserver = MakeScratchServer()
  var srcBnr = -1
  try
    srcBnr = ScratchSrcEdit(lspserver)
    var srcWinid = win_getid()
    :silent split my-LSP-Outline.txt
    var decoyWinid = win_getid()
    srcWinid->win_gotoid()
    :LspOutline
    assert_equal(1, ScratchBufsInTab()->len())

    :silent split XScratchDir/LSP-Outline
    :bwipeout
    assert_true(exists('#LSPOutline#BufEnter'))

    srcWinid->win_gotoid()
    :LspOutline close
    assert_equal([], ScratchBufsInTab())
    :LspOutline toggle
    assert_equal(1, ScratchBufsInTab()->len())
    :LspOutline toggle
    assert_equal([], ScratchBufsInTab())
    assert_notequal(0, decoyWinid->win_id2win())
  finally
    buf.BufLspServerRemove(srcBnr, lspserver)
    :%bw!
  endtry
enddef

# Test that the hover text doesn't replace the text of a modified buffer of the
# user in the preview window, which the preview window can't leave.
def g:Test_HoverInPreview_KeepsModifiedPreviewBuffer()
  var lspserver = MakeScratchServer()
  var srcBnr = -1
  try
    srcBnr = ScratchSrcEdit(lspserver)
    :silent pedit XScratchNotes.txt
    :wincmd P
    setline(1, ['user text'])
    var notesBnr = bufnr()
    :wincmd p

    var exception = ''
    try
      ScratchHoverShow(lspserver)
    catch
      exception = v:exception
    endtry
    assert_match('E37:', exception)
    assert_equal([['user text'], ''],
		 [notesBnr->getbufline(1, '$'), getbufvar(notesBnr, '&buftype')])
  finally
    buf.BufLspServerRemove(srcBnr, lspserver)
    :%bw!
  endtry
enddef

# Only here to because the test runner needs it
def g:StartLangServer(): bool
  return true
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
