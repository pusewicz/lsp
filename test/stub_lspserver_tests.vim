vim9script
# Unit tests using a stub language server

import '../autoload/lsp/lspserver.vim' as lserver
import '../autoload/lsp/lsp.vim' as lsp
import '../autoload/lsp/codeaction.vim' as codeaction
import '../autoload/lsp/codelens.vim' as codelens
import '../autoload/lsp/signature.vim' as signature
import '../autoload/lsp/completion.vim' as completion
import '../autoload/lsp/handlers.vim' as handlers
import '../autoload/lsp/diag.vim' as diag
import '../autoload/lsp/symbol.vim' as symbol
import '../autoload/lsp/util.vim' as util
import '../autoload/lsp/buffer.vim' as buf
import '../autoload/lsp/ontypeformat.vim' as ontypeformat
import '../autoload/lsp/linkedediting.vim' as linkedediting
import '../autoload/lsp/textedit.vim' as textedit
import '../autoload/lsp/inlayhints.vim' as inlayhints
import '../autoload/lsp/documentcolor.vim' as documentcolor
import '../autoload/lsp/inlinecompletion.vim' as inlinecompletion
import '../autoload/lsp/snippet.vim' as snippet
import '../autoload/lsp/capabilities.vim' as capabilities
import '../autoload/lsp/hover.vim' as hover
import '../autoload/lsp/options.vim' as opt
import '../autoload/lsp/watchedfiles.vim'

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
  AssertRequestError(lspserver, responses,
    {id: 26, method: 'workspace/inlayHint/refresh', params: {foo: 1}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 27, method: 'workspace/semanticTokens/refresh', params: {foo: 1}},
    -32602)

  # Unknown method should return MethodNotFound.
  AssertRequestError(lspserver, responses,
    {id: 28, method: 'workspace/notARealMethod', params: {}}, -32601)
  # Inline values are not supported
  AssertRequestError(lspserver, responses,
    {id: 29, method: 'workspace/inlineValue/refresh'}, -32601)
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
  lspserver.debug = true
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

# Test that a dropped message is not serialised for the debug log when the
# server isn't debugged.
def g:Test_ProcessMessages_DroppedMessageNotTracedWithoutDebug()
  var lspserver = MakeTestLspServer([])
  var traceMsgs: list<string> = []
  lspserver.traceLog = (msg) => traceMsgs->add(msg)
  lspserver.debug = false

  lspserver.data = {jsonrpc: '2.0', id: 'X-unknown-response-id', result: {}}
  lspserver.processMessage()
  lspserver.data = {id: 1, method: 'test/method'}
  lspserver.processMessage()

  assert_equal([], traceMsgs)
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

# Returns the LSP "messages" as a language server sends them.
def EncodeLspMessages(messages: list<dict<any>>): string
  return messages->mapnew((_, msg) => {
    var body = msg->json_encode()
    return $"Content-Length: {body->len()}\r\n\r\n{body}"
  })->join('')
enddef

# Start a job that stands in for a language server: it sends "messages" and
# then reads what it is sent without ever replying.
def StartStubServerJob(messages: list<dict<any>>, jobOpts: dict<any> = {}): job
  return job_start(['sh', '-c', 'printf "%s" "$1"; exec cat >/dev/null', 'sh',
		    EncodeLspMessages(messages)],
		   {in_mode: 'lsp', out_mode: 'lsp', noblock: 1}->extend(jobOpts))
enddef

# Start a job like StartStubServerJob() that sends the messages in each of
# "steps" a second after the ones in the step before.
def StartSteppedStubServerJob(steps: list<list<dict<any>>>): job
  var script: string = range(1, steps->len())
    ->mapnew((_, i) => $'printf "%s" "${i}"')->join('; sleep 1; ')
  return job_start(['sh', '-c', $'{script}; exec cat >/dev/null', 'sh']
		     + steps->mapnew((_, msgs) => EncodeLspMessages(msgs)),
		   {in_mode: 'lsp', out_mode: 'lsp', noblock: 1})
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

# Test that an asynchronous request is pending until its reply arrives.
def g:Test_AsyncRpc_PendingUntilReplied()
  var lspserver = MakeTestLspServer([])
  # Vim numbers the asynchronous requests on a new channel from 1.
  lspserver.job = StartStubServerJob([{jsonrpc: '2.0', id: 1, result: {}}])
  try
    var replied = false
    lspserver.rpc_a('test/replied', {}, (_, _, _) => {
      replied = true
    })
    lspserver.rpc_a('test/noReply', {}, (_, _, _) => {
    })
    assert_equal({1: 'test/replied', 2: 'test/noReply'},
		 lspserver.pendingRequests)
    g:WaitForAssert(() => assert_true(replied))
    assert_equal({2: 'test/noReply'}, lspserver.pendingRequests)
  finally
    job_stop(lspserver.job)
  endtry
enddef

# Test that a reply saying that the request was cancelled, by the client or by
# the server, or that the content it was about was modified, is not reported
# as an error, and that the callback of an asynchronous request then gets no
# result.
def g:Test_Rpc_StaleRequestReplyIsNotAnError()
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
enddef

# Returns the messages of a language server that replies ContentModified to the
# asynchronous requests 1 to "count", as Vim numbers them on a new channel.
def ContentModifiedReplies(count: number): list<dict<any>>
  return range(1, count)->mapnew((_, id) => ({jsonrpc: '2.0', id: id,
    error: {code: -32801, message: 'content modified'}}))
enddef

# Test that a request answering a user command, asynchronous or synchronous,
# is sent again when the language server replies ContentModified to it, and
# that the reply to the request sent again is the one passed on.
def g:Test_Rpc_RetriesOnContentModified()
  var lspserver = MakeTestLspServer([])
  var syncId = lspserver.nextSyncRpcId
  lspserver.job = StartStubServerJob(ContentModifiedReplies(1) + [
    {jsonrpc: '2.0', id: 2, result: 'async'},
    {jsonrpc: '2.0', id: syncId,
     error: {code: -32801, message: 'content modified'}},
    {jsonrpc: '2.0', id: syncId + 1, result: 'sync'}
  ])
  try
    var replies: list<list<any>> = []
    assert_equal(1, lspserver.rpc_a('textDocument/definition', {},
      (_, reply, error) => {
	replies->add([reply, error])
      }))
    assert_equal({jsonrpc: '2.0', id: syncId + 1, result: 'sync'},
		 lspserver.rpc('textDocument/definition', {}))
    g:WaitForAssert(() => assert_equal([['async', {}]], replies))
    assert_equal({}, lspserver.pendingRequests)
  finally
    job_stop(lspserver.job)
  endtry
enddef

# Test that a request is sent again at most CONTENT_MODIFIED_MAX_RETRIES times
# after a ContentModified reply, and that its callback then gets no result, or
# the error when the caller handles the errors, which is not reported.
def g:Test_AsyncRpc_RetriesOnContentModifiedAtMostMaxTimes()
  var tries = lserver.CONTENT_MODIFIED_MAX_RETRIES + 1
  var modified = {code: -32801, message: 'content modified'}
  for handleError in [true, false]
    var lspserver = MakeTestLspServer([])
    # A reply more than the requests that may be sent
    lspserver.job = StartStubServerJob(ContentModifiedReplies(tries + 1))
    lspserver.debug = true
    var sent: list<string> = []
    lspserver.traceLog = (msg: string) => {
      if msg =~# '^Sent request '
	sent->add(msg)
      endif
    }
    try
      var beforeMessages = execute('messages')
      var replies: list<list<any>> = []
      lspserver.rpc_a('textDocument/definition', {}, (_, reply, error) => {
	replies->add([reply, error])
      }, {handleError: handleError})
      g:WaitForAssert(() => assert_equal(1, replies->len()))
      assert_equal([v:null, handleError ? {} : modified], replies[0])
      assert_equal(tries, sent->len())
      assert_equal({}, lspserver.pendingRequests)
      assert_equal(beforeMessages, execute('messages'))
    finally
      job_stop(lspserver.job)
    endtry
  endfor
enddef

# Test that the maps and lists in the server dict that grow with the number of
# open documents, pending requests and messages keep their type when they are
# emptied.  Before patch 9.2.1144, Vim goes through all the values of one that
# has no type on every server method call.
def g:Test_ServerState_StaysTyped()
  var types = {
    messages: 'list<string>',
    syncRpcReplies: 'dict<dict<any>>',
    pendingRequests: 'dict<string>',
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

  # Start the server and let it exit.
  lspserver.running = false
  lspserver.path = 'sh'
  lspserver.args = ['-c', 'exec cat >/dev/null']
  lspserver.startServer(bnr)
  job_stop(lspserver.job)
  g:WaitForAssert(() => assert_false(lspserver.running))
  # The initialize request that it didn't reply to is no longer pending
  assert_equal({}, lspserver.pendingRequests)
  AssertTyped(lspserver, 'after the server was started and exited')
  :%bw!
enddef

# Test that the exit of the language server is reported with its exit status,
# or with the signal that killed it, also in the debug log.
def g:Test_ServerExit_ReportsHow()
  silent! edit XServerExit.txt
  var bnr = bufnr()
  # The server exits once it has read the start of the "initialize" request.
  try
    for [cmd, how] in [['read l; exit 3', 'exited with status 3'],
		       ['read l; kill -SEGV $$', 'was killed by signal SEGV']]
      var lspserver = MakeTestLspServer([])
      var traceMsgs: list<string> = []
      lspserver.traceLog = (msg) => traceMsgs->add(msg)
      lspserver.path = 'sh'
      lspserver.args = ['-c', cmd]
      :messages clear

      lspserver.startServer(bnr)
      g:WaitForAssert(() => assert_false(lspserver.running))
      assert_match($'^Warn: .*: LSP server (test) {how}$',
		   execute('messages')->split("\n")[-1])
      assert_equal([$'LSP server {how}'], traceMsgs)
    endfor
  finally
    :%bw!
  endtry
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
  var [lspserver, bufnrs, listenerIds] = OpenTwoTestDocuments(messages, [])
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
    job_stop(lspserver.job)
  endtry
  :%bw!
enddef

# Test that the reply to a hover request saying that the content was modified,
# also after it was sent again, is not cached, so that hovering again at the
# same position asks the server again, while an empty hover result is still
# cached.
def g:Test_ShowHoverInfo_ContentModifiedIsNotCached()
  silent! edit XHoverContentModified.txt
  var lspserver = MakeTestLspServer([])
  lspserver.isHoverProvider = true
  lspserver.job = StartStubServerJob(
    ContentModifiedReplies(lserver.CONTENT_MODIFIED_MAX_RETRIES + 1))
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
    job_stop(lspserver.job)
  endtry
  :%bw!
enddef

# Test that the error that the language server replies to a request is
# reported once, and not at all for a silent request, as the automatic hover
# and highlight are.
def g:Test_ErrorReply_ReportedOnce()
  silent! edit XErrorReplyReportedOnce.txt
  var fname = expand('%:p')
  var bnr = bufnr()
  var lspserver = MakeTestLspServer([])
  lspserver.isHoverProvider = true
  lspserver.isDocumentHighlightProvider = true
  lspserver.isSignatureHelpProvider = true
  lspserver.isCompletionProvider = true
  lspserver.isDocumentSymbolProvider = true
  # [send the request, its method, whether the error is reported]
  var requests: list<list<any>> = [
    [() => lspserver.initServer(bnr), 'initialize', true],
    [() => lspserver.hover(''), 'textDocument/hover', true],
    [() => lspserver.hover('silent'), 'textDocument/hover', false],
    [() => lspserver.docHighlight(bnr, ''), 'textDocument/documentHighlight',
     true],
    [() => lspserver.docHighlight(bnr, 'silent'),
     'textDocument/documentHighlight', false],
    [() => lspserver.showSignature(), 'textDocument/signatureHelp', true],
    [() => lspserver.getCompletion(1, ''), 'textDocument/completion', true],
    [() => lspserver.getDocSymbols(fname, true),
     'textDocument/documentSymbol', true],
    [() => lspserver.getDocSymbols(fname, false),
     'textDocument/documentSymbol', true]
  ]
  try
    for [Request, method, reported] in requests
      # Vim numbers the asynchronous requests on a new channel from 1.
      lspserver.job = StartStubServerJob([{jsonrpc: '2.0', id: 1,
	error: {code: -32603, message: 'failed'}}])
      :messages clear
      var noMessages: list<string> = execute('messages')->split("\n")
      Request()
      g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
      if reported
	g:WaitForAssert(() => assert_notequal(noMessages,
					      execute('messages')->split("\n")))
	assert_equal(noMessages + [$'Error: request {method} failed (failed, error = InternalError)'],
		     execute('messages')->split("\n"), method)
      else
	assert_equal(noMessages, execute('messages')->split("\n"), method)
      endif
      job_stop(lspserver.job)
    endfor
  finally
    job_stop(lspserver.job)
  endtry
  :%bw!
enddef

# Test that, with 'hoverFallback' enabled, an empty hover result runs
# 'keywordprg' only for a request that is not silent: the automatic hover on
# CursorHold is silent and must not run it, while an explicit hover at the same
# position, answered from the cache, still falls back.
def g:Test_HoverReply_FallbackOnlyWhenNotSilent()
  silent! edit XHoverFallback.txt
  setline(1, 'fallbackword')
  command! -nargs=* XHoverFallback g:HoverFallbackArg = <q-args>
  setlocal keywordprg=:XHoverFallback
  g:LspOptionsSet({hoverFallback: true})
  var lspserver = MakeTestLspServer([])
  try
    var reqctx = hover.HoverRequestContextGet(lspserver)
    hover.HoverReply(lspserver, {contents: ''}, {}, 'silent', reqctx)
    assert_false(exists('g:HoverFallbackArg'))

    assert_true(hover.HoverShowCached(reqctx, lspserver, ''))
    assert_equal('fallbackword', g:HoverFallbackArg)
  finally
    g:LspOptionsSet({hoverFallback: false})
    delcommand XHoverFallback
    unlet! g:HoverFallbackArg
  endtry
  :%bw!
enddef

# Test that ':silent LspHover' in a buffer without a language server does not
# fall back to 'keywordprg', while ':LspHover' does.
def g:Test_Hover_NoServerFallbackOnlyWhenNotSilent()
  :enew!
  setline(1, 'fallbackword')
  command! -nargs=* XHoverFallback g:HoverFallbackArg = <q-args>
  setlocal keywordprg=:XHoverFallback
  g:LspOptionsSet({hoverFallback: true})
  try
    lsp.Hover('silent')
    assert_false(exists('g:HoverFallbackArg'))

    lsp.Hover('')
    assert_equal('fallbackword', g:HoverFallbackArg)
  finally
    g:LspOptionsSet({hoverFallback: false})
    delcommand XHoverFallback
    unlet! g:HoverFallbackArg
  endtry
  :%bw!
enddef

# Returns a running and ready test language server, attached to the current
# buffer, that sends the "replies" to the asynchronous requests, which Vim
# numbers from 1.  The channel callbacks only get the replies while Vim
# waits, e.g. in g:WaitForAssert().
def MakeAsyncReplyingLspServer(replies: list<any>,
			       notifications: list<dict<any>> = []): dict<any>
  var lspserver = MakeTestLspServer(notifications)
  lspserver.running = true
  lspserver.ready = true
  var id = 0
  lspserver.job = StartStubServerJob(replies->mapnew((_, result) => {
    id += 1
    return {jsonrpc: '2.0', id: id, result: result}
  }))
  buf.BufLspServerSet(bufnr(), lspserver)
  return lspserver
enddef

# Stop the test language server "lspserver" made by
# MakeAsyncReplyingLspServer() for buffer "bnr".
def StopAsyncReplyingLspServer(lspserver: dict<any>, bnr: number)
  job_stop(lspserver.job)
  buf.BufLspServerRemove(bnr, lspserver)
enddef

# Test that the reply to a goto definition request jumps to the definition
# when it arrives, unless the cursor moved before it did.
def g:Test_GotoDefinition_DropsReplyAfterCursorMoved()
  silent! edit XGotoDefinitionAsync.txt
  setline(1, ['use def', 'def'])
  var bnr = bufnr()
  var pos = {line: 1, character: 1}
  var location = {uri: util.LspBufnrToUri(bnr), range: {start: pos, end: pos}}
  try
    for moveCursor in [false, true]
      var lspserver = MakeAsyncReplyingLspServer([location])
      lspserver.isDefinitionProvider = true
      cursor(1, 5)
      lspserver.gotoDefinition(false, '', 0)
      assert_equal([1, 5], [line('.'), col('.')])
      if moveCursor
	cursor(1, 6)
      endif
      g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
      assert_equal(moveCursor ? [1, 6] : [2, 2], [line('.'), col('.')],
		   $'moveCursor: {moveCursor}')
      StopAsyncReplyingLspServer(lspserver, bnr)
    endfor
  finally
    :%bw!
  endtry
enddef

# Test that a goto definition request is sent again when the language server
# replies ContentModified, as rust-analyzer does when it reloads the project
# while it works on the request, and that the reply to the request sent again
# jumps to the definition.  A request superseding the one sent again cancels
# that one.
def g:Test_GotoDefinition_RetriesOnContentModified()
  silent! edit XGotoDefinitionRetry.txt
  setline(1, ['use def', 'def'])
  var bnr = bufnr()
  var pos = {line: 1, character: 1}
  var location = {uri: util.LspBufnrToUri(bnr), range: {start: pos, end: pos}}
  var notifications: list<dict<any>> = []
  var lspserver = MakeAsyncReplyingLspServer([], notifications)
  lspserver.isDefinitionProvider = true
  try
    job_stop(lspserver.job)
    lspserver.job = StartStubServerJob(ContentModifiedReplies(1)
      + [{jsonrpc: '2.0', id: 2, result: location}])
    cursor(1, 5)
    lspserver.gotoDefinition(false, '', 0)
    g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
    assert_equal([2, 2], [line('.'), col('.')])

    job_stop(lspserver.job)
    lspserver.job = StartStubServerJob(ContentModifiedReplies(1))
    cursor(1, 5)
    lspserver.gotoDefinition(false, '', 0)
    g:WaitForAssert(() => assert_equal({2: 'textDocument/definition'},
				       lspserver.pendingRequests))
    lspserver.gotoDefinition(false, '', 0)
    assert_equal([{method: '$/cancelRequest', params: {id: 2}}],
		 notifications->copy()->filter((_, n) => n.method == '$/cancelRequest'))
  finally
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
  endtry
enddef

# Test that the keys pending after ":LspGotoDefinition", from a mapping,
# ":normal", a register or feedkeys(), wait for the reply and act on the
# definition.
def g:Test_GotoDefinition_PendingKeysWaitForReply()
  silent! edit XGotoDefinitionPendingKeys.txt
  var bnr = bufnr()
  var pos = {line: 1, character: 1}
  var location = {uri: util.LspBufnrToUri(bnr), range: {start: pos, end: pos}}
  nnoremap <buffer> <F2> <Cmd>LspGotoDefinition<CR>rX
  setreg('q', ":LspGotoDefinition\<CR>rX")
  try
    for [source, Run] in [
	['mapping', () => feedkeys("\<F2>", 'xt')],
	[':normal', () => execute("normal :LspGotoDefinition\<CR>rX")],
	['register', () => execute('normal @q')],
	['feedkeys()', () => feedkeys(":LspGotoDefinition\<CR>rX", 'xt')]]
      setline(1, ['use def', 'def'])
      var lspserver = MakeAsyncReplyingLspServer([location])
      lspserver.isDefinitionProvider = true
      cursor(1, 5)
      Run()
      assert_equal(['use def', 'dXf'], getline(1, '$'), source)
      assert_equal([2, 2], [line('.'), col('.')], source)
      StopAsyncReplyingLspServer(lspserver, bnr)
    endfor
  finally
    nunmap <buffer> <F2>
    setreg('q', [])
    :%bw!
  endtry
enddef

# Test that the keys pending after ":LspGotoDefinition" also wait for the
# request sent again when the language server replies ContentModified.
def g:Test_GotoDefinition_PendingKeysWaitForRetry()
  silent! edit XGotoDefinitionPendingRetry.txt
  setline(1, ['use def', 'def'])
  var bnr = bufnr()
  var pos = {line: 1, character: 1}
  var location = {uri: util.LspBufnrToUri(bnr), range: {start: pos, end: pos}}
  var lspserver = MakeAsyncReplyingLspServer([])
  lspserver.isDefinitionProvider = true
  try
    job_stop(lspserver.job)
    # The reply to the request sent again comes a second later
    lspserver.job = StartSteppedStubServerJob([ContentModifiedReplies(1),
      [{jsonrpc: '2.0', id: 2, result: location}]])
    cursor(1, 5)
    exe "normal :LspGotoDefinition\<CR>rX"
    assert_equal(['use def', 'dXf'], getline(1, '$'))
  finally
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
  endtry
enddef

# Test that the keys pending after ":LspRename" in a mapping are read by the
# prompt for the new name, which opens when the language server replied to
# "textDocument/prepareRename", and that the keys after them act on the
# renamed text.
def g:Test_LspRename_PendingKeysWaitForRename()
  silent! edit XLspRenamePendingKeys.txt
  setline(1, ['foo bar foo'])
  var bnr = bufnr()
  var edit = {changes: {[util.LspBufnrToUri(bnr)]: [
    MakeTextEdit(0, 0, 0, 3, 'baz'), MakeTextEdit(0, 8, 0, 11, 'baz')]}}
  var range = {start: {line: 0, character: 0}, end: {line: 0, character: 3}}
  var lspserver = MakeAsyncReplyingLspServer([])
  lspserver.isRenameProvider = true
  lspserver.isRenamePrepareProvider = true
  job_stop(lspserver.job)
  # The reply to the rename comes a second after the one to prepareRename
  lspserver.job = StartSteppedStubServerJob([
    [{jsonrpc: '2.0', id: 1, result: range}],
    [{jsonrpc: '2.0', id: 2, result: edit}]])
  nnoremap <buffer> <F2> <Cmd>LspRename<CR><C-U>baz<CR>$rX
  try
    cursor(1, 1)
    feedkeys("\<F2>", 'xt')
    assert_equal(['baz bar baX'], getline(1, '$'))
  finally
    StopAsyncReplyingLspServer(lspserver, bnr)
    nunmap <buffer> <F2>
    :%bw!
  endtry
enddef

# Test that the keys pending after an LSP command stop waiting for the reply
# after the channel timeout, and that the request is not cancelled then.
def g:Test_PendingKeys_StopWaitingAfterTimeout()
  silent! edit XPendingKeysTimeout.txt
  setline(1, ['use def', 'def'])
  var bnr = bufnr()
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.running = true
  lspserver.ready = true
  lspserver.isDefinitionProvider = true
  # A language server that never replies
  lspserver.job = StartStubServerJob([], {timeout: 100})
  buf.BufLspServerSet(bnr, lspserver)
  try
    cursor(1, 5)
    exe "normal :LspGotoDefinition\<CR>rX"
    assert_equal(['use Xef', 'def'], getline(1, '$'))
    assert_equal(['textDocument/definition'],
		 lspserver.pendingRequests->values())
    assert_equal([], notifications->copy()
      ->filter((_, n) => n.method == '$/cancelRequest'))
  finally
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
  endtry
enddef

# Test that the keys pending after ":LspHover", which only shows something,
# don't wait for the reply.
def g:Test_LspHover_PendingKeysDontWait()
  silent! edit XLspHoverPendingKeys.txt
  setline(1, ['foo'])
  var bnr = bufnr()
  var lspserver = MakeAsyncReplyingLspServer([{contents: 'Foo'}])
  lspserver.isHoverProvider = true
  try
    cursor(1, 1)
    exe "normal :LspHover\<CR>rX"
    assert_equal(['Xoo'], getline(1, '$'))
    assert_equal(['textDocument/hover'], lspserver.pendingRequests->values())
    g:WaitForReplies()
  finally
    popup_clear()
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
  endtry
enddef

# The language server and the events of Test_PendingKeys_ChainedRequests().
var chainServer: dict<any> = {}
var chainEvents: list<string> = []

# Send the request "first" for a user action to "chainServer".  Its reply
# callback sends the request "second" and triggers the LspTestChain User
# autocommand.
def g:ChainRequests()
  chainServer.rpc_a('first', {}, (_, result: any, _) => {
    chainEvents->add($'{result} start')
    chainServer.rpc_a('second', {}, (_, r: any, _) => {
      chainEvents->add(r)
    })
    doautocmd <nomodeline> User LspTestChain
    chainEvents->add($'{result} end')
  }, {beforePendingKeys: true})
enddef

# Send the request "third" to "chainServer", for the LspTestChain User
# autocommand.
def ChainAutocmdRequest()
  chainServer.rpc_a('third', {}, (_, result: any, _) => {
    chainEvents->add(result)
  })
enddef

# Record that the keys after g:ChainRequests() ran.
def g:ChainKeys()
  chainEvents->add('keys')
enddef

# Test that the keys pending after a request for a user action also wait for
# the requests that its reply callback sends, which the callback doesn't wait
# for itself, but not for the requests that an autocommand triggered by the
# callback sends.
def g:Test_PendingKeys_ChainedRequests()
  silent! edit XPendingKeysChained.txt
  var bnr = bufnr()
  chainEvents = []
  chainServer = MakeTestLspServer([])
  chainServer.running = true
  chainServer.ready = true
  # Vim numbers the requests from 1, in the order they are sent.  Each reply
  # comes a second after the one before, so that the keys wait for the reply
  # to "second" only if they wait for the request, and run before the reply
  # to "third" unless they wait for that request.
  chainServer.job = StartSteppedStubServerJob([
    [{jsonrpc: '2.0', id: 1, result: 'first'}],
    [{jsonrpc: '2.0', id: 2, result: 'second'}],
    [{jsonrpc: '2.0', id: 3, result: 'third'}]])
  buf.BufLspServerSet(bnr, chainServer)
  augroup TestPendingKeysChain
    autocmd User LspTestChain ChainAutocmdRequest()
  augroup END
  try
    feedkeys(":call g:ChainRequests()\<CR>:call g:ChainKeys()\<CR>", 'xt')
    assert_equal(['first start', 'first end', 'second', 'keys'], chainEvents)
    g:WaitForReplies()
    assert_equal(['first start', 'first end', 'second', 'keys', 'third'],
		 chainEvents)
  finally
    augroup TestPendingKeysChain
      autocmd!
    augroup END
    augroup! TestPendingKeysChain
    StopAsyncReplyingLspServer(chainServer, bnr)
    chainServer = {}
    :%bw!
  endtry
enddef

# Test that ":LspFormat" applies the edits when the reply arrives, unless the
# buffer was changed before it did.
def g:Test_LspFormat_DropsReplyAfterChange()
  silent! edit XLspFormatAsync.txt
  var bnr = bufnr()
  try
    for change in [false, true]
      setline(1, ['int  x;'])
      var lspserver = MakeAsyncReplyingLspServer([[MakeTextEdit(0, 3, 0, 4, '')]])
      lspserver.isDocumentFormattingProvider = true
      :LspFormat
      assert_equal(['int  x;'], getline(1, '$'))
      if change
	append('$', 'int y;')
      endif
      g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
      assert_equal(change ? ['int  x;', 'int y;'] : ['int x;'],
		   getline(1, '$'), $'change: {change}')
      StopAsyncReplyingLspServer(lspserver, bnr)
      :%d _
    endfor
  finally
    :%bw!
  endtry
enddef

# Test that ":LspFormat" in a BufWritePre autocmd formats the buffer before it
# is written.
def g:Test_LspFormat_InBufWritePreFormatsBeforeWriting()
  silent! edit XLspFormatOnWrite.txt
  setline(1, ['int  x;'])
  var bnr = bufnr()
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isDocumentFormattingProvider = true
  # A synchronous request has an ID of its own
  lspserver.job = StartStubServerJob([{jsonrpc: '2.0',
    id: lspserver.nextSyncRpcId, result: [MakeTextEdit(0, 3, 0, 4, '')]}])
  buf.BufLspServerSet(bnr, lspserver)
  augroup TestLspFormatOnWrite
    autocmd BufWritePre <buffer> LspFormat
  augroup END
  try
    :write
    assert_equal(['int x;'], readfile('XLspFormatOnWrite.txt'))
  finally
    autocmd! TestLspFormatOnWrite
    augroup! TestLspFormatOnWrite
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
    delete('XLspFormatOnWrite.txt')
  endtry
enddef

# Test that ":LspFormat!" formats the buffer before the command that follows
# it runs.
def g:Test_LspFormatBang_WaitsForReply()
  silent! edit XLspFormatBang.txt
  setline(1, ['int  x;'])
  var bnr = bufnr()
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isDocumentFormattingProvider = true
  # A synchronous request has an ID of its own
  lspserver.job = StartStubServerJob([{jsonrpc: '2.0',
    id: lspserver.nextSyncRpcId, result: [MakeTextEdit(0, 3, 0, 4, '')]}])
  buf.BufLspServerSet(bnr, lspserver)
  try
    LspFormat! | write
    assert_equal(['int x;'], readfile('XLspFormatBang.txt'))
  finally
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
    delete('XLspFormatBang.txt')
  endtry
enddef

# Test that the pulled diagnostics are stored when the reply arrives, and that
# the request is sent again when the reply says that the content was modified.
def g:Test_PullDiagnostics_Async()
  DiagInitOnce()
  silent! edit XPullDiagnosticsAsync.txt
  setline(1, ['one', 'two'])
  var bnr = bufnr()
  var lspserver = MakeAsyncReplyingLspServer([])
  lspserver.features = {diagnostics: true}
  lspserver.isDiagnosticsProvider = true
  var queued: list<number> = []
  lspserver.queuePullDiagnostics = (queuedBnr: number) => {
    queued->add(queuedBnr)
  }
  var DiagMessages = () => diag.GetDiagsForBuf(bnr)->mapnew((_, d) => d.message)
  try
    job_stop(lspserver.job)
    lspserver.job = StartStubServerJob([{jsonrpc: '2.0', id: 1,
      error: {code: -32801, message: 'content modified'}}])
    lspserver.pullDiagnostics(bnr)
    g:WaitForAssert(() => assert_equal([bnr], queued))

    job_stop(lspserver.job)
    lspserver.job = StartStubServerJob([{jsonrpc: '2.0', id: 1,
      result: {kind: 'full', resultId: 'r1', items: [MakeLineDiag(1, 'pulled')]}}])
    lspserver.pullDiagnostics(bnr)
    assert_equal([], DiagMessages())
    g:WaitForAssert(() => assert_equal(['pulled'], DiagMessages()))
    assert_equal('r1', lspserver.diagnosticResultIds[bnr])
    assert_equal([bnr], queued)
  finally
    diag.DiagRemoveFile(bnr)
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
  endtry
enddef

# Test that closing a document cancels the pending pull diagnostics request
# for it, and that its reply is ignored.
def g:Test_PullDiagnostics_CancelledWhenDocumentClosed()
  DiagInitOnce()
  silent! edit XPullDiagnosticsClosed.txt
  var bnr = bufnr()
  var notifications: list<dict<any>> = []
  var lspserver = MakeAsyncReplyingLspServer([
    {kind: 'full', items: [MakeLineDiag(0, 'stale')]}, v:null], notifications)
  lspserver.features = {diagnostics: true}
  lspserver.isDiagnosticsProvider = true
  try
    lspserver.pullDiagnostics(bnr)
    lspserver.textdocDidClose(bnr)
    assert_equal([{method: '$/cancelRequest', params: {id: 1}}], notifications)
    assert_equal({}, lspserver.supersedableRequests)

    # The replies arrive in order, so once the second one has, the first one
    # was ignored
    var replied = false
    lspserver.rpc_a('test/barrier', {}, (_, _, _) => {
      replied = true
    })
    g:WaitForAssert(() => assert_true(replied))
    assert_equal([], diag.GetDiagsForBuf(bnr))
    assert_false(lspserver.diagnosticResultIds->has_key(bnr))
  finally
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
  endtry
enddef

# Returns a type hierarchy item for type "name" at line "lnum" (0-based) in
# the document "uri".
def MakeTypeHierarchyItem(name: string, uri: string, lnum: number): dict<any>
  var range = {start: {line: lnum, character: 6},
	       end: {line: lnum, character: 7}}
  return {name: name, kind: 5, uri: uri, range: range,
	  selectionRange: range->deepcopy()}
enddef

# Test that the type hierarchy is retrieved with a request for each type in
# it, and displayed once all the replies arrived.
def g:Test_TypeHierarchy_RetrievesAllLevels()
  silent! edit XTypeHierarchyAsync.txt
  setline(1, ['class A', 'class B', 'class C'])
  var bnr = bufnr()
  var uri = util.LspBufnrToUri(bnr)
  var lspserver = MakeAsyncReplyingLspServer([
    [MakeTypeHierarchyItem('C', uri, 2)],
    [MakeTypeHierarchyItem('B', uri, 1)],
    [MakeTypeHierarchyItem('A', uri, 0)],
    []])
  lspserver.isTypeHierarchyProvider = true
  try
    cursor(3, 7)
    lspserver.typeHierarchy(1)
    g:WaitForAssert(() => assert_notequal(-1,
      lspserver.typeHierPopup->winbufnr()))
    assert_equal(['▾ C (C)', '| ▾ B (C)', '| |   A (C)'],
		 lspserver.typeHierPopup->winbufnr()->getbufline(1, '$'))
  finally
    popup_clear()
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
  endtry
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
  var failed = {code: -32603, message: 'failed'}

  # Vim numbers the asynchronous requests on a new channel from 1.
  lspserver.job = StartStubServerJob([{jsonrpc: '2.0', id: 1, error: failed}])
  try
    lspserver.gotoDefinition(false, '', 0)
    g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
  finally
    job_stop(lspserver.job)
  endtry

  lspserver.job = StartStubServerJob([{jsonrpc: '2.0',
    id: lspserver.nextSyncRpcId, error: failed}])
  try
    assert_equal(null, lspserver.tagFunc('XNoSuchTag', '', {}))
  finally
    job_stop(lspserver.job)
  endtry
  assert_equal('Warn: symbol definition is not found', LastMessage())
  :%bw!
enddef

# Test that the tag function treats the pattern as a regexp with the "r" flag,
# as Vim does for ":tag /Foo" and when completing ":tag Fo<Tab>": it asks the
# server for the word the pattern starts with and returns the symbols whose
# name the pattern matches, each with its own name.
def g:Test_TagFunc_RegexpFlagMatchesSymbolNames()
  var fname = 'XTagFuncRegexp.txt'
  writefile(['MyFirst', 'MySecond', 'Other', 'XMyThing'], fname)
  silent! execute 'edit' fname
  var uri = util.LspBufnrToUri(bufnr())
  var lspserver = MakeTestLspServer([])
  lspserver.isWorkspaceSymbolProvider = true
  var queries: list<string> = []
  var symbols: list<dict<any>> = []
  for lnum in range(1, 4)
    var pos = {line: lnum - 1, character: 0}
    symbols->add({
      name: getline(lnum),
      location: {uri: uri, range: {start: pos, end: pos}}
    })
  endfor
  lspserver.rpc = (method: string, params: any, opts: dict<any> = {}) => {
    queries->add($'{method} {params.query}')
    return {result: symbols}
  }
  try
    var tags = lspserver.tagFunc('^My', 'r', {})
    assert_equal(['MyFirst', 'MySecond'], tags->mapnew((_, tag) => tag.name))
    assert_equal(['/\%1l\%1c/', '/\%2l\%1c/'], tags->mapnew((_, tag) => tag.cmd))
    assert_equal(['workspace/symbol My'], queries)

    queries = []
    assert_equal(['MySecond'],
      lspserver.tagFunc('My.*d$', 'r', {})->mapnew((_, tag) => tag.name))
    assert_equal(['workspace/symbol My'], queries)

    # Not anchored, as for ":tag /Thing", which finds the symbol, too.
    queries = []
    assert_equal(['XMyThing'],
      lspserver.tagFunc('Thing', 'r', {})->mapnew((_, tag) => tag.name))
    assert_equal(['workspace/symbol Thing'], queries)

    # The word under the cursor is looked up as a symbol name, not a definition.
    queries = []
    normal! gg0
    assert_equal(['MyFirst'],
      lspserver.tagFunc('MyFirst', 'r', {})->mapnew((_, tag) => tag.name))
    assert_equal(['workspace/symbol MyFirst'], queries)

    # Without the flag a name has to match completely.
    queries = []
    assert_equal(['MySecond'],
      lspserver.tagFunc('MySecond', '', {})->mapnew((_, tag) => tag.name))
    assert_equal(null, lspserver.tagFunc('My', '', {}))
    assert_equal(['workspace/symbol MySecond', 'workspace/symbol My'], queries)

    assert_equal(null, lspserver.tagFunc('^Nothing', 'r', {}))
  finally
    :%bw!
    delete(fname)
  endtry
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

# Test that the diagnostics of all the buffers are pulled when the progress of
# some work ends, and not on each notification before that.
def g:Test_ProcessNotif_Progress_PullsDiagnosticsOnEnd()
  var lspserver = MakeTestLspServer([])
  lspserver.isDiagnosticsProvider = true
  var queued = 0
  lspserver.queuePullDiagnosticsAllBuffers = () => {
    queued += 1
  }

  def Progress(value: dict<any>)
    handlers.ProcessNotif(lspserver, {jsonrpc: '2.0', method: '$/progress',
      params: {token: 'X-progress', value: value}})
  enddef

  try
    Progress({kind: 'begin', title: 'Indexing'})
    Progress({kind: 'report', message: '1/2', percentage: 50})
    Progress({kind: 'report', message: '2/2', percentage: 100})
    assert_equal(0, queued)

    Progress({kind: 'end'})
    assert_equal(1, queued)
  finally
    if g:LspProgress->has_key('X-progress')
      g:LspProgress->remove('X-progress')
    endif
  endtry
enddef

# Test that a stream of progress notifications fires the LspProgressUpdate
# autocmd once, after the last one, and that it sees the latest state.
def g:Test_ProcessNotif_Progress_CoalescesUpdateAutocmd()
  var lspserver = MakeTestLspServer([])
  g:ProgressUpdates = []
  augroup LspProgressTest
    au!
    au User LspProgressUpdate g:ProgressUpdates->add(
          \ deepcopy(g:LspProgress->get('X-progress', {})))
  augroup END

  def Progress(value: dict<any>)
    handlers.ProcessNotif(lspserver, {jsonrpc: '2.0', method: '$/progress',
      params: {token: 'X-progress', value: value}})
  enddef

  try
    Progress({kind: 'begin', title: 'Indexing'})
    Progress({kind: 'report', message: '1/2', percentage: 50})
    Progress({kind: 'report', message: '2/2', percentage: 100})
    assert_equal([], g:ProgressUpdates)
    g:WaitForAssert(() => assert_equal(1, g:ProgressUpdates->len()))
    assert_equal('2/2', g:ProgressUpdates[0].message)
    assert_equal(100, g:ProgressUpdates[0].percentage)

    # A notification after the autocmd fired fires it again.
    Progress({kind: 'end'})
    g:WaitForAssert(() => assert_equal(2, g:ProgressUpdates->len()))
    assert_equal({}, g:ProgressUpdates[1])
    sleep 150m
    assert_equal(2, g:ProgressUpdates->len())
  finally
    augroup LspProgressTest
      au!
    augroup END
    augroup! LspProgressTest
    unlet g:ProgressUpdates
    if g:LspProgress->has_key('X-progress')
      g:LspProgress->remove('X-progress')
    endif
  endtry
enddef

# Test that a document highlight request supersedes only the pending request
# for the same buffer.
def g:Test_DocHighlight_CancelsSupersededRequestForSameBuffer()
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.isDocumentHighlightProvider = true
  var lastId = 0
  lspserver.rpc_a = (_, _, _, _: dict<any> = {}) => {
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

# Test that a request whose reply was processed before rpc_a() returned, as a
# stand-in for it can do, is not cancelled by the next request.
def g:Test_GetCompletion_DoesNotCancelAnsweredRequest()
  silent! edit XGetCompletionAnswered.txt
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.isCompletionProvider = true
  lspserver.completionLazyDoc = false
  var lastId = 0
  lspserver.rpc_a = (_, _, Cb, _: dict<any> = {}) => {
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
  lspserver.rpc_a = (_, params, _, _: dict<any> = {}) => {
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

# Test that the inlay hints request for some lines of a buffer starts at the
# first one and ends at the start of the line after the last one, or at the
# end of the buffer.
def g:Test_InlayHintsShow_LineRange()
  silent! edit XInlayHintsLineRange.txt
  setline(1, ['a', 'b', 'c', 'd', 'end'])
  var lspserver = MakeTestLspServer([])
  lspserver.isInlayHintProvider = true
  lspserver.isClangdInlayHintsProvider = false
  var ranges: list<dict<any>> = []
  lspserver.rpc_a = (_, params, _, _: dict<any> = {}) => {
    ranges->add(params.range->deepcopy())
    return 0
  }

  lspserver.inlayHintsShow(bufnr(), 2, 3)
  lspserver.inlayHintsShow(bufnr(), 4, 5)
  lspserver.inlayHintsShow(bufnr(), 1, 9)

  var bufEnd: dict<number> = {line: 4, character: 3}
  assert_equal([
    {start: {line: 1, character: 0}, end: {line: 3, character: 0}},
    {start: {line: 3, character: 0}, end: bufEnd},
    {start: {line: 0, character: 0}, end: bufEnd}
  ], ranges)
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
  lspserver.debug = true
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
  lspserver.job = StartStubServerJob([{jsonrpc: '2.0', id: 1, error: error}])
  buf.BufLspServerSet(bufnr(), lspserver)
  try
    lspserver.pullDiagnostics(bufnr())
    g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
  finally
    buf.BufLspServerRemove(bufnr(), lspserver)
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

# Returns a running test language server providing inlay hints, semantic
# tokens and code lenses, which adds the replies it sends to "responses" and
# the buffer number of each document it requests the inlay hints, the semantic
# tokens or the code lenses of to "requested".
def MakeRefreshTestLspServer(responses: list<dict<any>>,
			     requested: list<number>): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isInlayHintProvider = true
  lspserver.isSemanticTokensProvider = true
  lspserver.isCodeLensProvider = true
  lspserver.sendResponse = function(CaptureResponse, [responses])
  lspserver.inlayHintsShow = (bnr: number, ..._) => {
    requested->add(bnr)
  }
  lspserver.semanticHighlightUpdate = (bnr: number) => {
    requested->add(bnr)
  }
  lspserver.codeLensShow = (bnr: number) => {
    requested->add(bnr)
  }
  return lspserver
enddef

# Edit three buffers, of which the second one is not shown in a window, and
# open their documents on "lspserver".  The document of the third buffer is
# opened on "otherServer" first, which then provides the features for it.
# Returns the buffer numbers.
def OpenRefreshTestDocuments(lspserver: dict<any>,
			     otherServer: dict<any>): list<number>
  # Showing a buffer attached to a language server refreshes its diagnostics
  DiagInitOnce()
  silent! edit XRefresh1.txt
  silent! new XRefresh2.txt
  :hide
  silent! new XRefresh3.txt
  var bufnrs = ['XRefresh1.txt', 'XRefresh2.txt', 'XRefresh3.txt']
    ->map((_, name) => bufnr(name))
  buf.BufLspServerSet(bufnrs[2], otherServer)
  otherServer.textdocDidOpen(bufnrs[2], 'text')
  for bnr in bufnrs
    buf.BufLspServerSet(bnr, lspserver)
    lspserver.textdocDidOpen(bnr, 'text')
  endfor
  return bufnrs
enddef

# Undo OpenRefreshTestDocuments().
def CloseRefreshTestDocuments(lspserver: dict<any>, otherServer: dict<any>,
			      bufnrs: list<number>)
  for bnr in bufnrs
    buf.BufLspServerRemove(bnr, lspserver)
    buf.BufLspServerRemove(bnr, otherServer)
  endfor
  :%bw!
enddef

# Test that a "workspace/inlayHint/refresh" request gets a reply, and then
# updates the inlay hints from the server right away in the documents shown in
# a window when in Normal mode, and else after a CursorHold in them.  Not when
# the inlay hints are not shown, and not the inlay hints of a document from
# another server.
def g:Test_InlayHintRefresh_UpdatesShownDocuments()
  var responses: list<dict<any>> = []
  var requested: list<number> = []
  var otherRequested: list<number> = []
  var lspserver = MakeRefreshTestLspServer(responses, requested)
  var otherServer = MakeRefreshTestLspServer([], otherRequested)
  var bufnrs = OpenRefreshTestDocuments(lspserver, otherServer)
  var NeedsUpdate = () => bufnrs->mapnew((_, bnr) =>
    bnr->getbufvar('LspInlayHintsNeedsUpdate', true))
  g:InlayHintRefreshTest = (id: number) => {
    lspserver.processRequest({jsonrpc: '2.0', id: id,
			      method: 'workspace/inlayHint/refresh'})
  }
  try
    for bnr in bufnrs
      setbufvar(bnr, 'LspInlayHintsNeedsUpdate', false)
    endfor
    g:InlayHintRefreshTest(1)
    assert_equal([{id: 1, result: null, error: {}}], responses)
    assert_equal([false, false, false], NeedsUpdate())

    # Not with g:LspOptionsSet(), which would show the inlay hints in every
    # buffer.
    opt.lspOptions.showInlayHints = true
    feedkeys("i\<Cmd>call g:InlayHintRefreshTest(2)\<CR>\<Esc>", 'xt')
    assert_equal([], requested)
    assert_equal([true, true, false], NeedsUpdate())

    g:InlayHintRefreshTest(3)
    g:WaitForAssert(() => assert_equal([bufnrs[0]], requested))
    assert_equal([false, true, false], NeedsUpdate())
    assert_equal([1, 2, 3], responses->mapnew((_, r) => r.id))

    exe $'sbuffer {bufnrs[1]}'
    inlayhints.BufferInit(lspserver, bufnrs[1])
    doautocmd CursorHold
    g:WaitForAssert(() => assert_equal(bufnrs[0 : 1], requested))
    assert_equal([], otherRequested)
  finally
    opt.lspOptions.showInlayHints = false
    unlet g:InlayHintRefreshTest
    CloseRefreshTestDocuments(lspserver, otherServer, bufnrs)
  endtry
enddef

# Test that a "workspace/codeLens/refresh" request gets a reply, and then
# updates the code lenses from the server right away in the documents shown
# in a window when in Normal mode, and else after a CursorHold in them.  Not
# when the code lenses are not shown, and not the code lenses of a document
# from another server.
def g:Test_CodeLensRefresh_UpdatesShownDocuments()
  var responses: list<dict<any>> = []
  var requested: list<number> = []
  var otherRequested: list<number> = []
  var lspserver = MakeRefreshTestLspServer(responses, requested)
  var otherServer = MakeRefreshTestLspServer([], otherRequested)
  var bufnrs = OpenRefreshTestDocuments(lspserver, otherServer)
  var NeedsUpdate = () => bufnrs->mapnew((_, bnr) =>
    bnr->getbufvar('LspCodeLensNeedsUpdate', true))
  g:CodeLensRefreshTest = (id: number) => {
    lspserver.processRequest({jsonrpc: '2.0', id: id,
			      method: 'workspace/codeLens/refresh'})
  }
  try
    for bnr in bufnrs
      setbufvar(bnr, 'LspCodeLensNeedsUpdate', false)
    endfor
    g:CodeLensRefreshTest(1)
    assert_equal([{id: 1, result: null, error: {}}], responses)
    assert_equal([false, false, false], NeedsUpdate())

    # Not with g:LspOptionsSet(), which would show the code lenses in every
    # buffer.
    opt.lspOptions.showCodeLens = true
    feedkeys("i\<Cmd>call g:CodeLensRefreshTest(2)\<CR>\<Esc>", 'xt')
    assert_equal([], requested)
    assert_equal([true, true, false], NeedsUpdate())

    g:CodeLensRefreshTest(3)
    assert_equal([bufnrs[0]], requested)
    assert_equal([false, true, false], NeedsUpdate())
    assert_equal([1, 2, 3], responses->mapnew((_, r) => r.id))

    codelens.BufferInit(lspserver, bufnrs[1])
    assert_equal([bufnrs[0]], requested)
    exe $'sbuffer {bufnrs[1]}'
    doautocmd CursorHold
    assert_equal(bufnrs[0 : 1], requested)
    assert_equal([], otherRequested)
  finally
    opt.lspOptions.showCodeLens = false
    unlet g:CodeLensRefreshTest
    CloseRefreshTestDocuments(lspserver, otherServer, bufnrs)
  endtry
enddef

# Test that a "workspace/semanticTokens/refresh" request gets a reply, and
# then updates the semantic highlighting from the server in the documents
# shown in a window, and in the other documents when they are shown in one
# again.  Not when semantic highlighting is off, and not the semantic
# highlighting of a document from another server.
def g:Test_SemanticTokensRefresh_UpdatesShownDocuments()
  var responses: list<dict<any>> = []
  var requested: list<number> = []
  var otherRequested: list<number> = []
  var lspserver = MakeRefreshTestLspServer(responses, requested)
  var otherServer = MakeRefreshTestLspServer([], otherRequested)
  var bufnrs = OpenRefreshTestDocuments(lspserver, otherServer)
  var Refresh = (id: number) => {
    lspserver.processRequest({jsonrpc: '2.0', id: id,
			      method: 'workspace/semanticTokens/refresh'})
  }
  var UpdatePending = () => bufnrs->mapnew((_, bnr) =>
    bnr->getbufvar('LspSemanticTimer', 0) > 0)
  var RefreshWhenShown = (bnr: number) =>
    autocmd_get({group: 'LspSemanticRefresh', pattern: $'<buffer={bnr}>'})
    ->len()
  try
    Refresh(1)
    assert_equal([{id: 1, result: null, error: {}}], responses)
    assert_equal([false, false, false], UpdatePending())

    g:LspOptionsSet({semanticHighlight: true, semanticHighlightDelay: 1})
    Refresh(2)
    assert_equal([2], responses[1 :]->mapnew((_, r) => r.id))
    assert_equal([true, false, false], UpdatePending())
    assert_equal([0, 1, 0], bufnrs->mapnew((_, bnr) => RefreshWhenShown(bnr)))
    g:WaitForAssert(() => assert_equal([bufnrs[0]], requested))

    exe $'sbuffer {bufnrs[1]}'
    g:WaitForAssert(() => assert_equal(bufnrs[0 : 1], requested))
    assert_equal(0, RefreshWhenShown(bufnrs[1]))
    assert_equal([], otherRequested)
  finally
    g:LspOptionsSet({semanticHighlight: false, semanticHighlightDelay: 1000})
    CloseRefreshTestDocuments(lspserver, otherServer, bufnrs)
  endtry
enddef

# Test that detaching a buffer from its language servers cancels the update of
# its semantic highlighting deferred until it is shown in a window.
def g:Test_SemanticTokensRefresh_DetachCancelsUpdateWhenShown()
  var lspserver = MakeRefreshTestLspServer([], [])
  silent! edit XSemanticRefreshDetach1.txt
  silent! new XSemanticRefreshDetach2.txt
  var bnr = bufnr()
  :hide
  buf.BufLspServerSet(bnr, lspserver)
  lspserver.textdocDidOpen(bnr, 'text')
  var acmd = {group: 'LspSemanticRefresh', pattern: $'<buffer={bnr}>'}
  g:LspOptionsSet({semanticHighlight: true})
  try
    lspserver.processRequest({jsonrpc: '2.0', id: 1,
			      method: 'workspace/semanticTokens/refresh'})
    assert_equal(1, autocmd_get(acmd)->len())
    lsp.RemoveFile(bnr)
    assert_equal([], autocmd_get(acmd))
  finally
    g:LspOptionsSet({semanticHighlight: false})
    buf.BufLspServerRemove(bnr, lspserver)
    :%bw!
  endtry
enddef

# Test that a reply with no inlay hints removes the inlay hints shown in the
# buffer, and that one without a result, as when the request was cancelled,
# leaves them as they are.
def g:Test_InlayHintsReply_RemovesHintsWhenThereAreNone()
  if prop_type_get('LspInlayHintsType')->empty()
    inlayhints.InitOnce()
  endif
  silent! edit XInlayHintsNone.txt
  setline(1, ['int x = f(1);'])
  var lspserver = MakeTestLspServer([])
  var hint = {position: {line: 0, character: 10}, label: 'a:', kind: 2}
  var Hints = () => prop_list(1, {types: ['LspInlayHintsParam']})->len()

  inlayhints.InlayHintsReply(lspserver, [hint], {}, bufnr())
  assert_equal(1, Hints())
  inlayhints.InlayHintsReply(lspserver, null, {}, bufnr())
  assert_equal(1, Hints())
  inlayhints.InlayHintsReply(lspserver, [], {}, bufnr())
  assert_equal(0, Hints())
  :%bw!
enddef

# Test that a reply received in Insert mode leaves the inlay hints shown in
# the buffer as they are, and makes the next cursor rest request them again.
def g:Test_InlayHintsReply_KeepsHintsInInsertMode()
  if prop_type_get('LspInlayHintsType')->empty()
    inlayhints.InitOnce()
  endif
  silent! edit XInlayHintsInsertMode.txt
  setline(1, ['int x = f(1);'])
  var bnr = bufnr()
  var lspserver = MakeTestLspServer([])
  var hint = {position: {line: 0, character: 10}, label: 'a:', kind: 2}
  var Hints = () => prop_list(1, {types: ['LspInlayHintsParam']})->len()

  inlayhints.InlayHintsReply(lspserver, [hint], {}, bnr)
  assert_equal(1, Hints())
  setbufvar(bnr, 'LspInlayHintsNeedsUpdate', false)

  var modeInReply = ''
  timer_start(10, (_) => {
    modeInReply = mode()
    inlayhints.InlayHintsReply(lspserver, [], {}, bnr)
    feedkeys("\<Esc>", 't')
  })
  feedkeys('i', 'xt!')

  assert_equal('i', modeInReply)
  assert_equal(1, Hints())
  assert_true(bnr->getbufvar('LspInlayHintsNeedsUpdate', false))
  :%bw!
enddef

# Test that the inlay hints are requested only for the lines shown in a window
# and one window height above and below them, and requested again when the
# window is scrolled past those lines: right away in Normal mode, and after a
# CursorHold in Insert mode, where no update requests them.  Not for a buffer
# that no window shows.
def g:Test_InlayHints_RequestVisibleLines()
  if prop_type_get('LspInlayHintsType')->empty()
    inlayhints.InitOnce()
  endif
  silent! edit XInlayHintsVisible.txt
  :only
  setline(1, range(1, 1000)->mapnew((_, n) => $'line {n}'))
  var bnr = bufnr()
  var hidden = bufadd('XInlayHintsHidden.txt')
  hidden->bufload()
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isInlayHintProvider = true
  var requested: list<list<number>> = []
  lspserver.inlayHintsShow = (b: number, first: number = 1, last: number = 0) => {
    requested->add([b, first, last])
  }
  opt.lspOptions.showInlayHints = true
  try
    for b in [bnr, hidden]
      buf.BufLspServerSet(b, lspserver)
      inlayhints.BufferInit(lspserver, b)
    endfor
    var h = winheight(0)
    assert_true(h > 3)

    inlayhints.LspInlayHintsUpdateNow(bnr)
    assert_equal([[bnr, 1, line('w$') + h]], requested)
    assert_false(bnr->getbufvar('LspInlayHintsNeedsUpdate', true))

    # Scrolling within the requested lines requests nothing
    execute "normal! 3\<C-E>"
    assert_equal(4, line('w0'))
    :doautocmd <nomodeline> WinScrolled
    assert_equal(1, requested->len())

    # Scrolling past them requests the lines shown now
    cursor(500, 1)
    normal! zt
    :doautocmd <nomodeline> WinScrolled
    assert_equal([[bnr, 500 - h, line('w$') + h]], requested[1 : ])

    # Not in Insert mode, but at the next CursorHold
    g:InlayHintsUpdateNowTest = () => inlayhints.LspInlayHintsUpdateNow(bnr)
    feedkeys("i\<Cmd>call cursor(900, 1)\<CR>\<Cmd>normal! zt\<CR>"
	     .. "\<Cmd>doautocmd <nomodeline> WinScrolled\<CR>"
	     .. "\<Cmd>call g:InlayHintsUpdateNowTest()\<CR>\<Esc>", 'xt')
    assert_equal(900, line('w0'))
    assert_equal(2, requested->len())
    assert_true(bnr->getbufvar('LspInlayHintsNeedsUpdate', false))
    :doautocmd <nomodeline> CursorHold
    assert_equal([[bnr, 900 - h, line('w$') + h]], requested[2 : ])

    # A buffer that no window shows is updated once it is shown
    inlayhints.LspInlayHintsUpdateNow(hidden)
    assert_equal(3, requested->len())
    assert_true(hidden->getbufvar('LspInlayHintsNeedsUpdate', false))
    execute $'sbuffer {hidden}'
    assert_equal([hidden, 1, 1], requested[-1])
    assert_equal(4, requested->len())
  finally
    unlet! g:InlayHintsUpdateNowTest
    opt.lspOptions.showInlayHints = false
    for b in [bnr, hidden]
      autocmd_delete([{group: 'LspInlayHints', bufnr: b}])
      buf.BufLspServerRemove(b, lspserver)
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

# Diagnostics published for an unloaded buffer are ignored and must not load
# it, as loading it attaches it to the language servers again.  So a buffer
# drops its diagnostics when it is unloaded, as they would go stale.
def g:Test_DiagNotification_IgnoresUnloadedBuffer()
  g:LspOptionsSet({autoHighlightDiags: false})
  silent! edit XDiagUnloadedBuffer.txt
  var bnr = bufnr()
  var uri = util.LspBufnrToUri(bnr)
  var lspserver = MakeTestLspServer([])
  lspserver.featureEnabled = (_) => true
  var errDiag = {
    range: {
      start: {line: 0, character: 0},
      end: {line: 0, character: 1}
    },
    severity: 1,
    message: 'error'
  }

  # A loaded buffer gets the diagnostics without being attached, and loses
  # them when it is unloaded
  diag.DiagNotification(lspserver, uri, [errDiag], 'push')
  assert_equal(1, diag.DiagsGetErrorCount(bnr).Error)
  :enew
  assert_false(bufloaded(bnr))
  assert_equal(0, diag.DiagsGetErrorCount(bnr).Error)

  diag.DiagNotification(lspserver, uri, [errDiag], 'push')
  assert_false(bufloaded(bnr))
  assert_equal(0, diag.DiagsGetErrorCount(bnr).Error)
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

  # The buffers are kept loaded: the diagnostics published for an unloaded
  # buffer are ignored
  silent! hide edit XDiagClosed.c
  var closed = bufnr()
  var closedUri = util.LspBufnrToUri(closed)
  lspserver.textdocDidOpen(closed, 'c')
  handlers.ProcessNotif(lspserver, PublishDiagsNotif(closedUri, ['open']))
  assert_equal(['open'], DiagMsgs(diag.GetDiagsForBuf(closed)))
  lspserver.textdocDidClose(closed)
  assert_false(lspserver.docBufnrs->has_key(closedUri))
  handlers.ProcessNotif(lspserver, PublishDiagsNotif(closedUri, []))
  assert_equal([], diag.GetDiagsForBuf(closed))

  silent! hide edit XDiagWipedOut.c
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
  # The plugin draws the highlights for the diagnostic tags with ALE.
  DiagInitOnce()
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

# The related information of a diagnostic sent to ALE is in the detail of its
# entry, after the message, for ":ALEDetail".  An entry without related
# information has no detail.
def g:Test_AleSupport_RelatedInformationInDetail()
  var aleStub = InstallAleStub()
  var otherFname = WriteRelatedInfoFile('XAleRelatedOther.c')
  silent! edit XAleRelated.c
  setline(1, ['int x;', 'int x;'])
  var bnr = bufnr()
  var clangd = MakeDiagServer('clangd')
  buf.BufLspServerSet(bnr, clangd)
  try
    var diags: list<dict<any>> = [
      RelatedInfoDiag(bnr, otherFname, 32),
      MakeLineDiag(0, 'no related information')
    ]
    diag.DiagNotification(clangd, util.LspBufnrToUri(bnr), diags, 'push')
    var loclist: list<dict<any>> = g:LspTestAleCalls[-1][4]
    assert_equal(["redefinition of 'x'",
		  'XAleRelated.c:1:5: previous definition is here',
		  'XAleRelatedOther.c:2:17: other'],
		 loclist[1].detail->split("\n"))
    assert_false(loclist[0]->has_key('detail'))
  finally
    delete(otherFname)
    RemoveAleStub(aleStub)
    :%bw!
  endtry
enddef

# The diagnostics of a buffer that ALE doesn't track (e.g. one it dropped on
# BufDelete) are not cleared in ALE, which would make ALE track the buffer.
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
  # The same diagnostics sent again are not sent to ALE again, so each
  # publish sends another message.
  var msgCount = 0
  g:LspTestPublishDiags = () => {
    msgCount += 1
    diag.DiagNotification(clangd, uri,
			  [MakeLineDiag(0, $'clangd diag {msgCount}')], 'push')
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
  assert_equal({clangd: [$'clangd diag {msgCount}']}, AleResultsByLinter())

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

# ALE has the "E", "W" and "I" types and treats any other one as an error, so
# a hint is sent to ALE as information.  A diagnostic without a severity is an
# error.
def g:Test_AleSupport_DiagTypes()
  var aleStub = InstallAleStub()
  silent! edit XAleSupportTypes.c
  setline(1, ['int a;', 'int b;', 'int c;', 'int d;', 'int e;'])
  var bnr = bufnr()
  var clangd = MakeDiagServer('clangd')
  buf.BufLspServerSet(bnr, clangd)

  var diags: list<dict<any>> = [
    MakeDiag(0, 0, 1, 'error'),
    MakeDiag(1, 0, 2, 'warning'),
    MakeDiag(2, 0, 3, 'info'),
    MakeDiag(3, 0, 4, 'hint'),
    MakeDiag(4, 0, 0, 'no severity')
  ]
  diag.DiagNotification(clangd, util.LspBufnrToUri(bnr), diags, 'push')
  assert_equal([['error', 'E'], ['warning', 'W'], ['info', 'I'],
		['hint', 'I'], ['no severity', 'E']],
	       g:LspTestAleCalls[-1][4]->mapnew((_, v) => [v.text, v.type]))

  diag.DiagRemoveFile(bnr)
  buf.BufLspServerRemove(bnr, clangd)
  RemoveAleStub(aleStub)
  :%bw!
enddef

# The same diagnostics sent again for the same text are neither drawn again
# nor reported with LspDiagsUpdated, and a buffer displayed again keeps the
# diagnostics drawn in it (#145).  After a text change, or with other
# diagnostics or options, they are drawn again.
def g:Test_DiagNotification_SkipsUnchangedDiags()
  DiagInitOnce()
  silent! edit XDiagsUnchanged.c
  setline(1, ['int a;', 'int b;', 'int c;'])
  var bnr = bufnr()
  var uri = util.LspBufnrToUri(bnr)
  var lspserver = MakeDiagServer('srv')
  g:DiagsUpdatedCount = 0
  augroup TestDiagsUnchanged
    autocmd!
    autocmd User LspDiagsUpdated g:DiagsUpdatedCount += 1
  augroup END
  var SignLnums = () => sign_getplaced(bnr, {group: 'LSPDiag'})[0].signs
    ->mapnew((_, sign) => sign.lnum)

  try
    var diags = [MakeLineDiag(0, 'a'), MakeLineDiag(1, 'b')]
    diag.DiagNotification(lspserver, uri, diags->deepcopy(), 'push')
    assert_equal([1, 2], SignLnums())
    assert_equal(1, g:DiagsUpdatedCount)

    # Remove a sign behind the plugin's back to see whether it draws again.
    sign_unplace('LSPDiag', {buffer: bnr, id: sign_getplaced(bnr,
      {group: 'LSPDiag', lnum: 1})[0].signs[0].id})
    diag.DiagNotification(lspserver, uri, diags->deepcopy(), 'push')
    assert_equal([2], SignLnums())
    assert_equal(1, g:DiagsUpdatedCount)
    # As when the buffer is displayed in a window again
    diag.DiagsRefresh(bnr)
    assert_equal([2], SignLnums())

    # The text changed
    setline(3, 'int d;')
    diag.DiagNotification(lspserver, uri, diags->deepcopy(), 'push')
    assert_equal([1, 2], SignLnums())
    assert_equal(2, g:DiagsUpdatedCount)

    # Other diagnostics
    diag.DiagNotification(lspserver, uri, [MakeLineDiag(2, 'c')], 'push')
    assert_equal([3], SignLnums())
    assert_equal(3, g:DiagsUpdatedCount)

    # Other options draw them again.
    sign_unplace('LSPDiag', {buffer: bnr})
    diag.DiagsRefresh(bnr)
    assert_equal([], SignLnums())
    g:LspOptionsSet({showDiagWithVirtualText: true})
    g:LspOptionsSet({showDiagWithVirtualText: false})
    assert_equal([3], SignLnums())

    # No diagnostics anymore
    diag.DiagNotification(lspserver, uri, [], 'push')
    assert_equal([], SignLnums())
    assert_equal(4, g:DiagsUpdatedCount)
    diag.DiagNotification(lspserver, uri, [], 'push')
    assert_equal(4, g:DiagsUpdatedCount)
  finally
    augroup TestDiagsUnchanged
      autocmd!
    augroup END
    augroup! TestDiagsUnchanged
    diag.DiagRemoveFile(bnr)
    :%bw!
  endtry
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

# Return the [lnum, col, length] of the text properties of type "propType" in
# the current buffer.
def PropLocations(propType: string): list<list<number>>
  return prop_list(1, {end_lnum: line('$'), types: [propType]})
    ->mapnew((_, p) => [p.lnum, p.col, p.length])
enddef

# A diagnostic with the Unnecessary or the Deprecated tag highlights its text
# with "LspDiagInlineUnnecessary" or "LspDiagInlineDeprecated", in addition to
# the highlight for its severity.  A hint with a tag gets only those
# highlights: no sign, no virtual text and no highlight for its severity,
# unless "highlightDiagInline" is off.  Unsupported tags are ignored.
def g:Test_DiagTags_Visuals()
  DiagInitOnce()
  silent! edit XDiagTags.txt
  setline(1, ['int unused, xyz;', 'old_api();', 'int yyy;', 'int zzz;'])
  var bnr = bufnr()
  g:LspOptionsSet({showDiagWithVirtualText: true,
		   diagVirtualTextMostSevere: true})
  var lspserver = MakeDiagServer('srv')
  var diags: list<dict<any>> = [
    MakeDiag(0, 4, 4, 'unused')->extend({tags: [1]}),
    MakeDiag(0, 12, 4, 'plain hint'),
    MakeDiag(1, 0, 2, 'deprecated')->extend({tags: [2, 1, 2]}),
    MakeDiag(2, 4, 4, 'unsupported tag')->extend({tags: [99, 'a']}),
    MakeDiag(3, 4, 4, 'null tags')->extend({tags: v:null})
  ]
  diag.DiagNotification(lspserver, util.LspBufnrToUri(bnr), diags, 'push')

  var Signs = () => sign_getplaced(bnr, {group: 'LSPDiag'})[0].signs
    ->mapnew((_, s) => [s.lnum, s.name])->sort()
  assert_equal([[1, 'LspDiagHint'], [2, 'LspDiagWarning'],
		[3, 'LspDiagHint'], [4, 'LspDiagHint']], Signs())
  assert_equal([[1, 13, 3], [3, 5, 3], [4, 5, 3]],
	       PropLocations('LspDiagInlineHint'))
  assert_equal([[2, 1, 3]], PropLocations('LspDiagInlineWarning'))
  assert_equal([[1, 5, 3], [2, 1, 3]],
	       PropLocations('LspDiagInlineUnnecessary'))
  assert_equal([[2, 1, 3]], PropLocations('LspDiagInlineDeprecated'))
  # The most severe diagnostic on a line is chosen from the other ones
  assert_equal([[1, '┌─ plain hint'], [2, '┌─ deprecated'],
		[3, '┌─ unsupported tag'], [4, '┌─ null tags']],
	       DiagVirtualTexts()->mapnew((_, v) => [v[0], v[2]]))

  g:LspOptionsSet({diagVirtualTextMostSevere: false})
  assert_equal([1, 2, 3, 4], DiagVirtualTexts()->mapnew((_, v) => v[0]))

  g:LspOptionsSet({highlightDiagInline: false})
  assert_equal([[1, 'LspDiagHint'], [1, 'LspDiagHint'], [2, 'LspDiagWarning'],
		[3, 'LspDiagHint'], [4, 'LspDiagHint']], Signs())
  assert_equal(0, PropCount('^LspDiagInline'))
  assert_equal([1, 1, 2, 3, 4],
	       DiagVirtualTexts()->mapnew((_, v) => v[0])->sort('n'))

  g:LspOptionsSet({highlightDiagInline: true})
  assert_equal(4, Signs()->len())
  assert_equal([[1, 5, 3], [2, 1, 3]],
	       PropLocations('LspDiagInlineUnnecessary'))

  g:LspOptionsSet({showDiagWithVirtualText: false})
  diag.DiagRemoveFile(bnr)
  :%bw!
enddef

# The "LspDiagInlineUnnecessary" highlight group is linked to "Comment" and
# "LspDiagInlineDeprecated" strikes through the text.  The latter is set again
# for a color scheme that clears it, but a definition of its own is kept.
def g:Test_DiagTags_Highlights()
  DiagInitOnce()
  const strikethrough: dict<any> = {term: {strikethrough: true},
				    cterm: {strikethrough: true},
				    gui: {strikethrough: true}}
  var Deprecated = (): dict<any> => hlget('LspDiagInlineDeprecated')[0]
  assert_equal('Comment', hlget('LspDiagInlineUnnecessary')[0].linksto)
  assert_equal(strikethrough, Deprecated()->filter((k, _) => k =~ 'term\|gui'))

  try
    :highlight clear LspDiagInlineDeprecated
    assert_true(Deprecated()->get('cleared', false))
    :doautocmd <nomodeline> ColorScheme
    assert_equal(strikethrough,
		 Deprecated()->filter((k, _) => k =~ 'term\|gui'))

    :highlight! link LspDiagInlineDeprecated Comment
    :doautocmd <nomodeline> ColorScheme
    assert_equal('Comment', Deprecated()->get('linksto', ''))
  finally
    :highlight! link LspDiagInlineDeprecated NONE
    :doautocmd <nomodeline> ColorScheme
  endtry
  assert_equal(strikethrough, Deprecated()->filter((k, _) => k =~ 'term\|gui'))
enddef

# Return the diagnostics for Test_DiagTags_Listed() and Test_DiagTags_Ale():
# an error, a hint with each tag, a hint without one and a warning with a tag.
def ListedTestDiags(): list<dict<any>>
  return [
    MakeDiag(0, 0, 1, 'error'),
    MakeDiag(1, 4, 4, 'unused')->extend({tags: [1]}),
    MakeDiag(2, 0, 4, 'plain hint'),
    MakeDiag(3, 0, 4, 'deprecated')->extend({tags: [2]}),
    MakeDiag(4, 0, 2, 'tagged warning')->extend({tags: [1]})
  ]
enddef

# A hint displayed only by the highlight for its tag is skipped by the
# ":LspDiag" jumps and left out of the counts and the diagnostics location
# list, which is updated right away when "highlightDiagInline" changes.
# ":LspDiag current" still displays it.  A diagnostic of another severity with
# a tag is listed, and with "highlightDiagInline" off, so is the hint.
def g:Test_DiagTags_Listed()
  DiagInitOnce()
  silent! edit XDiagTagsListed.txt
  setline(1, ['int a;', 'int unused;', 'int b;', 'old_api();', 'int c;'])
  var bnr = bufnr()
  var winid = win_getid()
  g:LspOptionsSet({autoPopulateDiags: true, showDiagInPopup: false})
  var lspserver = MakeDiagServer('srv')
  diag.DiagNotification(lspserver, util.LspBufnrToUri(bnr), ListedTestDiags(),
			'push')
  # Returns the line that the ":LspDiag" command "cmd" jumps to from the start
  # of line "lnum".
  var JumpFrom = (lnum: number, cmd: string): number => {
    cursor(lnum, 1)
    execute(cmd)
    return line('.')
  }
  try
    assert_equal({Error: 1, Warn: 1, Info: 0, Hint: 1},
		 diag.DiagsGetErrorCount(bnr))
    assert_equal([['error', 'plain hint', 'tagged warning']],
		 DiagLocListTexts(winid))

    assert_equal(3, JumpFrom(1, 'LspDiag next'))
    assert_equal(5, JumpFrom(3, 'LspDiag next'))
    assert_equal(5, JumpFrom(1, ':2LspDiag next'))
    assert_equal(1, JumpFrom(5, 'LspDiag nextWrap'))
    assert_equal(3, JumpFrom(5, 'LspDiag prev'))
    assert_equal(1, JumpFrom(3, 'LspDiag prev'))
    assert_equal(5, JumpFrom(1, 'LspDiag prevWrap'))
    assert_equal(1, JumpFrom(3, 'LspDiag first'))
    assert_equal(5, JumpFrom(1, 'LspDiag last'))
    cursor(2, 1)
    assert_match('No more diagnostics found on this line',
		 execute('LspDiag here'))
    assert_equal([2, 1], [line('.'), col('.')])
    assert_equal(['unused'], execute('LspDiag current')->split("\n"))

    g:LspOptionsSet({highlightDiagInline: false})
    assert_equal({Error: 1, Warn: 1, Info: 0, Hint: 3},
		 diag.DiagsGetErrorCount(bnr))
    assert_equal([['error', 'unused', 'plain hint', 'deprecated',
		   'tagged warning']], DiagLocListTexts(winid))
    assert_equal(2, JumpFrom(1, 'LspDiag next'))
    assert_equal(4, JumpFrom(5, 'LspDiag prev'))

    g:LspOptionsSet({highlightDiagInline: true})
    assert_equal([['error', 'plain hint', 'tagged warning']],
		 DiagLocListTexts(winid))
  finally
    g:LspOptionsSet({highlightDiagInline: true, showDiagInPopup: true})
    DiagLocListTestCleanup([bnr])
  endtry
enddef

# A hint displayed only by the highlight for its tag isn't sent to ALE.  The
# diagnostics are sent again right away when "highlightDiagInline" changes.
# ALE draws the other diagnostics, and the plugin draws only the highlights for
# the tags, of every diagnostic.
def g:Test_DiagTags_Ale()
  DiagInitOnce()
  var aleStub = InstallAleStub()
  silent! edit XDiagTagsAle.c
  setline(1, ['int a;', 'int unused;', 'int b;', 'old_api();', 'int c;'])
  var bnr = bufnr()
  var clangd = MakeDiagServer('clangd')
  buf.BufLspServerSet(bnr, clangd)
  g:LspOptionsSet({showDiagWithVirtualText: true})
  try
    diag.DiagNotification(clangd, util.LspBufnrToUri(bnr), ListedTestDiags(),
			  'push')
    assert_equal({clangd: ['error', 'plain hint', 'tagged warning']},
		 AleResultsByLinter())
    assert_equal([[2, 5, 3], [5, 1, 3]],
		 PropLocations('LspDiagInlineUnnecessary'))
    assert_equal([[4, 1, 3]], PropLocations('LspDiagInlineDeprecated'))
    assert_equal(3, PropCount('^LspDiag'))
    assert_equal([], sign_getplaced(bnr, {group: 'LSPDiag'})[0].signs)

    # The tag highlights go with the diagnostics.
    diag.DiagNotification(clangd, util.LspBufnrToUri(bnr),
			  ListedTestDiags()[: 1], 'push')
    assert_equal([[2, 5, 3]], PropLocations('LspDiagInlineUnnecessary'))
    assert_equal(1, PropCount('^LspDiag'))
    diag.DiagNotification(clangd, util.LspBufnrToUri(bnr), ListedTestDiags(),
			  'push')
    assert_equal(3, PropCount('^LspDiag'))

    g:LspOptionsSet({highlightDiagInline: false})
    assert_equal({clangd: ['error', 'unused', 'plain hint', 'deprecated',
			   'tagged warning']}, AleResultsByLinter())
    assert_equal(0, PropCount('^LspDiag'))
    g:LspOptionsSet({highlightDiagInline: true})
    assert_equal({clangd: ['error', 'plain hint', 'tagged warning']},
		 AleResultsByLinter())
    assert_equal(3, PropCount('^LspDiag'))

    # Without ALE, the plugin draws everything again.
    g:LspOptionsSet({aleSupport: false, autoHighlightDiags: true})
    assert_equal(3, sign_getplaced(bnr, {group: 'LSPDiag'})[0].signs->len())
    g:LspOptionsSet({aleSupport: true, autoHighlightDiags: false})
    assert_equal([], sign_getplaced(bnr, {group: 'LSPDiag'})[0].signs)
    assert_equal(3, PropCount('^LspDiag'))
  finally
    g:LspOptionsSet({showDiagWithVirtualText: false})
    g:LspOptionsSet({highlightDiagInline: true})
    diag.DiagRemoveFile(bnr)
    buf.BufLspServerRemove(bnr, clangd)
    RemoveAleStub(aleStub)
    :%bw!
  endtry
enddef

# Write the file "fname" for the related information of a diagnostic, with a
# multibyte character before the location on its second line.  Returns its
# full path.
def WriteRelatedInfoFile(fname: string): string
  writefile(['/* other */', 'int 😊_x; int other;'], fname)
  return fname->fnamemodify(':p')
enddef

# Returns a redefinition diagnostic on line 2 of buffer "bnr" with related
# information: the previous definition on line 1 of the buffer, and a location
# in the file "otherFname" on line 2, after a character that takes two UTF-16
# code units.  The offsets are in "posEncoding".
def RelatedInfoDiag(bnr: number, otherFname: string,
		    posEncoding: number): dict<any>
  var otherStart: number = posEncoding == 16 ? 14 : 13
  return {
    range: {start: {line: 1, character: 4}, end: {line: 1, character: 5}},
    severity: 1,
    message: "redefinition of 'x'",
    relatedInformation: [
      {location: {uri: util.LspBufnrToUri(bnr),
		  range: {start: {line: 0, character: 4},
			  end: {line: 0, character: 5}}},
       message: 'previous definition is here'},
      {location: {uri: util.LspFileToUri(otherFname),
		  range: {start: {line: 1, character: otherStart},
			  end: {line: 1, character: otherStart + 5}}},
       message: 'other'}
    ]
  }
enddef

# The related information of a diagnostic is displayed after its message by
# ":LspDiag current", in a popup or in the message area, with the location of
# each item as compilers print it.  Its items follow the diagnostic in the
# diagnostics location list.  The positions are decoded from the encoding of
# the server, and encoded back for a code action request, without loading
# the files that aren't in a buffer.
def g:Test_DiagRelatedInformation()
  g:LspOptionsSet({autoHighlightDiags: false})
  var otherFname = WriteRelatedInfoFile('XDiagRelatedOther.c')
  silent! edit XDiagRelated.c
  setline(1, ['int x;', 'int x;'])
  var bnr = bufnr()
  var winid = win_getid()
  var lspserver = MakeDiagServer('srv')
  lspserver.posEncoding = 16
  lspserver.needOffsetEncoding = true
  try
    diag.DiagNotification(lspserver, util.LspBufnrToUri(bnr),
			  [RelatedInfoDiag(bnr, otherFname, 16)], 'push')
    assert_false(otherFname->bufexists())
    assert_equal(RelatedInfoDiag(bnr, otherFname, 32).relatedInformation,
		 diag.GetDiagsForBuf(bnr)[0].relatedInformation)

    var expected = ["redefinition of 'x'",
		    'XDiagRelated.c:1:5: previous definition is here',
		    'XDiagRelatedOther.c:2:17: other']
    g:LspOptionsSet({showDiagInPopup: false})
    cursor(2, 5)
    assert_equal(expected, execute('LspDiag current')->split("\n"))
    g:LspOptionsSet({showDiagInPopup: true})
    :LspDiag current
    var ids = popup_list()
    assert_equal(1, ids->len())
    assert_equal(expected, getbufline(ids[0]->winbufnr(), 1, '$'))
    popup_clear()

    diag.ShowAllDiags()
    :lclose
    var items = getloclist(winid)
    assert_equal([
	[bnr, 2, 5, 2, 6, "redefinition of 'x'"],
	[bnr, 1, 5, 1, 6, 'previous definition is here'],
	[otherFname, 2, 17, 2, 22, 'other']
      ], items->mapnew((_, item) =>
	[item.bufnr == bnr ? bnr : item.bufnr->bufname()->fnamemodify(':p'),
	 item.lnum, item.col, item.end_lnum, item.end_col, item.text]))
    assert_equal(['', 'previous definition is here', 'other'],
		 items->mapnew((_, item) => item.user_data
		   ->get('relatedInformation', {})->get('message', '')))
    assert_equal(["redefinition of 'x'"],
		 items->mapnew((_, item) => item.user_data.diagnostic.message)
		   ->uniq())
    assert_false(otherFname->bufloaded())

    var stored = diag.GetDiagsForBuf(bnr)[0]
    assert_equal(RelatedInfoDiag(bnr, otherFname, 16).relatedInformation,
		 codeaction.ContextDiag(lspserver, bnr, stored)
		   .relatedInformation)
    assert_equal(stored, diag.GetDiagsForBuf(bnr)[0])
  finally
    popup_clear()
    g:LspOptionsSet({showDiagInPopup: true})
    delete(otherFname)
    DiagLocListTestCleanup([bnr])
  endtry
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
  lspserver.rpc_a = (_, params, _, _: dict<any> = {}) => {
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

# Returns a stub language server with the position encoding "posEncoding" that
# published the diagnostics "diags" for the current buffer.  The params of the
# code action requests sent to the server are added to "sentParams".
def MakeDiagCodeActionServer(posEncoding: number, diags: list<dict<any>>,
			     sentParams: list<dict<any>>): dict<any>
  g:LspOptionsSet({autoHighlightDiags: false})
  var lspserver = MakeTestLspServer([])
  lspserver.posEncoding = posEncoding
  lspserver.needOffsetEncoding = posEncoding != 32
  lspserver.features = {diagnostics: true}
  lspserver.featureEnabled = (_) => true
  lspserver.isCodeActionProvider = true
  lspserver.rpc_a = (_, params, _, _: dict<any> = {}) => {
    sentParams->add(params->deepcopy())
    return 1
  }
  diag.DiagNotification(lspserver, util.LspBufnrToUri(bufnr()),
			diags->deepcopy(), 'push')
  return lspserver
enddef

# Returns the "character" values of all the positions in "value", the params
# of a request or a part of them.
def PositionCharacters(value: any): list<number>
  var chars: list<number> = []
  if value->type() == v:t_dict
    if value->has_key('character')
      chars->add(value.character)
    endif
    for v in value->values()
      chars->extend(PositionCharacters(v))
    endfor
  elseif value->type() == v:t_list
    for v in value
      chars->extend(PositionCharacters(v))
    endfor
  endif
  return chars
enddef

# The diagnostics in the context of a code action request are in the position
# encoding of the language server.  A diagnostic that ends past the end of a
# line with multibyte, composing and astral plane characters ends at the end
# of the line, and no position is negative.
def g:Test_CodeActionContext_DiagnosticPastEndOfLine()
  silent! edit XCodeActionDiagPastEol.txt
  setline(1, ['x;', "é a\u0301 😊"])
  # The second line is 11 bytes, 7 UTF-16 code units and 6 characters long,
  # and "a" is at byte 3, UTF-16 code unit 2 and character 2.
  var aIdx = {8: 3, 16: 2, 32: 2}
  var lineLen = {8: 11, 16: 7, 32: 6}
  for posEncoding in [8, 16, 32]
    var diags = [{range: {start: {line: 1, character: aIdx[posEncoding]},
			  end: {line: 1, character: 40}},
		  message: 'past the end'}]
    var sentParams: list<dict<any>> = []
    var lspserver = MakeDiagCodeActionServer(posEncoding, diags, sentParams)
    cursor(2, 1)
    lspserver.codeActionAsync(@%, 2, 2, '', (_, _, _, _) => 0)

    var msg = $'UTF-{posEncoding}'
    assert_equal(1, sentParams->len(), msg)
    var params = sentParams[0]
    assert_equal({start: {line: 1, character: 0},
		  end: {line: 1, character: lineLen[posEncoding]}},
		 params.range, msg)
    # A UTF-32 server gets back the position that it sent, which is not
    # decoded
    var diagEnd = posEncoding == 32 ? 40 : lineLen[posEncoding]
    assert_equal([{start: {line: 1, character: aIdx[posEncoding]},
		   end: {line: 1, character: diagEnd}}],
		 params.context.diagnostics->mapnew((_, d) => d.range), msg)
    var chars = PositionCharacters(params)
    assert_equal(4, chars->len(), msg)
    assert_equal([], chars->filter((_, c) => c < 0), msg)

    ClearBufferDiagnostics()
  endfor
  :%bw!
enddef

# The range of a code action request for a line that the cursor is not on
# starts at the start of the line, not at the column of the cursor.
def g:Test_CodeAction_OtherLineRangeStartsAtLineStart()
  silent! edit XCodeActionOtherLine.txt
  setline(1, ['x;', "é a\u0301 😊"])
  for posEncoding in [8, 16, 32]
    var sentParams: list<dict<any>> = []
    var lspserver = MakeDiagCodeActionServer(posEncoding, [], sentParams)
    cursor(2, 1)
    :normal! $
    lspserver.codeActionAsync(@%, 1, 1, '', (_, _, _, _) => 0)
    assert_equal({start: {line: 0, character: 0},
		  end: {line: 0, character: 2}},
		 sentParams[0].range, $'UTF-{posEncoding}')
    ClearBufferDiagnostics()
  endfor
  :%bw!
enddef

# Returns the diagnostics for the lines set by PublishDiagsPastEnd(), in the
# position encoding "posEncoding".  Once the last three lines are deleted,
# "stale end" ends past the end of the buffer, "last line" covers the "é" at
# the start of the last line and "stale start" is entirely past the end.
def PastEndDiags(posEncoding: number): list<dict<any>>
  return [
    {range: {start: {line: 1, character: 2}, end: {line: 4, character: 3}},
     severity: 1, message: 'stale end'},
    {range: {start: {line: 2, character: 0},
	     end: {line: 2, character: posEncoding == 8 ? 2 : 1}},
     severity: 1, message: 'last line'},
    {range: {start: {line: 4, character: 1}, end: {line: 5, character: 0}},
     severity: 1, message: 'stale start'}
  ]
enddef

# The ranges of PastEndDiags() in a buffer without their last three lines,
# where the last line is 6 characters long.
const PAST_END_DIAG_RANGES: list<dict<dict<number>>> = [
  {start: {line: 1, character: 2}, end: {line: 2, character: 6}},
  {start: {line: 2, character: 0}, end: {line: 2, character: 1}},
  {start: {line: 2, character: 6}, end: {line: 2, character: 6}}
]

# Sets six lines in the current buffer, publishes PastEndDiags() for it from
# "lspserver" and deletes the last three lines, before publishing if
# "deleteFirst" is true and after it otherwise.  The third line, which is the
# last one left, is 11 bytes, 7 UTF-16 code units and 6 characters long.
def PublishDiagsPastEnd(lspserver: dict<any>, deleteFirst: bool)
  setline(1, ['abcdef', 'ghijkl', "é á 😊", 'line 4', 'line 5',
	      'line 6'])
  if deleteFirst
    :4,$delete _
  endif
  diag.DiagNotification(lspserver, util.LspBufnrToUri(bufnr()),
			PastEndDiags(lspserver.posEncoding), 'push')
  if !deleteFirst
    :4,$delete _
  endif
enddef

# Returns the message for the assertions of a test of PublishDiagsPastEnd()
# with "deleteFirst".
def PastEndMsg(deleteFirst: bool): string
  return deleteFirst ? 'lines deleted before publishing'
		     : 'lines deleted after publishing'
enddef

# The signs, the virtual text and the inline highlights of the diagnostics are
# placed within the buffer when lines that the diagnostics are on are
# deleted.  A diagnostic past the end of the buffer is at the end of the last
# line, and a range ending past it ends there.
def g:Test_DiagsPastEndOfBuffer_Visuals()
  DiagInitOnce()
  silent! edit XDiagsPastEndVisuals.txt
  g:LspOptionsSet({showDiagWithVirtualText: true})
  var bnr = bufnr()
  var lspserver = MakeDiagServer('srv')
  for deleteFirst in [false, true]
    PublishDiagsPastEnd(lspserver, deleteFirst)
    diag.DiagsRefresh(bnr)

    var msg = PastEndMsg(deleteFirst)
    assert_equal([2, 3, 3], sign_getplaced(bnr, {group: 'LSPDiag'})[0].signs
		   ->mapnew((_, s) => s.lnum)->sort('n'), msg)
    assert_equal([[2, '┌─ stale end'], [3, '┌─ last line'],
		  [3, '┌─ stale start']],
		 DiagVirtualTexts()->mapnew((_, v) => [v[0], v[2]])->sort(),
		 msg)
    # [lnum, col, length] of each line of the inline highlights, sorted as
    # strings
    assert_equal([[2, 3, 5], [3, 1, 11], [3, 1, 2], [3, 12, 0]],
		 prop_list(1, {end_lnum: -1})
		   ->filter((_, p) => p.type =~ '^LspDiagInline')
		   ->mapnew((_, p) => [p.lnum, p.col, p.length])->sort(),
		 msg)
    diag.DiagRemoveFile(bnr)
  endfor
  g:LspOptionsSet({showDiagWithVirtualText: false})
  :%bw!
enddef

# The location list items of the diagnostics are within the buffer when lines
# that the diagnostics are on are deleted.  Their 'user_data' has the
# diagnostics as the server sent them.
def g:Test_DiagsPastEndOfBuffer_LocList()
  silent! edit XDiagsPastEndLocList.txt
  g:LspOptionsSet({autoHighlightDiags: false})
  var bnr = bufnr()
  var winid = win_getid()
  var lspserver = MakeDiagServer('srv')
  try
    for deleteFirst in [false, true]
      PublishDiagsPastEnd(lspserver, deleteFirst)
      diag.ShowAllDiags()
      :lclose
      var msg = PastEndMsg(deleteFirst)
      var items = getloclist(winid)
      assert_equal([[2, 3, 3, 12, 'stale end'], [3, 1, 3, 3, 'last line'],
		    [3, 12, 3, 12, 'stale start']],
		   items->mapnew((_, item) =>
		     [item.lnum, item.col, item.end_lnum, item.end_col,
		      item.text]), msg)
      assert_equal(PastEndDiags(32)->mapnew((_, d) => d.range),
		   items->mapnew((_, item) => item.user_data.diagnostic.range),
		   msg)
    endfor
  finally
    DiagLocListTestCleanup([bnr])
  endtry
enddef

# The diagnostics are looked up by the lines they cover in the buffer when
# lines that the diagnostics are on are deleted, and they are returned with
# their ranges within the buffer.  The diagnostics are kept as the server
# sent them, so they are where they were when the lines are added back.
def g:Test_DiagsPastEndOfBuffer_Lookups()
  silent! edit XDiagsPastEndLookups.txt
  g:LspOptionsSet({autoHighlightDiags: false})
  var bnr = bufnr()
  var lspserver = MakeDiagServer('srv')
  var Ranges = (diags: list<dict<any>>): list<any> =>
    diags->mapnew((_, d) => d.range)
  var MsgAt = (lnum: number, col: number): string =>
    diag.GetDiagByPos(bnr, lnum, col, true)->get('message', '')
  for deleteFirst in [false, true]
    PublishDiagsPastEnd(lspserver, deleteFirst)

    var msg = PastEndMsg(deleteFirst)
    assert_equal(['stale end'], DiagMsgs(diag.GetDiagsByLine(bnr, 2)), msg)
    assert_equal(PAST_END_DIAG_RANGES, Ranges(diag.GetDiagsByLine(bnr, 3)),
		 msg)
    assert_equal(PAST_END_DIAG_RANGES,
		 Ranges(diag.GetDiagsByLine(bnr, 3, lspserver)), msg)
    assert_equal(PAST_END_DIAG_RANGES,
		 Ranges(diag.GetDiagsInLineRange(bnr, 1, 3)), msg)
    assert_equal([], diag.GetDiagsByLine(bnr, 4), msg)
    assert_equal(PAST_END_DIAG_RANGES, Ranges(diag.GetDiagsForBuf(bnr)), msg)
    # The last line is "é á 😊", 5 characters long without the composing
    # character
    assert_equal('last line', MsgAt(3, 1), msg)
    assert_equal('stale end', MsgAt(3, 2), msg)
    assert_equal('stale end', MsgAt(3, 5), msg)
    assert_equal('', MsgAt(3, 6), msg)

    append('$', ['line 4', 'line 5', 'line 6'])
    assert_equal(PastEndDiags(32)->mapnew((_, d) => d.range),
		 Ranges(diag.GetDiagsForBuf(bnr)), msg)
    assert_equal(['stale end', 'stale start'],
		 DiagMsgs(diag.GetDiagsByLine(bnr, 5)), msg)
    diag.DiagRemoveFile(bnr)
  endfor
  g:LspOptionsSet({autoHighlightDiags: true})
  :%bw!
enddef

# The diagnostics in the context of a code action request are within the
# buffer when lines that the diagnostics are on are deleted, and in the
# position encoding of the language server.  The server already has the
# document without the deleted lines, so it gets a diagnostic past the end of
# the document at its end.
def g:Test_DiagsPastEndOfBuffer_CodeActionContext()
  silent! edit XDiagsPastEndCodeAction.txt
  # The length of the last line and the end of the "é" at its start
  var lineLen = {8: 11, 16: 7, 32: 6}
  var eEnd = {8: 2, 16: 1, 32: 1}
  for posEncoding in [8, 16, 32]
    for deleteFirst in [false, true]
      var sentParams: list<dict<any>> = []
      var lspserver = MakeDiagCodeActionServer(posEncoding, [], sentParams)
      PublishDiagsPastEnd(lspserver, deleteFirst)
      cursor(3, 1)
      lspserver.codeActionAsync(@%, 2, 3, '', (_, _, _, _) => 0)

      var msg = $'UTF-{posEncoding}, {PastEndMsg(deleteFirst)}'
      var len = lineLen[posEncoding]
      assert_equal({start: {line: 1, character: 0},
		    end: {line: 2, character: len}},
		   sentParams[0].range, msg)
      assert_equal([
	  {start: {line: 1, character: 2}, end: {line: 2, character: len}},
	  {start: {line: 2, character: 0},
	   end: {line: 2, character: eEnd[posEncoding]}},
	  {start: {line: 2, character: len}, end: {line: 2, character: len}}
	], sentParams[0].context.diagnostics->mapnew((_, d) => d.range), msg)
      ClearBufferDiagnostics()
    endfor
  endfor
  :%bw!
enddef

# The diagnostics sent to ALE are within the buffer when lines that the
# diagnostics are on are deleted.  The end column sent to ALE is inclusive.
def g:Test_DiagsPastEndOfBuffer_Ale()
  var aleStub = InstallAleStub()
  silent! edit XDiagsPastEndAle.c
  var bnr = bufnr()
  var clangd = MakeDiagServer('clangd')
  buf.BufLspServerSet(bnr, clangd)
  for deleteFirst in [false, true]
    PublishDiagsPastEnd(clangd, deleteFirst)
    g:LspTestAleCalls = []
    diag.AleHook(bnr)
    g:WaitForAssert(() => assert_equal(2, g:LspTestAleCalls->len()))
    assert_equal([[2, 3, 3, 11], [3, 1, 3, 2], [3, 12, 3, 12]],
		 g:LspTestAleCalls[-1][4]->mapnew((_, v) =>
		   [v.lnum, v.col, v.end_lnum, v.end_col]),
		 PastEndMsg(deleteFirst))
  endfor
  diag.DiagRemoveFile(bnr)
  buf.BufLspServerRemove(bnr, clangd)
  RemoveAleStub(aleStub)
  :%bw!
enddef

# The ranges of the code lens and the document link that are resolved are in
# the position encoding of the language server.  A range that ends past the
# end of a line with multibyte, composing and astral plane characters ends at
# the end of the line.
def g:Test_Resolve_RangePastEndOfLine()
  silent! edit XResolvePastEol.txt
  setline(1, ["é a\u0301 😊"])
  var aIdx = {8: 3, 16: 2, 32: 2}
  var lineLen = {8: 11, 16: 7}
  for posEncoding in [8, 16, 32]
    var lspserver = MakeTestLspServer([])
    lspserver.posEncoding = posEncoding
    lspserver.needOffsetEncoding = posEncoding != 32
    lspserver.isCodeLensResolveProvider = true
    lspserver.isDocumentLinkResolveProvider = true
    var requests: list<dict<any>> = []
    lspserver.rpc_a = (method: string, params: any, Cbfunc: func, _ = {}) => {
      requests->add({method: method, params: params->deepcopy()})
      Cbfunc(lspserver, params->deepcopy(), {})
      return requests->len()
    }

    # The range as the language server sent it, decoded
    var range = {start: {line: 0, character: aIdx[posEncoding]},
		 end: {line: 0, character: 40}}
    lspserver.decodeRange(bufnr(), range)
    lspserver.resolveCodeLens(bufnr(), {range: range->deepcopy()}, (_) => 0)
    lspserver.resolveDocumentLink(bufnr(), {range: range->deepcopy()},
				  (_) => 0)

    var msg = $'UTF-{posEncoding}'
    assert_equal(['codeLens/resolve', 'documentLink/resolve'],
		 requests->mapnew((_, r) => r.method), msg)
    var rangeEnd = posEncoding == 32 ? 40 : lineLen[posEncoding]
    for r in requests
      assert_equal({start: {line: 0, character: aIdx[posEncoding]},
		    end: {line: 0, character: rangeEnd}},
		   r.params.range, $'{msg}: {r.method}')
    endfor
  endfor
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
  lspserver.debug = true
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
  lspserver.debug = true
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
  lspserver.debug = true
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
  lspserver.debug = true
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
  lspserver.debug = true
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

# Type "keys" at the end of the first line of the current buffer, with the
# keys a mapping produces still in the typeahead when the next key is
# processed, as when typing, and leave Insert mode after the text change.  Vim
# triggers TextChangedI only when the typeahead is empty.  The timer only ends
# Insert mode if TextChangedI isn't triggered.
def TypeInInsertMode(keys: string)
  :%delete _
  setline(1, ['abc'])
  autocmd TextChangedI <buffer> ++once feedkeys("\<Esc>", 't')
  var timer = timer_start(5000, (_) => feedkeys("\<Esc>", 't'))
  feedkeys($"A{keys}", 'xt!')
  timer_stop(timer)
enddef

# Test that a newline typed with a <CR> mapping that adds keys after the
# newline requests on-type formatting, as vim-eunuch's <CR> mapping does.
def g:Test_OnTypeFormatting_CRMappingAddsKeys()
  g:LspOptionsSet({onTypeFormatting: true})
  silent! edit XOnTypeFormattingCRMapping.txt
  var bnr = bufnr()

  var requests: list<list<any>> = []
  var srv = MakeTestLspServer([])
  srv.running = true
  srv.ready = true
  srv.isDocumentOnTypeFormattingProvider = true
  srv.onTypeFormattingTriggers = ["\n"]
  srv.featureEnabled = (_: string): bool => true
  srv.textDocOnTypeFormat = (ch: string) => {
    requests->add([ch, line('.'), col('.')])
  }
  buf.BufLspServerSet(bnr, srv)
  ontypeformat.BufferInit(srv, bnr)

  try
    # The mapping inserts the newline and then evaluates an expression that
    # inserts nothing.
    inoremap <buffer> <expr> <CR> "\<CR>\<C-R>=''\<CR>"
    TypeInInsertMode("\<CR>")
    assert_equal([["\n", 2, 1]], requests)

    # A key typed after the mapped keys still cancels the request.
    requests = []
    TypeInInsertMode("\<CR>\<Left>")
    assert_equal([], requests)

    # The mapping moves the cursor after the newline.
    requests = []
    inoremap <buffer> <expr> <CR> "\<CR>\<Up>"
    TypeInInsertMode("\<CR>")
    assert_equal([], requests)

    # The mapping inserts text after the newline.
    inoremap <buffer> <expr> <CR> "\<CR>x"
    TypeInInsertMode("\<CR>")
    assert_equal([], requests)
  finally
    ontypeformat.BufferDeInit(bnr)
    buf.BufLspServerRemove(bnr, srv)
    g:LspOptionsSet({onTypeFormatting: false})
    :bw!
  endtry
enddef

# Test that the signature help autocmds are added to the buffer that is
# initialized, also when another buffer is the current one, and that
# detaching the buffer from its language servers removes them.
def g:Test_SignatureAutocmds_InitAndDetach()
  signature.InitOnce()
  silent! edit XSignatureAutocmds.txt
  var bnr = bufnr()

  var srv = MakeTestLspServer([])
  srv.caps = {signatureHelpProvider: {triggerCharacters: ['(', ',']}}
  srv.isSignatureHelpProvider = true
  buf.BufLspServerSet(bnr, srv)
  :new
  signature.BufferInit(srv, bnr)
  var otherBnr = bufnr()
  :close
  var BufEvents = (b: number): list<string> =>
    autocmd_get({group: 'LspSignatureHelp', pattern: $'<buffer={b}>'})
      ->mapnew((_, a) => a.event)->sort()
  assert_equal([], BufEvents(otherBnr))
  assert_equal(['InsertEnter', 'KeyInputPre'], BufEvents(bnr))

  lsp.RemoveFile(bnr)
  assert_equal([], BufEvents(bnr))
  :%bw!
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

# Test that detaching a buffer from its language servers removes the inlay
# hint autocmds of the buffer.
def g:Test_LspDetached_RemovesInlayHintAutocmds()
  silent! edit XLspDetachedInlayHints.txt
  var bnr = bufnr()
  var bufPattern = $'<buffer={bnr}>'

  var srv = MakeTestLspServer([])
  srv.isInlayHintProvider = true
  srv.syncInit = true
  srv.featureEnabled = (_) => true
  buf.BufLspServerSet(bnr, srv)
  g:LspOptionsSet({showInlayHints: true})
  try
    inlayhints.BufferInit(srv, bnr)
    assert_notequal([], autocmd_get({group: 'LspInlayHints', pattern: bufPattern}))
    assert_notequal([], autocmd_get({group: 'LspAttached', pattern: bufPattern}))

    lsp.RemoveFile(bnr)
    assert_equal([], autocmd_get({group: 'LspInlayHints', pattern: bufPattern}))
    assert_equal([], autocmd_get({group: 'LspAttached', pattern: bufPattern}))
  finally
    g:LspOptionsSet({showInlayHints: false})
    :bw!
  endtry
enddef

# Detaching a buffer cancels its initialization deferred until the language
# server is ready, but not the one of the other buffers waiting for it.
def g:Test_RemoveFile_CancelsOnlyItsPendingBufferInit()
  var notifications: list<dict<any>> = []
  var srv = MakeTestLspServer(notifications)
  srv.caps = {textDocumentSync: 2}
  capabilities.ProcessServerCaps(srv, srv.caps)
  var readyAcmd = {group: 'LSPBufferAutocmds', event: 'User',
		   pattern: $'LspServerReady_{srv.id}'}
  silent! edit XPendingBufferInit1.txt
  var bnr1 = bufnr()
  silent! new XPendingBufferInit2.txt
  var bnr2 = bufnr()
  for bnr in [bnr1, bnr2]
    buf.BufLspServerSet(bnr, srv)
    autocmd_add([readyAcmd->extendnew({once: true,
				       cmd: $'BufferInit({srv.id}, {bnr})'})])
  endfor

  lsp.RemoveFile(bnr1)
  var pending = autocmd_get(readyAcmd)
  assert_equal([$'BufferInit({srv.id}, {bnr2})'],
	       pending->mapnew((_, acmd) => acmd.cmd))
  assert_true(pending[0].once)

  # The kept autocmd still initializes its buffer once the server is ready
  srv.running = true
  srv.ready = true
  exe $'doautocmd <nomodeline> LSPBufferAutocmds User LspServerReady_{srv.id}'
  assert_equal([['textDocument/didOpen', util.LspBufnrToUri(bnr2)]],
	       notifications->mapnew((_, n) => [n.method, n.params.textDocument.uri]))
  assert_equal([], autocmd_get(readyAcmd))

  lsp.RemoveFile(bnr2)
  :%bw!
enddef

# Detaching a buffer cancels its pending requests (e.g. document highlight)
# before closing it, so their late replies are ignored, and keeps the pending
# requests for the other buffers.
def g:Test_RemoveFile_CancelsPendingBufferRequests()
  var notifications: list<dict<any>> = []
  var srv = MakeTestLspServer(notifications)
  srv.caps = {textDocumentSync: 2}
  capabilities.ProcessServerCaps(srv, srv.caps)
  srv.isDocumentHighlightProvider = true
  srv.running = true
  srv.ready = true
  var lastId = 0
  srv.rpc_a = (_, _, _, _: dict<any> = {}) => {
    lastId += 1
    return lastId
  }

  silent! edit XCancelOnDetach1.txt
  var bnr1 = bufnr()
  silent! new XCancelOnDetach2.txt
  var bnr2 = bufnr()
  buf.BufLspServerSet(bnr1, srv)
  buf.BufLspServerSet(bnr2, srv)
  srv.docHighlight(bnr2, 'silent')
  wincmd p
  srv.docHighlight(bnr1, 'silent')

  lsp.RemoveFile(bnr1)
  assert_equal([['$/cancelRequest', {id: 2}],
		['textDocument/didClose',
		 {textDocument: {uri: util.LspBufnrToUri(bnr1)}}]],
	       notifications->mapnew((_, n) => [n.method, n.params]))
  assert_equal([$'textDocument/documentHighlight {bnr2}'],
	       srv.supersedableRequests->keys())

  lsp.RemoveFile(bnr2)
  assert_equal({}, srv.supersedableRequests)
  :%bw!
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

  silent! hide edit XCodeActionRoutingOther.txt
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

# Returns a preferred quick fix code action resolving the diagnostic "d",
# which runs the command "fix.{message}".
def AutoFixAction(d: dict<any>): dict<any>
  return {
    title: $'Fix {d.message}',
    kind: 'quickfix',
    isPreferred: true,
    diagnostics: [d],
    command: {title: $'Fix {d.message}', command: $'fix.{d.message}'}
  }
enddef

# Returns a running stub language server for the current buffer with the
# position encoding "posEncoding", that published the diagnostics "diags".
# The server replies to a code action request with an AutoFixAction() for
# each diagnostic in the context of the request if "echo" is true, and for
# each diagnostic in "diags" otherwise.  The commands run are added to
# "execCmds".
def MakeAutoFixServer(posEncoding: number, diags: list<dict<any>>,
		      echo: bool, execCmds: list<string>): dict<any>
  var lspserver = MakeDiagCodeActionServer(posEncoding, diags, [])
  lspserver.name = 'autofix'
  lspserver.running = true
  lspserver.ready = true
  lspserver.rpc_a = (_, params, Cbfunc, _: dict<any> = {}) => {
    Cbfunc({}, (echo ? params.context.diagnostics : diags)
      ->mapnew((_, d) => AutoFixAction(d)), {})
    return 1
  }
  lspserver.executeCommand = (cmd: dict<any>) => {
    execCmds->add(cmd.command)
  }
  buf.BufLspServerSet(bufnr(), lspserver)
  return lspserver
enddef

# A line with multibyte text before "foo" and "bar", which are at bytes 8 and
# 12, UTF-16 code units 5 and 9 and characters 4 and 8.
const AUTOFIX_LINE: string = '😊 é foo bar'
const AUTOFIX_FOO_IDX: dict<number> = {8: 8, 16: 5, 32: 4}
const AUTOFIX_BAR_IDX: dict<number> = {8: 12, 16: 9, 32: 8}

# Returns a diagnostic with "message" for the three characters at "character"
# in the first line.
def AutoFixDiag(character: number, message: string): dict<any>
  return {
    range: {
      start: {line: 0, character: character},
      end: {line: 0, character: character + 3}
    },
    severity: 1,
    message: message
  }
enddef

# :LspAutoFix applies the code action resolving each diagnostic on a line
# with multibyte text before the diagnostics, for a language server using any
# position encoding.  The server can list in the code actions the diagnostics
# that it got in the request or the ones that it published.
def g:Test_LspAutoFix_MultibyteDiagRange()
  silent! edit XLspAutoFixMultibyte.txt
  set filetype=text
  setline(1, [AUTOFIX_LINE])
  for posEncoding in [8, 16, 32]
    for echo in [true, false]
      var diags = [AutoFixDiag(AUTOFIX_FOO_IDX[posEncoding], 'foo'),
		   AutoFixDiag(AUTOFIX_BAR_IDX[posEncoding], 'bar')]
      var execCmds: list<string> = []
      var lspserver = MakeAutoFixServer(posEncoding, diags, echo, execCmds)

      lsp.AutoFix()
      assert_equal(['fix.foo', 'fix.bar'], execCmds,
		   $'UTF-{posEncoding}, echo: {echo}')

      ClearBufferDiagnostics()
      buf.BufLspServerRemove(bufnr(), lspserver)
    endfor
  endfor
  :%bw!
enddef

# :LspAutoFix applies to each of the diagnostics with the same range the code
# action resolving it, which lists a diagnostic with its message, and not the
# code actions resolving the other diagnostics.
def g:Test_LspAutoFix_SameRangeDiags()
  silent! edit XLspAutoFixSameRange.txt
  set filetype=text
  setline(1, [AUTOFIX_LINE])
  g:LspOptionsSet({usePopupInCodeAction: true})
  for posEncoding in [8, 16, 32]
    var diags = [AutoFixDiag(AUTOFIX_FOO_IDX[posEncoding], 'first'),
		 AutoFixDiag(AUTOFIX_FOO_IDX[posEncoding], 'second')]
    var execCmds: list<string> = []
    var lspserver = MakeAutoFixServer(posEncoding, diags, true, execCmds)

    lsp.AutoFix()
    var msg = $'UTF-{posEncoding}'
    assert_equal(['fix.first', 'fix.second'], execCmds, msg)
    assert_equal([], popup_list(), msg)

    popup_clear()
    ClearBufferDiagnostics()
    buf.BufLspServerRemove(bufnr(), lspserver)
  endfor
  g:LspOptionsSet({usePopupInCodeAction: false})
  :%bw!
enddef

# :LspAutoFix applies the code action resolving a diagnostic whose message
# the "processDiagHandler" of the language server changed, when the server
# lists in the code action the diagnostic as it published it.
def g:Test_LspAutoFix_ProcessDiagHandlerMessage()
  silent! edit XLspAutoFixDiagHandler.txt
  set filetype=text
  setline(1, [AUTOFIX_LINE])
  for posEncoding in [8, 16, 32]
    var diags = [AutoFixDiag(AUTOFIX_BAR_IDX[posEncoding], 'bar')]
    var execCmds: list<string> = []
    var lspserver = MakeAutoFixServer(posEncoding, diags, false, execCmds)
    lspserver.processDiagHandler = (pdiags: list<dict<any>>) =>
      pdiags->map((_, d) => d->extend({message: $'srv: {d.message}'}))
    diag.DiagNotification(lspserver, util.LspBufnrToUri(bufnr()),
			  diags->deepcopy(), 'push')

    lsp.AutoFix()
    assert_equal(['fix.bar'], execCmds, $'UTF-{posEncoding}')

    ClearBufferDiagnostics()
    buf.BufLspServerRemove(bufnr(), lspserver)
  endfor
  :%bw!
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

# With full sync, a change that leaves the text as it was is not sent, so the
# version of the document stays that of its text, for which the language
# server can make edits.  The text that is sent is the one that incremental
# sync diffs against when it is turned on.
def g:Test_TextdocDidChange_FullSync_SkipsUnchangedText()
  silent! edit XFullSyncUnchanged.txt
  setline(1, ['abc'])
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  var bnr = bufnr()
  lspserver.textdocDidOpen(bnr, 'text')
  var version = lspserver.docVersions[bnr]

  setline(1, 'xyz')
  setline(1, 'abc')
  lspserver.textdocDidChange(bnr)
  assert_equal([], notifications)
  assert_equal(version, lspserver.docVersions[bnr])

  setline(1, 'ABC')
  lspserver.textdocDidChange(bnr)
  assert_equal([{text: "ABC\n"}], notifications[-1].params.contentChanges)
  assert_true(notifications[-1].params.textDocument.version > version)

  if opt.incrementalSyncSupported
    g:LspOptionsSet({incrementalSync: true})
    append('$', 'def')
    lspserver.textdocDidChange(bnr)
    assert_equal([{range: {start: {line: 1, character: 0},
			   end: {line: 1, character: 0}},
		   text: "def\n"}],
		 notifications[-1].params.contentChanges)
    g:LspOptionsSet({incrementalSync: false})
  endif
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

# Returns the offset in a document with "lines" of the LSP position "pos",
# in a document with one byte per character.
def DocumentOffset(lines: list<string>, pos: dict<number>): number
  var docOffset = pos.character
  for i in range(pos.line)
    docOffset += lines[i]->len() + 1
  endfor
  return docOffset
enddef

# Returns the document "text" after a language server made the
# "contentChanges" of a "textDocument/didChange" notification to it.
def ApplyContentChanges(text: string, contentChanges: list<dict<any>>): string
  var doc = text
  for change in contentChanges
    if !change->has_key('range')
      doc = change.text
      continue
    endif
    var lines = doc->split("\n", true)
    var startOffset = DocumentOffset(lines, change.range.start)
    var endOffset = DocumentOffset(lines, change.range.end)
    doc = doc->strpart(0, startOffset) .. change.text .. doc->strpart(endOffset)
  endfor
  return doc
enddef

# Returns the document that a language server has for buffer "bnr" when it is
# in sync: the text that Vim writes.
def DocumentText(bnr: number): string
  if util.BufIsEmpty(bnr)
    return ''
  endif
  return bnr->getbufline(1, '$')->join("\n") .. (util.BufWritesEol(bnr) ? "\n" : '')
enddef

# Returns a test language server like MakeTestLspServer() does, which
# lsp.AddBufListener() can add a listener for.
def MakeListenedLspServer(notifications: list<dict<any>>): dict<any>
  var lspserver = MakeTestLspServer(notifications)
  lspserver.isDiagnosticsProvider = false
  return lspserver
enddef

# Test that sending the changes the listener passes to a server that wants
# incremental changes keeps the document of each server equal to the buffer,
# also when the lines are changed in other ways than typing, and with or
# without a newline at the end of the document.
def g:Test_TextdocDidChange_ListenerChangesKeepDocumentsInSync()
  g:LspOptionsSet({incrementalSync: true})
  var ops = [
    "ox\<Esc>", "ddk", "Jx", "Oabc\<Esc>", "yyp", "3ddu", "u\<C-r>",
    ":s/a/BB/g\<CR>", "ix\<CR>y\<Esc>", "A tail\<Esc>", "0D",
    ":g/a/normal Ax\<CR>", "P", ":2,3d\<CR>", "Vjd", "ccnew\<Esc>", ">>",
    ":%s/\\d\\+/N/\<CR>", ":%j\<CR>", "uu", ":m0\<CR>", "G$x", "ggdG",
    "ione\<CR>two\<CR>three\<Esc>", "ddp", "dd", "p", ":%d\<CR>", "ix\<Esc>",
    "yyPjdd", "G\<C-v>kkd"
  ]
  for eol in [true, false]
    silent! edit XListenerSync.txt
    setline(1, range(1, 12)->mapnew((_, n) => $'line {n} a'))
    execute eol ? 'setlocal eol fixeol' : 'setlocal noeol nofixeol'
    var bnr = bufnr()
    var servers: list<dict<any>>
    var notifications: list<list<dict<any>>>
    var docs: list<string>
    for i in range(2)
      notifications->add([])
      servers->add(MakeListenedLspServer(notifications[i]))
      servers[i].textdocDidOpen(bnr, 'text')
      lsp.AddBufListener(servers[i], bnr)
      docs->add(DocumentText(bnr))
    endfor
    var ranges = 0
    try
      for op in ops
        execute 'silent! normal' op
        listener_flush(bnr)
        for i in range(2)
          for notification in notifications[i]
            assert_equal('textDocument/didChange', notification.method)
            var contentChanges = notification.params.contentChanges
            ranges += contentChanges->copy()->filter((_, c) => c->has_key('range'))->len()
            docs[i] = ApplyContentChanges(docs[i], contentChanges)
          endfor
          notifications[i]->filter((_, _) => false)
          assert_equal(DocumentText(bnr), docs[i],
		       $'eol: {eol}, server {i}, after {op->string()}')
          assert_equal(util.BufIsEmpty(bnr) ? [] : bnr->getbufline(1, '$'),
		       servers[i].cachedBufferContent[bnr])
        endfor
      endfor
    finally
      lsp.RemoveBufListener(bnr)
      :%bw!
    endtry
    # Most changes are sent as the lines that changed, not the whole text
    assert_true(ranges > ops->len(), $'eol: {eol}, changes with a range: {ranges}')
  endfor
  g:LspOptionsSet({incrementalSync: false})
enddef

# Test the changes sent for the usual edits: each replaces the lines that
# changed, in the order they were made, and the changes made before the
# listener is invoked are sent together.
def g:Test_TextdocDidChange_ListenerChangesAreTheChangedLines()
  g:LspOptionsSet({incrementalSync: true})
  silent! edit XListenerLines.txt
  setline(1, ['one', 'two', 'three'])
  var notifications: list<dict<any>> = []
  var lspserver = MakeListenedLspServer(notifications)
  var bnr = bufnr()
  lspserver.textdocDidOpen(bnr, 'text')
  lsp.AddBufListener(lspserver, bnr)
  try
    setline(2, 'TWO')
    listener_flush(bnr)
    assert_equal(1, notifications->len())
    assert_equal([{range: {start: {line: 1, character: 0},
			   end: {line: 2, character: 0}},
		   text: "TWO\n"}],
		 notifications[0].params.contentChanges)

# Changes to the same line are sent in the order they were made, each for
# the document after the ones before it.
notifications->remove(0, -1)
setline(2, 'two')
setline(2, 'dos')
listener_flush(bnr)
assert_equal(1, notifications->len())
var lineRange = {start: {line: 1, character: 0}, end: {line: 2, character: 0}}
assert_equal([{range: lineRange, text: "two\n"},
		  {range: lineRange, text: "dos\n"}],
		 notifications[0].params.contentChanges)

notifications->remove(0, -1)
append(1, ['uno', 'tres'])
listener_flush(bnr)
assert_equal([{range: {start: {line: 1, character: 0},
			   end: {line: 1, character: 0}},
		   text: "uno\ntres\n"}],
		 notifications[0].params.contentChanges)

notifications->remove(0, -1)
deletebufline(bnr, 1)
listener_flush(bnr)
assert_equal([{range: {start: {line: 0, character: 0},
			   end: {line: 1, character: 0}},
		   text: ''}],
		 notifications[0].params.contentChanges)
assert_equal(['uno', 'tres', 'dos', 'three'],
		 lspserver.cachedBufferContent[bnr])
  finally
    lsp.RemoveBufListener(bnr)
    :%bw!
    g:LspOptionsSet({incrementalSync: false})
  endtry
enddef

# Test that the last line of a document without a newline at the end is
# replaced relative to the end of the line before it.
def g:Test_TextdocDidChange_ListenerChangesWithoutNewlineAtEnd()
  g:LspOptionsSet({incrementalSync: true})
  silent! edit XListenerNoEol.txt
  setline(1, ['abc', 'def'])
  setlocal noeol nofixeol
  var notifications: list<dict<any>> = []
  var lspserver = MakeListenedLspServer(notifications)
  var bnr = bufnr()
  lspserver.textdocDidOpen(bnr, 'text')
  lsp.AddBufListener(lspserver, bnr)
  try
    setline(2, 'XYZ')
    listener_flush(bnr)
    assert_equal([{range: {start: {line: 0, character: 3},
			   end: {line: 1, character: 3}},
		   text: "\nXYZ"}],
		 notifications[0].params.contentChanges)
    assert_equal("abc\nXYZ",
		 ApplyContentChanges("abc\ndef",
				     notifications[0].params.contentChanges))

    notifications->remove(0, -1)
    setline(1, 'ABC')
    listener_flush(bnr)
    assert_equal([{range: {start: {line: 0, character: 0},
			   end: {line: 1, character: 0}},
		   text: "ABC\n"}],
		 notifications[0].params.contentChanges)
  finally
    lsp.RemoveBufListener(bnr)
    :%bw!
    g:LspOptionsSet({incrementalSync: false})
  endtry
enddef

# Test that the whole text is sent when the changes don't fit the document of
# the server, which is then the one of the buffer again, and that a document
# that is not the buffer's is corrected by comparing the two.
def g:Test_TextdocDidChange_ListenerChangesThatDontFitSendTheWholeText()
  g:LspOptionsSet({incrementalSync: true})
  silent! edit XListenerMismatch.txt
  setline(1, ['one', 'two', 'three'])
  var notifications: list<dict<any>> = []
  var lspserver = MakeListenedLspServer(notifications)
  var bnr = bufnr()
  lspserver.textdocDidOpen(bnr, 'text')
  lsp.AddBufListener(lspserver, bnr)
  try
    # The server lost a line
    lspserver.cachedBufferContent[bnr]->remove(0)
    setline(3, 'THREE')
    listener_flush(bnr)
    assert_equal([{text: "one\ntwo\nTHREE\n"}],
		 notifications[-1].params.contentChanges)
    assert_equal(['one', 'two', 'THREE'], lspserver.cachedBufferContent[bnr])

    # The server has other text on a line, which only a comparison finds out
    notifications->remove(0, -1)
    lspserver.cachedBufferContent[bnr][1] = 'WRONG'
    setline(1, 'ONE')
    listener_flush(bnr)
    assert_equal(1, notifications->len())
    lspserver.textdocDidChange(bnr)
    assert_equal(2, notifications->len())
    assert_equal({range: {start: {line: 1, character: 0},
			   end: {line: 2, character: 0}},
		  text: "two\n"},
		 notifications[1].params.contentChanges[0])
    assert_equal(['ONE', 'two', 'THREE'], lspserver.cachedBufferContent[bnr])

    # From and to a document with no text
    notifications->remove(0, -1)
    :%d
    listener_flush(bnr)
    assert_equal([{text: ''}], notifications[-1].params.contentChanges)
    setline(1, 'abc')
    listener_flush(bnr)
    assert_equal([{text: "abc\n"}], notifications[-1].params.contentChanges)
    notifications->remove(0, -1)
    execute "normal! ddp"
    listener_flush(bnr)
    var doc = "abc\n"
    for notification in notifications
      doc = ApplyContentChanges(doc, notification.params.contentChanges)
    endfor
    assert_equal(DocumentText(bnr), doc)
  finally
    lsp.RemoveBufListener(bnr)
    :%bw!
    g:LspOptionsSet({incrementalSync: false})
  endtry
enddef

# Test that a change that Vim hasn't passed to the listener yet is made to
# the document of the server before the buffer is compared with it, so that it
# is neither sent twice nor lost.
def g:Test_TextdocDidChange_PendingListenerChangesAreSentOnce()
  g:LspOptionsSet({incrementalSync: true})
  silent! edit XListenerPending.txt
  setline(1, ['one', 'two', 'three'])
  var notifications: list<dict<any>> = []
  var lspserver = MakeListenedLspServer(notifications)
  var bnr = bufnr()
  lspserver.textdocDidOpen(bnr, 'text')
  lsp.AddBufListener(lspserver, bnr)
  try
    setline(2, 'TWO')
    lspserver.textdocDidChange(bnr)
    assert_equal(1, notifications->len())
    listener_flush(bnr)
    assert_equal(1, notifications->len())
    assert_equal(['one', 'TWO', 'three'], lspserver.cachedBufferContent[bnr])
  finally
    lsp.RemoveBufListener(bnr)
    :%bw!
    g:LspOptionsSet({incrementalSync: false})
  endtry
enddef

# Test that a server gets the whole text on each change when the
# 'incrementalSync' option is off, as before, with no text for the changes.
def g:Test_TextdocDidChange_ListenerChangesNotUsedForFullSync()
  g:LspOptionsSet({incrementalSync: false})
  silent! edit XListenerFull.txt
  setline(1, ['one', 'two'])
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  var bnr = bufnr()
  lspserver.textdocDidOpen(bnr, 'text')
  assert_false(lspserver.usesIncrementalSync())
  var changes: list<dict<any>>
  var listenerId = listener_add((_, _, _, _, listenerChanges) => {
    changes = listenerChanges->deepcopy()
  }, bnr, {text: lspserver.usesIncrementalSync()})
  try
    setline(2, 'TWO')
    listener_flush(bnr)
    assert_false(changes[0]->has_key('text'))
    lspserver.textdocDidChange(bnr, changes)
    assert_equal([{text: "one\nTWO\n"}], notifications[-1].params.contentChanges)
  finally
    listener_remove(listenerId)
    :%bw!
  endtry
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

# Text edits keep the cursor of each window on the buffer on the same text:
# it moves with the text after an edit, also when the edit adds or removes
# lines on the cursor line (#171), stays before text inserted at it, and keeps
# its line and column inside the replaced text.
def g:Test_ApplyTextEdits_KeepsCursorOnText()
  silent! edit XApplyTextEditsCursor.txt
  var bnr = bufnr()
  # [lines, cursor, edits, expected lines, expected cursor]
  var cases: list<list<any>> = [
    [['int n = pri'], [1, 9], [MakeTextEdit(0, 0, 0, 0, "#include <x>\n")],
     ['#include <x>', 'int n = pri'], [2, 9]],
    [['a', 'b c'], [2, 3], [MakeTextEdit(1, 0, 1, 1, "x\ny\nz")],
     ['a', 'x', 'y', 'z c'], [4, 3]],
    [['a', 'x', 'y', 'z c'], [4, 3], [MakeTextEdit(1, 0, 3, 1, 'b')],
     ['a', 'b c'], [2, 3]],
    [['abc def'], [1, 5], [MakeTextEdit(0, 3, 0, 4, "\n")],
     ['abc', 'def'], [2, 1]],
    [['abc', 'def'], [2, 2], [MakeTextEdit(0, 3, 1, 0, ' ')],
     ['abc def'], [1, 6]],
    [['é x'], [1, 4], [MakeTextEdit(0, 0, 0, 1, "ü\nö")],
     ['ü', 'ö x'], [2, 4]],
    [['abc'], [1, 2], [MakeTextEdit(0, 1, 0, 1, "x\n")],
     ['ax', 'bc'], [1, 2]],
    [['abc', 'def'], [2, 2], [MakeTextEdit(0, 0, 2, 0, "x\ny\nz\nw\n")],
     ['x', 'y', 'z', 'w'], [2, 1]],
    [['abc', 'def', 'ghi'], [3, 2], [MakeTextEdit(2, 0, 2, 0, "new\n"),
				     MakeTextEdit(0, 0, 0, 0, "top\n")],
     ['top', 'abc', 'def', 'new', 'ghi'], [5, 2]],
  ]
  for [text, cursor, textEdits, expected, expectedCursor] in cases
    :%d
    setline(1, text)
    cursor(cursor[0], cursor[1])
    textedit.ApplyTextEdits(bnr, textEdits)
    var msg = $'{text}, {cursor}, {textEdits}'
    assert_equal(expected, getline(1, '$'), msg)
    assert_equal(expectedCursor, [line('.'), col('.')], msg)
  endfor

  # The cursor of another window on the buffer moves too.
  :%d
  setline(1, ['abc', 'def'])
  cursor(2, 2)
  var winid = win_getid()
  :new
  textedit.ApplyTextEdits(bnr, [MakeTextEdit(1, 0, 1, 0, "x\ny\n")])
  assert_equal([1, 1], [line('.'), col('.')])
  assert_equal(['abc', 'x', 'y', 'def'], getbufline(bnr, 1, '$'))
  assert_equal([4, 2], getcurpos(winid)[1 : 2])

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

# Passes "result" in a reply to a request to "Cbfunc" and returns the request
# id.  Stands in for lspserver.rpc_a() of "lspserver".
def StubAsyncRpcReply(lspserver: dict<any>, result: any, method: string,
		      params: any, Cbfunc: func, opts: dict<any> = {}): number
  Cbfunc(lspserver, result->deepcopy(), {})
  return 1
enddef

# Returns a running and ready language server that replies "result" to every
# request.
def MakeReplyingLspServer(result: any): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.rpc_a = function(StubAsyncRpcReply, [lspserver, result])
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

# Returns a TextDocumentEdit inserting "text" at the start of version
# "version" of the document with URI "uri".
def MakeInsertEdit(uri: string, text: string, version: any = v:null): dict<any>
  return {textDocument: {uri: uri, version: version},
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

# Runs "Cmd" and returns true when Vim did not ask a question meanwhile.  Vim
# asks it in a dialog that reads the keys typed by the user and ignores
# typeahead, and the test runner types no keys, so the question would wait
# forever.  <CR> is fed as typed first to answer it, and whether it is left
# unread tells whether a question was asked.
def AsksNoQuestion(Cmd: func()): bool
  var unread: bool
  test_feedinput("\r")
  try
    Cmd()
  finally
    unread = getcharstr(0) == "\r"
  endtry
  return unread
enddef

# Creating the file of a loaded buffer that has no file yet, as after ":edit"
# of a new file, makes it the file of the buffer, so that Vim does not ask
# what to do about a file created after editing started (W13).
def g:Test_ApplyWorkspaceEdit_CreateFileOfNewBuffer()
  var fname = 'XWorkspaceEditCreateNew.txt'
  var uri = util.LspFileToUri(fname)
  var Create = () => {
    ApplyResourceOp({kind: 'create', uri: uri})
  }
  try
    exe $'silent edit {fname}'
    setlocal bomb
    assert_true(AsksNoQuestion(Create))
    assert_equal(0, getfsize(fname))
    assert_notmatch('\[New\]', execute('file'))
    bwipe!
    delete(fname)

    var bnr = bufadd(fname)
    bnr->bufload()
    assert_true(AsksNoQuestion(Create))
    assert_equal(0, getfsize(fname))
    assert_notmatch('\[New\]', util.ExecuteInBuffer(bnr, 'file'))
    assert_equal([], win_findbuf(bnr))
    var CheckTime = () => {
      checktime
    }
    assert_true(AsksNoQuestion(CheckTime))
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
    # The document is open only once the server is ready
    srv.ready = true
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

# A text document edit for a version of a document that is open at the
# language server is applied only when that is the version of the current
# text, once the pending changes are sent.  Otherwise none of the changes of
# the workspace edit is applied.  The versions are those of the documents
# before the workspace edit.
def g:Test_ApplyWorkspaceEdit_ChecksDocumentVersion()
  var fname = 'XWorkspaceEdit+Version.txt'
  var created = 'XWorkspaceEditVersionCreated.txt'
  var other = 'XWorkspaceEditVersionOther.txt'
  var uri = util.LspFileToUri(fname)
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  silent! exe $'edit {fname}'
  setline(1, ['one'])
  var bnr = bufnr()
  lspserver.textdocDidOpen(bnr, 'text')
  var listenerId = listener_add((changedBnr, _, _, _, _) => {
    lspserver.textdocDidChange(changedBnr)
  }, bnr)
  try
    var version = lspserver.docVersions[bnr]
    var edit = {documentChanges: [MakeInsertEdit(uri, 'a', version),
				  MakeInsertEdit(uri, 'b', version)]}
    assert_equal({applied: true}, textedit.ApplyWorkspaceEdit(edit, lspserver))
    assert_equal(['baone'], getline(1, '$'))

    edit = {documentChanges: [{kind: 'create', uri: util.LspFileToUri(created)},
			      MakeInsertEdit(uri, 'c', version)]}
    var result = textedit.ApplyWorkspaceEdit(edit, lspserver)
    var current = lspserver.docVersions[bnr]
    assert_true(current > version)
    var reason = 'Text document edit failed, the edit is for version '
      .. $'{version} of {fnamemodify(fname, ":p")}, which is at version {current}'
    assert_equal({applied: false, failureReason: reason, failedChange: 1},
		 result)
    assert_equal($'Error: {reason}', LastMessage())
    assert_false(filereadable(created))
    assert_equal(['baone'], getline(1, '$'))

    # A change that was not sent yet makes the version of the server stale.
    # The document is found also by a URI that escapes fewer characters.
    setline(1, 'two')
    var unescapedUri = $'file://{fnamemodify(fname, ":p")}'
    assert_notequal(uri, unescapedUri)
    edit = {documentChanges: [MakeInsertEdit(unescapedUri, 'd', current)]}
    assert_false(textedit.ApplyWorkspaceEdit(edit, lspserver).applied)
    assert_equal(['two'], getline(1, '$'))
    assert_equal('textDocument/didChange', notifications[-1].method)
    assert_equal([{text: "two\n"}], notifications[-1].params.contentChanges)

    # The version is not checked for an edit without one, for a document that
    # is not open at the server or without a server.
    edit = {documentChanges: [
      MakeInsertEdit(uri, 'e'),
      MakeInsertEdit(util.LspFileToUri(other), 'f', 1)
    ]}
    assert_equal({applied: true}, textedit.ApplyWorkspaceEdit(edit, lspserver))
    assert_equal(['etwo'], getline(1, '$'))
    assert_equal(['f'], getbufline(other, 1, '$'))
    edit = {documentChanges: [MakeInsertEdit(uri, 'g', version)]}
    assert_equal({applied: true}, textedit.ApplyWorkspaceEdit(edit))
    assert_equal(['getwo'], getline(1, '$'))
  finally
    listener_remove(listenerId)
    delete(created)
    :%bwipe!
  endtry
enddef

# The command of a code action is not run when the workspace edit of the code
# action fails.
def g:Test_CodeAction_SkipsCommandWhenEditFails()
  var execCmds: list<string> = []
  var lspserver = MakeCodeActionServer('test', [], execCmds)
  var action = {title: 'Fix', edit: {documentChanges: [{kind: 'copy'}]},
		command: {title: 'Fix', command: 'test.fix'}}
  codeaction.HandleCodeAction(lspserver, action)
  assert_equal([], execCmds)

  action.edit = {documentChanges: []}
  codeaction.HandleCodeAction(lspserver, action)
  assert_equal(['test.fix'], execCmds)
enddef

# Returns a test language server that uses UTF-16 positions.
def MakeUtf16LspServer(): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.posEncoding = 16
  lspserver.needOffsetEncoding = true
  return lspserver
enddef

# Returns a workspace edit with UTF-16 positions that creates file "fname",
# inserts in it a line starting with a character that takes two UTF-16 code
# units, and then inserts "!" after that character.  Only the text of the
# file after the changes before it tells where that is.
def Utf16CreateAndEdit(fname: string): dict<any>
  var uri = util.LspFileToUri(fname)
  return {documentChanges: [
    {kind: 'create', uri: uri},
    MakeInsertEdit(uri, "😀ab\n"),
    {textDocument: {uri: uri, version: v:null},
     edits: [MakeTextEdit(0, 2, 0, 2, '!')]}
  ]}
enddef

# The positions of the text edits of a rename are decoded for the text that
# the edits are applied to, after the changes before them.
def g:Test_RenameSymbol_DecodesEditsAfterPrecedingChanges()
  var fname = 'XRenameUtf16Created.txt'
  var lspserver = MakeUtf16LspServer()
  lspserver.isRenameProvider = true
  lspserver.rpc_a = function(StubAsyncRpcReply,
			     [lspserver, Utf16CreateAndEdit(fname)])
  try
    silent! edit XRenameUtf16Source.txt
    lspserver.renameSymbol(bufnr(), {line: 0, character: 0}, 'new')
    assert_equal(['😀!ab'], getbufline(fname, 1, '$'))
  finally
    delete(fname)
    :%bwipe!
  endtry
enddef

# Test that the rename request is about the given position in the given
# buffer, also when that is not where the cursor is.
def g:Test_RenameSymbol_SendsGivenPosition()
  silent! edit XRenameSymbolTarget.txt
  var bnr = bufnr()
  var requests: list<list<any>> = []
  var lspserver = MakeTestLspServer([])
  lspserver.isRenameProvider = true
  lspserver.rpc_a = (method: string, params: any, _: any, _ = {}) => {
    requests->add([method, params])
    return 1
  }
  try
    silent! edit XRenameSymbolOther.txt
    var pos = {line: 2, character: 3}
    lspserver.renameSymbol(bnr, pos, 'new')
    assert_equal([['textDocument/rename',
		   {textDocument: {uri: util.LspBufnrToUri(bnr)},
		    position: pos, newName: 'new'}]], requests)
  finally
    :%bwipe!
  endtry
enddef

# Returns a running and ready language server with UTF-16 positions for the
# current buffer that supports "textDocument/prepareRename" and replies to it
# with "reply", which has the "result" or the "error" of the reply.  Instead of
# renaming, its renameSymbol() adds the new name to "newNames" and the
# position of the symbol to "positions".
def MakePrepareRenameLspServer(reply: dict<any>, newNames: list<string>,
			       positions: list<dict<number>> = []): dict<any>
  var lspserver = MakeUtf16LspServer()
  lspserver.running = true
  lspserver.ready = true
  lspserver.isRenameProvider = true
  lspserver.isRenamePrepareProvider = true
  # Vim numbers the asynchronous requests on a new channel from 1.
  lspserver.job = StartStubServerJob([{jsonrpc: '2.0', id: 1}->extend(reply)])
  lspserver.renameSymbol = (_: number, pos: dict<number>, newName: string) => {
    positions->add(pos)
    newNames->add(newName)
  }
  buf.BufLspServerSet(bufnr(), lspserver)
  return lspserver
enddef

# Discard the keys that a test fed and that nothing read, so that they are not
# executed after it.
def DiscardTypeahead()
  while getcharstr(0) != ''
  endwhile
enddef

# Test that ":LspRename" pre-fills the prompt for the new name with the name
# that the language server replies to "textDocument/prepareRename": its
# placeholder, or else the text in its range, or else, when the server leaves
# it to the client or the range is on more than one line, the word under the
# cursor.  Without "textDocument/prepareRename", the prompt is pre-filled with
# the word under the cursor.
def g:Test_LspRename_PrepareRenamePrefillsPrompt()
  silent! edit XLspRenamePrepare.txt
  setline(1, ["😀 = $foo + 'a", 'b'])
  var bnr = bufnr()
  var range = {start: {line: 0, character: 5}, end: {line: 0, character: 9}}
  try
    for [result, name] in [
	[range, '$foo'],
	[{range: range, placeholder: 'bar'}, 'bar'],
	[{range: range, placeholder: ''}, '$foo'],
	[{defaultBehavior: true}, 'foo'],
	[{start: {line: 0, character: 13}, end: {line: 1, character: 1}}, 'foo']]
      var newNames: list<string> = []
      var lspserver = MakePrepareRenameLspServer({result: result}, newNames)
      cursor(1, 9)
      feedkeys("X\<CR>", 't')
      :LspRename
      g:WaitForAssert(() => assert_equal([$'{name}X'], newNames))
      StopAsyncReplyingLspServer(lspserver, bnr)
    endfor

    var newNames: list<string> = []
    var lspserver = MakePrepareRenameLspServer({result: v:null}, newNames)
    lspserver.isRenamePrepareProvider = false
    feedkeys("X\<CR>", 't')
    :LspRename
    assert_equal(['fooX'], newNames)
    StopAsyncReplyingLspServer(lspserver, bnr)
  finally
    DiscardTypeahead()
    :%bw!
  endtry
enddef

# Test that ":LspRename" neither prompts for a new name nor renames when the
# language server refuses to rename the symbol under the cursor, and that it
# tells why, unless the request was cancelled.
def g:Test_LspRename_PrepareRenameRefused()
  silent! edit XLspRenameRefused.txt
  setline(1, ['foo'])
  var bnr = bufnr()
  var nothing = 'Warn: Nothing to rename at the cursor'
  try
    for [reply, msg] in [
	[{result: v:null}, nothing],
	[{result: {defaultBehavior: false}}, nothing],
	[{error: {code: -32602, message: 'No symbol'}}, 'Error: No symbol'],
	[{error: {code: -32800, message: 'Cancelled'}}, ''],
	[{result: [1]},
	 'Error: prepareRename response from the language server is not a Dict']]
      var newNames: list<string> = []
      var lspserver = MakePrepareRenameLspServer(reply, newNames)
      :messages clear
      var beforeMessages = execute('messages')
      # A prompt would read the <Esc> and cancel
      feedkeys("\<Esc>", 't')
      :LspRename
      g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
      assert_equal(msg,
		   execute('messages')->strpart(beforeMessages->len())->trim(),
		   string(reply))
      assert_equal([], newNames)
      assert_equal("\<Esc>", getcharstr(0))
      StopAsyncReplyingLspServer(lspserver, bnr)
    endfor
  finally
    DiscardTypeahead()
    :%bw!
  endtry
enddef

# Test that ":LspRename {newName}" renames the symbol that was under the cursor
# without a prompt when the language server replies that it can be renamed,
# also when the cursor moved before the reply arrived, but not when the buffer
# was changed.  ":LspRename" doesn't prompt for a new name when the cursor
# moved.
def g:Test_LspRename_PrepareRenameAfterCursorMoved()
  silent! edit XLspRenameMoved.txt
  var bnr = bufnr()
  var pos = {line: 0, character: 0}
  var range = {start: pos, end: {line: 0, character: 3}}
  try
    for [cmd, action, expected] in [
	['LspRename baz', '', ['baz']],
	['LspRename baz', 'move', ['baz']],
	['LspRename baz', 'change', []],
	['LspRename', 'move', []]]
      setline(1, ['foo bar'])
      var newNames: list<string> = []
      var positions: list<dict<number>> = []
      var lspserver = MakePrepareRenameLspServer({result: range}, newNames,
						 positions)
      cursor(1, 1)
      exe cmd
      if action == 'move'
	cursor(1, 5)
      elseif action == 'change'
	setline(1, ['foo baz'])
      endif
      # A prompt would read the <Esc> and cancel.  Fed after the command, as
      # the command waits for the reply when keys are pending.
      feedkeys("\<Esc>", 't')
      g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
      assert_equal(expected, newNames, $'{cmd}, action: {action}')
      assert_equal(expected->mapnew((_, _) => pos), positions)
      assert_equal("\<Esc>", getcharstr(0))
      StopAsyncReplyingLspServer(lspserver, bnr)
    endfor
  finally
    DiscardTypeahead()
    :%bw!
  endtry
enddef

# The positions of the text edits of a code action, also of one that is
# resolved, are decoded for the text that the edits are applied to, after the
# changes before them.
def g:Test_CodeAction_DecodesEditsAfterPrecedingChanges()
  var fname = 'XCodeActionUtf16Created.txt'
  var action = {title: 'Create'}
  var lspserver = MakeUtf16LspServer()
  lspserver.isCodeActionProvider = true
  lspserver.isCodeActionResolveProvider = true
  lspserver.rpc_a = (method: string, _: any, Cbfunc: func, _ = {}) => {
    var resolved = action->extendnew({edit: Utf16CreateAndEdit(fname)})
    Cbfunc(lspserver, method == 'codeAction/resolve' ? resolved : [resolved],
	   {})
    return 1
  }
  try
    silent! edit XCodeActionUtf16Source.txt
    lspserver.codeActionAsync(@%, 1, 1, '1', (srv, actions, query, _) => {
      codeaction.ApplyCodeAction(srv, actions, query)
    })
    assert_equal(['😀!ab'], getbufline(fname, 1, '$'))
    exe $'bwipe! {fname}'
    delete(fname)

    codeaction.HandleCodeAction(lspserver, action)
    assert_equal(['😀!ab'], getbufline(fname, 1, '$'))
  finally
    delete(fname)
    :%bwipe!
  endtry
enddef

# The positions of the text edits of a workspace edit that the language server
# asks for are decoded for the text that the edits are applied to, after the
# changes before them.
def g:Test_ProcessApplyEditReq_DecodesEditsAfterPrecedingChanges()
  var fname = 'XApplyEditUtf16Created.txt'
  var responses: list<dict<any>> = []
  var lspserver = MakeUtf16LspServer()
  lspserver.sendResponse = function(CaptureResponse, [responses])
  try
    lspserver.processRequest({id: 1, method: 'workspace/applyEdit',
			      params: {edit: Utf16CreateAndEdit(fname)}})
    assert_equal({applied: true}, responses[0].result)
    assert_equal(['😀!ab'], getbufline(fname, 1, '$'))
  finally
    delete(fname)
    :%bwipe!
  endtry
enddef

# The reply to a completionItem/resolve request is kept with the item that was
# sent, to apply its additional text edits when it is accepted, and a reply
# saying that the request failed is not.
def g:Test_ResolveCompletion_KeepsResolvedItem()
  silent! edit XResolveCompletion.txt
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.isCompletionResolveProvider = true
  var replyCbs: list<func> = []
  lspserver.rpc_a = (_, _, Cb, _: dict<any> = {}) => {
    replyCbs->add(Cb)
    return replyCbs->len()
  }
  var item = {label: 'foo', data: 1}
  var resolved = item->extendnew({additionalTextEdits: [{
    range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}},
    newText: "import foo\n"}]})

  lspserver.resolveCompletion(item)
  replyCbs[0](lspserver, v:null, {code: -32603, message: 'failed'})
  assert_equal([], lspserver.completionResolved)

  lspserver.resolveCompletion(item)
  replyCbs[1](lspserver, resolved, {})
  assert_equal([[item, resolved]], lspserver.completionResolved)
  :%bw!
enddef

# Resolving a completion item synchronously while the asynchronous resolve of
# the same item is pending, as when the item is accepted right after it was
# selected, waits for the reply to that request instead of sending another.
def g:Test_ResolveCompletion_WaitsForPendingResolve()
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.isCompletionResolveProvider = true
  var item = {label: 'foo', data: 1}
  var resolved = item->extendnew({additionalTextEdits: [{
    range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}},
    newText: "import foo\n"}]})
  # The reply to the asynchronous request, which Vim numbers 1 on a new
  # channel, arrives a second after the request is sent.
  lspserver.job = StartSteppedStubServerJob([[],
    [{jsonrpc: '2.0', id: 1, result: resolved}]])
  try
    var syncId = lspserver.nextSyncRpcId

    lspserver.resolveCompletion(item)
    assert_equal(resolved, lspserver.resolveCompletion(item, true))

    assert_equal(syncId, lspserver.nextSyncRpcId)
    assert_equal([[item, resolved]], lspserver.completionResolved)
    assert_equal({}, lspserver.pendingRequests)
    assert_equal({}, lspserver.completionResolvePending)
    assert_equal([], notifications)
  finally
    job_stop(lspserver.job)
  endtry
enddef

# The pending asynchronous resolve of a completion item is waited for as long
# as a synchronous request would wait, and then cancelled.  An item whose
# resolve is not pending is resolved with a synchronous request.
def g:Test_ResolveCompletion_PendingResolveTimesOut()
  var notifications: list<dict<any>> = []
  var lspserver = MakeTestLspServer(notifications)
  lspserver.isCompletionResolveProvider = true
  var item = {label: 'foo', data: 1}
  # A language server that never replies
  lspserver.job = StartStubServerJob([], {timeout: 100})
  try
    var syncId = lspserver.nextSyncRpcId

    lspserver.resolveCompletion(item)
    assert_equal({}, lspserver.resolveCompletion(item, true))

    assert_equal(syncId, lspserver.nextSyncRpcId)
    assert_equal([{method: '$/cancelRequest', params: {id: 1}}],
		 notifications)
    assert_equal({}, lspserver.supersedableRequests)

    notifications->remove(0, -1)
    lspserver.resolveCompletion(item)
    assert_equal({}, lspserver.resolveCompletion({label: 'bar', data: 2}, true))

    assert_equal(syncId + 1, lspserver.nextSyncRpcId)
    assert_equal([{method: '$/cancelRequest', params: {id: syncId}}],
		 notifications)
  finally
    job_stop(lspserver.job)
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
  lspserver.rpc_a = (_, _, Cb, _: dict<any> = {}) => {
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
  lspserver.rpc_a = (_, _, Cb, _: dict<any> = {}) => {
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

# Omni completion reads the reply to its request from the channel while it
# waits for it, and a reply that arrives before it waits, e.g. while a
# completion plugin polls g:LspOmniCompletePending(), goes to the request's
# callback through the channel callback.
def g:Test_OmniFunc_ReadsReplyFromChannel()
  silent! edit XOmniFuncReply.vim
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isCompletionProvider = true
  lspserver.completionLazyDoc = false
  lspserver.completionTriggerChars = []
  buf.BufLspServerSet(bufnr(), lspserver)
  var ProcessMessage = (_, msg) => {
    lspserver.data = msg
    lspserver.processMessage()
  }

  try
    setline(1, 'fo ')
    cursor(1, 3)
    var id = lspserver.nextSyncRpcId
    lspserver.job = StartStubServerJob(
      [{jsonrpc: '2.0', id: id, result: [{label: 'foo'}, {label: 'bar'}]}],
      {out_cb: ProcessMessage})
    assert_equal(0, g:LspOmniFunc(1, ''))
    assert_equal({[id]: 'textDocument/completion'}, lspserver.pendingRequests)
    var start = reltime()
    assert_equal(['foo'],
		 g:LspOmniFunc(0, 'fo')->mapnew((_, v) => v.word))
    assert_true(start->reltime()->reltimefloat() < 1.0)
    assert_equal({}, lspserver.awaitedReplies)
    assert_equal({}, lspserver.pendingRequests)
    job_stop(lspserver.job)

    id = lspserver.nextSyncRpcId
    lspserver.job = StartStubServerJob(
      [{jsonrpc: '2.0', id: id, result: [{label: 'foobar'}]}],
      {out_cb: ProcessMessage})
    assert_equal(0, g:LspOmniFunc(1, ''))
    g:WaitForAssert(() => assert_false(g:LspOmniCompletePending()))
    assert_equal({}, lspserver.awaitedReplies)
    assert_equal({}, lspserver.pendingRequests)
    assert_equal(['foobar'],
		 g:LspOmniFunc(0, 'fo')->mapnew((_, v) => v.word))
  finally
    job_stop(lspserver.job)
    buf.BufLspServerRemove(bufnr(), lspserver)
    :%bw!
  endtry
enddef

# Test that ":LspCodeLens" resolves the code lens items without a command,
# leaves out of the menu those that cannot be resolved, and runs the command
# of the selected item.
def g:Test_LspCodeLens_ResolvesItems()
  silent! edit XCodeLens.txt
  setline(1, ['one', 'two', 'three'])
  var LineRange = (lnum: number): dict<any> => ({
    start: {line: lnum, character: 0}, end: {line: lnum, character: 1}})
  var lenses = [
    {range: LineRange(0), data: 'unresolvable'},
    {range: LineRange(1), command: {title: 'Run', command: 'run'}},
    {range: LineRange(2), data: 'resolvable'}
  ]
  var resolved = {range: LineRange(2),
		  command: {title: 'Debug', command: 'debug'}}
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isCodeLensProvider = true
  lspserver.isCodeLensResolveProvider = true
  var resolveRequests: list<string> = []
  lspserver.rpc_a = (method: string, params: any, Cbfunc: func, _ = {}) => {
    var result: any = null
    if method == 'textDocument/codeLens'
      result = lenses->deepcopy()
    elseif method == 'codeLens/resolve'
      resolveRequests->add(params.data)
      if params.data == 'resolvable'
	result = resolved->deepcopy()
      endif
    endif
    Cbfunc(lspserver, result, {})
    return 1
  }
  var execCmds: list<string> = []
  lspserver.executeCommand = (cmd: dict<any>) => {
    execCmds->add(cmd.command)
  }
  buf.BufLspServerSet(bufnr(), lspserver)

  try
    # Select the second item in the menu, which is the second resolved item
    feedkeys(":LspCodeLens\<CR>2\<CR>", 'xt')
    assert_equal(['unresolvable', 'resolvable'], resolveRequests)
    assert_equal(['debug'], execCmds)
  finally
    buf.BufLspServerRemove(bufnr(), lspserver)
    :%bw!
  endtry
enddef

# Define the code lens highlight group and text property type, which are
# otherwise defined only when the first language server is started.
def CodeLensInitOnce()
  if prop_type_get('LspCodeLens')->empty()
    codelens.InitOnce()
  endif
enddef

# Returns the LSP range of the character at "character" on the zero-based
# line "line".
def CodeLensRange(line: number, character: number): dict<any>
  return {start: {line: line, character: character},
	  end: {line: line, character: character + 1}}
enddef

# Returns the texts of the code lenses shown above each line of the current
# buffer.
def CodeLensTexts(): list<list<string>>
  return range(1, line('$'))->mapnew((_, lnum) =>
    prop_list(lnum, {types: ['LspCodeLens']})->mapnew((_, p) => p.text))
enddef

# Returns a running test language server providing code lenses, attached to
# the current buffer.  It replies to "textDocument/codeLens" with "lenses",
# and to "codeLens/resolve" with the item in "resolved" for the "data" of the
# code lens, or with null.  The methods of the requests it gets are added to
# "requests", and the commands it runs to "execCmds".
def MakeCodeLensServer(lenses: list<dict<any>>, resolved: dict<dict<any>>,
		       requests: list<string>,
		       execCmds: list<string>): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isCodeLensProvider = true
  lspserver.isCodeLensResolveProvider = true
  lspserver.rpc_a = (method: string, params: any, Cbfunc: func, _ = {}) => {
    requests->add(method)
    var result: any = null
    if method == 'textDocument/codeLens'
      result = lenses->deepcopy()
    elseif resolved->has_key(params->get('data', ''))
      result = resolved[params.data]->deepcopy()
    endif
    Cbfunc(lspserver, result, {})
    return 1
  }
  lspserver.executeCommand = (cmd: dict<any>) => {
    execCmds->add(cmd.command)
  }
  buf.BufLspServerSet(bufnr(), lspserver)
  return lspserver
enddef

# Test that setting the "showCodeLens" option shows the code lenses above
# their lines, indented like the line: the resolved ones, on one line for a
# line with several, in the order of their columns.  Resetting the option
# removes them.
def g:Test_CodeLens_ShownAboveTheirLines()
  CodeLensInitOnce()
  silent! edit XCodeLensShow.txt
  setlocal tabstop=4
  setline(1, ['fn a() {}', "\t  fn b() {}", 'fn c() {}', 'fn d() {}'])
  var lenses = [
    {range: CodeLensRange(0, 3), command: {title: 'Run', command: 'run'}},
    {range: CodeLensRange(0, 0), command: {title: 'Debug', command: 'debug'}},
    {range: CodeLensRange(1, 3), data: 'refs'},
    {range: CodeLensRange(2, 0), data: 'unresolvable'},
    {range: CodeLensRange(3, 0), command: {title: "two\nlines", command: 'x'}}
  ]
  var resolved = {refs: {range: CodeLensRange(1, 3),
			 command: {title: '2 references', command: 'refs'}}}
  var requests: list<string> = []
  var lspserver = MakeCodeLensServer(lenses, resolved, requests, [])
  try
    g:LspOptionsSet({showCodeLens: true})
    assert_equal(['textDocument/codeLens', 'codeLens/resolve',
		  'codeLens/resolve'], requests)
    assert_equal([['Debug | Run'], ['      2 references'], [], ['two lines']],
		 CodeLensTexts())
    assert_equal('above', prop_list(1, {types: ['LspCodeLens']})[0].text_align)

    g:LspOptionsSet({showCodeLens: false})
    assert_equal([[], [], [], []], CodeLensTexts())
    assert_equal([], autocmd_get({group: 'LspCodeLens',
				  pattern: $'<buffer={bufnr()}>'}))
  finally
    g:LspOptionsSet({showCodeLens: false})
    buf.BufLspServerRemove(bufnr(), lspserver)
    :%bw!
  endtry
enddef

# Test that the code lenses are updated when the cursor rests after a change,
# that a reply to a request made before a change is dropped, and that the code
# lenses are not updated in Insert mode, but when the cursor rests after it.
def g:Test_CodeLens_UpdatedAfterChange()
  CodeLensInitOnce()
  silent! edit XCodeLensChange.txt
  setline(1, ['one', 'two'])
  var bnr = bufnr()
  var lenses = [
    {range: CodeLensRange(0, 0), command: {title: 'One', command: 'one'}}
  ]
  var requests: list<string> = []
  var lspserver = MakeCodeLensServer(lenses, {}, requests, [])
  opt.lspOptions.showCodeLens = true
  try
    codelens.BufferInit(lspserver, bnr)
    assert_equal([['One'], []], CodeLensTexts())

    # Without a change, the code lenses are not requested again
    doautocmd CursorHold
    assert_equal(1, requests->len())

    lenses[0] = {range: CodeLensRange(1, 0),
		 command: {title: 'Two', command: 'two'}}
    append(0, 'zero')
    doautocmd TextChanged
    doautocmd CursorHold
    assert_equal(2, requests->len())
    assert_equal([[], ['Two'], []], CodeLensTexts())

    # The reply to a request made before a change is dropped
    var Replies: list<func> = []
    lspserver.rpc_a = (_, _, Cbfunc: func, _ = {}) => {
      Replies->add(() => Cbfunc(lspserver, lenses->deepcopy(), {}))
      return 1
    }
    lenses[0].range = CodeLensRange(2, 0)
    doautocmd TextChanged
    doautocmd CursorHold
    deletebufline(bnr, 1)
    Replies[0]()
    assert_equal([['Two'], []], CodeLensTexts())

    # The code lenses are not shown in Insert mode, but after it
    g:CodeLensShowTest = () => {
      codelens.ShowCodeLenses(bnr, [{range: CodeLensRange(0, 0),
				   command: {title: 'Ins', command: 'ins'}}])
    }
    feedkeys("i\<Cmd>call g:CodeLensShowTest()\<CR>\<Esc>", 'xt')
    assert_equal([['Two'], []], CodeLensTexts())
    assert_true(bnr->getbufvar('LspCodeLensNeedsUpdate'))
  finally
    opt.lspOptions.showCodeLens = false
    silent! unlet g:CodeLensShowTest
    buf.BufLspServerRemove(bnr, lspserver)
    :%bw!
  endtry
enddef

# Test that detaching a buffer from its language servers removes the code
# lenses shown in it and stops updating them.
def g:Test_CodeLens_RemovedWhenDetached()
  CodeLensInitOnce()
  silent! edit XCodeLensDetach.txt
  setline(1, ['one'])
  var bnr = bufnr()
  var lenses = [
    {range: CodeLensRange(0, 0), command: {title: 'One', command: 'one'}}
  ]
  var lspserver = MakeCodeLensServer(lenses, {}, [], [])
  opt.lspOptions.showCodeLens = true
  try
    codelens.BufferInit(lspserver, bnr)
    assert_equal([['One']], CodeLensTexts())
    lsp.RemoveFile(bnr)
    assert_equal([[]], CodeLensTexts())
    assert_equal([], autocmd_get({group: 'LspCodeLens',
				  pattern: $'<buffer={bnr}>'}))
  finally
    opt.lspOptions.showCodeLens = false
    buf.BufLspServerRemove(bnr, lspserver)
    :%bw!
  endtry
enddef

# Test that ":LspCodeLensRun" runs the code lens on the cursor line, without
# a menu when it is the only one, and resolves only the code lenses on that
# line.
def g:Test_LspCodeLensRun()
  silent! edit XCodeLensRun.txt
  setline(1, ['one', 'two', 'three'])
  var lenses = [
    {range: CodeLensRange(0, 0), command: {title: 'Run', command: 'run'}},
    {range: CodeLensRange(1, 0), command: {title: 'A', command: 'a'}},
    {range: CodeLensRange(1, 2), data: 'b'}
  ]
  var resolved = {b: {range: CodeLensRange(1, 2),
		      command: {title: 'B', command: 'b'}}}
  var requests: list<string> = []
  var execCmds: list<string> = []
  var lspserver = MakeCodeLensServer(lenses, resolved, requests, execCmds)
  try
    cursor(1, 1)
    :LspCodeLensRun
    assert_equal(['textDocument/codeLens'], requests)
    assert_equal(['run'], execCmds)

    # Select the second code lens on the line
    cursor(2, 1)
    feedkeys(":LspCodeLensRun\<CR>2\<CR>", 'xt')
    assert_equal(['textDocument/codeLens', 'codeLens/resolve'],
		 requests[1 :])
    assert_equal(['run', 'b'], execCmds)

    cursor(3, 1)
    :LspCodeLensRun
    assert_equal('Warn: No code lens actions found for the current line',
		 LastMessage())
    assert_equal(['run', 'b'], execCmds)
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
  lspserver.rpc_a = (method: string, params: any, Cbfunc: func, _ = {}) => {
    requests->add({method: method, params: params->deepcopy()})
    var result: any = method == 'documentLink/resolve' ? resolved : links
    Cbfunc(lspserver, result->deepcopy(), {})
    return requests->len()
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

# Send a "window/showDocument" request with "params" from the language server
# "lspserver" made by MakeRequestTestLspServer() with "responses", and return
# the result of the reply.
def ShowDocument(lspserver: dict<any>, responses: list<dict<any>>,
		 params: dict<any>): any
  responses->filter('0')
  lspserver.processRequest({jsonrpc: '2.0', id: 1,
			    method: 'window/showDocument', params: params})
  assert_equal(1, responses->len())
  assert_equal({}, responses[0].error)
  return responses[0].result
enddef

# Test that a "window/showDocument" request without a URI, or with a selection
# that is not a range, gets an InvalidParams error.
def g:Test_ShowDocument_InvalidParams()
  var responses: list<dict<any>> = []
  var lspserver = MakeRequestTestLspServer(responses)
  AssertRequestError(lspserver, responses,
    {id: 1, method: 'window/showDocument', params: {}}, -32602)
  AssertRequestError(lspserver, responses,
    {id: 2, method: 'window/showDocument',
     params: {uri: 'file:///tmp/x', selection: []}}, -32602)
enddef

# Test that a "window/showDocument" request shows a file in a window and puts
# the cursor at the start of the selection, decoded from the position
# encoding, and that by default the window takes the focus.  The cursor
# location is pushed onto the tag stack, as for a jump to a definition.
def g:Test_ShowDocument_TakesFocus()
  writefile(['one', "\U1F60A ab"], 'XShowDocTarget.txt')
  silent! edit XShowDocSrc.txt
  setline(1, ['src'])
  :write
  var responses: list<dict<any>> = []
  var lspserver = MakeRequestTestLspServer(responses)
  lspserver.posEncoding = 16
  var uri = util.LspFileToUri('XShowDocTarget.txt')
  try
    # "a" is after the emoji (2 UTF-16 code units) and the space
    var selection = {start: {line: 1, character: 3},
		     end: {line: 1, character: 5}}
    assert_equal({success: true}, ShowDocument(lspserver, responses,
					       {uri: uri, selection: selection}))
    assert_equal(1, winnr('$'))
    assert_equal('XShowDocTarget.txt', expand('%:t'))
    assert_equal([2, 6], [line('.'), col('.')])
    assert_equal('XShowDocSrc.txt',
		 gettagstack().items[-1].bufnr->bufname())

    # Without a selection the cursor stays where it is
    cursor(1, 2)
    assert_equal({success: true}, ShowDocument(lspserver, responses,
					       {uri: uri, takeFocus: true}))
    assert_equal([1, 2], [line('.'), col('.')])
  finally
    :%bw!
    delete('XShowDocTarget.txt')
    delete('XShowDocSrc.txt')
  endtry
enddef

# Test that a "window/showDocument" request that asks not to take the focus
# shows a file in a window split from the current one, or in the window
# already showing it, and puts the cursor in that window at the start of the
# selection, while the cursor stays in the current window.
def g:Test_ShowDocument_KeepsFocus()
  writefile(['one', 'two', 'three'], 'XShowDocTarget.txt')
  silent! edit XShowDocSrc.txt
  setline(1, ['src'])
  var srcWinid = win_getid()
  var responses: list<dict<any>> = []
  var lspserver = MakeRequestTestLspServer(responses)
  var uri = util.LspFileToUri('XShowDocTarget.txt')
  var Selection = (lnum: number): dict<any> => ({
    start: {line: lnum, character: 1}, end: {line: lnum, character: 1}})
  try
    for lnum in [1, 2]
      assert_equal({success: true},
		   ShowDocument(lspserver, responses,
				{uri: uri, selection: Selection(lnum),
				 takeFocus: false}))
      assert_equal(srcWinid, win_getid())
      assert_equal(2, winnr('$'))
      var targetWinid = bufnr('XShowDocTarget.txt')->bufwinid()
      assert_equal([lnum + 1, 2],
		   getcurpos(targetWinid)[1 : 2], $'lnum: {lnum}')
    endfor
  finally
    :%bw!
    delete('XShowDocTarget.txt')
  endtry
enddef

# Test that a "window/showDocument" request shows a URI externally with the
# opener from the Vim runtime when the server asks for it, and that it reports
# a failure for a URI that it cannot show in Vim.
def g:Test_ShowDocument_External()
  writefile(['#!/bin/sh', 'printf "%s" "$1" > XShowDocOpened'],
	    'XShowDocOpener')
  setfperm('XShowDocOpener', 'rwx------')
  g:Openprg = './XShowDocOpener'
  var responses: list<dict<any>> = []
  var lspserver = MakeRequestTestLspServer(responses)
  var uri = 'https://example.com/doc'
  try
    assert_equal({success: false},
		 ShowDocument(lspserver, responses, {uri: uri}))
    assert_match('Cannot show "https://example.com/doc" in Vim',
		 execute('messages'))
    assert_false(filereadable('XShowDocOpened'))

    assert_equal({success: true},
		 ShowDocument(lspserver, responses, {uri: uri, external: true}))
    g:WaitFor(() => filereadable('XShowDocOpened')
		      && readfile('XShowDocOpened') == [uri])
  finally
    unlet g:Openprg
    delete('XShowDocOpener')
    delete('XShowDocOpened')
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
  lspserver.rpc_a = (method: string, params: any, Cbfunc: func, _ = {}) => {
    var result: list<dict<any>> = method == 'callHierarchy/incomingCalls'
      ? [{from: item->deepcopy(), fromRanges: []}]
      : [item->deepcopy()]
    Cbfunc(lspserver, result, {})
    return 1
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

# Returns a language server that reports a Function symbol for each line
# "void {name}(void) {}" of a document.
def MakeOutlineServer(): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isDocumentSymbolProvider = true
  lspserver.rpc_a = (method: string, params: any, Cbfunc: func, _: dict<any> = {}): number => {
    var symbols: list<dict<any>> = []
    var lines = util.LspUriToBufnr(params.textDocument.uri)->getbufline(1, '$')
    for idx in range(lines->len())
      var name: string = lines[idx]->matchstr('^void \zs\w\+')
      if !name->empty()
	var symRange = {start: {line: idx, character: 5},
			end: {line: idx, character: 5 + name->len()}}
	symbols->add({name: name, kind: 12, range: symRange,
		      selectionRange: symRange->deepcopy()})
      endif
    endfor
    Cbfunc(lspserver, symbols, {})
    return 1
  }
  return lspserver
enddef

# Edits the file "fname" with the lines "lines" in the current window, with
# the language server "lspserver" for it.  Returns the buffer number.
def OutlineSrcEdit(lspserver: dict<any>, fname: string,
		   lines: list<string>): number
  exe $'silent edit {fname}'
  setline(1, lines)
  :setlocal nomodified filetype=text
  buf.BufLspServerSet(bufnr(), lspserver)
  return bufnr()
enddef

# Returns the numbers of the lines in the outline buffer "bnr" with the
# highlight of the current symbol.
def OutlineHighlightLnums(bnr: number): list<number>
  return prop_list(1, {bufnr: bnr, end_lnum: -1,
		       types: ['LspOutlineHighlight']})
    ->map((_, p) => p.lnum)
enddef

# Test that the outline highlights the symbol at the cursor in the source
# file, after it is updated and when the cursor is idle.
def g:Test_LspOutline_HighlightCurrentSymbol()
  var lspserver = MakeOutlineServer()
  var srcBnr = -1
  try
    srcBnr = OutlineSrcEdit(lspserver, 'XOutlineHighlight.c',
			    ['void aOutlineFunc(void) {}', '',
			     'void bOutlineFunc(void) {}'])
    cursor(3, 1)
    :LspOutline
    var outlineBnr: number = ScratchBufsInTab()[0]
    assert_equal([6], OutlineHighlightLnums(outlineBnr))

    cursor(1, 1)
    :doautocmd CursorHold
    assert_equal([5], OutlineHighlightLnums(outlineBnr))
    cursor(2, 1)
    :doautocmd CursorHold
    assert_equal([], OutlineHighlightLnums(outlineBnr))
  finally
    buf.BufLspServerRemove(srcBnr, lspserver)
    :%bw!
  endtry
enddef

# Test that the outline, open in two tab pages for the same file, keeps the
# cursor in both outline windows, and jumps to and highlights the symbols at
# their current lines in both tab pages, after it is refreshed in one of them.
def g:Test_LspOutline_InTwoTabPages_Refresh()
  var lspserver = MakeOutlineServer()
  var srcBnr = -1
  try
    srcBnr = OutlineSrcEdit(lspserver, 'XOutlineTabs.c',
			    ['void aOutlineFunc(void) {}',
			     'void bOutlineFunc(void) {}'])
    :LspOutline
    var outlineBnr: number = ScratchBufsInTab()[0]
    var outlineWinids: list<number> = [outlineBnr->bufwinid()]
    :tab split
    :LspOutline
    assert_equal([outlineBnr], ScratchBufsInTab())
    outlineWinids->add(outlineBnr->bufwinid())
    win_execute(outlineWinids[0], 'cursor(6, 1)')
    win_execute(outlineWinids[1], 'cursor(5, 1)')

    append(0, ['', ''])
    g:LspRequestDocSymbols()
    assert_equal(['Function@', '  aOutlineFunc', '  bOutlineFunc'],
		 outlineBnr->getbufline(4, '$'))
    assert_equal([6, 5], outlineWinids->mapnew((_, w) => getcurpos(w)[1]))

    # [tab page, outline line to select, its source line, source line for
    # the highlight, its outline line]
    for [tabnr, selLnum, srcLnum, hlSrcLnum, hlLnum] in [[1, 6, 4, 3, 5],
							  [2, 5, 3, 4, 6]]
      var ctx = $'tab page {tabnr}'
      exe $'tabnext {tabnr}'
      var srcWinid = win_getid()
      outlineWinids[tabnr - 1]->win_gotoid()
      cursor(selLnum, 1)
      exe "normal \<CR>"
      assert_equal([srcWinid, srcLnum, 6], [win_getid(), line('.'), col('.')],
		   ctx)

      cursor(hlSrcLnum, 1)
      :doautocmd CursorHold
      assert_equal([hlLnum], OutlineHighlightLnums(outlineBnr), ctx)
    endfor
  finally
    buf.BufLspServerRemove(srcBnr, lspserver)
    :%bw!
  endtry
enddef

# Test that opening the outline in a second tab page keeps the symbols that it
# shows, until the language server replies.
def g:Test_LspOutline_InTwoTabPages_KeepsSymbolsUntilReply()
  var lspserver = MakeOutlineServer()
  var srcBnr = -1
  try
    srcBnr = OutlineSrcEdit(lspserver, 'XOutlineTabs.c',
			    ['', 'void aOutlineFunc(void) {}'])
    :LspOutline
    var outlineBnr: number = ScratchBufsInTab()[0]
    var outlineLines: list<string> = outlineBnr->getbufline(1, '$')
    lspserver.rpc_a = (method: string, params: any, Cbfunc: func, ..._): number => 1

    :tab split
    :LspOutline
    assert_equal(outlineLines, outlineBnr->getbufline(1, '$'))
    outlineBnr->bufwinid()->win_gotoid()
    cursor(5, 1)
    exe "normal \<CR>"
    assert_equal([2, srcBnr, 2, 6],
		 [tabpagenr(), bufnr(), line('.'), col('.')])
  finally
    buf.BufLspServerRemove(srcBnr, lspserver)
    :%bw!
  endtry
enddef

# Test that the outline, open in two tab pages for different files, jumps to
# the file that it shows from the tab page where it was not refreshed.
def g:Test_LspOutline_InTwoTabPages_OtherFile()
  var lspserver = MakeOutlineServer()
  var srcBnrs: list<number> = []
  try
    srcBnrs->add(OutlineSrcEdit(lspserver, 'XOutlineTabsA.c',
				['void aOutlineFunc(void) {}']))
    var srcWinid = win_getid()
    :LspOutline
    var outlineBnr: number = ScratchBufsInTab()[0]
    outlineBnr->bufwinid()->win_gotoid()

    :tabnew
    srcBnrs->add(OutlineSrcEdit(lspserver, 'XOutlineTabsB.c',
				['', 'void bOutlineFunc(void) {}']))
    :LspOutline
    assert_equal(['Function@', '  bOutlineFunc'],
		 outlineBnr->getbufline(4, '$'))

    :tabfirst
    assert_equal(outlineBnr, bufnr())
    cursor(5, 1)
    exe "normal \<CR>"
    assert_equal([1, srcWinid, 'XOutlineTabsB.c', 2, 6],
		 [tabpagenr(), win_getid(), bufname(), line('.'), col('.')])
  finally
    for bnr in srcBnrs
      buf.BufLspServerRemove(bnr, lspserver)
    endfor
    :%bw!
  endtry
enddef

# Requests the document symbols for the outline, and returns the exception
# that this throws, or an empty string when it throws none.
def OutlineRefreshException(): string
  try
    g:LspRequestDocSymbols()
  catch
    return v:exception
  endtry
  return ''
enddef

# Test that an error in updating the outline, in showing a symbol or in an
# autocmd for the LspOutlineUpdated event, goes back to the window of the
# document and doesn't keep the outline from being refreshed afterwards.
def g:Test_LspOutline_RefreshesAfterError()
  var lspserver = MakeOutlineServer()
  var SymbolsRpc: func = lspserver.rpc_a
  var srcBnr = -1
  try
    srcBnr = OutlineSrcEdit(lspserver, 'XOutlineError.c',
			    ['void aOutlineFunc(void) {}'])
    var srcWinid = win_getid()
    :LspOutline
    var outlineBnr: number = ScratchBufsInTab()[0]

    # A symbol whose selection range has no line
    lspserver.rpc_a = (method: string, params: any, Cbfunc: func, _: dict<any> = {}): number => {
      var symRange = {start: {line: 0, character: 5},
		      end: {line: 0, character: 17}}
      Cbfunc(lspserver, [{name: 'aOutlineFunc', kind: 12, range: symRange,
			  selectionRange: {start: {character: 5},
					   end: {character: 17}}}], {})
      return 1
    }
    assert_match('E716:', OutlineRefreshException())
    v:errmsg = ''
    assert_equal(srcWinid, win_getid())
    lspserver.rpc_a = SymbolsRpc
    srcWinid->win_gotoid()
    setline(1, 'void bOutlineFunc(void) {}')
    g:LspRequestDocSymbols()
    assert_equal(['Function@', '  bOutlineFunc'],
		 outlineBnr->getbufline(4, '$'))

    autocmd_add([{group: 'XOutlineError', event: 'User',
		  pattern: 'LspOutlineUpdated', once: true,
		  cmd: "throw 'XOutlineUpdatedError'"}])
    assert_equal('XOutlineUpdatedError', OutlineRefreshException())
    assert_equal(srcWinid, win_getid())
    srcWinid->win_gotoid()
    setline(1, 'void cOutlineFunc(void) {}')
    g:LspRequestDocSymbols()
    assert_equal(['Function@', '  cOutlineFunc'],
		 outlineBnr->getbufline(4, '$'))
  finally
    :silent! autocmd_delete([{group: 'XOutlineError'}])
    buf.BufLspServerRemove(srcBnr, lspserver)
    :%bw!
  endtry
enddef

# Lines of the document "XDocSymbols.c" whose symbols DocSymbolsReply()
# returns.
const docSymbolsSrc: list<string> = ['struct aStruct {', '  int aField;', '};',
				     'void bFunc(void) {}']

# Returns the LSP range from line "sl", character "sc" to line "el",
# character "ec".
def SymRange(sl: number, sc: number, el: number, ec: number): dict<any>
  return {start: {line: sl, character: sc}, end: {line: el, character: ec}}
enddef

# Returns the reply to a "textDocument/documentSymbol" request for the
# document "uri" with the lines "docSymbolsSrc": a DocumentSymbol[] when
# "hierarchical" is true, and a SymbolInformation[] otherwise.
def DocSymbolsReply(uri: string, hierarchical: bool): list<dict<any>>
  if hierarchical
    var field = {name: 'aField', kind: 8, detail: 'int',
		 range: SymRange(1, 2, 1, 13),
		 selectionRange: SymRange(1, 6, 1, 12)}
    return [{name: 'aStruct', kind: 23, detail: 'struct',
	     range: SymRange(0, 0, 2, 2),
	     selectionRange: SymRange(0, 7, 0, 14),
	     children: [field]},
	    {name: 'bFunc', kind: 12, detail: 'void (void)',
	     range: SymRange(3, 0, 3, 19),
	     selectionRange: SymRange(3, 5, 3, 10)}]
  endif
  return [{name: 'aStruct', kind: 23,
	   location: {uri: uri, range: SymRange(0, 0, 2, 2)}},
	  {name: 'aField', kind: 8, containerName: 'aStruct',
	   location: {uri: uri, range: SymRange(1, 2, 1, 13)}},
	  {name: 'bFunc', kind: 12, containerName: '',
	   location: {uri: uri, range: SymRange(3, 0, 3, 19)}}]
enddef

# Returns a language server that replies to a "textDocument/documentSymbol"
# request with DocSymbolsReply().
def MakeDocSymbolsServer(hierarchical: bool): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.running = true
  lspserver.ready = true
  lspserver.isDocumentSymbolProvider = true
  lspserver.rpc_a = (method: string, params: any, Cbfunc: func, _: dict<any> = {}): number => {
    Cbfunc(lspserver, DocSymbolsReply(params.textDocument.uri, hierarchical),
	   {})
    return 1
  }
  return lspserver
enddef

# Test the outline for both kinds of reply to a "textDocument/documentSymbol"
# request: the symbols that it shows, grouped by kind in the order of the LSP
# SymbolKind numbers, the symbol that it highlights for a line of the
# document, the detail that "K" shows for a symbol, and the location that
# selecting a symbol jumps to.
def g:Test_LspOutline_DocumentSymbolAndSymbolInformation()
  var cases = [
    {hierarchical: true, ctx: 'DocumentSymbol[]',
     text: ['', 'Function@', '  bFunc', '', 'Struct@', '  aStruct',
	    '    Field', '      aField'],
     symbols: [['  aStruct', 'aStruct: struct', 1, 8],
	       ['      aField', 'aField: int', 2, 7],
	       ['  bFunc', 'bFunc: void (void)', 4, 6]]},
    {hierarchical: false, ctx: 'SymbolInformation[]',
     text: ['', 'Field@', '  aField [aStruct]', '', 'Function@', '  bFunc', '',
	    'Struct@', '  aStruct'],
     symbols: [['  aStruct', 'aStruct', 1, 1],
	       ['  aField [aStruct]', 'aField [aStruct]', 2, 3],
	       ['  bFunc', 'bFunc', 4, 1]]}
  ]
  for c in cases
    var lspserver = MakeDocSymbolsServer(c.hierarchical)
    var srcBnr = -1
    try
      srcBnr = OutlineSrcEdit(lspserver, 'XDocSymbols.c', docSymbolsSrc)
      var srcWinid = win_getid()
      :LspOutline
      var outlineBnr: number = ScratchBufsInTab()[0]
      var outlineLines: list<string> = outlineBnr->getbufline(1, '$')
      assert_equal(c.text, outlineLines[2 :], c.ctx)

      for [srcLnum, sym] in [[1, c.symbols[0]], [2, c.symbols[1]],
			     [3, c.symbols[0]], [4, c.symbols[2]]]
	cursor(srcLnum, 1)
	:doautocmd CursorHold
	assert_equal([outlineLines->index(sym[0]) + 1],
		     OutlineHighlightLnums(outlineBnr), $'{c.ctx}: {srcLnum}')
      endfor

      for [symLine, detail, lnum, col] in c.symbols
	outlineBnr->bufwinid()->win_gotoid()
	cursor(outlineLines->index(symLine) + 1, 1)
	assert_equal($"\n{detail}", execute('normal K'), $'{c.ctx}: {symLine}')
	exe "normal \<CR>"
	assert_equal([srcWinid, lnum, col], [win_getid(), line('.'), col('.')],
		     $'{c.ctx}: {symLine}')
      endfor
    finally
      buf.BufLspServerRemove(srcBnr, lspserver)
      :%bw!
    endtry
  endfor
enddef

# Returns [type, lnum, col, length] of the text properties highlighting the
# name and the range of the symbol selected in the :LspDocumentSymbol popup,
# in this order.
def DocSymbolHighlightProps(): list<list<any>>
  return prop_list(1, {end_lnum: -1,
		       types: ['LspSymbolNameProp', 'LspSymbolRangeProp']})
    ->map((_, p) => [p.type, p.lnum, p.col, p.length])
    ->sort()
enddef

# Define the text property types of the :LspDocumentSymbol popup, which are
# otherwise defined only when the first language server is started.
def SymbolInitOnce()
  if prop_type_get('LspSymbolNameProp')->empty()
    symbol.InitOnce()
  endif
enddef

# Test the :LspDocumentSymbol popup for both kinds of reply to a
# "textDocument/documentSymbol" request: the symbols that it lists, the range
# and the name that it highlights for the selected symbol, and the location
# that selecting a symbol jumps to.
def g:Test_LspDocumentSymbol_DocumentSymbolAndSymbolInformation()
  var cases = [
    {hierarchical: true, ctx: 'DocumentSymbol[]',
     bFuncProps: [['LspSymbolNameProp', 4, 6, 5],
		  ['LspSymbolRangeProp', 4, 1, 19]],
     aFieldProps: [['LspSymbolNameProp', 2, 7, 6],
		   ['LspSymbolRangeProp', 2, 3, 11]],
     aFieldPos: [2, 7]},
    {hierarchical: false, ctx: 'SymbolInformation[]',
     bFuncProps: [['LspSymbolNameProp', 4, 1, 19],
		  ['LspSymbolRangeProp', 4, 1, 19]],
     aFieldProps: [['LspSymbolNameProp', 2, 3, 11],
		   ['LspSymbolRangeProp', 2, 3, 11]],
     aFieldPos: [2, 3]}
  ]
  SymbolInitOnce()
  for c in cases
    var lspserver = MakeDocSymbolsServer(c.hierarchical)
    var srcBnr = -1
    try
      srcBnr = OutlineSrcEdit(lspserver, 'XDocSymbols.c', docSymbolsSrc)
      cursor(4, 1)
      :LspDocumentSymbol
      var menus: list<number> = popup_list()
	->filter((_, id) => !id->getwinvar('symbolTable', [])->empty())
      assert_equal(1, menus->len(), c.ctx)
      assert_equal(['struct : aStruct', 'field : aField [aStruct]',
		    'function : bFunc'],
		   menus[0]->winbufnr()->getbufline(1, '$'), c.ctx)
      assert_equal(c.bFuncProps, DocSymbolHighlightProps(), c.ctx)

      feedkeys("\<Up>", 'xt')
      assert_equal(c.aFieldProps, DocSymbolHighlightProps(), c.ctx)

      feedkeys("\<CR>", 'xt')
      assert_equal([], popup_list(), c.ctx)
      assert_equal(c.aFieldPos, [line('.'), col('.')], c.ctx)
      assert_equal([], DocSymbolHighlightProps(), c.ctx)
    finally
      popup_clear()
      buf.BufLspServerRemove(srcBnr, lspserver)
      :%bw!
    endtry
  endfor
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

# The text document sync capabilities of a language server that wants to know
# when a document is saved and to make edits to it before that.  The changes
# are sent as the full text, to make them easy to check.
const WILL_SAVE_SYNC_CAPS: dict<any> = {
  openClose: true,
  change: 1,
  save: true,
  willSave: true,
  willSaveWaitUntil: true
}

# Returns a TextEdit that inserts "text" at the start of the document.
def InsertAtStartEdit(text: string): dict<any>
  var pos = {line: 0, character: 0}
  return {range: {start: pos, end: pos}, newText: text}
enddef

# Returns a running and ready language server with the capabilities "caps".
# The notifications sent to the server are added to "messages".
def MakeCapsServer(caps: dict<any>, messages: list<dict<any>>): dict<any>
  var lspserver = MakeTestLspServer(messages)
  lspserver.caps = caps
  capabilities.ProcessServerCaps(lspserver, caps)
  lspserver.running = true
  lspserver.ready = true
  return lspserver
enddef

# Returns a running and ready language server with the capabilities "caps".
# It replies to a request with the reply for its method in "replies", and
# with none (as when the request times out) to the other requests.  The
# notifications and the requests sent to the server are added to "messages".
def MakeSaveServer(caps: dict<any>, replies: dict<dict<any>>,
		   messages: list<dict<any>>): dict<any>
  var lspserver = MakeCapsServer(caps, messages)
  lspserver.rpc = (method: string, params: any): dict<any> => {
    messages->add({method: method, params: params->deepcopy()})
    return replies->get(method, {})->deepcopy()
  }
  return lspserver
enddef

# Edits file "fname" with the lines "lines", and attaches the language servers
# "lspservers" to its buffer, as when they get ready.  Returns the buffer
# number.  The messages sent to the servers when they are attached are not
# kept.
def SaveTestEdit(fname: string, lines: list<string>,
		 lspservers: list<dict<any>>,
		 messages: list<list<dict<any>>>): number
  writefile(lines, fname)
  exe $'silent edit {fname}'
  var bnr = bufnr()
  for lspserver in lspservers
    buf.BufLspServerSet(bnr, lspserver)
  endfor
  for lspserver in lspservers
    lsp.BufferInit(lspserver.id, bnr)
  endfor
  for msgs in messages
    msgs->filter('0')
  endfor
  return bnr
enddef

# Returns the methods of the messages "messages".
def Methods(messages: list<dict<any>>): list<string>
  return messages->mapnew((_, msg) => msg.method)
enddef

# Test that before a buffer is written to its file, the language server is
# told so and the edits it asks for are made to the buffer and written.  The
# server gets the edits before the notification that the file was saved.
def g:Test_WillSave_EditsWrittenWithBuffer()
  var fname = 'XWillSaveEdits.txt'
  var messages: list<dict<any>> = []
  var lspserver = MakeSaveServer({textDocumentSync: WILL_SAVE_SYNC_CAPS},
    {'textDocument/willSaveWaitUntil': {result: [InsertAtStartEdit("// fixed\n")]}},
    messages)
  var bnr = SaveTestEdit(fname, ['int x;'], [lspserver], [messages])
  try
    :write
    assert_equal(['// fixed', 'int x;'], readfile(fname))
    assert_false(&modified)

    var uri = util.LspFileToUri(fname)
    var params = {textDocument: {uri: uri}, reason: 1}
    assert_equal(['textDocument/willSave', 'textDocument/willSaveWaitUntil'],
		 Methods(messages[: 1]))
    assert_equal([params, params], messages[: 1]->mapnew((_, m) => m.params))
    assert_equal('textDocument/didChange', messages[-2].method)
    assert_equal([{text: "// fixed\nint x;\n"}],
		 messages[-2].params.contentChanges)
    assert_equal({method: 'textDocument/didSave',
		  params: {textDocument: {uri: uri}}}, messages[-1])
  finally
    lsp.RemoveFile(bnr)
    :%bw!
    delete(fname)
  endtry
enddef

# Test that a buffer with several language servers attached to it is saved
# once: each server gets one of each save message, and the edits of each are
# made once.
def g:Test_WillSave_SeveralServers()
  var fname = 'XWillSaveServers.txt'
  var messages1: list<dict<any>> = []
  var messages2: list<dict<any>> = []
  var srv1 = MakeSaveServer({textDocumentSync: WILL_SAVE_SYNC_CAPS},
    {'textDocument/willSaveWaitUntil': {result: [InsertAtStartEdit("// one\n")]}},
    messages1)
  var srv2 = MakeSaveServer({textDocumentSync: WILL_SAVE_SYNC_CAPS},
    {'textDocument/willSaveWaitUntil': {result: [InsertAtStartEdit("// two\n")]}},
    messages2)
  var bnr = SaveTestEdit(fname, ['int x;'], [srv1, srv2],
			 [messages1, messages2])
  try
    for event in ['BufWritePre', 'BufWritePost', 'InsertLeave']
      assert_equal(1, autocmd_get({group: 'LSPBufferAutocmds', bufnr: bnr,
				   event: event})->len(), event)
    endfor

    :write
    assert_equal(['// two', '// one', 'int x;'], readfile(fname))
    for msgs in [messages1, messages2]
      assert_equal(['textDocument/willSave', 'textDocument/willSaveWaitUntil',
		    'textDocument/didSave'],
		   Methods(msgs)->filter((_, m) => m != 'textDocument/didChange'))
    endfor
  finally
    lsp.RemoveFile(bnr)
    :%bw!
    delete(fname)
  endtry
enddef

# Test that writing a buffer to another file doesn't save its document: the
# language server is not told about the write and the buffer is not changed.
def g:Test_WillSave_WriteToOtherFile()
  var fname = 'XWillSaveOrig.txt'
  var copy = 'XWillSaveCopy.txt'
  var messages: list<dict<any>> = []
  var caps = {textDocumentSync: WILL_SAVE_SYNC_CAPS,
	      documentFormattingProvider: true}
  var lspserver = MakeSaveServer(caps,
    {'textDocument/formatting': {result: [InsertAtStartEdit("// fmt\n")]},
     'textDocument/willSaveWaitUntil': {result: [InsertAtStartEdit("// fixed\n")]}},
    messages)
  var bnr = SaveTestEdit(fname, ['int x;'], [lspserver], [messages])
  g:LspOptionsSet({formatOnSave: true})
  try
    exe $'write {copy}'
    assert_equal(['int x;'], readfile(copy))
    assert_equal(['int x;'], getline(1, '$'))
    assert_equal([], messages)
  finally
    g:LspOptionsSet({formatOnSave: false})
    lsp.RemoveFile(bnr)
    :%bw!
    delete(fname)
    delete(copy)
  endtry
enddef

# Test that a buffer that is not modifiable is written unchanged, after the
# language server is told about the write.
def g:Test_WillSave_NotModifiable()
  var fname = 'XWillSaveNoModifiable.txt'
  var messages: list<dict<any>> = []
  var caps = {textDocumentSync: WILL_SAVE_SYNC_CAPS,
	      documentFormattingProvider: true}
  var lspserver = MakeSaveServer(caps,
    {'textDocument/formatting': {result: [InsertAtStartEdit("// fmt\n")]},
     'textDocument/willSaveWaitUntil': {result: [InsertAtStartEdit("// fixed\n")]}},
    messages)
  var bnr = SaveTestEdit(fname, ['int x;'], [lspserver], [messages])
  g:LspOptionsSet({formatOnSave: true})
  try
    setlocal nomodifiable
    :write!
    assert_equal(['int x;'], readfile(fname))
    assert_equal(['textDocument/willSave', 'textDocument/didSave'],
		 Methods(messages))
  finally
    g:LspOptionsSet({formatOnSave: false})
    lsp.RemoveFile(bnr)
    :%bw!
    delete(fname)
  endtry
enddef

# Test that a buffer is written without the edits of a language server that
# has the "willSaveWaitUntil" feature disabled, which is not asked for them.
def g:Test_WillSave_FeatureDisabled()
  var fname = 'XWillSaveDisabled.txt'
  var messages: list<dict<any>> = []
  var lspserver = MakeSaveServer({textDocumentSync: WILL_SAVE_SYNC_CAPS},
    {'textDocument/willSaveWaitUntil': {result: [InsertAtStartEdit("// fixed\n")]}},
    messages)
  lspserver.features = {willSaveWaitUntil: false}
  var bnr = SaveTestEdit(fname, ['int x;'], [lspserver], [messages])
  try
    :write
    assert_equal(['int x;'], readfile(fname))
    assert_equal(['textDocument/willSave', 'textDocument/didSave'],
		 Methods(messages))
  finally
    lsp.RemoveFile(bnr)
    :%bw!
    delete(fname)
  endtry
enddef

# Test that a buffer is written unchanged when the language server doesn't
# reply in time to the request for the edits to make before the write.
def g:Test_WillSave_NoReply()
  var fname = 'XWillSaveNoReply.txt'
  var messages: list<dict<any>> = []
  var lspserver = MakeSaveServer({textDocumentSync: WILL_SAVE_SYNC_CAPS}, {},
				 messages)
  var bnr = SaveTestEdit(fname, ['int x;'], [lspserver], [messages])
  try
    :write
    assert_equal(['int x;'], readfile(fname))
    assert_equal(['textDocument/willSave', 'textDocument/willSaveWaitUntil',
		  'textDocument/didSave'], Methods(messages))
  finally
    lsp.RemoveFile(bnr)
    :%bw!
    delete(fname)
  endtry
enddef

# Test that only a language server that asks for them gets the messages about
# a write, and that a buffer is written without an error when the
# "formatOnSave" option is set and the server doesn't support formatting.
def g:Test_WillSave_NotSupported()
  var fname = 'XWillSaveUnsupported.txt'
  var messages: list<dict<any>> = []
  var lspserver = MakeSaveServer(
    {textDocumentSync: {openClose: true, change: 1, save: true}},
    {'textDocument/formatting': {result: [InsertAtStartEdit("// fmt\n")]},
     'textDocument/willSaveWaitUntil': {result: [InsertAtStartEdit("// fixed\n")]}},
    messages)
  var bnr = SaveTestEdit(fname, ['int x;'], [lspserver], [messages])
  g:LspOptionsSet({formatOnSave: true})
  try
    :write
    assert_equal(['int x;'], readfile(fname))
    assert_equal(['textDocument/didSave'], Methods(messages))
  finally
    g:LspOptionsSet({formatOnSave: false})
    lsp.RemoveFile(bnr)
    :%bw!
    delete(fname)
  endtry
enddef

# Returns a TextEdit that replaces the two spaces in "int  x;" with one.
def SpacesFormatEdit(): dict<any>
  return {range: {start: {line: 0, character: 3}, end: {line: 0, character: 5}},
	  newText: ' '}
enddef

# Test that with the "formatOnSave" option set, a buffer is formatted before
# it is written, and that it is not formatted by default.
def g:Test_FormatOnSave()
  var fname = 'XFormatOnSave.txt'
  var messages: list<dict<any>> = []
  var caps = {textDocumentSync: {openClose: true, change: 1, save: true},
	      documentFormattingProvider: true}
  var lspserver = MakeSaveServer(caps,
    {'textDocument/formatting': {result: [SpacesFormatEdit()]}}, messages)
  var bnr = SaveTestEdit(fname, ['int  x;'], [lspserver], [messages])
  try
    :write
    assert_equal(['int  x;'], readfile(fname))
    assert_equal(['textDocument/didSave'], Methods(messages))

    messages->filter('0')
    g:LspOptionsSet({formatOnSave: true})
    :write
    assert_equal(['int x;'], readfile(fname))
    assert_equal('textDocument/formatting', messages[0].method)
    assert_equal(util.LspFileToUri(fname),
		 messages[0].params.textDocument.uri)
    assert_equal('textDocument/didChange', messages[-2].method)
    assert_equal([{text: "int x;\n"}], messages[-2].params.contentChanges)
    assert_equal('textDocument/didSave', messages[-1].method)
  finally
    g:LspOptionsSet({formatOnSave: false})
    lsp.RemoveFile(bnr)
    :%bw!
    delete(fname)
  endtry
enddef

# Test that with the "formatOnSave" option set, a buffer is formatted before
# the language server is told that it will be written and makes its edits.
def g:Test_FormatOnSave_BeforeWillSave()
  var fname = 'XFormatOnSaveOrder.txt'
  var messages: list<dict<any>> = []
  var caps = {textDocumentSync: WILL_SAVE_SYNC_CAPS,
	      documentFormattingProvider: true}
  var lspserver = MakeSaveServer(caps,
    {'textDocument/formatting': {result: [SpacesFormatEdit()]},
     'textDocument/willSaveWaitUntil': {result: [InsertAtStartEdit("// fixed\n")]}},
    messages)
  var bnr = SaveTestEdit(fname, ['int  x;'], [lspserver], [messages])
  g:LspOptionsSet({formatOnSave: true})
  try
    :write
    assert_equal(['// fixed', 'int x;'], readfile(fname))
    assert_equal(['textDocument/formatting', 'textDocument/willSave',
		  'textDocument/willSaveWaitUntil', 'textDocument/didSave'],
		 Methods(messages)->filter((_, m) => m != 'textDocument/didChange'))
  finally
    g:LspOptionsSet({formatOnSave: false})
    lsp.RemoveFile(bnr)
    :%bw!
    delete(fname)
  endtry
enddef

# A signature label with multibyte, composing and astral plane characters
# before its parameters, and a parameter whose name starts with the name of the
# next one.
const SIG_LABEL = "fn(é x, 😊 y, á z, int aa, int a) -> 😊"
# The labels of the parameters in SIG_LABEL, their byte columns in it and their
# [start, end] offsets in it in the UTF-8, UTF-16 and UTF-32 encodings.
const SIG_PARAMS = ['é x', '😊 y', "á z", 'int aa', 'int a']
const SIG_PARAM_COLS = [4, 10, 18, 25, 33]
const SIG_PARAM_OFFSETS = {
  8: [[3, 7], [9, 15], [17, 22], [24, 30], [32, 37]],
  16: [[3, 6], [8, 12], [14, 18], [20, 26], [28, 33]],
  32: [[3, 6], [8, 11], [13, 17], [19, 25], [27, 32]]
}

# Return a stub language server with the position encoding "posEncoding" for
# the signature-help tests.
def MakeSigServer(posEncoding: number): dict<any>
  var lspserver = MakeTestLspServer([])
  lspserver.posEncoding = posEncoding
  return lspserver
enddef

# Return a signature-help reply with "total" signatures labelled "label",
# whose parameters have the labels "paramLabels" and the parameter
# "activeParam" is active.
def MakeSigHelp(label: string, paramLabels: list<any>, activeParam: number,
		total: number = 1): dict<any>
  var sig = {label: label,
	     parameters: paramLabels->mapnew((_, l) => ({label: l}))}
  return {signatures: repeat([sig], total), activeSignature: 0,
	  activeParameter: activeParam}
enddef

# Return the [byte column, text] of each active-parameter highlight in the
# signature popup.
def SigPopupHighlights(): list<list<any>>
  var bnr = popup_list()[0]->winbufnr()
  var text = getbufline(bnr, 1)[0]
  return prop_list(1, {bufnr: bnr})
    ->mapnew((_, p) => [p.col, text->strpart(p.col - 1, p.length)])
enddef

# Return the screen attribute of text echoed in the command line with the
# highlight group "group".
def CmdlineAttr(group: string): number
  exe $'echohl {group}'
  echo 'x'
  echohl None
  return screenattr(&lines, 1)
enddef

# Return the text in the command line that is drawn with the screen attribute
# "attr".
def CmdlineTextWithAttr(attr: number): string
  return range(1, &columns)
    ->filter((_, c) => screenattr(&lines, c) == attr)
    ->mapnew((_, c) => screenstring(&lines, c))
    ->join('')
enddef

# Test for highlighting the active parameter in the signature popup when the
# labels of the parameters are offsets in the signature label.  The offsets are
# in the position encoding negotiated with the language server, and
# multibyte, composing and astral plane characters come before the parameters.
def g:Test_SignatureHelp_OffsetLabels()
  signature.InitOnce()
  g:LspOptionsSet({echoSignature: false, showSignatureDocs: false})
  for posEncoding in [8, 16, 32]
    var lspserver = MakeSigServer(posEncoding)
    var offsets: list<list<number>> = SIG_PARAM_OFFSETS[posEncoding]->deepcopy()
    var msg = $'UTF-{posEncoding}'
    for i in range(SIG_PARAMS->len())
      signature.SignatureHelp(lspserver, MakeSigHelp(SIG_LABEL, offsets, i), {})
      assert_equal([[SIG_PARAM_COLS[i], SIG_PARAMS[i]]], SigPopupHighlights(),
		   $'{msg}, parameter {i}')
    endfor

    # An end offset past the end of the label is at the end of the label, also
    # when the overload indicator follows the label.
    offsets[4][1] = 100
    for total in [1, 2]
      signature.SignatureHelp(lspserver,
			      MakeSigHelp(SIG_LABEL, offsets, 4, total), {})
      assert_equal([[33, 'int a) -> 😊']], SigPopupHighlights(),
		   $'{msg}, {total} signatures')
    endfor

    # Nothing is highlighted for a parameter that starts past the end of the
    # label.
    offsets[4] = [100, 101]
    signature.SignatureHelp(lspserver, MakeSigHelp(SIG_LABEL, offsets, 4), {})
    assert_equal([], SigPopupHighlights(), msg)

    signature.SignatureHelp(lspserver, {}, {})
  endfor
  :%bw!
enddef

# Test for highlighting the active parameter in the signature popup when the
# labels of the parameters are strings.  Each parameter is searched for in the
# signature label after the previous one, as a whole word if it can be found
# as one.
def g:Test_SignatureHelp_StringLabels()
  signature.InitOnce()
  g:LspOptionsSet({echoSignature: false, showSignatureDocs: false})
  # [signature label, parameter labels, active parameter, expected highlight]
  var cases: list<list<any>> = [
    ['f(int a, int aa)', ['int a', 'int aa'], 0, [[3, 'int a']]],
    ['f(int a, int aa)', ['int a', 'int aa'], 1, [[10, 'int aa']]],
    ['add(a, d)', ['a', 'd'], 0, [[5, 'a']]],
    ['add(a, d)', ['a', 'd'], 1, [[8, 'd']]],
    ['éa(a, é)', ['a', 'é'], 0, [[5, 'a']]],
    ['éa(a, é)', ['a', 'é'], 1, [[8, 'é']]],
    ['f(xy, y)', ['x', 'y'], 1, [[7, 'y']]],
    ['f(b, a)', ['a', 'b'], 1, [[3, 'b']]],
    ['f(int x)', ['int y'], 0, []]
  ]
  for i in range(SIG_PARAMS->len())
    cases->add([SIG_LABEL, SIG_PARAMS, i, [[SIG_PARAM_COLS[i], SIG_PARAMS[i]]]])
  endfor

  for posEncoding in [8, 16, 32]
    var lspserver = MakeSigServer(posEncoding)
    for [label, params, active, expected] in cases
      signature.SignatureHelp(lspserver, MakeSigHelp(label, params, active), {})
      assert_equal(expected, SigPopupHighlights(),
		   $'UTF-{posEncoding}, {label}, parameter {active}')
    endfor
    signature.SignatureHelp(lspserver, {}, {})
  endfor
  :%bw!
enddef

# Test for highlighting the active parameter in the signature echoed in the
# command line when the labels of the parameters are offsets in the signature
# label, in the position encoding negotiated with the language server.  The
# active parameter is highlighted in reverse, so that it is drawn differently
# from the rest of the signature whatever the highlight it is linked to.
def g:Test_SignatureHelp_EchoOffsetLabels()
  signature.InitOnce()
  var savedHl = hlget('LspSigActiveParameter')
  hlset([{name: 'LspSigActiveParameter', linksto: 'NONE'},
	 {name: 'LspSigActiveParameter', term: {reverse: true},
	  cterm: {reverse: true}, gui: {reverse: true}}])
  g:LspOptionsSet({echoSignature: true, showSignatureDocs: false})
  try
    var hlAttr = CmdlineAttr('LspSigActiveParameter')
    assert_notequal(CmdlineAttr('None'), hlAttr)
    for posEncoding in [8, 16, 32]
      var lspserver = MakeSigServer(posEncoding)
      for i in range(SIG_PARAMS->len())
	signature.SignatureHelp(lspserver,
	  MakeSigHelp(SIG_LABEL, SIG_PARAM_OFFSETS[posEncoding], i), {})
	assert_equal(SIG_PARAMS[i], CmdlineTextWithAttr(hlAttr),
		     $'UTF-{posEncoding}, parameter {i}')
      endfor
      signature.SignatureHelp(lspserver, {}, {})
    endfor
  finally
    g:LspOptionsSet({echoSignature: false})
    hlset(savedHl)
    :%bw!
  endtry
enddef

# Test that the signature popup moves below the cursor line while the
# completion menu is open above it, and back above it when the menu closes or
# opens below it, so that the two don't overlap.
def g:Test_SignatureHelp_PopupAvoidsCompletionMenu()
  signature.InitOnce()
  g:LspOptionsSet({echoSignature: false, showSignatureDocs: false})
  silent! edit XSignaturePopupPum.txt
  var bnr = bufnr()
  var srv = MakeTestLspServer([])
  srv.caps = {signatureHelpProvider: {triggerCharacters: ['(']}}
  srv.isSignatureHelpProvider = true
  srv.running = true
  srv.ready = true
  srv.showSignature = (kind: number, char: string) => {
  }
  buf.BufLspServerSet(bnr, srv)
  signature.BufferInit(srv, bnr)
  var positions: list<list<any>> = []
  var refPos: dict<any> = {}
  g:SigPumTestShow = () => {
    signature.SignatureHelp(srv, MakeSigHelp('f(int a)', ['int a'], 0), {})
    # Where the popup was before it moved with the menu
    var ref = popup_create('f(int a)', {line: 'cursor-1', col: 'cursor',
      pos: 'botleft', posinvert: true, padding: [0, 1, 0, 1]})
    refPos = popup_getpos(ref)
    popup_close(ref)
  }
  g:SigPumTestRecord = () => {
    var pos = popup_getpos(srv.signaturePopup)
    positions->add([pumvisible(), pum_getpos()->get('row', -1),
		    pos->get('line', -1), pos->get('col', -1)])
  }
  inoremap <buffer> <F3> <Cmd>call g:SigPumTestShow()<CR>
  inoremap <buffer> <F4> <Cmd>call g:SigPumTestRecord()<CR>
  inoremap <buffer> <F5> <Cmd>call complete(col('.'), range(20)->map((_, v) => $'w{v}'))<CR>
  try
    setlocal number
    setline(1, range(1, 100)->map((_, v) => $"\tf({v}"))
    # [command that moves the cursor, whether the menu opens above the cursor
    #  line, the line of the popup without and with the menu, from the cursor
    #  line]
    var cases: list<list<any>> = [
      ['normal! G4k', true, -1, 1],
      ['normal! gg5G', false, -1, -1],
      # No line above the cursor line for the popup
      ['normal! gg', false, 1, 1]
    ]
    for [cmd, pumAbove, offset, pumOffset] in cases
      exe cmd
      var row = win_screenpos(0)[0] + winline() - 1
      positions = []
      feedkeys("A\<F3>\<F4>\<F5>\<F4>\<C-E>\<F4>\<Esc>", 'xt')
      assert_equal(3, positions->len(), cmd)
      # Where a popup at the cursor would be, after the Tab and the number
      assert_equal(row + offset, refPos.line, cmd)
      assert_true(refPos.col > 9, cmd)
      assert_equal([0, -1, row + offset, refPos.col], positions[0], cmd)
      assert_equal(1, positions[1][0], cmd)
      assert_equal(pumAbove, positions[1][1] < row - 1, cmd)
      assert_equal([row + pumOffset, refPos.col], positions[1][2 : ], cmd)
      # Back where it was when the menu closes
      assert_equal([0, -1, row + offset, refPos.col], positions[2], cmd)
    endfor
  finally
    signature.SignatureHelp(srv, {}, {})
    signature.BufferDeInit(bnr)
    buf.BufLspServerRemove(bnr, srv)
    unlet g:SigPumTestShow g:SigPumTestRecord
    :%bw!
  endtry
enddef

# Type "keys", which enter Insert mode, and return the [trigger kind, trigger
# character] of the signature help requests of the language server
# "lspserver" for it, waiting for the first one when "waitForRequest" is true
# and 200 ms otherwise.  feedkeys() stays in Insert mode with the "!" flag,
# so a timer leaves it.
def SigRequestsOnTyping(lspserver: dict<any>, keys: string,
			waitForRequest: bool = true): list<list<any>>
  var requests: list<list<any>> = []
  lspserver.showSignature = (kind: number, char: string) => {
    requests->add([kind, char])
  }
  var tries = 0
  timer_start(10, (timer) => {
    tries += 1
    if !requests->empty() || tries >= (waitForRequest ? 500 : 20)
      timer_stop(timer)
      feedkeys("\<Esc>", 't')
    endif
  }, {repeat: -1})
  feedkeys(keys, 'xt!')
  return requests
enddef

# Test for the trigger kind and character of the signature help requested
# while typing: a typed trigger character, or a retrigger character while a
# signature is shown, is sent as such, also when typing it changes the text,
# and entering Insert mode right after a trigger character, skipping white
# space and blank lines, requests the signature help as invoked.
def g:Test_SignatureHelp_TriggerKinds()
  signature.InitOnce()
  g:LspOptionsSet({echoSignature: false, showSignatureDocs: false})
  silent! edit XSignatureTriggerKinds.txt
  set filetype=text
  var bnr = bufnr()
  var srv = MakeTestLspServer([])
  srv.caps = {signatureHelpProvider: {triggerCharacters: ['(', ','],
				      retriggerCharacters: [')']}}
  srv.isSignatureHelpProvider = true
  srv.running = true
  srv.ready = true
  buf.BufLspServerSet(bnr, srv)
  signature.BufferInit(srv, bnr)
  try
    # [whether a signature is shown, text of the line(s), keys typed at the
    #  third column of the first line, expected requests]
    var cases = [
      [false, 'f(a', 'a(', [[2, '(']]],
      [false, 'f(a', 'a)', []],
      [true, 'f(a', 'a,', [[2, ',']]],
      [true, 'f(a', 'a)', [[2, ')']]],
      # A trigger character in an expression doesn't insert itself
      [false, 'f(a', "a\<C-R>=toupper('x')\<CR>", []],
      # Entering Insert mode after a trigger character, also on a line below
      # it, or not
      [false, 'f(', 'A', [[1, '']]],
      [false, 'f(a, ', 'A', [[1, '']]],
      [false, 'f(a,', 'o', [[1, '']]],
      [false, ['f(', '', '  '], 'jjI', [[1, '']]],
      [false, 'f(a', 'A', []],
      [false, 'f(a)', 'A', []],
      [false, 'f(a', 'I', []],
      [false, 'f(a', 'o', []]
    ]
    for [shown, line, keys, expected] in cases
      deletebufline(bnr, 1, '$')
      setline(1, line)
      cursor(1, 3)
      if shown
	signature.SignatureHelp(srv, MakeSigHelp('f(int a, int b)',
						 ['int a', 'int b'], 0), {})
      endif
      assert_equal(expected, SigRequestsOnTyping(srv, keys, !expected->empty()),
		   $'shown: {shown}, line: {line}, keys: {keys}')
    endfor
  finally
    signature.BufferDeInit(bnr)
    buf.BufLspServerRemove(bnr, srv)
    :%bw!
  endtry
enddef

# Test that the signature help of a buffer is initialized for a language
# server that has retrigger characters but no trigger characters.
def g:Test_SignatureHelp_OnlyRetriggerCharacters()
  signature.InitOnce()
  silent! edit XSignatureOnlyRetrigger.txt
  var bnr = bufnr()
  var srv = MakeTestLspServer([])
  srv.caps = {signatureHelpProvider: {retriggerCharacters: [')']}}
  srv.isSignatureHelpProvider = true
  signature.BufferInit(srv, bnr)
  assert_equal(['InsertEnter', 'KeyInputPre'],
	       autocmd_get({group: 'LspSignatureHelp', pattern: $'<buffer={bnr}>'})
		 ->mapnew((_, a) => a.event)->sort())
  signature.BufferDeInit(bnr)
  :%bw!
enddef

# Returns the commands of the autocmds for the features of buffer "bnr" that
# use one of its language servers, by event.
def BufFeatureAutocmds(bnr: number): dict<list<string>>
  var acmds: dict<list<string>> = {}
  for event in ['CursorMoved', 'CursorHold', 'BufLeave']
    acmds[event] = autocmd_get({group: 'LSPBufferAutocmds', bufnr: bnr,
				event: event})->mapnew((_, acmd) => acmd.cmd)
  endfor
  return acmds
enddef

# Returns what BufFeatureAutocmds() returns for buffer "bnr" when it has the
# autocmds for both the automatic highlight and the hover on CursorHold.
def HighlightAndHoverAutocmds(bnr: number): dict<list<string>>
  var hoverStop = $'LspHoverAutoStop({bnr})'
  return {
    CursorMoved: [
      $'call LspDocHighlightClear({bnr}) | call LspDocHighlight({bnr}, "silent")',
      hoverStop
    ],
    CursorHold: [$'LspHoverAutoSchedule({bnr})'],
    BufLeave: [hoverStop]
  }
enddef

# Test that the autocmds for the features that use one of the language
# servers of a buffer are added once, when all the servers are ready and have
# the document open, however many servers provide the features.  The second
# server is ready either when it is attached to the buffer or only later.
def g:Test_BufFeatureAutocmds_AddedOnce()
  g:LspOptionsSet({autoHighlight: true, hoverOnCursorHold: true})
  var caps = {textDocumentSync: {openClose: true, change: 1},
	      documentHighlightProvider: true, hoverProvider: true}
  try
    for readyWhenAttached in [true, false]
      var srv1 = MakeCapsServer(caps, [])
      var srv2 = MakeCapsServer(caps, [])
      srv2.ready = readyWhenAttached
      :silent edit XBufFeatureAutocmds.txt
      var bnr = bufnr()
      buf.BufLspServerSet(bnr, srv1)
      buf.BufLspServerSet(bnr, srv2)
      lsp.BufferInit(srv1.id, bnr)
      assert_equal({CursorMoved: [], CursorHold: [], BufLeave: []},
		   BufFeatureAutocmds(bnr), readyWhenAttached)
      srv2.ready = true
      lsp.BufferInit(srv2.id, bnr)
      assert_equal(HighlightAndHoverAutocmds(bnr), BufFeatureAutocmds(bnr),
		   readyWhenAttached)
      lsp.RemoveFile(bnr)
      :%bw!
    endfor
  finally
    g:LspOptionsSet({autoHighlight: false, hoverOnCursorHold: false})
  endtry
enddef

# Test that the semantic highlighting of a buffer is initialized for the
# language server that provides it, when another server is the last to get
# ready.
def g:Test_SemanticHighlight_InitForItsServer()
  g:LspOptionsSet({semanticHighlight: true})
  try
    var sync = {textDocumentSync: {openClose: true, change: 1}}
    var srv1 = MakeCapsServer(sync->extendnew({semanticTokensProvider: {
      legend: {tokenTypes: [], tokenModifiers: []}, full: true}}), [])
    var srv2 = MakeCapsServer(sync, [])
    srv2.ready = false
    :silent edit XSemanticInit.txt
    var bnr = bufnr()
    buf.BufLspServerSet(bnr, srv1)
    buf.BufLspServerSet(bnr, srv2)
    lsp.BufferInit(srv1.id, bnr)
    srv2.ready = true
    lsp.BufferInit(srv2.id, bnr)
    assert_equal([$'LspUpdateSemanticHighlight({bnr})'],
		 autocmd_get({group: 'LSPBufferAutocmds', bufnr: bnr,
			      event: 'TextChanged'})->mapnew((_, a) => a.cmd))
    lsp.RemoveFile(bnr)
  finally
    g:LspOptionsSet({semanticHighlight: false})
    :%bw!
  endtry
enddef

# Test that initializing the inlay hints of a buffer again, as when it is
# attached to the language servers again, doesn't add the autocmds again.
def g:Test_InlayHints_BufferInitTwice()
  g:LspOptionsSet({showInlayHints: true})
  try
    var srv = MakeCapsServer({inlayHintProvider: true}, [])
    srv.syncInit = true
    :silent edit XInlayHintsInitTwice.txt
    var bnr = bufnr()
    inlayhints.BufferInit(srv, bnr)
    inlayhints.BufferInit(srv, bnr)
    # autocmd_get() names the BufReadPost event BufRead
    assert_equal(['BufLeave', 'BufRead', 'BufWinEnter', 'CursorHold',
		  'TextChanged'],
		 autocmd_get({group: 'LspInlayHints', bufnr: bnr})
		   ->mapnew((_, a) => a.event)->sort())
    assert_equal(1, autocmd_get({group: 'LspAttached', bufnr: bnr})->len())
    autocmd_delete([{group: 'LspInlayHints', bufnr: bnr},
		    {group: 'LspAttached', bufnr: bnr}])
  finally
    g:LspOptionsSet({showInlayHints: false})
    :%bw!
  endtry
enddef

# Test that the autocmds for a feature are not added when the language server
# that provides it has the feature disabled.
def g:Test_BufFeatureAutocmds_FeatureDisabled()
  g:LspOptionsSet({autoHighlight: true, hoverOnCursorHold: true})
  try
    var srv = MakeCapsServer({textDocumentSync: {openClose: true, change: 1},
			      documentHighlightProvider: true,
			      hoverProvider: true}, [])
    srv.features = {documentHighlight: false}
    var bnr = SaveTestEdit('XBufFeatureDisabled.txt', [], [srv], [])
    assert_equal({CursorMoved: [$'LspHoverAutoStop({bnr})'],
		  CursorHold: [$'LspHoverAutoSchedule({bnr})'],
		  BufLeave: [$'LspHoverAutoStop({bnr})']},
		 BufFeatureAutocmds(bnr))
    lsp.RemoveFile(bnr)
  finally
    g:LspOptionsSet({autoHighlight: false, hoverOnCursorHold: false})
    :%bw!
    delete('XBufFeatureDisabled.txt')
  endtry
enddef

# Returns an LSP ColorInformation for the color with the red, green and blue
# components "rgb" (from 0 to 1) from character "schar" to character "echar"
# of line "line".
def ColorInfo(line: number, schar: number, echar: number,
	      rgb: list<any>): dict<any>
  return {range: {start: {line: line, character: schar},
		  end: {line: line, character: echar}},
	  color: {red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1}}
enddef

# Returns the color swatches in buffer "bnr": the line, the column and the
# text property type of each, and its text.
def ColorSwatches(bnr: number): list<list<any>>
  return prop_list(1, {bufnr: bnr, end_lnum: -1})
    ->filter((_, p) => p.type =~# '^LspDocumentColor')
    ->mapnew((_, p) => [p.lnum, p.col, p.type, p.text])
enddef

# Returns the GUI and the terminal colors of highlight group "name".
def HighlightColors(name: string): list<string>
  var hl: dict<any> = hlget(name)[0]
  return [hl->get('guifg', '')->tolower(), hl->get('ctermfg', '')]
enddef

# Returns a running and ready language server that finds the colors in the
# current buffer, using UTF-16 positions, and sends the "replies" to the
# requests, like MakeAsyncReplyingLspServer().
def MakeColorServer(replies: list<any>): dict<any>
  var lspserver = MakeAsyncReplyingLspServer(replies)
  lspserver.isColorProvider = true
  lspserver.posEncoding = 16
  lspserver.needOffsetEncoding = true
  return lspserver
enddef

# Test that a swatch of each color that the language server finds in a buffer
# is shown before the color, in that color, at the position decoded from the
# negotiated position encoding.  The swatches shown before are replaced, but
# kept when the server replies without a result.
def g:Test_DocumentColors_ShowSwatches()
  g:LspOptionsSet({showDocumentColors: true})
  silent! edit XDocumentColors.css
  setline(1, ['a { color: #ff0000; }', '/* 😊 */ b { color: rgb(128 128 128); }'])
  var bnr = bufnr()
  # "rgb(" starts at UTF-16 code unit 20 of the second line
  var grayCol = getline(2)->stridx('rgb(') + 1
  try
    var lspserver = MakeColorServer([[
      ColorInfo(0, 11, 18, [1, 0, 0]),
      ColorInfo(1, 20, 37, [0.5, 0.5, 0.5])
    ]])
    documentcolor.BufferInit(lspserver, bnr)
    g:WaitForAssert(() => assert_equal([
      [1, 12, 'LspDocumentColorFF0000', '■ '],
      [2, grayCol, 'LspDocumentColor808080', '■ ']
    ], ColorSwatches(bnr)))
    assert_equal(['#ff0000', '196'], HighlightColors('LspDocumentColorFF0000'))
    assert_equal(['#808080', '244'], HighlightColors('LspDocumentColor808080'))
    StopAsyncReplyingLspServer(lspserver, bnr)

    lspserver = MakeColorServer([[ColorInfo(1, 20, 37, [0, 0, 1.0])]])
    lspserver.documentColorsUpdate(bnr)
    var blue = [[2, grayCol, 'LspDocumentColor0000FF', '■ ']]
    g:WaitForAssert(() => assert_equal(blue, ColorSwatches(bnr)))
    assert_equal(['#0000ff', '21'], HighlightColors('LspDocumentColor0000FF'))
    StopAsyncReplyingLspServer(lspserver, bnr)

    lspserver = MakeColorServer([v:null])
    lspserver.documentColorsUpdate(bnr)
    g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
    assert_equal(blue, ColorSwatches(bnr))
    StopAsyncReplyingLspServer(lspserver, bnr)
  finally
    documentcolor.BufferDeInit(bnr)
    g:LspOptionsSet({showDocumentColors: false})
    :%bw!
  endtry
enddef

# Test that the colors are not shown when the buffer was changed before the
# reply arrived.
def g:Test_DocumentColors_DropsReplyAfterChange()
  silent! edit XDocumentColorsChange.css
  setline(1, ['a { color: #ff0000; }'])
  var bnr = bufnr()
  try
    var lspserver = MakeColorServer([[ColorInfo(0, 11, 18, [1, 0, 0])]])
    lspserver.documentColorsUpdate(bnr)
    setline(1, ['ab { color: #ff0000; }'])
    g:WaitForAssert(() => assert_equal({}, lspserver.supersedableRequests))
    assert_equal([], ColorSwatches(bnr))
    StopAsyncReplyingLspServer(lspserver, bnr)
  finally
    :%bw!
  endtry
enddef

# Test that the colors are shown and updated only while the
# 'showDocumentColors' option is set, that initializing a buffer again doesn't
# add the autocmds again, that the colors are updated once after changes stop
# for a moment, and that detaching the buffer from the language server removes
# the swatches.
def g:Test_DocumentColors_UpdatesAndOption()
  documentcolor.InitOnce()
  silent! edit XDocumentColorsOption.css
  setline(1, ['a { color: #ff0000; }'])
  var bnr = bufnr()
  var srv = MakeCapsServer({colorProvider: true}, [])
  var updates: list<number> = []
  srv.documentColorsUpdate = (b: number) => {
    updates->add(b)
    documentcolor.ColorsShow(b, [ColorInfo(0, 11, 18, [1, 0, 0])])
  }
  buf.BufLspServerSet(bnr, srv)
  var Events = () => autocmd_get({group: 'LspDocumentColors', bufnr: bnr})
			->mapnew((_, a) => a.event)
  var swatch = [[1, 12, 'LspDocumentColorFF0000', '■ ']]
  try
    documentcolor.BufferInit(srv, bnr)
    assert_equal([], updates)
    assert_equal([], ColorSwatches(bnr))

    g:LspOptionsSet({showDocumentColors: true})
    documentcolor.BufferInit(srv, bnr)
    assert_equal([bnr, bnr], updates)
    assert_equal(swatch, ColorSwatches(bnr))
    assert_equal(['TextChanged'], Events())

    doautocmd TextChanged
    doautocmd TextChanged
    assert_equal([bnr, bnr], updates)
    g:WaitForAssert(() => assert_equal([bnr, bnr, bnr], updates))
    :sleep 50m
    assert_equal([bnr, bnr, bnr], updates)

    doautocmd TextChanged
    g:LspOptionsSet({showDocumentColors: false})
    assert_equal([], ColorSwatches(bnr))
    assert_equal([], Events())
    :sleep 350m
    assert_equal([bnr, bnr, bnr], updates)

    g:LspOptionsSet({showDocumentColors: true})
    assert_equal([bnr, bnr, bnr, bnr], updates)
    assert_equal(swatch, ColorSwatches(bnr))
    assert_equal(['TextChanged'], Events())

    lsp.RemoveFile(bnr)
    assert_equal([], ColorSwatches(bnr))
    assert_equal([], Events())
  finally
    g:LspOptionsSet({showDocumentColors: false})
    :%bw!
  endtry
enddef

# Test that the colors in a buffer are shown for the language server that
# finds them, when another server is the last to get ready.
def g:Test_DocumentColors_InitForItsServer()
  g:LspOptionsSet({showDocumentColors: true})
  try
    var sync = {textDocumentSync: {openClose: true, change: 1}}
    var srv1 = MakeCapsServer(sync->extendnew({colorProvider: true}), [])
    var updates: list<number> = []
    srv1.documentColorsUpdate = (b: number) => {
      updates->add(b)
    }
    var srv2 = MakeCapsServer(sync, [])
    srv2.ready = false
    :silent edit XDocumentColorsInit.css
    var bnr = bufnr()
    buf.BufLspServerSet(bnr, srv1)
    buf.BufLspServerSet(bnr, srv2)
    lsp.BufferInit(srv1.id, bnr)
    assert_equal([], updates)
    srv2.ready = true
    lsp.BufferInit(srv2.id, bnr)
    assert_equal([bnr], updates)
    assert_equal([$'ColorsUpdateLater({bnr})'],
		 autocmd_get({group: 'LspDocumentColors', bufnr: bnr})
		   ->mapnew((_, a) => a.cmd))
    lsp.RemoveFile(bnr)
  finally
    g:LspOptionsSet({showDocumentColors: false})
    :%bw!
  endtry
enddef

# Test that the swatches get their colors back after a color scheme cleared
# their highlight groups.
def g:Test_DocumentColors_ColorScheme()
  documentcolor.InitOnce()
  silent! edit XDocumentColorsScheme.css
  setline(1, ['a { color: #00ff00; }'])
  documentcolor.ColorsShow(bufnr(), [ColorInfo(0, 11, 18, [0, 1, 0])])
  :highlight clear LspDocumentColor00FF00
  assert_equal(['', ''], HighlightColors('LspDocumentColor00FF00'))
  doautocmd ColorScheme
  assert_equal(['#00ff00', '46'], HighlightColors('LspDocumentColor00FF00'))
  :%bw!
enddef

# Returns a running language server that provides folding ranges, attached to
# the current buffer as when it gets ready.  The folding range requests it is
# sent are added to "requests", a Dict for each with its "params" and the
# function "Reply" that delivers the folding ranges passed to it as the reply.
def MakeFoldingServer(requests: list<dict<any>>): dict<any>
  var lspserver = MakeCapsServer({textDocumentSync: {openClose: true, change: 2},
				  foldingRangeProvider: true}, [])
  lspserver.rpc_a = (method, params, Cb, _: dict<any> = {}) => {
    if method == 'textDocument/foldingRange'
      requests->add({params: params->deepcopy(), Reply: (ranges: any) => {
	Cb(lspserver, ranges, {})
      }})
    endif
    return requests->len()
  }
  buf.BufLspServerSet(bufnr(), lspserver)
  lsp.BufferInit(lspserver.id, bufnr())
  return lspserver
enddef

# Edit file "fname" with the lines "lines" and the folds computed with
# lsp#lsp#FoldExpr(), from the folding ranges of the test language server made
# with MakeFoldingServer(), and wait for its request for them.
def FoldExprTestEdit(fname: string, lines: list<string>,
		     requests: list<dict<any>>)
  exe $'silent edit {fname}'
  setline(1, lines)
  MakeFoldingServer(requests)
  :setlocal foldmethod=expr foldexpr=lsp#lsp#FoldExpr() foldlevel=0
  assert_equal(0, foldlevel(1))
  g:WaitForAssert(() => assert_equal(1, requests->len()))
enddef

# Returns the result of the function "fname" for each line of the current
# buffer, as foldlevel() gets it.
def ForEachLine(fname: string): list<any>
  return range(1, line('$'))->mapnew((_, lnum) => call(fname, [lnum]))
enddef

# Test that lsp#lsp#FoldExpr() and lsp#lsp#FoldText() make the folds of a
# buffer from the folding ranges of the language server, which are requested
# when its folds are first computed.  A range that ends after the buffer ends
# with it, and a range on a single line and a duplicate one are left out.
def g:Test_FoldExpr_FoldsFromFoldingRanges()
  var requests: list<dict<any>> = []
  FoldExprTestEdit('XFoldExprRanges.txt',
		   range(1, 12)->mapnew((_, n) => $'line {n}'), requests)
  :setlocal foldtext=lsp#lsp#FoldText()
  assert_equal({textDocument: {uri: util.LspBufnrToUri(bufnr())}},
	       requests[0].params)

  var ranges = [
    {startLine: 1, endLine: 3, collapsedText: 'A'},
    {startLine: 4, endLine: 9, collapsedText: 'B'},
    {startLine: 4, endLine: 6, collapsedText: 'C'},
    {startLine: 7, endLine: 8},
    {startLine: 7, endLine: 8},
    {startLine: 10, endLine: 10},
    {startLine: 10, endLine: 20}
  ]
  requests[0].Reply(ranges)
  assert_equal([0, 1, 1, 1, 2, 2, 2, 2, 2, 1, 1, 1], ForEachLine('foldlevel'))
  assert_equal([-1, 2, 2, 2, 5, 5, 5, 5, 5, 5, 11, 11],
	       ForEachLine('foldclosed'))
  assert_equal([-1, 4, 4, 4, 10, 10, 10, 10, 10, 10, 12, 12],
	       ForEachLine('foldclosedend'))
  assert_equal('A', foldtextresult(2))
  assert_equal('B', foldtextresult(5))

  :5foldopen
  assert_equal([-1, 2, 2, 2, 5, 5, 5, 8, 8, -1, 11, 11],
	       ForEachLine('foldclosed'))
  assert_equal('C', foldtextresult(5))

  # Without a collapsed text, the closed fold shows what foldtext() returns
  :setlocal foldtext&
  var defaultTexts = [foldtextresult(8), foldtextresult(11)]
  :setlocal foldtext=lsp#lsp#FoldText()
  assert_equal(defaultTexts, [foldtextresult(8), foldtextresult(11)])

  lsp.RemoveFile(bufnr())
  :%bw!
enddef

# Test that the folds computed with lsp#lsp#FoldExpr() follow the lines when
# lines are added and deleted, until the folding ranges are requested again
# after the changes.  The folds that are still there stay open or closed, a
# new fold is closed unless it has the cursor line, and a reply about an older
# text of the buffer is dropped.
def g:Test_FoldExpr_FollowsChanges()
  var requests: list<dict<any>> = []
  FoldExprTestEdit('XFoldExprChanges.txt',
		   range(1, 10)->mapnew((_, n) => $'line {n}'), requests)
  requests[0].Reply([{startLine: 1, endLine: 3}, {startLine: 5, endLine: 7}])
  :2foldopen
  assert_equal([-1, 6], [foldclosed(2), foldclosed(6)])
  g:optionSetCount = 0
  augroup FoldExprTest
    autocmd!
    autocmd OptionSet foldmethod g:optionSetCount += 1
  augroup END

  append(0, ['added 1', 'added 2'])
  :5delete _
  assert_equal([0, 0, 0, 1, 1, 0, 1, 1, 1, 0, 0], ForEachLine('foldlevel'))
  assert_equal([-1, -1, -1, -1, -1, -1, 7, 7, 7, -1, -1],
	       ForEachLine('foldclosed'))
  g:WaitForAssert(() => assert_equal(2, requests->len()))

  setline(11, 'changed')
  requests[1].Reply([{startLine: 0, endLine: 10}])
  assert_equal([0, 0, 0, 1, 1, 0, 1, 1, 1, 0, 0], ForEachLine('foldlevel'))
  g:WaitForAssert(() => assert_equal(3, requests->len()))

  cursor(10, 1)
  var ranges = [
    {startLine: 0, endLine: 1},
    {startLine: 3, endLine: 4},
    {startLine: 6, endLine: 8},
    {startLine: 9, endLine: 10}
  ]
  requests[2].Reply(ranges)
  assert_equal([1, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1], ForEachLine('foldlevel'))
  assert_equal([1, 1, -1, -1, -1, -1, 7, 7, 7, -1, -1],
	       ForEachLine('foldclosed'))
  assert_equal('expr', &foldmethod)
  assert_equal(0, g:optionSetCount)

  augroup FoldExprTest
    autocmd!
  augroup END
  augroup! FoldExprTest
  unlet g:optionSetCount
  lsp.RemoveFile(bufnr())
  :%bw!
enddef

# Test that the folding ranges are requested again after the text typed in
# Insert mode only when Insert mode is left, so that the folds don't change
# around the text while it is typed.
def g:Test_FoldExpr_WaitsUntilInsertModeIsLeft()
  var requests: list<dict<any>> = []
  FoldExprTestEdit('XFoldExprInsert.txt', ['a', 'b', 'c'], requests)
  requests[0].Reply([{startLine: 0, endLine: 2}])

  var requestsInInsertMode = -1
  timer_start(1000, (_) => {
    requestsInInsertMode = requests->len()
    feedkeys("\<Esc>", 't')
  })
  feedkeys('Atyped', 'xt!')
  assert_equal(1, requestsInInsertMode)
  g:WaitForAssert(() => assert_equal(2, requests->len()))

  lsp.RemoveFile(bufnr())
  :%bw!
enddef

# Test that the folding ranges of a buffer whose folds are computed with
# lsp#lsp#FoldExpr() before its language server is ready are requested when
# it is, and again when the buffer is attached again after it was detached.
def g:Test_FoldExpr_RequestsWhenServerReady()
  silent! edit XFoldExprReady.txt
  setline(1, ['a', 'b', 'c'])
  :setlocal foldmethod=expr foldexpr=lsp#lsp#FoldExpr() foldlevel=0
  assert_equal(0, foldlevel(2))

  var requests: list<dict<any>> = []
  MakeFoldingServer(requests)
  g:WaitForAssert(() => assert_equal(1, requests->len()))
  requests[0].Reply([{startLine: 0, endLine: 2}])
  assert_equal([1, 1, 1], ForEachLine('foldlevel'))

  # Detached, the folding ranges are forgotten and no longer requested
  lsp.RemoveFile(bufnr())
  assert_equal({levels: [], texts: [], adjusted: true, listenerId: 0,
		timerId: 0, changed: false}, b:LspFoldState)
  setline(1, 'changed')
  assert_equal(0, b:LspFoldState.timerId)

  MakeFoldingServer(requests)
  g:WaitForAssert(() => assert_equal(2, requests->len()))
  requests[1].Reply([{startLine: 1, endLine: 2}])
  assert_equal([0, 1, 1], ForEachLine('foldlevel'))

  lsp.RemoveFile(bufnr())
  :%bw!
enddef

# Test that the folds of all the windows that show a buffer, also in another
# tab page, are computed again with its new folding ranges.  A new fold that
# has the cursor line of a window is open in it, and a closed fold that has it
# stays closed.
def g:Test_FoldExpr_UpdatesAllWindows()
  var requests: list<dict<any>> = []
  FoldExprTestEdit('XFoldExprWindows.txt', ['a', 'b', 'c', 'd', 'e'],
		   requests)
  cursor(5, 1)
  :split
  :tab split
  requests[0].Reply([{startLine: 0, endLine: 2}])
  assert_equal([1, 1, 1, -1, -1], ForEachLine('foldclosed'))
  :tabprevious
  assert_equal([1, 1, 1, -1, -1], ForEachLine('foldclosed'))
  :wincmd w
  assert_equal([1, 1, 1, -1, -1], ForEachLine('foldclosed'))

  cursor(1, 1)
  append(0, 'x')
  g:WaitForAssert(() => assert_equal(2, requests->len()))
  requests[1].Reply([{startLine: 1, endLine: 3}, {startLine: 4, endLine: 5}])
  assert_equal(2, line('.'))
  assert_equal([-1, 2, 2, 2, 5, 5], ForEachLine('foldclosed'))
  :wincmd w
  assert_equal(6, line('.'))
  assert_equal([-1, 2, 2, 2, -1, -1], ForEachLine('foldclosed'))
  :tabnext
  assert_equal([-1, 2, 2, 2, -1, -1], ForEachLine('foldclosed'))

  lsp.RemoveFile(bufnr())
  :%bw!
enddef

# Test that a "workspace/foldingRange/refresh" request gets a reply, and then
# requests the folding ranges again for the documents whose folds are computed
# with lsp#lsp#FoldExpr(), and whose folds change with them.  Not for a
# document whose folds are not.
def g:Test_FoldExpr_RefreshRequest()
  var requests: list<dict<any>> = []
  FoldExprTestEdit('XFoldExprRefresh1.txt', ['a', 'b', 'c'], requests)
  var bnr = bufnr()
  var lspserver = buf.BufLspServerGet(bnr)
  var responses: list<dict<any>> = []
  lspserver.sendResponse = function(CaptureResponse, [responses])
  requests[0].Reply([{startLine: 0, endLine: 2}])
  :silent! new XFoldExprRefresh2.txt
  buf.BufLspServerSet(bufnr(), lspserver)
  lsp.BufferInit(lspserver.id, bufnr())
  assert_equal(0, foldlevel(1))

  lspserver.processRequest({jsonrpc: '2.0', id: 1,
			    method: 'workspace/foldingRange/refresh'})
  assert_equal([{id: 1, result: null, error: {}}], responses)
  g:WaitForAssert(() => assert_equal(2, requests->len()))
  assert_equal(util.LspBufnrToUri(bnr), requests[1].params.textDocument.uri)
  requests[1].Reply([{startLine: 1, endLine: 2}])
  :wincmd w
  assert_equal([0, 1, 1], ForEachLine('foldlevel'))
  assert_equal(2, requests->len())

  lsp.RemoveFile(bnr)
  lsp.RemoveFile(bufnr('XFoldExprRefresh2.txt'))
  :%bw!
enddef

# Test that the folding ranges are requested again when the file of a buffer
# changed outside of Vim and the buffer is reloaded, which listeners don't
# get.
def g:Test_FoldExpr_FileChangedOutsideVim()
  var fname = 'XFoldExprReload.txt'
  writefile(['a', 'b'], fname)
  var requests: list<dict<any>> = []
  try
    exe $'silent edit {fname}'
    MakeFoldingServer(requests)
    :setlocal foldmethod=expr foldexpr=lsp#lsp#FoldExpr()
    assert_equal(0, foldlevel(1))
    g:WaitForAssert(() => assert_equal(1, requests->len()))
    requests[0].Reply([{startLine: 0, endLine: 1}])
    assert_equal([1, 1], ForEachLine('foldlevel'))

    :setlocal autoread
    writefile(['a', 'b', 'c', 'd'], fname)
    :checktime
    assert_equal(['a', 'b', 'c', 'd'], getline(1, '$'))
    g:WaitForAssert(() => assert_equal(2, requests->len()))
    requests[1].Reply([{startLine: 2, endLine: 3}])
    assert_equal([0, 0, 1, 1], ForEachLine('foldlevel'))
  finally
    lsp.RemoveFile(bufnr())
    :%bw!
    delete(fname)
  endtry
enddef

# Test that the LSP snippets are converted to the text they insert when
# nothing is typed in them.
def g:Test_SnippetToText()
  var cases = [
    ['plain text', 'plain text'],
    ['foo($1, $2)$0', 'foo(, )'],
    ['foo(${1}, ${2:b})', 'foo(, b)'],
    ['${1:outer ${2:inner} text}', 'outer inner text'],
    ['${1|one,two,three|}', 'one'],
    ['${1|a\,b,c|}', 'a,b'],
    ['$TM_FILENAME ${TM_LINE_NUMBER} ${UNKNOWN:default}', '  default'],
    ['${1/(.*)/${1:/upcase}/g}x', 'x'],
    ['\$1 \} \\ \x', '$1 } \ \x'],
    ['$1abc', 'abc'],
    ['cost $ 5 ${', 'cost $ 5 ${'],
    ['${1:unterminated', '${1:unterminated'],
    ['}', '}'],
    ["a\n\t${1:b}", "a\n\tb"],
  ]
  for [snip, expected] in cases
    assert_equal(expected, snippet.SnippetToText(snip), snip)
  endfor
enddef

# Test that the inline completion capability is advertised, and that a
# language server that provides inline completions is recognized.
def g:Test_InlineCompletion_Capabilities()
  assert_equal({dynamicRegistration: false},
	       capabilities.GetClientCaps().textDocument.inlineCompletion)
  for [caps, expected] in [[{}, false],
			   [{inlineCompletionProvider: false}, false],
			   [{inlineCompletionProvider: true}, true],
			   [{inlineCompletionProvider: {}}, true]]
    var srv = MakeCapsServer(caps, [])
    assert_equal(expected, srv.isInlineCompletionProvider, string(caps))
  endfor
enddef

# Test that the inline completion autocmds are added to a buffer when its
# language server provides inline completions and the feature isn't disabled
# for it, and removed when the buffer is detached.
def g:Test_InlineCompletion_BufferInit()
  InlineCompletionInitOnce()
  for disabled in [false, true]
    var srv = MakeCapsServer({textDocumentSync: {openClose: true, change: 1},
			      inlineCompletionProvider: true}, [])
    if disabled
      srv.features = {inlineCompletion: false}
    endif
    var bnr = SaveTestEdit('XInlineCompletionInit.txt', [], [srv], [])
    var events = autocmd_get({group: 'LspInlineCompletion',
			     pattern: $'<buffer={bnr}>'})
      ->mapnew((_, acmd) => acmd.event)->sort()
    assert_equal(disabled ? [] : ['BufLeave', 'CompleteChanged', 'CompleteDone',
				  'CursorMovedI', 'InsertEnter', 'TextChangedI',
				  'TextChangedP', 'WinLeave'],
		 events, $'disabled: {disabled}')
    lsp.RemoveFile(bnr)
    assert_equal([], autocmd_get({group: 'LspInlineCompletion',
				  pattern: $'<buffer={bnr}>'}))
    :%bw!
  endfor
  delete('XInlineCompletionInit.txt')
enddef

# Define the text property type of the inline completions, which is otherwise
# defined only when the first language server is started.
def InlineCompletionInitOnce()
  if prop_type_get('LspInlineCompletion')->empty()
    inlinecompletion.InitOnce()
  endif
enddef

# Returns a running and ready language server that provides the inline
# completions of the current buffer.  It replies to the n-th inline completion
# request with "replies[n]", or with none when there are fewer replies, from a
# timer as a reply arrives after the request.  The method and the params of
# the requests are added to "requests", the commands it is asked to execute to
# "commands" and the notifications it is sent to "notifications".
def MakeInlineCompletionServer(replies: list<any>,
			       requests: list<dict<any>>,
			       commands: list<dict<any>> = [],
			       notifications: list<dict<any>> = []): dict<any>
  InlineCompletionInitOnce()
  var srv = MakeCapsServer({inlineCompletionProvider: true}, notifications)
  srv.rpc_a = (method: string, params: any, Cbfunc: func, _ = {}): number => {
    requests->add({method: method, params: params->deepcopy()})
    var reply: any = replies->get(requests->len() - 1, null)
    timer_start(0, (_) => {
      Cbfunc(srv, reply, {})
    })
    return requests->len()
  }
  srv.executeCommand = (cmd: dict<any>) => {
    commands->add(cmd)
  }
  buf.BufLspServerSet(bufnr(), srv)
  inlinecompletion.BufferInit(srv, bufnr())
  return srv
enddef

# Detach the language server "srv" made by MakeInlineCompletionServer() from
# the current buffer.
def StopInlineCompletionServer(srv: dict<any>)
  inlinecompletion.BufferDeInit(bufnr())
  buf.BufLspServerRemove(bufnr(), srv)
enddef

# Returns the ghost text of the inline completion in the cursor line: the
# [column, text] of the text in the line, and then the [0, text] of the lines
# below it, from the top.
def GhostText(): list<list<any>>
  var props = prop_list(line('.'), {types: ['LspInlineCompletion']})
  # prop_list() lists the lines below from the one added last
  return props->copy()->filter((_, p) => p.col > 0)
	   ->mapnew((_, p) => [p.col, p.text])
    + props->copy()->filter((_, p) => p.col == 0)
	   ->mapnew((_, p) => [0, p.text])->reverse()
enddef

# Type "keys", which enter Insert mode, and then go through the "steps": wait
# until the first function of a step returns true, or for 5 seconds, and then
# type the keys that its second function returns.  Insert mode is left after
# the last step, or after an exception.  feedkeys() stays in Insert mode with
# the "!" flag, so a timer acts in it.
def InsertModeSteps(keys: string, steps: list<list<func>>)
  var step = 0
  var tries = 0
  timer_start(10, (timer) => {
    try
      tries += 1
      var Ready: func = steps[step][0]
      var ready: bool = Ready()
      if !ready && tries < 500
	return
      endif
      if !ready
	assert_report($'Step {step + 1} timed out')
      endif
      var Act: func = steps[step][1]
      var stepKeys: string = Act()
      step += 1
      tries = 0
      if step == steps->len()
	timer_stop(timer)
	stepKeys ..= "\<Esc>"
      endif
      feedkeys(stepKeys, 't')
    catch
      timer_stop(timer)
      v:errors->add($'Exception in step {step + 1}: {v:exception} at {v:throwpoint}')
      feedkeys("\<Esc>", 't')
    endtry
  }, {repeat: -1})
  feedkeys(keys, 'xt!')
enddef

# Test that inline completions are requested while typing in Insert mode and
# shown as ghost text: the first line at the cursor, with its tabs as the
# spaces they take, and the other lines below the cursor line.
def g:Test_InlineCompletion_ShowsGhostTextWhileTyping()
  g:LspOptionsSet({autoInlineCompletion: true, inlineCompletionDelay: 10})
  silent! edit XInlineCompletionTyping.txt
  setlocal tabstop=8
  setline(1, ["\tfoo("])
  var requests: list<dict<any>> = []
  var item = {insertText: "a,\tb)\n\tbar\n\nbaz"}
  var srv = MakeInlineCompletionServer([[item]], requests)
  try
    var expected = [[6, 'a,  b)'], [0, repeat(' ', 8) .. 'bar'], [0, ' '],
		    [0, 'baz']]
    var shown: list<list<any>>
    InsertModeSteps('A', [
      [() => GhostText() == expected, () => {
	shown = GhostText()
	assert_true(g:LspInlineCompletionVisible())
	return ''
      }]
    ])
    assert_equal(expected, shown)
    assert_equal([], GhostText())
    assert_false(g:LspInlineCompletionVisible())
    assert_equal(1, requests->len())
    assert_equal({
      method: 'textDocument/inlineCompletion',
      params: {
	textDocument: {uri: util.LspBufnrToUri(bufnr()), version: 0},
	position: {line: 0, character: 5},
	context: {triggerKind: 2},
	formattingOptions: {tabSize: 8, insertSpaces: false}
      }
    }, requests[0])
    assert_equal(["\tfoo("], getline(1, '$'))
  finally
    StopInlineCompletionServer(srv)
    g:LspOptionsSet({autoInlineCompletion: false, inlineCompletionDelay: 100})
    :%bw!
  endtry
enddef

# Test that an inline completion with a range is shown with the text typed in
# its range, positions in the encoding of the language server, keeps being
# shown while its text is typed, without asking the language server again,
# and is hidden when other text is typed.
def g:Test_InlineCompletion_RangeAndTypingThrough()
  silent! edit XInlineCompletionRange.txt
  # "😀" is two UTF-16 code units and four bytes
  setline(1, ['😀 = f()'])
  var requests: list<dict<any>> = []
  var item = {insertText: 'f(a, b)',
	      range: {start: {line: 0, character: 5},
		      end: {line: 0, character: 8}}}
  var srv = MakeInlineCompletionServer([{items: [item]}], requests)
  srv.posEncoding = 16
  try
    var shown: list<list<list<any>>> = []
    cursor(1, 9)
    InsertModeSteps('a', [
      [() => true, () => "\<Plug>(LspInlineCompletionTrigger)"],
      # The text in the line is around the ")" that the item replaces
      [() => !GhostText()->empty(), () => {
	shown->add(GhostText())
	return 'a'
      }],
      [() => GhostText() != shown[-1], () => {
	shown->add(GhostText())
	return 'x'
      }],
      [() => GhostText()->empty(), () => ''],
    ])
    assert_equal([[[10, 'a, b']], [[11, ', b']]], shown)
    assert_equal(1, requests->len())
    assert_equal({line: 0, character: 7}, requests[0].params.position)
    assert_equal({triggerKind: 1}, requests[0].params.context)
    assert_equal(['😀 = f(ax)'], getline(1, '$'))
  finally
    StopInlineCompletionServer(srv)
    :%bw!
  endtry
enddef

# Test accepting the next word, the next line and all of an inline
# completion, which then executes its command.
def g:Test_InlineCompletion_Accept()
  silent! edit XInlineCompletionAccept.txt
  setline(1, ['if x'])
  var requests: list<dict<any>> = []
  var commands: list<dict<any>> = []
  var command = {title: 'Accepted', command: 'test.accepted', arguments: [1]}
  var item = {insertText: ":\n    y = 1\n    z = 2\n", command: command}
  var srv = MakeInlineCompletionServer([[item]], requests, commands)
  try
    var shown: list<list<list<any>>> = []
    var texts: list<list<string>> = []
    InsertModeSteps('A', [
      [() => true, () => "\<Plug>(LspInlineCompletionTrigger)"],
      [() => !GhostText()->empty(), () => {
	shown->add(GhostText())
	return "\<Plug>(LspInlineCompletionAcceptWord)"
      }],
      [() => getline(1) == 'if x:', () => {
	shown->add(GhostText())
	texts->add(getline(1, '$'))
	return "\<Plug>(LspInlineCompletionAcceptLine)"
      }],
      [() => line('$') == 2, () => {
	shown->add(GhostText())
	texts->add(getline(1, '$'))
	assert_equal([], commands)
	return "\<Plug>(LspInlineCompletionAccept)"
      }],
      [() => line('$') == 4, () => {
	shown->add(GhostText())
	texts->add(getline(1, '$') + [string([line('.'), col('.')])])
	assert_false(g:LspInlineCompletionVisible())
	return ''
      }],
    ])
    assert_equal([
      [[5, ':'], [0, '    y = 1'], [0, '    z = 2'], [0, ' ']],
      [[0, '    y = 1'], [0, '    z = 2'], [0, ' ']],
      [[0, '    z = 2'], [0, ' ']],
      []
    ], shown)
    assert_equal([
      ['if x:'],
      ['if x:', '    y = 1'],
      ['if x:', '    y = 1', '    z = 2', '', '[4, 1]']
    ], texts)
    assert_equal([command], commands)
    assert_equal(1, requests->len())
  finally
    StopInlineCompletionServer(srv)
    :%bw!
  endtry
enddef

# Test accepting an inline completion that replaces text after the cursor,
# keeping the text after its range, and accepting the word of a snippet
# inline completion, which is inserted as the text it inserts when nothing is
# typed in it.
def g:Test_InlineCompletion_AcceptReplacingText()
  silent! edit XInlineCompletionReplace.txt
  var requests: list<dict<any>> = []
  for [insertText, keys, expected] in [
      ['g(a, b)', "\<Plug>(LspInlineCompletionAccept)", 'x = g(a, b); y'],
      ['g(a, b)', "\<Plug>(LspInlineCompletionAcceptWord)"
		  .. "\<Plug>(LspInlineCompletionAcceptWord)", 'x = g(a,); y'],
      [{kind: 'snippet', value: 'g(${1:a}, ${2|b,c|})$0'},
       "\<Plug>(LspInlineCompletionAccept)", 'x = g(a, b); y']]
    setline(1, ['x = g(); y'])
    var item = {insertText: insertText,
		range: {start: {line: 0, character: 4},
			end: {line: 0, character: 7}}}
    requests = []
    var srv = MakeInlineCompletionServer([[item]], requests)
    cursor(1, 6)
    InsertModeSteps('a', [
      [() => true, () => "\<Plug>(LspInlineCompletionTrigger)"],
      [() => !GhostText()->empty(), () => keys],
      [() => getline(1) != 'x = g(); y', () => ''],
    ])
    assert_equal([expected], getline(1, '$'), string(insertText) .. keys)
    StopInlineCompletionServer(srv)
  endfor
  :%bw!
enddef

# Test showing the next and the previous inline completions: when the inline
# completions were requested while typing, they are asked for first.
def g:Test_InlineCompletion_Cycle()
  g:LspOptionsSet({autoInlineCompletion: true, inlineCompletionDelay: 10})
  silent! edit XInlineCompletionCycle.txt
  setline(1, ['x = '])
  var requests: list<dict<any>> = []
  var items = [{insertText: 'one'}, {insertText: 'two'}, {insertText: 'three'}]
  var srv = MakeInlineCompletionServer([[items[0]], {items: items}], requests)
  try
    var shown: list<string> = []
    var Ghost = (): string => GhostText()->get(0, [0, ''])[1]
    InsertModeSteps('A', [
      [() => Ghost() == 'one', () => "\<Plug>(LspInlineCompletionNext)"],
      [() => Ghost() != 'one', () => {
	shown->add(Ghost())
	return "\<Plug>(LspInlineCompletionNext)"
      }],
      [() => true, () => {
	shown->add(Ghost())
	return "\<Plug>(LspInlineCompletionNext)"
      }],
      [() => true, () => {
	shown->add(Ghost())
	return "\<Plug>(LspInlineCompletionPrev)"
      }],
      [() => true, () => {
	shown->add(Ghost())
	return ''
      }],
    ])
    assert_equal(['two', 'three', 'one', 'three'], shown)
    assert_equal([2, 1], requests->mapnew((_, r) => r.params.context.triggerKind))
  finally
    StopInlineCompletionServer(srv)
    g:LspOptionsSet({autoInlineCompletion: false, inlineCompletionDelay: 100})
    :%bw!
  endtry
enddef

# Test that an inline completion is hidden when dismissed and while the
# completion popup menu is shown, and that the reply to a request is dropped
# when the text changes before it arrives, and the request is cancelled.
def g:Test_InlineCompletion_HideAndDrop()
  silent! edit XInlineCompletionHide.txt
  setline(1, ['foobar foobaz', ''])
  var requests: list<dict<any>> = []
  var notifications: list<dict<any>> = []
  var srv = MakeInlineCompletionServer([[{insertText: 'fooqux'}],
					[{insertText: 'fooqux'}],
					[{insertText: 'foozzz'}]],
				       requests, [], notifications)
  var save_completeopt = &completeopt
  set completeopt=menuone,noselect
  try
    var shown: list<list<list<any>>> = []
    var ticks = 0
    cursor(2, 1)
    InsertModeSteps('A', [
      [() => true, () => "\<Plug>(LspInlineCompletionTrigger)"],
      [() => !GhostText()->empty(), () => {
	shown->add(GhostText())
	return "\<Plug>(LspInlineCompletionDismiss)"
      }],
      [() => true, () => {
	shown->add(GhostText())
	return "\<Plug>(LspInlineCompletionTrigger)"
      }],
      [() => !GhostText()->empty(), () => 'fo'],
      [() => GhostText() == [[3, 'oqux']], () => "\<C-N>"],
      [() => pumvisible(), () => {
	shown->add(GhostText())
	return "\<C-E>"
      }],
      [() => !pumvisible() && !GhostText()->empty(), () => {
	shown->add(GhostText())
	# The text changes before the reply arrives
	return "\<Plug>(LspInlineCompletionTrigger)o"
      }],
      [() => {
	ticks += 1
	return ticks > 10
      }, () => {
	shown->add(GhostText())
	return ''
      }],
    ])
    assert_equal([[[1, 'fooqux']], [], [], [[3, 'oqux']], [[4, 'qux']]], shown)
    assert_equal(3, requests->len())
    assert_equal([{method: '$/cancelRequest', params: {id: 3}}],
		 notifications->copy()
		   ->filter((_, n) => n.method == '$/cancelRequest'))
    assert_equal(['foobar foobaz', 'foo'], getline(1, '$'))
  finally
    &completeopt = save_completeopt
    StopInlineCompletionServer(srv)
    :%bw!
  endtry
enddef

# Test that an inline completion is shown when the reply of a language server
# job arrives.  The request is sent before Vim waits, which reads the reply.
def g:Test_InlineCompletion_AsyncReply()
  InlineCompletionInitOnce()
  silent! edit XInlineCompletionAsync.txt
  setline(1, ['x = '])
  var bnr = bufnr()
  var srv = MakeAsyncReplyingLspServer([{items: [{insertText: 'y'}]}])
  srv.isInlineCompletionProvider = true
  inlinecompletion.BufferInit(srv, bnr)
  try
    var shown: list<list<any>>
    InsertModeSteps("A\<Plug>(LspInlineCompletionTrigger)", [
      [() => !GhostText()->empty(), () => {
	shown = GhostText()
	return ''
      }],
    ])
    assert_equal([[5, 'y']], shown)
  finally
    inlinecompletion.BufferDeInit(bnr)
    StopAsyncReplyingLspServer(srv, bnr)
    :%bw!
  endtry
enddef

# Test that an inline completion is hidden when CTRL-C ends Insert mode,
# which doesn't trigger InsertLeave.
def g:Test_InlineCompletion_HiddenAfterCtrlC()
  silent! edit XInlineCompletionCtrlC.txt
  setline(1, ['x'])
  var requests: list<dict<any>> = []
  var srv = MakeInlineCompletionServer([[{insertText: 'yz'}]], requests)
  try
    InsertModeSteps('A', [
      [() => true, () => "\<Plug>(LspInlineCompletionTrigger)"],
      [() => !GhostText()->empty(), () => "\<C-C>"],
    ])
    assert_equal('n', mode())
    assert_equal([], GhostText())
    assert_equal(['x'], getline(1, '$'))
  finally
    StopInlineCompletionServer(srv)
    :%bw!
  endtry
enddef

# Test a mapping that accepts the inline completion shown, and else types the
# key it maps.
def g:Test_InlineCompletion_ConditionalMapping()
  silent! edit XInlineCompletionMapping.txt
  setline(1, ['x'])
  var requests: list<dict<any>> = []
  var srv = MakeInlineCompletionServer([[{insertText: 'yz'}]], requests)
  imap <buffer> <expr> <Tab> g:LspInlineCompletionVisible() ? "\<Plug>(LspInlineCompletionAccept)" : "\<Tab>"
  try
    InsertModeSteps('A', [
      [() => true, () => "\<Tab>\<Plug>(LspInlineCompletionTrigger)"],
      [() => !GhostText()->empty(), () => "\<Tab>"],
      [() => getline(1) =~ 'z$', () => "\<Tab>"],
    ])
    assert_equal(["x\tyz\t"], getline(1, '$'))
  finally
    iunmap <buffer> <Tab>
    StopInlineCompletionServer(srv)
    :%bw!
  endtry
enddef

# Returns a running language server with the workspace folders "folders" that
# keeps the notifications that it is sent in "notifications" and the responses
# to the requests that it sends in "responses".
def MakeWatchingLspServer(notifications: list<dict<any>>,
			  responses: list<dict<any>>,
			  folders: list<string> = []): dict<any>
  var lspserver = MakeTestLspServer(notifications)
  lspserver.sendResponse = function(CaptureResponse, [responses])
  lspserver.running = true
  lspserver.ready = true
  lspserver.workspaceFolders = folders->mapnew((_, dir) => dir->fnamemodify(':p'))
  return lspserver
enddef

# Has language server "lspserver" register the file system watchers
# "watchers" with the registration ID "id", and checks that the registration
# succeeded.
def RegisterWatchers(lspserver: dict<any>, responses: list<dict<any>>,
		     id: string, watchers: list<any>)
  responses->filter((_, _) => false)
  var registration = {id: id, method: 'workspace/didChangeWatchedFiles',
		      registerOptions: {watchers: watchers}}
  var request = {id: 1, method: 'client/registerCapability',
		 params: {registrations: [registration]}}
  lspserver.processRequest(request)
  assert_equal([{id: 1, result: null, error: {}}], responses)
enddef

# Returns the changes of the "workspace/didChangeWatchedFiles" notifications
# in "notifications".
def WatchedFileChanges(notifications: list<dict<any>>): list<any>
  return notifications->copy()
    ->filter((_, notif) => notif.method == 'workspace/didChangeWatchedFiles')
    ->mapnew((_, notif) => notif.params.changes)->flattennew()
enddef

# Returns the URI of the file "fname" in a "workspace/didChangeWatchedFiles"
# notification.  The full path of a file in a directory that is a symbolic
# link is in the directory that the link points to.
def WatchedFileUri(fname: string): string
  return util.LspPathToUri(fname->fnamemodify(':p')
			      ->substitute('\(.\)/$', '\1', ''))
enddef

# Returns the types of the changes to the file with URI "uri" in the
# "workspace/didChangeWatchedFiles" notifications in "notifications".
def WatchedFileChangeTypes(notifications: list<dict<any>>, uri: string): list<any>
  return WatchedFileChanges(notifications)
    ->filter((_, change) => change.uri == uri)->mapnew((_, change) => change.type)
enddef

# Waits for a change to the file with URI "uri" in the
# "workspace/didChangeWatchedFiles" notifications in "notifications", and
# checks that the first one is of type "type".  Later changes can be fswatch
# reporting the change that Vim made.
def AssertWatchedFileChange(notifications: list<dict<any>>, uri: string,
			    type: number)
  g:WaitForAssert(() => assert_notequal([],
					WatchedFileChangeTypes(notifications, uri)))
  assert_equal(type, WatchedFileChangeTypes(notifications, uri)->get(0, 0))
enddef

# Returns the fswatch jobs that are running.
def FswatchJobs(): list<job>
  return job_info()->filter((_, job) => job->job_info().cmd[0] == 'fswatch'
				       && job->job_status() == 'run')
enddef

# Test that the file system watchers that a language server registers match
# the files as their glob patterns say.
def g:Test_WatchedFiles_GlobPatterns()
  var notifications: list<dict<any>> = []
  var responses: list<dict<any>> = []
  var lspserver = MakeWatchingLspServer(notifications, responses,
					['/XLspWatchWs'])
  try
    RegisterWatchers(lspserver, responses, 'globs', [
      {globPattern: {baseUri: 'file:///XLspWatch', pattern: '**/*.{go,mod}'}},
      {globPattern: '/XLspWatch/abs/*.txt'},
      {globPattern: '**/Cargo.toml'},
      {globPattern: {baseUri: 'file:///XLspWatch/', pattern: 'n/file.[0-9]'}},
      {globPattern: {baseUri: 'file:///XLspWatch', pattern: 'n/[!a]x'}},
      {globPattern: {baseUri: 'file:///XLspWatch', pattern: 'q/?.c'}},
      {globPattern: {baseUri: 'file:///XLspWatch', pattern: 'lit/a+b$.c~'}},
      {globPattern: {baseUri: 'file:///XLspWatch', pattern: 'u/{a'}},
      {globPattern: {baseUri: 'file:///XLspWatch', pattern: 'all/**'}},
      {globPattern: {baseUri: {uri: 'file:///XLspWatch2', name: 'w2'},
		     pattern: '*.c'}}
    ])
    var matched: list<string> = [
      '/XLspWatch/a.go', '/XLspWatch/x/y/b.mod', '/XLspWatch/abs/a.txt',
      '/XLspWatchWs/p/Cargo.toml', '/XLspWatch/n/file.1', '/XLspWatch/n/bx',
      '/XLspWatch/q/a.c', '/XLspWatch/lit/a+b$.c~', '/XLspWatch/u/{a',
      '/XLspWatch/all', '/XLspWatch/all/x/y', '/XLspWatch2/a.c']
    var unmatched: list<string> = [
      '/XLspWatch/a.rs', '/XLspOther/a.go', '/XLspWatch/abs/sub/a.txt',
      # Not in a workspace folder
      '/XLspOther/Cargo.toml',
      '/XLspWatch/n/file.a', '/XLspWatch/n/ax', '/XLspWatch/q/ab.c',
      '/XLspWatch/lit/aab$.c~', '/XLspWatch/allx', '/XLspWatch2/s/a.c']
    for path in unmatched + matched
      watchedfiles.VimChangedFile(path, watchedfiles.FILE_CHANGED)
    endfor
    g:WaitForAssert(() => assert_equal(1, notifications->len()))
    assert_equal(matched->mapnew((_, path) => ({uri: util.LspPathToUri(path),
						type: 2})),
		 WatchedFileChanges(notifications))
  finally
    watchedfiles.RemoveServer(lspserver)
  endtry
enddef

# Test that a change is sent for the watchers of its kind, and that the
# changes made to a file before they are sent are merged into one.
def g:Test_WatchedFiles_ChangeKindsAndMerging()
  var notifications: list<dict<any>> = []
  var responses: list<dict<any>> = []
  var lspserver = MakeWatchingLspServer(notifications, responses)
  try
    RegisterWatchers(lspserver, responses, 'kinds', [
      {globPattern: {baseUri: 'file:///XLspWatch', pattern: '*.del'}, kind: 4},
      {globPattern: {baseUri: 'file:///XLspWatch', pattern: '*.c'}}])
    const CREATED = watchedfiles.FILE_CREATED
    const CHANGED = watchedfiles.FILE_CHANGED
    const DELETED = watchedfiles.FILE_DELETED
    for [fname, type] in [
	['x.del', CREATED], ['y.del', DELETED],
	['m1.c', CREATED], ['m1.c', DELETED],
	['m2.c', DELETED], ['m2.c', CREATED],
	['m3.c', CREATED], ['m3.c', CHANGED],
	['m4.c', CHANGED], ['m4.c', DELETED],
	['m5.c', CHANGED], ['m5.c', CHANGED]]
      watchedfiles.VimChangedFile($'/XLspWatch/{fname}', type)
    endfor
    g:WaitForAssert(() => assert_equal(1, notifications->len()))
    assert_equal([{uri: 'file:///XLspWatch/y.del', type: DELETED},
		  {uri: 'file:///XLspWatch/m2.c', type: CHANGED},
		  {uri: 'file:///XLspWatch/m3.c', type: CREATED},
		  {uri: 'file:///XLspWatch/m4.c', type: DELETED},
		  {uri: 'file:///XLspWatch/m5.c', type: CHANGED}],
		 WatchedFileChanges(notifications))
  finally
    watchedfiles.RemoveServer(lspserver)
  endtry
enddef

# Test that each language server is sent the changes for its own watchers,
# and that unregistered watchers are no longer used.
def g:Test_WatchedFiles_RegistrationsPerServer()
  var notifications1: list<dict<any>> = []
  var responses1: list<dict<any>> = []
  var server1 = MakeWatchingLspServer(notifications1, responses1)
  var notifications2: list<dict<any>> = []
  var responses2: list<dict<any>> = []
  var server2 = MakeWatchingLspServer(notifications2, responses2)
  try
    RegisterWatchers(server1, responses1, 'a', [{globPattern: '/XLspWatch/*.a'}])
    RegisterWatchers(server1, responses1, 'b', [{globPattern: '/XLspWatch/*.b'}])
    RegisterWatchers(server2, responses2, 'a', [{globPattern: '/XLspWatch/*.a'}])
    assert_true(exists('#LspWatchedFiles#BufWritePost'))

    responses1->filter((_, _) => false)
    var unregistration = {id: 'a', method: 'workspace/didChangeWatchedFiles'}
    var request = {id: 2, method: 'client/unregisterCapability',
		   params: {unregisterations: [unregistration]}}
    server1.processRequest(request)
    assert_equal([{id: 2, result: null, error: {}}], responses1)

    watchedfiles.VimChangedFile('/XLspWatch/x.a', watchedfiles.FILE_CHANGED)
    watchedfiles.VimChangedFile('/XLspWatch/x.b', watchedfiles.FILE_CHANGED)
    g:WaitForAssert(() => assert_equal(1, notifications2->len()))
    assert_equal([{uri: 'file:///XLspWatch/x.b', type: 2}],
		 WatchedFileChanges(notifications1))
    assert_equal([{uri: 'file:///XLspWatch/x.a', type: 2}],
		 WatchedFileChanges(notifications2))
  finally
    watchedfiles.RemoveServer(server1)
    watchedfiles.RemoveServer(server2)
  endtry
  assert_false(exists('#LspWatchedFiles'))
enddef

# Test that a registration with a watcher that is not valid fails and
# registers none of its watchers.
def g:Test_WatchedFiles_InvalidRegistration()
  var notifications1: list<dict<any>> = []
  var responses1: list<dict<any>> = []
  var server1 = MakeWatchingLspServer(notifications1, responses1)
  var notifications2: list<dict<any>> = []
  var responses2: list<dict<any>> = []
  var server2 = MakeWatchingLspServer(notifications2, responses2)
  try
    var valid: dict<any> = {globPattern: '/XLspWatch/*'}
    for registration in [
	{id: 'r', method: 'workspace/didChangeWatchedFiles'},
	{method: 'workspace/didChangeWatchedFiles',
	 registerOptions: {watchers: [valid]}},
	{id: 'r', method: 'workspace/didChangeWatchedFiles',
	 registerOptions: {watchers: {}}},
	{id: 'r', method: 'workspace/didChangeWatchedFiles',
	 registerOptions: {watchers: [valid, {}]}},
	{id: 'r', method: 'workspace/didChangeWatchedFiles',
	 registerOptions: {watchers: [valid, {globPattern: 1}]}},
	{id: 'r', method: 'workspace/didChangeWatchedFiles',
	 registerOptions: {watchers: [valid, {globPattern: {pattern: '*'}}]}},
	{id: 'r', method: 'workspace/didChangeWatchedFiles',
	 registerOptions: {watchers: [valid, {globPattern: '*', kind: '7'}]}}]
      AssertRequestError(server1, responses1,
	{id: 3, method: 'client/registerCapability',
	 params: {registrations: [registration]}}, -32602)
    endfor

    RegisterWatchers(server2, responses2, 'r', [valid])
    watchedfiles.VimChangedFile('/XLspWatch/x', watchedfiles.FILE_CHANGED)
    g:WaitForAssert(() => assert_equal(1, notifications2->len()))
    assert_equal([], notifications1)
  finally
    watchedfiles.RemoveServer(server1)
    watchedfiles.RemoveServer(server2)
  endtry
enddef

# Test that the client offers to watch files only when the "watchFiles" option
# is set and fswatch is found, and that watchers registered without the option
# are ignored.
def g:Test_WatchedFiles_WatchFilesOption()
  var notifications1: list<dict<any>> = []
  var responses1: list<dict<any>> = []
  var server1 = MakeWatchingLspServer(notifications1, responses1)
  var notifications2: list<dict<any>> = []
  var responses2: list<dict<any>> = []
  var server2 = MakeWatchingLspServer(notifications2, responses2)
  var watcher: dict<any> = {globPattern: '/XLspWatch/*'}
  try
    var workspaceCaps: dict<any> = capabilities.GetClientCaps().workspace
    assert_equal(executable('fswatch'),
		 workspaceCaps->has_key('didChangeWatchedFiles'))
    if executable('fswatch')
      assert_equal({dynamicRegistration: true, relativePatternSupport: true},
		   capabilities.GetClientCaps().workspace.didChangeWatchedFiles)
    endif

    g:LspOptionsSet({watchFiles: false})
    assert_false(
      capabilities.GetClientCaps().workspace->has_key('didChangeWatchedFiles'))
    RegisterWatchers(server1, responses1, 'r', [watcher])

    g:LspOptionsSet({watchFiles: true})
    RegisterWatchers(server2, responses2, 'r', [watcher])
    watchedfiles.VimChangedFile('/XLspWatch/x', watchedfiles.FILE_CHANGED)
    g:WaitForAssert(() => assert_equal(1, notifications2->len()))
    assert_equal([], notifications1)
  finally
    g:LspOptionsSet({watchFiles: true})
    watchedfiles.RemoveServer(server1)
    watchedfiles.RemoveServer(server2)
  endtry
enddef

# Test that a language server whose "watchFiles" feature is off is not
# offered to have its files watched and that its watchers are ignored, while
# another language server's are used.
def g:Test_WatchedFiles_FeatureOff()
  silent! edit XWatchedFilesFeatureOff.txt
  var notifications1: list<dict<any>> = []
  var responses1: list<dict<any>> = []
  var server1 = MakeWatchingLspServer(notifications1, responses1)
  server1.features = {watchFiles: false}
  var notifications2: list<dict<any>> = []
  var responses2: list<dict<any>> = []
  var server2 = MakeWatchingLspServer(notifications2, responses2)
  var watcher: dict<any> = {globPattern: '/XLspWatch/*'}
  try
    assert_false(capabilities.GetClientCaps(false).workspace
		   ->has_key('didChangeWatchedFiles'))

    for [lspserver, watching] in [[server1, false], [server2, true]]
      lspserver.job = StartStubServerJob([])
      lspserver.initServer(bufnr())
      assert_equal(watching && executable('fswatch') == 1,
		   !!lspserver.rpcInitializeRequest.capabilities.workspace
		     ->has_key('didChangeWatchedFiles'))
      job_stop(lspserver.job)
    endfor

    RegisterWatchers(server1, responses1, 'r', [watcher])
    RegisterWatchers(server2, responses2, 'r', [watcher])
    watchedfiles.VimChangedFile('/XLspWatch/x', watchedfiles.FILE_CHANGED)
    g:WaitForAssert(() => assert_equal(1, notifications2->len()))
    assert_equal([], notifications1)
  finally
    job_stop(server1->get('job', null_job))
    job_stop(server2->get('job', null_job))
    watchedfiles.RemoveServer(server1)
    watchedfiles.RemoveServer(server2)
    :%bw!
  endtry
enddef

# Test that the changes to files that Vim writes are sent.
def g:Test_WatchedFiles_VimWrites()
  var dir = 'XWatchedFilesVimWrites'
  mkdir(dir)
  var notifications: list<dict<any>> = []
  var responses: list<dict<any>> = []
  var lspserver = MakeWatchingLspServer(notifications, responses, [dir])
  try
    RegisterWatchers(lspserver, responses, 'txt', [{globPattern: '**/*.txt'}])
    var fname = $'{dir}/new.txt'
    var copy = $'{dir}/copy.txt'
    var part = $'{dir}/part.txt'
    var other = $'{dir}/other.log'

    exe $'edit {fname}'
    setline(1, ['one', 'two'])
    :write
    AssertWatchedFileChange(notifications, WatchedFileUri(fname),
			    watchedfiles.FILE_CREATED)

    notifications->filter((_, _) => false)
    setline(1, 'three')
    :write
    AssertWatchedFileChange(notifications, WatchedFileUri(fname),
			    watchedfiles.FILE_CHANGED)

    notifications->filter((_, _) => false)
    exe $'write {copy}'
    AssertWatchedFileChange(notifications, WatchedFileUri(copy),
			    watchedfiles.FILE_CREATED)

    notifications->filter((_, _) => false)
    exe $'write >> {copy}'
    AssertWatchedFileChange(notifications, WatchedFileUri(copy),
			    watchedfiles.FILE_CHANGED)

    notifications->filter((_, _) => false)
    exe $'write {other}'
    exe $':1write {part}'
    AssertWatchedFileChange(notifications, WatchedFileUri(part),
			    watchedfiles.FILE_CREATED)
    assert_equal([], WatchedFileChangeTypes(notifications,
					    WatchedFileUri(other)))
  finally
    watchedfiles.RemoveServer(lspserver)
    :%bwipe!
    delete(dir, 'rf')
  endtry
enddef

# Test that the files that a workspace edit creates, renames and deletes are
# sent as changes.
def g:Test_WatchedFiles_WorkspaceEdit()
  var dir = 'XWatchedFilesWorkspaceEdit'
  var sub = $'{dir}/sub'
  mkdir(sub, 'p')
  var notifications: list<dict<any>> = []
  var responses: list<dict<any>> = []
  var lspserver = MakeWatchingLspServer(notifications, responses, [dir])
  try
    RegisterWatchers(lspserver, responses, 'files',
		     [{globPattern: '**/*.txt'}, {globPattern: '**/sub'}])
    var fname = $'{dir}/a.txt'
    var renamed = $'{dir}/b.txt'

    ApplyResourceOp({kind: 'create', uri: util.LspFileToUri(fname)})
    AssertWatchedFileChange(notifications, WatchedFileUri(fname),
			    watchedfiles.FILE_CREATED)

    notifications->filter((_, _) => false)
    var fnameUri = WatchedFileUri(fname)
    ApplyResourceOp(MakeRename(fname, renamed))
    AssertWatchedFileChange(notifications, fnameUri, watchedfiles.FILE_DELETED)
    AssertWatchedFileChange(notifications, WatchedFileUri(renamed),
			    watchedfiles.FILE_CREATED)

    notifications->filter((_, _) => false)
    var renamedUri = WatchedFileUri(renamed)
    ApplyResourceOp(MakeDelete(renamed))
    AssertWatchedFileChange(notifications, renamedUri,
			    watchedfiles.FILE_DELETED)

    # fswatch can report that the directory was created, which it was before
    # the watcher was registered, before it reports that it was deleted.
    var subUri = WatchedFileUri(sub)
    ApplyResourceOp(MakeDelete(sub, {recursive: true}))
    g:WaitForAssert(() => assert_equal(watchedfiles.FILE_DELETED,
		      WatchedFileChangeTypes(notifications, subUri)->get(-1, 0)))
  finally
    watchedfiles.RemoveServer(lspserver)
    :%bwipe!
    delete(dir, 'rf')
  endtry
enddef

# Test that fswatch watches the workspace folders for the glob patterns that
# are strings, also absolute ones, and the base directories of the relative
# patterns, but not a directory in another one or one that is never a
# workspace root.
def g:Test_WatchedFiles_WatchedDirectories()
  if !executable('fswatch')
    # The tests run with fswatch in CI.
    assert_equal('', $CI, 'fswatch is not installed')
    return
  endif
  var workspace = 'XWatchedFilesWorkspace'
  var outside = 'XWatchedFilesOutside'
  var base = 'XWatchedFilesBase'
  mkdir($'{workspace}/nested', 'p')
  mkdir(outside)
  mkdir(base)
  var notifications: list<dict<any>> = []
  var responses: list<dict<any>> = []
  var lspserver = MakeWatchingLspServer(notifications, responses, [workspace])
  try
    RegisterWatchers(lspserver, responses, 'dirs', [
      {globPattern: '**/*.txt'},
      {globPattern: $'{fnamemodify(outside, ':p')}*.txt'},
      {globPattern: {baseUri: WatchedFileUri(base), pattern: '*.txt'}},
      {globPattern: {baseUri: WatchedFileUri($'{workspace}/nested'),
		     pattern: '*.txt'}},
      {globPattern: {baseUri: WatchedFileUri($HOME), pattern: '*.txt'}}])
    var jobs: list<job> = FswatchJobs()
    assert_equal(1, jobs->len())
    var dirs: list<string> = [workspace, base]
      ->mapnew((_, dir) => dir->fnamemodify(':p')->resolve()->substitute('/$', '', ''))
      ->sort()
    assert_equal(dirs, jobs[0]->job_info().cmd[-2 :])
    assert_equal('--', jobs[0]->job_info().cmd[-3])
  finally
    watchedfiles.RemoveServer(lspserver)
    delete(workspace, 'rf')
    delete(outside, 'rf')
    delete(base, 'rf')
  endtry
enddef

# Test that the changes that other programs make to files are sent, as
# fswatch reports them.  A file in a watched directory that is a symbolic link
# is sent by its path in that directory.
def g:Test_WatchedFiles_ExternalChanges()
  if !executable('fswatch')
    # The tests run with fswatch in CI.
    assert_equal('', $CI, 'fswatch is not installed')
    return
  endif
  var dir = 'XWatchedFilesExternal'
  var link = 'XWatchedFilesExternalLink'
  mkdir(dir)
  system($'ln -s {dir} {link}')
  var notifications: list<dict<any>> = []
  var responses: list<dict<any>> = []
  var lspserver = MakeWatchingLspServer(notifications, responses)
  var linkUri = WatchedFileUri(link)
  try
    RegisterWatchers(lspserver, responses, 'go',
		     [{globPattern: {baseUri: linkUri, pattern: '**/*.go'}}])
    assert_equal(1, FswatchJobs()->len())

    # Wait until fswatch watches the directory.
    var watching = false
    for i in range(50)
      writefile([string(i)], $'{dir}/probe.go')
      if g:WaitForCommon(() => !WatchedFileChanges(notifications)->empty(),
			 v:null, 200) >= 0
	watching = true
	break
      endif
    endfor
    assert_true(watching)
    assert_equal([], WatchedFileChanges(notifications)
      ->filter((_, change) => change.uri != $'{linkUri}/probe.go'))

    var uri = $'{linkUri}/new.go'
    notifications->filter((_, _) => false)
    writefile(['package x'], $'{dir}/new.go')
    AssertWatchedFileChange(notifications, uri, watchedfiles.FILE_CREATED)

    notifications->filter((_, _) => false)
    writefile(['// more'], $'{dir}/new.go', 'a')
    AssertWatchedFileChange(notifications, uri, watchedfiles.FILE_CHANGED)

    notifications->filter((_, _) => false)
    delete($'{dir}/new.go')
    AssertWatchedFileChange(notifications, uri, watchedfiles.FILE_DELETED)

    notifications->filter((_, _) => false)
    mkdir($'{dir}/sub')
    writefile(['package sub'], $'{dir}/sub/sub.go')
    AssertWatchedFileChange(notifications, $'{linkUri}/sub/sub.go',
			    watchedfiles.FILE_CREATED)
  finally
    watchedfiles.RemoveServer(lspserver)
    delete(link)
    delete(dir, 'rf')
  endtry
  g:WaitForAssert(() => assert_equal([], FswatchJobs()))
enddef

# Returns the line, the column and the length of each linked editing range in
# buffer "bnr".
def LinkedRanges(bnr: number): list<list<number>>
  return prop_list(1, {bufnr: bnr, end_lnum: -1,
		       types: ['LspLinkedEditingRange']})
    ->mapnew((_, p) => [p.lnum, p.col, p.length])
enddef

# Returns an LSP Range from character "schar" to character "echar" of line
# "line".
def OneLineRange(line: number, schar: number, echar: number): dict<any>
  return {start: {line: line, character: schar},
	  end: {line: line, character: echar}}
enddef

# Edits the buffer "fname" with the lines "lines", for linked editing with a
# language server that is attached to it.  Returns the language server, which
# counts its requests for the linked ranges in "requests".
def LinkedEditingEdit(fname: string, lines: list<string>,
		      requests: list<number>): dict<any>
  linkedediting.InitOnce()
  g:LspOptionsSet({linkedEditing: true})
  exe $'silent! edit {fname}'
  setline(1, lines)
  # Start a new undo block, as a typed command does
  &undolevels = &undolevels
  var srv = MakeCapsServer({linkedEditingRangeProvider: true}, [])
  srv.linkedEditingRangesUpdate = () => {
    requests->add(bufnr())
  }
  buf.BufLspServerSet(bufnr(), srv)
  linkedediting.BufferInit(srv, bufnr())
  return srv
enddef

# Stops linked editing in the current buffer, edited with LinkedEditingEdit()
# with the language server "srv".
def LinkedEditingStop(srv: dict<any>)
  linkedediting.BufferDeInit(bufnr())
  buf.BufLspServerRemove(bufnr(), srv)
  g:LspOptionsSet({linkedEditing: false})
  :%bw!
enddef

# The keys that TypeAfterChanges() types
var typeAhead: list<string> = []

# Type the next key in "typeAhead".
def TypeNextKey()
  if !typeAhead->empty()
    feedkeys(typeAhead->remove(0), 't')
  endif
enddef

# Run the Normal mode command "cmd", which starts Insert mode, and type the
# "keys" one at a time, each after Vim handled the text change of the one
# before, as when typing, and then <Esc>.  Vim triggers TextChangedI and
# TextChangedP only when the typeahead is empty.  The timer only ends Insert
# mode if the text isn't changed.
def TypeAfterChanges(cmd: string, keys: list<string>)
  typeAhead = keys + ["\<Esc>"]
  autocmd_add([{group: 'TestTypeAfterChanges', pattern: '*',
		event: ['TextChangedI', 'TextChangedP'], cmd: 'TypeNextKey()'}])
  var timer = timer_start(5000, (_) => feedkeys("\<Esc>", 't'))
  try
    feedkeys(cmd, 'xt!')
  finally
    timer_stop(timer)
    autocmd_delete([{group: 'TestTypeAfterChanges'}])
    typeAhead = []
  endtry
enddef

# Test that the ranges that the language server links are linked only when
# there are two or more of them, each in a line, with the same text, without
# overlapping, and the cursor is in one of them.
def g:Test_LinkedEditing_RangesSet()
  var requests: list<number> = []
  var srv = LinkedEditingEdit('XLinkedRangesSet.txt',
			      ['<div><p></p></div>', '<div>', '</div>', 'aaa'],
			      requests)
  var bnr = bufnr()
  try
    for [ranges, cursorPos] in [
	[[OneLineRange(0, 1, 4)], [1, 2]],
	[[OneLineRange(0, 1, 4), OneLineRange(0, 7, 8)], [1, 2]],
	[[OneLineRange(3, 0, 2), OneLineRange(3, 1, 3)], [4, 2]],
	[[{start: {line: 1, character: 1}, end: {line: 2, character: 3}},
	  OneLineRange(0, 1, 4)], [1, 2]],
	[[OneLineRange(0, 1, 4), OneLineRange(0, 14, 17)], [1, 6]],
	[[OneLineRange(0, 1, 4), OneLineRange(5, 2, 5)], [1, 2]]]
      cursor(cursorPos)
      linkedediting.RangesSet(bnr, ranges, '')
      assert_equal([], LinkedRanges(bnr), ranges->string())
    endfor

    # The cursor is at the end of the second range
    cursor(3, 6)
    linkedediting.RangesSet(bnr, [OneLineRange(1, 1, 4), OneLineRange(2, 2, 5)], '')
    assert_equal([[2, 2, 3], [3, 3, 3]], LinkedRanges(bnr))
    assert_equal('MatchParen', hlget('LspLinkedEditingRange')[0].linksto)
  finally
    LinkedEditingStop(srv)
  endtry
enddef

# Test that a change typed in a linked editing range is made to the other
# ranges after each key, and is undone with them.
def g:Test_LinkedEditing_InsertMode()
  var requests: list<number> = []
  var srv = LinkedEditingEdit('XLinkedInsert.txt',
			      ['<div>', '  <p>x</p>', '</div>'], requests)
  var bnr = bufnr()
  try
    cursor(1, 3)
    linkedediting.RangesSet(bnr, [OneLineRange(0, 1, 4), OneLineRange(2, 2, 5)], '')
    TypeAfterChanges('ciws', ['p', 'a', 'n'])
    assert_equal(['<span>', '  <p>x</p>', '</span>'], getline(1, '$'))
    assert_equal([[1, 2, 4], [3, 3, 4]], LinkedRanges(bnr))
    assert_equal([], requests)

    :normal! u
    assert_equal(['<div>', '  <p>x</p>', '</div>'], getline(1, '$'))
    doautocmd TextChanged
    assert_equal([[1, 2, 3], [3, 3, 3]], LinkedRanges(bnr))

    # Deleting the whole text of a range deletes the text of the others
    cursor(3, 4)
    :normal! diw
    doautocmd TextChanged
    assert_equal(['<>', '  <p>x</p>', '</>'], getline(1, '$'))
    assert_equal([[1, 2, 0], [3, 3, 0]], LinkedRanges(bnr))
  finally
    LinkedEditingStop(srv)
  endtry
enddef

# Test that a change made in Normal mode to a linked editing range is made to
# the other ranges, and that one undo undoes it in all of them.
def g:Test_LinkedEditing_NormalMode()
  var requests: list<number> = []
  var srv = LinkedEditingEdit('XLinkedNormal.txt', ['<div>x</div>'], requests)
  var bnr = bufnr()
  try
    cursor(1, 9)
    linkedediting.RangesSet(bnr, [OneLineRange(0, 1, 4), OneLineRange(0, 8, 11)], '')
    :normal! x
    doautocmd TextChanged
    assert_equal('<iv>x</iv>', getline(1))
    :normal! u
    assert_equal('<div>x</div>', getline(1))
    doautocmd TextChanged
    assert_equal([[1, 2, 3], [1, 9, 3]], LinkedRanges(bnr))
  finally
    LinkedEditingStop(srv)
  endtry
enddef

# Test that a change to a linked editing range that is after a range in the
# same line keeps the cursor at the text it was at, also for moving to
# another line.
def g:Test_LinkedEditing_KeepsCursor()
  var requests: list<number> = []
  var srv = LinkedEditingEdit('XLinkedCursor.txt', ['<a>x</a>', '1234567890'],
			      requests)
  var bnr = bufnr()
  try
    cursor(1, 7)
    linkedediting.RangesSet(bnr, [OneLineRange(0, 1, 2), OneLineRange(0, 6, 7)], '')
    TypeAfterChanges('cwb', ['c'])
    assert_equal('<bc>x</bc>', getline(1))
    assert_equal([1, 9], [line('.'), col('.')])

    :normal! x
    doautocmd TextChanged
    assert_equal('<b>x</b>', getline(1))
    assert_equal([1, 8], [line('.'), col('.')])
    :normal! j
    assert_equal([2, 8], [line('.'), col('.')])
  finally
    LinkedEditingStop(srv)
  endtry
enddef

# Test that a change that leaves a text that doesn't match the word pattern in
# a linked editing range, or that changes the ranges in other ways, is not
# made to the other ranges, which are no longer linked.
def g:Test_LinkedEditing_StopsLinking()
  var requests: list<number> = []
  var srv = LinkedEditingEdit('XLinkedStop.txt', ['<div>', '</div>'], requests)
  var bnr = bufnr()
  try
    # White space with the default word pattern
    cursor(1, 4)
    linkedediting.RangesSet(bnr, [OneLineRange(0, 1, 4), OneLineRange(1, 2, 5)], '')
    TypeAfterChanges('a ', ['c'])
    assert_equal(['<div c>', '</div>'], getline(1, '$'))
    assert_equal([], LinkedRanges(bnr))

    # A character that the word pattern of the language server doesn't allow
    setline(1, '<div>')
    cursor(1, 4)
    linkedediting.RangesSet(bnr, [OneLineRange(0, 1, 4), OneLineRange(1, 2, 5)],
			    '[a-z]*')
    TypeAfterChanges('aX', [])
    assert_equal(['<divX>', '</div>'], getline(1, '$'))
    assert_equal([], LinkedRanges(bnr))

    # A new line in a range
    setline(1, '<div>')
    cursor(1, 3)
    linkedediting.RangesSet(bnr, [OneLineRange(0, 1, 4), OneLineRange(1, 2, 5)], '')
    TypeAfterChanges("i\<CR>", [])
    assert_equal(['<d', 'iv>', '</div>'], getline(1, '$'))
    assert_equal([], LinkedRanges(bnr))

    # A deleted range
    :%d _
    setline(1, ['<div>', '</div>'])
    cursor(1, 3)
    linkedediting.RangesSet(bnr, [OneLineRange(0, 1, 4), OneLineRange(1, 2, 5)], '')
    :2delete _
    doautocmd TextChanged
    assert_equal([], LinkedRanges(bnr))
  finally
    LinkedEditingStop(srv)
  endtry
enddef

# The closing tags that Test_LinkedEditing_CompletionMenu() saw
var closingTags: list<string> = []

# Test that typing in a linked editing range with the completion popup menu
# shown changes the other ranges right away, unless one of them is before the
# cursor in the cursor line: then they are changed after the menu is closed.
def g:Test_LinkedEditing_CompletionMenu()
  var requests: list<number> = []
  var srv = LinkedEditingEdit('XLinkedPopup.txt',
    ['<div>x</div>', 'divine dividend', '<div>', '</div>'], requests)
  var bnr = bufnr()
  var save_completeopt = &completeopt
  set completeopt=menu,menuone
  # The text of the other range while the menu is shown
  closingTags = []
  autocmd_add([{group: 'TestLinkedPopup', event: 'TextChangedP', pattern: '*',
		cmd: 'closingTags->add(getline(4)->matchstr(''</\zs\w*''))'}])
  try
    cursor(3, 2)
    linkedediting.RangesSet(bnr, [OneLineRange(2, 1, 4), OneLineRange(3, 2, 5)], '')
    TypeAfterChanges('cwd', ["\<C-N>", "\<C-N>", "\<C-Y>"])
    var tag = getline(3)->matchstr('<\zs\w*')
    assert_match('^divi', tag)
    assert_equal($'</{tag}>', getline(4))
    assert_equal(2, closingTags->len())
    assert_notequal('d', closingTags[0])

    cursor(1, 9)
    linkedediting.RangesSet(bnr, [OneLineRange(0, 1, 4), OneLineRange(0, 8, 11)], '')
    TypeAfterChanges('cwd', ["\<C-N>", "\<C-N>", "\<C-Y>"])
    tag = getline(1)->matchstr('</\zs\w*')
    assert_match('^divi', tag)
    assert_equal($'<{tag}>x</{tag}>', getline(1))
  finally
    autocmd_delete([{group: 'TestLinkedPopup'}])
    &completeopt = save_completeopt
    LinkedEditingStop(srv)
  endtry
enddef

# Test that the language server is asked for the linked editing ranges when
# the cursor moves out of the linked ranges, which are then no longer linked,
# and not while it moves in them, and that the ranges are linked when the
# reply arrives.
def g:Test_LinkedEditing_CursorMoved()
  linkedediting.InitOnce()
  g:LspOptionsSet({linkedEditing: true})
  silent! edit XLinkedCursorMoved.txt
  setline(1, ['<div>x</div>'])
  var bnr = bufnr()
  try
    var lspserver = MakeAsyncReplyingLspServer([{
      ranges: [OneLineRange(0, 1, 4), OneLineRange(0, 8, 11)],
      wordPattern: '[a-z]+'
    }])
    lspserver.isLinkedEditingRangeProvider = true
    linkedediting.BufferInit(lspserver, bnr)
    cursor(1, 3)
    doautocmd CursorMoved
    g:WaitForAssert(() => assert_equal([[1, 2, 3], [1, 9, 3]],
				       LinkedRanges(bnr)))
    cursor(1, 4)
    doautocmd CursorMoved
    assert_equal({}, lspserver.supersedableRequests)
    assert_equal([[1, 2, 3], [1, 9, 3]], LinkedRanges(bnr))

    cursor(1, 6)
    doautocmd CursorMoved
    assert_equal([], LinkedRanges(bnr))
    assert_equal(1, lspserver.supersedableRequests->len())

    # Resetting the option stops linked editing
    cursor(1, 3)
    linkedediting.RangesSet(bnr, [OneLineRange(0, 1, 4), OneLineRange(0, 8, 11)], '')
    g:LspOptionsSet({linkedEditing: false})
    doautocmd CursorMoved
    assert_equal([], LinkedRanges(bnr))
    StopAsyncReplyingLspServer(lspserver, bnr)
  finally
    linkedediting.BufferDeInit(bnr)
    g:LspOptionsSet({linkedEditing: false})
    :%bw!
  endtry
enddef

# Test that linked editing is initialized for the language server that
# provides it, and that detaching the buffer from the language servers stops
# it.
def g:Test_LinkedEditing_InitAndDetach()
  linkedediting.InitOnce()
  g:LspOptionsSet({linkedEditing: true})
  try
    var sync = {textDocumentSync: {openClose: true, change: 1}}
    var srv1 = MakeCapsServer(sync, [])
    var srv2 = MakeCapsServer(sync->extendnew({linkedEditingRangeProvider: true}), [])
    :silent edit XLinkedInit.txt
    setline(1, ['<div>x</div>'])
    var bnr = bufnr()
    buf.BufLspServerSet(bnr, srv1)
    buf.BufLspServerSet(bnr, srv2)
    lsp.BufferInit(srv1.id, bnr)
    lsp.BufferInit(srv2.id, bnr)
    var Events = () => autocmd_get({group: 'LspLinkedEditing', bufnr: bnr})
			  ->mapnew((_, a) => a.event)->sort()
    assert_equal(['CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI',
		  'TextChangedP'], Events())
    cursor(1, 3)
    linkedediting.RangesSet(bnr, [OneLineRange(0, 1, 4), OneLineRange(0, 8, 11)], '')
    assert_equal(2, LinkedRanges(bnr)->len())

    lsp.RemoveFile(bnr)
    assert_equal([], Events())
    assert_equal([], LinkedRanges(bnr))
  finally
    g:LspOptionsSet({linkedEditing: false})
    :%bw!
  endtry
enddef

# Test that accepting a snippet completion item of a language server expands
# its snippet, and that the cursor goes to its tabstops.
def g:Test_Completion_ExpandsSnippet()
  silent! edit XCompletionSnippet.c
  setline(1, ['int n = pri'])
  var bnr = bufnr()
  var lspserver = MakeAsyncReplyingLspServer([])
  # Omni completion numbers its request like a synchronous one.
  job_stop(lspserver.job)
  lspserver.job = StartStubServerJob([{jsonrpc: '2.0',
    id: lspserver.nextSyncRpcId,
    result: {isIncomplete: false, items: [{
      label: 'printf', kind: 3, insertTextFormat: 2,
      textEdit: {range: {start: {line: 0, character: 8},
			 end: {line: 0, character: 11}},
		 newText: 'printf(${1:fmt}, ${2:args})$0'},
    }]}}])
  lspserver->extend({
    isCompletionProvider: true,
    isCompletionResolveProvider: false,
    completionLazyDoc: false,
    completionTriggerChars: [],
    featureEnabled: (_) => true,
  })
  var next = "\<Plug>(LspSnippetJumpNext)"
  try
    completion.OmniComplSet('c', true)
    completion.BufferInit(lspserver, bnr, 'c')
    setlocal completeopt=menuone,noinsert,noselect
    g:FeedOmniCompleteKeys("A\<C-X>\<C-O>\<C-N>\<C-Y>\"%d\"" .. next .. 'x'
			   .. next .. ";\<Esc>")
    assert_equal(['int n = printf("%d", x);'], getline(1, '$'))
    assert_false(g:LspSnippetJumpable(1))
  finally
    completion.OmniComplSet('c', false)
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
  endtry
enddef

# Test that accepting a completion item right after selecting it, before its
# resolve was sent, resolves it and waits for the reply to apply its
# additional text edits, without sending a synchronous request.
def g:Test_Completion_AcceptWaitsForResolve()
  silent! edit XCompletionAcceptResolve.c
  setline(1, ['/* main */', 'int n = pri'])
  var bnr = bufnr()
  var item = {label: 'printf', kind: 3, data: 1}
  var resolved = item->extendnew({additionalTextEdits: [{
    range: {start: {line: 0, character: 0}, end: {line: 0, character: 0}},
    newText: "#include <stdio.h>\n"}]})
  var lspserver = MakeTestLspServer([])
  lspserver->extend({
    running: true,
    ready: true,
    isCompletionProvider: true,
    isCompletionResolveProvider: true,
    completionLazyDoc: true,
    completionTriggerChars: [],
    featureEnabled: (_) => true,
  })
  # Omni completion numbers its request like a synchronous one, and Vim
  # numbers the other requests on a new channel from 1: the completion reply
  # is sent at once and the resolve reply a second later.
  var syncId = lspserver.nextSyncRpcId
  lspserver.job = StartSteppedStubServerJob([
    [{jsonrpc: '2.0', id: syncId, result: {isIncomplete: false, items: [item]}}],
    [{jsonrpc: '2.0', id: 1, result: resolved}]])
  buf.BufLspServerSet(bnr, lspserver)
  try
    completion.OmniComplSet('c', true)
    completion.BufferInit(lspserver, bnr, 'c')
    setlocal completeopt=menuone,noinsert,noselect
    cursor(2, 1)
    g:FeedOmniCompleteKeys("A\<C-X>\<C-O>\<C-N>\<C-Y>;\<Esc>")
    assert_equal(['#include <stdio.h>', '/* main */', 'int n = printf;'],
		 getline(1, '$'))
    # No synchronous resolve request was sent.
    assert_equal(syncId + 1, lspserver.nextSyncRpcId)
  finally
    completion.OmniComplSet('c', false)
    StopAsyncReplyingLspServer(lspserver, bnr)
    :%bw!
  endtry
enddef

# Only here to because the test runner needs it
def g:StartLangServer(): bool
  return true
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
