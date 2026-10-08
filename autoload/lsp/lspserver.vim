vim9script

# LSP server functions
#
# The functions to send request messages to the language server are in this
# file.
#
# Refer to https://microsoft.github.io/language-server-protocol/specification
# for the Language Server Protocol (LSP) specificaiton.

import './options.vim' as opt
import './handlers.vim'
import './util.vim'
import './capabilities.vim'
import './offset.vim'
import './diag.vim'
import './selection.vim'
import './symbol.vim'
import './outline.vim'
import './textedit.vim'
import './completion.vim'
import './hover.vim'
import './signature.vim'
import './codeaction.vim'
import './codelens.vim'
import './documentlink.vim'
import './callhierarchy.vim' as callhier
import './typehierarchy.vim' as typehier
import './inlayhints.vim'
import './semantichighlight.vim'
import './buffer.vim' as buf

const DIAG_PULL_DEBOUNCE_MSEC = 200
const LSP_ERROR_SERVER_CANCELLED = -32802

# LSP server standard output handler
# LSP responses from server handled by channel job in LSP mode
def Output_cb(lspserver: dict<any>, chan: channel, msg: any): void
  if lspserver.debug
    if msg->has_key('id')
      lspserver.traceLog($'Got request {msg->json_encode()}')
    else
      lspserver.traceLog($'Got notification {msg->json_encode()}')
    endif
  endif
  lspserver.data = msg
  lspserver.processMessage()
enddef

# LSP server error output handler
def Error_cb(lspserver: dict<any>, chan: channel, emsg: string): void
  lspserver.errorLog(emsg)
enddef

# LSP server exit callback
def Exit_cb(lspserver: dict<any>, job: job, status: number): void
  util.WarnMsg($'{strftime("%m/%d/%y %T")}: LSP server ({lspserver.name}) exited with status {status}')
  if lspserver.diagnosticPullTimer != -1
    timer_stop(lspserver.diagnosticPullTimer)
    lspserver.diagnosticPullTimer = -1
  endif
  ClearMap(lspserver.pendingPullBufnrs)
  lspserver.running = false
  lspserver.ready = false
enddef

# Remove all the items of "map", one of the typed maps of the server dict (see
# NewLspServer()), keeping its type.
def ClearMap(map: dict<any>)
  map->filter((_, _) => false)
enddef

# Start a LSP server
#
def StartServer(lspserver: dict<any>, bnr: number): number
  if lspserver.running
    util.WarnMsg($'LSP server "{lspserver.name}" is already running')
    return 0
  endif

  var cmd = [lspserver.path]
  cmd->extend(lspserver.args)

  var opts = {in_mode: 'lsp',
		out_mode: 'lsp',
		err_mode: 'raw',
		noblock: 1,
		out_cb: function(Output_cb, [lspserver]),
		err_cb: function(Error_cb, [lspserver]),
		exit_cb: function(Exit_cb, [lspserver])}

  lspserver.data = ''
  lspserver.caps = {}
  lspserver.omniCompletePending = false
  lspserver.completionLazyDoc = false
  lspserver.completionTriggerChars = []
  lspserver.signaturePopup = -1
  lspserver.supportsWorkDoneProgress = false
  lspserver.sawWorkDoneProgressEnd = false
  ClearMap(lspserver.workDoneProgressTokens)
  ClearMap(lspserver.pendingPullBufnrs)
  lspserver.diagnosticPullTimer = -1
  ClearMap(lspserver.supersedableRequests)
  # A new server process has no open documents
  ClearMap(lspserver.docBufnrs)

  var job = cmd->job_start(opts)
  if job->job_status() == 'fail'
    util.ErrMsg($'Failed to start LSP server {lspserver.path}')
    return 1
  endif

  # wait a little for the LSP server to start
  sleep 10m

  lspserver.job = job
  lspserver.running = true

  lspserver.initServer(bnr)

  return 0
enddef

# process the "initialize" method reply from the LSP server
# Result: InitializeResult
def ServerInitReply(lspserver: dict<any>, initResult: dict<any>,
                    initError: dict<any>): void
  # Handle initialization error
  if !initError->empty()
    util.ErrMsg($'LSP server initialization failed: {initError.message}')
    return
  endif

  if initResult->empty()
    return
  endif

  var caps: dict<any> = initResult.capabilities
  lspserver.caps = caps

  for [key, val] in initResult->items()
    if key == 'capabilities'
      continue
    endif

    lspserver.caps[$'~additionalInitResult_{key}'] = val
  endfor

  capabilities.ProcessServerCaps(lspserver, caps)

  if caps->has_key('completionProvider')
    lspserver.completionTriggerChars =
			caps.completionProvider->get('triggerCharacters', [])
    lspserver.completionLazyDoc =
			caps.completionProvider->get('resolveProvider', false)
  endif

  # send a "initialized" notification to server
  lspserver.sendInitializedNotif()
  # send any workspace configuration (optional)
  if !lspserver.workspaceConfig->empty()
    lspserver.sendWorkspaceConfig()
  endif
  lspserver.ready = true
  if exists($'#User#LspServerReady{lspserver.name}')
    exe $'doautocmd <nomodeline> User LspServerReady{lspserver.name}'
  endif
  # Used internally, and shouldn't be used by users
  if exists($'#LSPBufferAutocmds#User#LspServerReady_{lspserver.id}')
    exe $'doautocmd <nomodeline> LSPBufferAutocmds User LspServerReady_{lspserver.id}'
  endif

  # set the server debug trace level
  if lspserver.traceLevel != 'off'
    lspserver.setTrace(lspserver.traceLevel)
  endif

  # if the outline window is opened, then request the symbols for the current
  # buffer
  if outline.OutlineBufnr()->bufwinid() != -1
    lspserver.getDocSymbols(@%, true)
  endif

  # Update the inlay hints (if enabled)
  if opt.lspOptions.showInlayHints && (lspserver.isInlayHintProvider
				    || lspserver.isClangdInlayHintsProvider)
    inlayhints.LspInlayHintsUpdateNow(bufnr())
  endif
enddef

# Request: "initialize"
# Param: InitializeParams
def InitServer(lspserver: dict<any>, bnr: number)
  # interface 'InitializeParams'
  var initparams: dict<any> = {}
  initparams.processId = getpid()
  initparams.clientInfo = {
	name: 'Vim',
	version: v:versionlong->string(),
      }

  # Compute the rootpath (based on the directory of the buffer)
  var rootPath = ''
  var rootSearchFiles = lspserver.rootSearchFiles
  var bufDir = bnr->bufname()->fnamemodify(':p:h')
  if !rootSearchFiles->empty()
    rootPath = util.FindNearestRootDir(bufDir, rootSearchFiles)
  endif
  if rootPath->empty()
    var cwd = getcwd()

    # bufDir is within cwd
    var bufDirPrefix = bufDir[0 : cwd->strcharlen() - 1]
    if &fileignorecase
        ? bufDirPrefix ==? cwd
        : bufDirPrefix == cwd
      rootPath = cwd
    else
      rootPath = bufDir
    endif
  endif

  rootPath = rootPath->fnamemodify(':p')

  if util.IsIgnoredRoot(rootPath, opt.lspOptions.workspaceIgnoredPaths)
    rootPath = ''
  endif

  if rootPath->empty()
    lspserver.workspaceFolders = []
    initparams.rootPath = v:null
    initparams.rootUri = v:null
    initparams.workspaceFolders = []
  else
    lspserver.workspaceFolders = [rootPath]
    var rootUri = util.LspFileToUri(rootPath)
    initparams.rootPath = rootPath
    initparams.rootUri = rootUri
    initparams.workspaceFolders = [{
      name: rootPath->fnamemodify(':t'),
      uri: rootUri
    }]
  endif

  initparams.trace = 'off'
  initparams.capabilities = capabilities.GetClientCaps()
  if !lspserver.initializationOptions->empty()
    initparams.initializationOptions = lspserver.initializationOptions
  else
    initparams.initializationOptions = {}
  endif

  lspserver.rpcInitializeRequest = initparams

  lspserver.rpc_a('initialize', initparams, ServerInitReply)
enddef

# Send a "initialized" notification to the language server
def SendInitializedNotif(lspserver: dict<any>)
  # Notification: 'initialized'
  # Params: InitializedParams
  lspserver.sendNotification('initialized')
enddef

# Request: shutdown
# Param: void
def ShutdownServer(lspserver: dict<any>, resp_timeout: number = -1): void
  var opts = {}
  if resp_timeout != -1
    opts.timeout = resp_timeout
  endif
  lspserver.rpc('shutdown', v:null, opts)
  if lspserver.debug
    lspserver.traceLog($'Sent shutdown request with {resp_timeout}ms timeout')
  endif
enddef

# Send a 'exit' notification to the language server
def ExitServer(lspserver: dict<any>): void
  # Notification: 'exit'
  # Params: void
  lspserver.sendNotification('exit')
enddef

# Stop a LSP server
def StopServer(lspserver: dict<any>): number
  if !lspserver.running
    util.WarnMsg($'LSP server {lspserver.name} is not running')
    return 0
  endif

  # Send the shutdown request to the server
  lspserver.shutdownServer()

  # Notify the server to exit
  lspserver.exitServer()

  # Wait for the server to process the exit notification and exit for a
  # maximum of 2 seconds.
  var maxCount: number = 1000
  var job = lspserver.job
  while job->job_status() == 'run' && maxCount > 0
    sleep 2m
    maxCount -= 1
  endwhile

  if job->job_status() == 'run'
    job->job_stop()
  endif
  if lspserver.diagnosticPullTimer != -1
    timer_stop(lspserver.diagnosticPullTimer)
    lspserver.diagnosticPullTimer = -1
  endif
  ClearMap(lspserver.pendingPullBufnrs)
  lspserver.running = false
  lspserver.ready = false
  return 0
enddef

# Set the language server trace level using the '$/setTrace' notification.
# Supported values for "traceVal" are "off", "messages" and "verbose".
def SetTrace(lspserver: dict<any>, traceVal: string)
  # Notification: '$/setTrace'
  # Params: SetTraceParams
  var params = {value: traceVal}
  lspserver.sendNotification('$/setTrace', params)
enddef

# Log a debug message to the LSP server debug file
def TraceLog(lspserver: dict<any>, msg: string)
  if lspserver.debug
    util.TraceLog(lspserver.logfile, false, msg)
  endif
enddef

# Log an error message to the LSP server error file
def ErrorLog(lspserver: dict<any>, errmsg: string)
  if lspserver.debug
    util.TraceLog(lspserver.errfile, true, errmsg)
  endif
enddef

# create a LSP server response message
def CreateResponse(lspserver: dict<any>, req_id: any): dict<any>
  var resp = {
    jsonrpc: '2.0',
    id: req_id
  }
  return resp
enddef

# create a LSP server notification message
def CreateNotification(lspserver: dict<any>, notif: string): dict<any>
  var req = {
    jsonrpc: '2.0',
    method: notif,
    params: {}
  }

  return req
enddef

# send a response message to the server
def SendResponse(lspserver: dict<any>, request: dict<any>, result: any, error: dict<any>)
  var reqid = request.id
  var idType = reqid->type()
  if idType != v:t_string && idType != v:t_number
    util.ErrMsg($'request.id ({reqid->string()}) of response to LSP server must be a number or a string')
    return
  endif
  var resp: dict<any> = lspserver.createResponse(reqid)
  if error->empty()
    resp.result = result
  else
    resp.error = error
  endif
  lspserver.sendMessage(resp)
enddef

# Send a message to LSP server without callback support
def SendMessage(lspserver: dict<any>, content: dict<any>): void
  var job = lspserver.job
  if job->job_status() != 'run'
    # LSP server has exited
    return
  endif
  if content->has_key('id') && content.id->type() == v:t_string
    SendRawMessage(job, content)
  else
    job->ch_sendexpr(content)
  endif
  if lspserver.debug
    if content->has_key('id')
      lspserver.traceLog($'Sent response {content->json_encode()}')
    else
      lspserver.traceLog($'Sent notification {content->json_encode()}')
    endif
  endif
enddef

def SendRawMessage(job: job, content: dict<any>): void
  var body = content->json_encode()
  var rawmsg = $"Content-Length: {body->len()}\r\n\r\n{body}"
  job->job_getchannel()->ch_sendraw(rawmsg)
enddef

# Send a notification message to the language server
def SendNotification(lspserver: dict<any>, method: string, params: any = {})
  var notif: dict<any> = CreateNotification(lspserver, method)
  notif.params->extend(params)
  lspserver.sendMessage(notif)
enddef

# Ask the language server to cancel the request with the ID "id".  The server
# still replies to the request.
# Notification: $/cancelRequest
# Params: CancelParams
def CancelRequest(lspserver: dict<any>, id: number)
  lspserver.sendNotification('$/cancelRequest', {id: id})
enddef

const LSP_ERROR_REQUEST_CANCELLED = -32800
const LSP_ERROR_CONTENT_MODIFIED = -32801

const lsp_errmsg_map: dict<string> = {
  -32001: 'UnknownErrorCode',
  -32002: 'ServerNotInitialized',
  -32600: 'InvalidRequest',
  -32601: 'MethodNotFound',
  -32602: 'InvalidParams',
  -32603: 'InternalError',
  -32700: 'ParseError',
  -32800: 'RequestCancelled',
  -32801: 'ContentModified',
  -32802: 'ServerCancelled',
  -32803: 'RequestFailed'
}

# Translate an LSP error code into a readable string
def LspGetErrorMessage(errcode: number): string
  return lsp_errmsg_map->get(errcode, errcode->string())
enddef

# Returns true when "responseError" says that the request has no result
# without having failed: it was cancelled, by the client or by the server, or
# the content that it was about was modified (ContentModified).
def IsStaleRequestError(responseError: dict<any>): bool
  var code = responseError->get('code', 0)
  return code == LSP_ERROR_REQUEST_CANCELLED
	|| code == LSP_ERROR_CONTENT_MODIFIED
	|| code == LSP_ERROR_SERVER_CANCELLED
enddef

# Process a LSP server response error and display an error message.  The error
# from a cancelled request, or from a request about modified content, is not
# reported.
def ProcessLspServerError(method: string, responseError: dict<any>)
  if IsStaleRequestError(responseError)
    return
  endif

  var emsg: string = responseError.message
  emsg ..= $', error = {LspGetErrorMessage(responseError.code)}'
  if responseError->has_key('data')
    emsg ..= $', data = {responseError.data->string()}'
  endif
  util.ErrMsg($'request {method} failed ({emsg})')
enddef

# Requests about a document whose reply can hold positions or edits in other
# documents.  The changes to all the documents open on the server are sent
# before them, like before the requests that don't name a document (e.g.
# "workspace/symbol" or "callHierarchy/incomingCalls").
const CROSS_DOCUMENT_REQUESTS: dict<bool> = {
  'textDocument/codeAction': true,
  'textDocument/declaration': true,
  'textDocument/definition': true,
  'textDocument/implementation': true,
  'textDocument/references': true,
  'textDocument/rename': true,
  'textDocument/typeDefinition': true
}

# Returns the URI of the document named by the "params" of a request, or an
# empty string when it doesn't name one.
def RequestDocumentUri(params: any): string
  if params->type() != v:t_dict
    return ''
  endif
  var textDocument: any = params->get('textDocument', {})
  if textDocument->type() != v:t_dict
    return ''
  endif
  var uri: any = textDocument->get('uri', '')
  return uri->type() == v:t_string ? uri : ''
enddef

# Send the changes made to the open documents "docBufnrs" (buffer numbers by
# URI) that Vim hasn't passed to the listeners yet, so that the request
# "method" with "params" is answered for the current text.  Vim invokes the
# listeners only before redrawing, which a mapping, an autocmd or a script
# making a request right after a change doesn't do.  Only the changes to the
# document that the request names are sent, unless it names no open document
# or its reply can depend on other documents (see CROSS_DOCUMENT_REQUESTS):
# requests are made on most keystrokes and cursor moves, so they must not
# take time proportional to the number of open documents.
def SendPendingChanges(docBufnrs: dict<number>, method: string, params: any)
  var uri = RequestDocumentUri(params)
  var bufnrs: list<number>
  if docBufnrs->has_key(uri) && !CROSS_DOCUMENT_REQUESTS->has_key(method)
    bufnrs = [docBufnrs[uri]]
  else
    bufnrs = docBufnrs->values()
  endif
  for bnr in bufnrs
    if bnr->bufloaded()
      bnr->listener_flush()
    endif
  endfor
enddef

# The ID of the first synchronous request to a language server.  Vim numbers
# the requests sent with ch_sendexpr() from 1, so synchronous requests, which
# are numbered by the plugin, use a range of their own.
const SYNC_RPC_FIRST_ID = 1000000000

# Send a sync RPC request message to the LSP server and return the received
# reply.  In case of an error, an empty Dict is returned, unless
# "opts.handleError" is false: then the caller handles the error, which is not
# reported, and the reply with the "error" is returned.
#
# ch_evalexpr() isn't used: while waiting for the reply, Vim invokes the
# channel callback for the other messages from the server, and in the "lsp"
# mode it can pass it the awaited reply too.  ch_evalexpr() then times out.
# So the request has an ID chosen here, the reply is waited for with
# ch_read(), and a reply that the channel callback gets is passed back through
# "lspserver.syncRpcReplies" (see handlers.ProcessMessage()).
#
# When the wait ends without a reply, because it timed out or CTRL-C
# interrupted it, the request is cancelled.  The interrupt is not caught.
def Rpc(lspserver: dict<any>, method: string, params: any, opts: dict<any> = {}): dict<any>
  var job = lspserver.job
  if job->job_status() != 'run'
    # LSP server has exited
    return {}
  endif

  SendPendingChanges(lspserver.docBufnrs, method, params)

  var id = lspserver.nextSyncRpcId
  lspserver.nextSyncRpcId += 1
  var req = {
    id: id,
    method: method,
    params: params
  }

  # Wait for the reply as long as ch_evalexpr() would
  var timeout: number = opts->get('timeout',
				  job->job_getchannel()->ch_info().out_timeout)

  var reply: dict<any> = {}
  lspserver.syncRpcReplies[id] = {}
  try
    job->ch_sendexpr(req)
    if lspserver.debug
      lspserver.traceLog($'Sent request {req->json_encode()}')
    endif

    var start = reltime()
    while job->job_status() == 'run'
      var msg: any = job->ch_read({id: id, timeout: 10})
      if msg->type() == v:t_dict
	reply = msg
	break
      endif
      if !lspserver.syncRpcReplies[id]->empty()
	reply = lspserver.syncRpcReplies[id]
	break
      endif
      if start->reltime()->reltimefloat() * 1000 >= timeout
	break
      endif
    endwhile
  finally
    lspserver.syncRpcReplies->remove(id)
    if reply->empty()
      lspserver.cancelRequest(id)
    endif
  endtry

  if lspserver.debug
    lspserver.traceLog($'Got response {reply->json_encode()}')
  endif

  if reply->has_key('result')
    # successful reply
    return reply
  endif

  if reply->has_key('error')
    if !opts->get('handleError', true)
      return reply
    endif
    ProcessLspServerError(method, reply.error)
  endif

  return {}
enddef

# LSP server asynchronous RPC callback.  When "handleError" is false, an error
# is not reported and "RpcCb" gets it, also for a stale request.
def AsyncRpcCb(lspserver: dict<any>, method: string, RpcCb: func,
	       handleError: bool, chan: channel, reply: dict<any>)
  if lspserver.debug
    lspserver.traceLog($'Got response {reply->json_encode()}')
  endif

  var result: any = v:null
  var error: dict<any> = {}

  if !reply->empty()
    if reply->has_key('error')
      if !handleError
	error = reply.error
      elseif !IsStaleRequestError(reply.error)
	# A stale request has no result, and that is not an error
	error = reply.error
	ProcessLspServerError(method, error)
      endif
    elseif !reply->has_key('result')
      # No result and no error is itself an error
      error = {
        code: -32603,
        message: 'Internal error',
        data: $'request {method} failed (no result)'
      }
      if handleError
	util.ErrMsg($'request {method} failed (no result)')
      endif
    elseif reply.result != v:null
      # Success case
      result = reply.result
    endif
  endif

  # Pass both result AND error to callback
  try
    RpcCb(lspserver, result, error)
  catch
    # backwards compatibility for old callback signature
    var retry: bool = false
    if v:exception =~# '\v:(E118):'
      if exists_compiled('v:stacktrace')
	retry = expand('<script>:p') == v:stacktrace[-1]['filepath']
      else
	retry = v:throwpoint =~# 'AsyncRpcCb,\s\+line\s\+\d'
      endif
    endif
    if retry
      try
        RpcCb(lspserver, result)
      catch
        lspserver.errorLog($'Callback for {method} raised exception: {v:exception}')
      endtry
    else
      lspserver.errorLog($'Callback for {method} raised exception: {v:exception}')
    endif
  endtry
enddef

# Send an async RPC request message to the LSP server with a callback function.
# Returns the LSP message id.  This id can be used to cancel the RPC request
# (if needed).  Returns -1 on error, and then the callback is not invoked.
# In case of an error reply, the error is reported and the callback gets it,
# unless "opts.handleError" is false: then the error is not reported, and the
# callback gets it also when the request is stale (see IsStaleRequestError()).
def AsyncRpc(lspserver: dict<any>, method: string, params: any, Cbfunc: func,
	     opts: dict<any> = {}): number
  var req = {
    method: method,
    params: params
  }

  var job = lspserver.job
  if job->job_status() != 'run'
    # LSP server has exited
    return -1
  endif

  SendPendingChanges(lspserver.docBufnrs, method, params)

  # Do the asynchronous RPC call
  var Fn = function('AsyncRpcCb', [lspserver, method, Cbfunc,
				   opts->get('handleError', true)])

  if get(g:, 'LSPTest')
    # When running LSP tests, make this a synchronous RPC call
    var id = lspserver.nextSyncRpcId
    Fn(test_null_channel(), Rpc(lspserver, method, params, {handleError: false}))
    return id
  endif

  # Otherwise, make an asynchronous RPC call
  var reply = job->ch_sendexpr(req, {callback: Fn})
  if reply->empty()
    return -1
  endif

  if lspserver.debug
    var logreq = {id: reply.id}->extend(req)
    lspserver.traceLog($'Sent request {logreq->json_encode()}')
  endif

  return reply.id
enddef

# Cancel the pending request sent with AsyncRpcSupersede() with "key", if any,
# and ignore its reply.
def CancelSupersedableRequest(lspserver: dict<any>, key: string)
  var req: dict<number> = lspserver.supersedableRequests->get(key, {})
  if req->empty()
    return
  endif
  lspserver.supersedableRequests->remove(key)
  if req.id > 0
    lspserver.cancelRequest(req.id)
  endif
enddef

# Send an async RPC request message to the LSP server with a callback
# function, like AsyncRpc().  The request supersedes the previous request sent
# with the same "key": when that one is still pending, it is cancelled and its
# reply is ignored.  Returns the LSP message id, or -1 on error.
def AsyncRpcSupersede(lspserver: dict<any>, key: string, method: string,
		      params: any, Cbfunc: func, opts: dict<any> = {}): number
  CancelSupersedableRequest(lspserver, key)

  # The callback identifies its request by this Dict and not by the message
  # id, because in tests the callback is invoked before AsyncRpc() returns.
  var req: dict<number> = {id: -1}
  lspserver.supersedableRequests[key] = req
  var id = lspserver.rpc_a(method, params, (_: dict<any>, reply, error) => {
    if lspserver.supersedableRequests->get(key, {}) isnot req
      return
    endif
    lspserver.supersedableRequests->remove(key)
    Cbfunc(lspserver, reply, error)
  }, opts)
  if lspserver.supersedableRequests->get(key, {}) is req
    req.id = id
  endif
  return id
enddef

# Cancel the pending requests about buffer "bnr" sent with AsyncRpcSupersede()
# (their key ends with the buffer number), and ignore their replies.
def CancelBufferRequests(lspserver: dict<any>, bnr: number)
  for [key, req] in lspserver.supersedableRequests->items()
    if key =~# $' {bnr}$'
      lspserver.supersedableRequests->remove(key)
      if req.id > 0
	lspserver.cancelRequest(req.id)
      endif
    endif
  endfor
enddef

# Send an async RPC request message to the LSP server like
# AsyncRpcSupersede(), about the editor state in "reqctx" (see
# util.RequestContextGet()).  The reply is passed to "Cbfunc" only when that
# state did not change, otherwise the user moved on and it is dropped.
def AsyncRpcInContext(lspserver: dict<any>, reqctx: dict<number>, key: string,
		      method: string, params: any, Cbfunc: func,
		      opts: dict<any> = {}): number
  return AsyncRpcSupersede(lspserver, key, method, params,
			   (_: dict<any>, reply: any, error: dict<any>) => {
    if util.RequestContextMatches(reqctx)
      Cbfunc(lspserver, reply, error)
    endif
  }, opts)
enddef

# Returns true when the "lspserver" has "feature" enabled.
# By default, all the features of a lsp server are enabled.
def FeatureEnabled(lspserver: dict<any>, feature: string): bool
  return lspserver.features->get(feature, true)
enddef

# Retrieve the Workspace configuration asked by the server.
# Request: workspace/configuration
def WorkspaceConfigGet(lspserver: dict<any>, configItem: dict<any>): dict<any>
  if lspserver.workspaceConfig->empty()
    return {}
  endif
  if !configItem->has_key('section') || configItem.section->empty()
    return lspserver.workspaceConfig
  endif
  var config: dict<any> = lspserver.workspaceConfig
  for part in configItem.section->split('\.')
    if !config->has_key(part)
      return {}
    endif
    config = config[part]
  endfor
  return config
enddef

# Update semantic highlighting for buffer "bnr"
# Request: textDocument/semanticTokens/full or
#	   textDocument/semanticTokens/full/delta
def SemanticHighlightUpdate(lspserver: dict<any>, bnr: number)
  if !lspserver.isSemanticTokensProvider
    return
  endif

  # Capture the current changedtick
  var requestTick = getbufvar(bnr, 'changedtick')

  var method = 'textDocument/semanticTokens/full'
  var params: dict<any> = {
    textDocument: {
      uri: util.LspBufnrToUri(bnr)
    }
  }

  # Should we send a semantic tokens delta request instead of a full request?
  if lspserver.semanticTokensDelta
    var prevResultId: string = ''
    prevResultId = bnr->getbufvar('LspSemanticResultId', '')
    if prevResultId != ''
      # semantic tokens delta request
      params.previousResultId = prevResultId
      method ..= '/delta'
    endif
  endif

  AsyncRpcSupersede(lspserver, $'textDocument/semanticTokens {bnr}', method,
		    params, (_: dict<any>, reply, error) => {
    semantichighlight.UpdateTokens(lspserver, reply, error, bnr, requestTick)
  })
enddef

# Send a "workspace/didChangeConfiguration" notification to the language
# server.
def SendWorkspaceConfig(lspserver: dict<any>)
  # Params: DidChangeConfigurationParams
  var params = {settings: lspserver.workspaceConfig}
  lspserver.sendNotification('workspace/didChangeConfiguration', params)
enddef

# Returns the text of a document with "lines", ending with a newline when
# "hasEol" is true and there are lines.
def LinesText(lines: list<string>, hasEol: bool): string
  var text = lines->join("\n")
  if hasEol && !lines->empty()
    text ..= "\n"
  endif
  return text
enddef

# Returns the lines of the document of buffer "bnr", none when the buffer has
# no text.
def BufferLines(bnr: number): list<string>
  return util.BufIsEmpty(bnr) ? [] : bnr->getbufline(1, '$')
enddef

# Returns the text of the document of buffer "bnr".
def BufferText(bnr: number): string
  return LinesText(BufferLines(bnr), util.BufWritesEol(bnr))
enddef

def HunkText(newBufLines: list<string>, hunk: dict<number>, hasEol: bool): string
  if hunk.to_count == 0
    return ''
  endif

  var lastIdx = hunk.to_idx + hunk.to_count - 1
  var text = newBufLines[hunk.to_idx : lastIdx]->join("\n")
  # Append a newline when there is more buffer content after this hunk (so
  # the replaced range boundary falls between lines), or when the document
  # ends with a newline and this hunk reaches the last line.
  if lastIdx < newBufLines->len() - 1 || hasEol
    text ..= "\n"
  endif
  return text
enddef

# Send a file/document opened notification to the language server.
def TextdocDidOpen(lspserver: dict<any>, bnr: number, ftype: string): void
  # Notification: 'textDocument/didOpen'
  # Params: DidOpenTextDocumentParams

  var languageId: string = ftype

  if type(lspserver.languageId) == v:t_func
    try
      languageId = lspserver.languageId()
    catch /^Vim\%((\S\+)\)\=:E/
    endtry
  endif

  var uri = util.LspBufnrToUri(bnr)
  var newBufLines = BufferLines(bnr)
  var hasEol = util.BufWritesEol(bnr)
  lspserver.docBufnrs[uri] = bnr
  lspserver.cachedBufferContent[bnr] = newBufLines
  lspserver.cachedBufferEol[bnr] = hasEol
  # Use Vim 'changedtick' as the LSP document version number
  var version: number = bnr->getbufvar('changedtick')
  lspserver.docVersions[bnr] = version

  if !lspserver.supportsDidOpenClose
    return
  endif

  var params = {
    textDocument: {
      uri: uri,
      languageId: languageId,
      version: version,
      text: LinesText(newBufLines, hasEol)
    }
  }
  lspserver.sendNotification('textDocument/didOpen', params)
enddef

# Send a file/document closed notification to the language server.
def TextdocDidClose(lspserver: dict<any>, bnr: number): void
  # Notification: 'textDocument/didClose'
  # Params: DidCloseTextDocumentParams

  # A reply about the closed document is of no use
  CancelBufferRequests(lspserver, bnr)

  var params = {
    textDocument: {
      uri: util.LspBufnrToUri(bnr)
    }
  }
  if lspserver.supportsDidOpenClose
    lspserver.sendNotification('textDocument/didClose', params)
  endif
  # By buffer number, as the buffer may have been renamed since it was opened
  lspserver.docBufnrs->filter((_, docBnr) => docBnr != bnr)
  if lspserver.cachedBufferContent->has_key(bnr)
    lspserver.cachedBufferContent->remove(bnr)
  endif
  if lspserver.cachedBufferEol->has_key(bnr)
    lspserver.cachedBufferEol->remove(bnr)
  endif
  if lspserver.docVersions->has_key(bnr)
    lspserver.docVersions->remove(bnr)
  endif
  if lspserver.diagnosticResultIds->has_key(bnr)
    lspserver.diagnosticResultIds->remove(bnr)
  endif
  if lspserver.pendingPullBufnrs->has_key(bnr)
    lspserver.pendingPullBufnrs->remove(bnr)
  endif
enddef

def RestartDiagnosticPullTimer(lspserver: dict<any>)
  if lspserver.diagnosticPullTimer != -1
    timer_stop(lspserver.diagnosticPullTimer)
  endif
  lspserver.diagnosticPullTimer = timer_start(
    DIAG_PULL_DEBOUNCE_MSEC,
    function(FlushQueuedDiagnosticsPull, [lspserver])
  )
enddef

def QueuePullDiagnostics(lspserver: dict<any>, bnr: number)
  if !lspserver.running || !lspserver.ready || !lspserver.isDiagnosticsProvider
    return
  endif

  if bnr->bufloaded() == 0 || buf.BufLspServerGetById(bnr, lspserver.id)->empty()
    return
  endif

  lspserver.pendingPullBufnrs[bnr] = true
  RestartDiagnosticPullTimer(lspserver)
enddef

def QueuePullDiagnosticsAllBuffers(lspserver: dict<any>)
  if !lspserver.running || !lspserver.ready || !lspserver.isDiagnosticsProvider
    return
  endif

  for bnr in lspserver.docBufnrs->values()
    if bnr->bufloaded() == 1
      lspserver.pendingPullBufnrs[bnr] = true
    endif
  endfor

  if lspserver.pendingPullBufnrs->empty()
    return
  endif

  RestartDiagnosticPullTimer(lspserver)
enddef

def FlushQueuedDiagnosticsPull(lspserver: dict<any>, _timerid: number)
  lspserver.diagnosticPullTimer = -1
  if !lspserver.running || !lspserver.ready || !lspserver.isDiagnosticsProvider
    ClearMap(lspserver.pendingPullBufnrs)
    return
  endif

  var bufs = lspserver.pendingPullBufnrs->keys()->map((_, k) => str2nr(k))
  ClearMap(lspserver.pendingPullBufnrs)

  for bnr in bufs
    if bnr->bufloaded() == 0 || buf.BufLspServerGetById(bnr, lspserver.id)->empty()
      continue
    endif
    lspserver.pullDiagnostics(bnr)
  endfor
enddef

# Pull diagnostics for a document.
# Request: "textDocument/diagnostic"
# Param: DocumentDiagnosticParams
def PullDiagnostics(lspserver: dict<any>, bnr: number)
  if !lspserver.isDiagnosticsProvider
    util.ErrMsg('LSP server does not support pull diagnostics')
    return
  endif

  var uri = util.LspBufnrToUri(bnr)
  var params: dict<any> = {
    textDocument: {
      uri: uri
    }
  }

  var prevResultId = lspserver.diagnosticResultIds->get(bnr, '')
  if prevResultId != ''
    params.previousResultId = prevResultId
  endif

  AsyncRpcSupersede(lspserver, $'textDocument/diagnostic {bnr}',
		    'textDocument/diagnostic', params,
		    (_: dict<any>, result: any, error: dict<any>) => {
    PullDiagnosticsReply(lspserver, bnr, uri, result, error)
  }, {handleError: false})
enddef

# Process the reply to the "textDocument/diagnostic" request for the document
# "uri" in buffer "bnr".
# Result: DocumentDiagnosticReport | null
def PullDiagnosticsReply(lspserver: dict<any>, bnr: number, uri: string,
			 result: any, error: dict<any>)
  if !bnr->bufloaded() || buf.BufLspServerGetById(bnr, lspserver.id)->empty()
    # The document was closed
    return
  endif

  # If the language server cancels the pull diagnostic request and asks for a
  # retrigger, or the content was modified, then send the pull diagnostic
  # request again.
  if !error->empty()
    var errorCode = error->get('code', 0)
    var errorData = error->get('data', {})
    if errorCode == LSP_ERROR_CONTENT_MODIFIED
        || (errorCode == LSP_ERROR_SERVER_CANCELLED
          && errorData->type() == v:t_dict
          && errorData->get('retriggerRequest', false))
      lspserver.queuePullDiagnostics(bnr)
    else
      ProcessLspServerError('textDocument/diagnostic', error)
    endif
    return
  endif

  if result->type() != v:t_dict || result->empty()
    return
  endif

  var report: dict<any> = result
  var reportKind = report->get('kind', '')

  if reportKind == 'full'
    var items = report->get('items', [])
    var waitForInitialProgress = lspserver.supportsWorkDoneProgress
      && !lspserver.sawWorkDoneProgressEnd
    if items->empty() && waitForInitialProgress
      return
    endif
    diag.DiagNotification(lspserver, uri, items, 'pull')
  elseif reportKind != 'unchanged'
    util.WarnMsg($'Unsupported diagnostic report kind "{reportKind}"')
  endif

  if report->has_key('resultId')
    lspserver.diagnosticResultIds[bnr] = report.resultId
  elseif reportKind == 'full' && lspserver.diagnosticResultIds->has_key(bnr)
    lspserver.diagnosticResultIds->remove(bnr)
  endif
enddef

# Send a file/document change notification to the language server.
# Params: DidChangeTextDocumentParams
def TextdocDidChange(lspserver: dict<any>, bnr: number): void
  # Notification: 'textDocument/didChange'
  # Params: DidChangeTextDocumentParams

  # Nothing to do when the server doesn't want change notifications.
  var textDocumentSync = lspserver.textDocumentSync
  if textDocumentSync == 0
    return
  endif

  var contentChanges: list<dict<any>>
  var hasEol = util.BufWritesEol(bnr)
  var newBufLines = BufferLines(bnr)
  var cachedBufferContent = lspserver.cachedBufferContent
  var cachedBufferEol = lspserver.cachedBufferEol

  if textDocumentSync == 1 || !opt.lspOptions.incrementalSync
    # TextDocumentSyncKind: Full — send the entire buffer on every change.
    # A change that leaves the text as it was, which Vim also passes to the
    # listeners, is not sent: the version of the document then stays that
    # of its text.
    if !cachedBufferContent->has_key(bnr)
	|| cachedBufferContent[bnr] != newBufLines
	|| cachedBufferEol->get(bnr, !hasEol) != hasEol
      contentChanges = [{text: LinesText(newBufLines, hasEol)}]
    endif
  elseif exists_compiled('*diff')
    # TextDocumentSyncKind: Incremental — send only the changed lines.
    if cachedBufferContent->has_key(bnr)
	&& cachedBufferEol[bnr] == hasEol
	&& cachedBufferContent[bnr]->empty() == newBufLines->empty()
      # Compute line-level diffs against the last snapshot and convert each
      # hunk into an LSP TextDocumentContentChangeEvent.  Hunks are emitted
      # bottom-up: the LSP spec applies contentChanges entries sequentially,
      # so a top-down hunk's range would be interpreted against a document
      # already shifted by an earlier hunk in the same notification.
      contentChanges = []
      var oldBufLines = cachedBufferContent[bnr]
      var oldLineCount = oldBufLines->len()
      var diffs = diff(oldBufLines, newBufLines, {output: 'indices'})
      for hunk in diffs->copy()->reverse()
	var startLine = hunk.from_idx
	var startChar = 0
	var endLine = hunk.from_idx + hunk.from_count
	var endChar = 0
	var text = HunkText(newBufLines, hunk, hasEol)
	if !hasEol && endLine == oldLineCount
	  # The old document has no trailing newline, so
	  # {line: oldLineCount, character: 0} isn't a valid position in it;
	  # anchor to the end of the last line instead.  When the hunk
	  # doesn't start at the first line, pull the start back over the
	  # newline that precedes it too, so that line's break is removed.
	  endLine = oldLineCount - 1
	  endChar = offset.EncodedLineLen(lspserver, oldBufLines[endLine])
	  if startLine > 0
	    startLine -= 1
	    startChar = offset.EncodedLineLen(lspserver, oldBufLines[startLine])
	    if hunk.to_count > 0
	      text = "\n" .. text
	    endif
	  endif
	endif
	contentChanges->add({
	  range: {
	    start: {line: startLine, character: startChar},
	    end:   {line: endLine, character: endChar}
	  },
	  text: text
	})
      endfor
    else
      # No cached snapshot available, or its line-ending state doesn't
      # match the current buffer, or only one of them has no text (the
      # old-document end-of-file math above would be wrong); fall back to a
      # full-text change.
      contentChanges = [{text: LinesText(newBufLines, hasEol)}]
    endif
  endif
  cachedBufferContent[bnr] = newBufLines
  cachedBufferEol[bnr] = hasEol

  if contentChanges->empty()
    return
  endif

  var params = {
    textDocument: {
      uri: util.LspBufnrToUri(bnr),
      version: NextDocVersion(lspserver, bnr)
    },
    contentChanges: contentChanges
  }
  lspserver.sendNotification('textDocument/didChange', params)
enddef

# Returns the version of the next change to the document of buffer "bnr" and
# records it.  That is Vim's 'changedtick', or one more than the previous
# version when 'changedtick' didn't change (e.g. when setting 'endofline'
# removed the newline at the end of the document), as the version of a
# document must increase with every change.
def NextDocVersion(lspserver: dict<any>, bnr: number): number
  var version: number = [bnr->getbufvar('changedtick'),
			 lspserver.docVersions->get(bnr, 0) + 1]->max()
  lspserver.docVersions[bnr] = version
  return version
enddef

# Send a change notification for buffer "bnr" when setting 'endofline',
# 'fixendofline' or 'binary' added or removed the newline at the end of its
# document.  That changes neither a line nor 'changedtick', so the listener
# doesn't see it.
def TextdocEolChanged(lspserver: dict<any>, bnr: number): void
  var cachedBufferEol = lspserver.cachedBufferEol
  if !cachedBufferEol->has_key(bnr)
      || cachedBufferEol[bnr] == util.BufWritesEol(bnr)
    return
  endif
  TextdocDidChange(lspserver, bnr)
enddef

# Return the current cursor position as a LSP position.
# find_ident will search for a identifier in front of the cursor, just like
# CTRL-] and c_CTRL-R_CTRL-W does.
#
# LSP line and column numbers start from zero, whereas Vim line and column
# numbers start from one. The LSP column number is the character index in the
# line and not the byte index in the line.
def GetPosition(lspserver: dict<any>, find_ident: bool): dict<number>
  var lnum: number = line('.') - 1
  var col: number = charcol('.') - 1
  var line = getline('.')

  if find_ident
    # 1. skip to start of identifier
    while line[col] != '' && line[col] !~ '\k'
      col = col + 1
    endwhile

    # 2. back up to start of identifier
    while col > 0 && line[col - 1] =~ '\k'
      col = col - 1
    endwhile
  endif

  # Compute character index counting composing characters as separate
  # characters
  var pos = {line: lnum, character: util.GetCharIdxWithCompChar(line, col)}
  lspserver.encodePosition(bufnr(), pos)

  return pos
enddef

# Return the current file name and current cursor position as a LSP
# TextDocumentPositionParams structure
def GetTextDocPosition(lspserver: dict<any>, find_ident: bool): dict<dict<any>>
  # interface TextDocumentIdentifier
  # interface Position
  return {textDocument: {uri: util.LspFileToUri(@%)},
	  position: lspserver.getPosition(find_ident)}
enddef

# Get a list of completion items.
# Request: "textDocument/completion"
# Param: CompletionParams
def GetCompletion(lspserver: dict<any>, triggerKind_arg: number, triggerChar: string): void
  # Check whether LSP server supports completion
  if !lspserver.isCompletionProvider
    util.ErrMsg('LSP server does not support completion')
    return
  endif

  var fname = @%
  if fname->empty()
    return
  endif

  # interface CompletionParams
  #   interface TextDocumentPositionParams
  var params = lspserver.getTextDocPosition(false)
  #   interface CompletionContext
  params.context = {triggerKind: triggerKind_arg}
  if triggerKind_arg == 2 && !triggerChar->empty()
    params.context.triggerCharacter = triggerChar
  endif

  # CompletionReply() itself, not a lambda calling it: Vim checks the type of
  # every value of the reply each time it is passed to a function.
  AsyncRpcSupersede(lspserver, 'textDocument/completion',
		    'textDocument/completion', params,
		    completion.CompletionReply)
enddef

# Cancel the pending completion request, if any, and ignore its reply.
# Notification: $/cancelRequest
def CancelCompletion(lspserver: dict<any>)
  CancelSupersedableRequest(lspserver, 'textDocument/completion')
enddef

# Get lazy properties for a completion item.
# Request: "completionItem/resolve"
# Param: CompletionItem
def ResolveCompletion(lspserver: dict<any>, item: dict<any>, sync: bool = false): dict<any>
  # Check whether LSP server supports completion item resolve
  if !lspserver.isCompletionResolveProvider
    return {}
  endif

  # interface CompletionItem
  if sync
    var reply = lspserver.rpc('completionItem/resolve', item)
    if !reply->empty() && !reply.result->empty()
      return reply.result
    endif
  else
    AsyncRpcSupersede(lspserver, 'completionItem/resolve',
		      'completionItem/resolve', item,
		      completion.CompletionResolveReply)
  endif
  return {}
enddef

# Jump to or peek a symbol location.
#
# Send 'msg' to a LSP server and process the reply.  'msg' is one of the
# following:
#   textDocument/definition
#   textDocument/declaration
#   textDocument/typeDefinition
#   textDocument/implementation
#
# Process the LSP server reply and jump to the symbol location.  Before
# jumping to the symbol location, save the current cursor position in the tag
# stack.
#
# If 'peekSymbol' is true, then display the symbol location in the preview
# window but don't jump to the symbol location.
#
# Result: Location | Location[] | LocationLink[] | null
def GotoSymbolLoc(lspserver: dict<any>, msg: string, peekSymbol: bool,
		  cmdmods: string, count: number)
  var cword = expand('<cword>')
  var vcount = v:count
  AsyncRpcInContext(lspserver, util.RequestContextGet('cursor'), 'goto', msg,
		    lspserver.getTextDocPosition(true),
		    (_: dict<any>, result: any, error: dict<any>) => {
    GotoSymbolLocReply(lspserver, msg, peekSymbol, cmdmods, count, cword,
		       vcount, error->empty() ? result : null)
  }, {handleError: false})
enddef

# Process the reply "result" to the "msg" request sent by GotoSymbolLoc() for
# the word "cword" under the cursor, with "vcount" as v:count.
def GotoSymbolLocReply(lspserver: dict<any>, msg: string, peekSymbol: bool,
		       cmdmods: string, count: number, cword: string,
		       vcount: number, result: any)
  if result->empty()
    var emsg: string
    if msg == 'textDocument/declaration'
      emsg = 'symbol declaration is not found'
    elseif msg == 'textDocument/typeDefinition'
      emsg = 'symbol type definition is not found'
    elseif msg == 'textDocument/implementation'
      emsg = 'symbol implementation is not found'
    else
      if &tagfunc !=# 'lsp#lsp#TagFunc' && opt.lspOptions.definitionFallback
	emsg = 'symbol definition is not found; falling back to tags file'
	try
	  # Use :tjump instead of 'CTRL-]' using :tag because
	  # 'tjump' works better with multiple tags.
	  # Use commands as mappings close selection dialog immediately!
	  if peekSymbol
	    execute (vcount > 0 ? ':' .. vcount .. 'ptag' : 'ptjump') cword
	  else
	    execute (vcount > 0 ? ':' .. vcount .. 'tag' : 'tjump') cword
	  endif
	catch /^Vim\%((\a\+)\)\=:E42[36]/
	endtry
      else
	emsg = 'symbol definition is not found'
      endif
    endif

    util.WarnMsg(emsg)
    return
  endif

  var location: dict<any>
  if result->type() == v:t_list
    if count == 0
      # When there are multiple symbol locations, and a specific one isn't
      # requested with 'count', display the locations in a location list.
      if result->len() > 1
	var title: string = ''
	if msg == 'textDocument/declaration'
	  title = 'Declarations'
	elseif msg == 'textDocument/typeDefinition'
	  title = 'Type Definitions'
	elseif msg == 'textDocument/implementation'
	  title = 'Implementations'
	else
	  title = 'Definitions'
	endif

	if lspserver.needOffsetEncoding
	  # Decode the position encoding in all the symbol locations
	  result->map((_, loc) => {
	    lspserver.decodeLocation(loc)
	    return loc
	  })
	endif

	symbol.ShowLocations(lspserver, result, peekSymbol, title)
	return
      endif
    endif

    # Select the location requested in 'count'
    var idx = count - 1
    if idx >= result->len()
      idx = result->len() - 1
    endif
    location = result[idx]
  else
    location = result
  endif
  lspserver.decodeLocation(location)

  symbol.GotoSymbol(lspserver, location, peekSymbol, cmdmods)
enddef

# Request: "textDocument/definition"
# Param: DefinitionParams
def GotoDefinition(lspserver: dict<any>, peek: bool, cmdmods: string, count: number)
  # Check whether LSP server supports jumping to a definition
  if !lspserver.isDefinitionProvider
    util.ErrMsg('Jumping to a symbol definition is not supported')
    return
  endif

  # interface DefinitionParams
  #   interface TextDocumentPositionParams
  GotoSymbolLoc(lspserver, 'textDocument/definition', peek, cmdmods, count)
enddef

# Request: "textDocument/declaration"
# Param: DeclarationParams
def GotoDeclaration(lspserver: dict<any>, peek: bool, cmdmods: string, count: number)
  # Check whether LSP server supports jumping to a declaration
  if !lspserver.isDeclarationProvider
    util.ErrMsg('Jumping to a symbol declaration is not supported')
    return
  endif

  # interface DeclarationParams
  #   interface TextDocumentPositionParams
  GotoSymbolLoc(lspserver, 'textDocument/declaration', peek, cmdmods, count)
enddef

# Request: "textDocument/typeDefinition"
# Param: TypeDefinitionParams
def GotoTypeDef(lspserver: dict<any>, peek: bool, cmdmods: string, count: number)
  # Check whether LSP server supports jumping to a type definition
  if !lspserver.isTypeDefinitionProvider
    util.ErrMsg('Jumping to a symbol type definition is not supported')
    return
  endif

  # interface TypeDefinitionParams
  #   interface TextDocumentPositionParams
  GotoSymbolLoc(lspserver, 'textDocument/typeDefinition', peek, cmdmods, count)
enddef

# Request: "textDocument/implementation"
# Param: ImplementationParams
def GotoImplementation(lspserver: dict<any>, peek: bool, cmdmods: string, count: number)
  # Check whether LSP server supports jumping to a implementation
  if !lspserver.isImplementationProvider
    util.ErrMsg('Jumping to a symbol implementation is not supported')
    return
  endif

  # interface ImplementationParams
  #   interface TextDocumentPositionParams
  GotoSymbolLoc(lspserver, 'textDocument/implementation', peek, cmdmods, count)
enddef

# Request: "textDocument/switchSourceHeader"
# Param: TextDocumentIdentifier
# Clangd specific extension
def SwitchSourceHeader(lspserver: dict<any>)
  var param = {
    uri: util.LspFileToUri(@%)
  }
  AsyncRpcInContext(lspserver, util.RequestContextGet('window'),
		    'textDocument/switchSourceHeader',
		    'textDocument/switchSourceHeader', param,
		    (_: dict<any>, result: any, _) => {
    SwitchSourceHeaderReply(result)
  })
enddef

# process the 'textDocument/switchSourceHeader' reply from the LSP server
# Result: URI | null
def SwitchSourceHeaderReply(result: any)
  if result->empty()
    util.WarnMsg('Source/Header file is not found')
    return
  endif

  var fname = util.LspUriToFile(result)
  # TODO: Add support for cmd modifiers
  if (&modified && !&hidden) || &buftype != ''
    # if the current buffer has unsaved changes and 'hidden' is not set,
    # or if the current buffer is a special buffer, then ask to save changes
    exe $'confirm edit {fname->fnameescape()}'
  else
    exe $'edit {fname->fnameescape()}'
  endif
enddef

# get symbol signature help.
# Request: "textDocument/signatureHelp"
# Param: SignatureHelpParams
def ShowSignature(lspserver: dict<any>, triggerKind_arg: number = 1, triggerChar: string = ''): void
  # Check whether LSP server supports signature help
  if !lspserver.isSignatureHelpProvider
    util.ErrMsg('LSP server does not support signature help')
    return
  endif

  # interface SignatureHelpParams
  #   interface TextDocumentPositionParams
  var params = lspserver.getTextDocPosition(false)
  var reqctx: dict<number> = signature.SignatureRequestContextGet()
  params.context = signature.GetSignatureHelpContext(lspserver,
						     triggerKind_arg,
						     triggerChar)
  AsyncRpcSupersede(lspserver, 'textDocument/signatureHelp',
		    'textDocument/signatureHelp', params, (_: dict<any>, reply, error) => {
		signature.SignatureHelp(lspserver, reply, error, reqctx)
	})
enddef

# Tell the language server that buffer "bnr" is about to be written to its
# file, and apply the edits that the server asks to make to it before that.
# The buffer is written without the edits when the server doesn't reply in
# time.
def WillSaveFile(lspserver: dict<any>, bnr: number): void
  # Notification: 'textDocument/willSave'
  # Request: 'textDocument/willSaveWaitUntil'
  # Params: WillSaveTextDocumentParams
  # The reason is TextDocumentSaveReason.Manual: Vim writes a buffer only
  # when it is asked to.
  var params: dict<any> = {
    textDocument: {uri: util.LspBufnrToUri(bnr)},
    reason: 1
  }

  if lspserver.supportsWillSave
    lspserver.sendNotification('textDocument/willSave', params)
  endif

  # The edits can't be made to a buffer that is not modifiable
  if !lspserver.supportsWillSaveWaitUntil
      || !lspserver.featureEnabled('willSaveWaitUntil')
      || !bnr->getbufvar('&modifiable')
    return
  endif

  var reply = lspserver.rpc('textDocument/willSaveWaitUntil', params)

  # Result: TextEdit[] | null
  if reply->empty() || reply.result->empty()
    return
  endif

  if lspserver.needOffsetEncoding
    reply.result->map((_, textEdit) => {
      lspserver.decodeRange(bnr, textEdit.range)
      return textEdit
    })
  endif

  textedit.ApplyTextEdits(bnr, reply.result)
enddef

# Send a file/document saved notification to the language server
def DidSaveFile(lspserver: dict<any>, bnr: number): void
  # Check whether the LSP server supports the didSave notification
  if !lspserver.supportsDidSave
    # LSP server doesn't support text document synchronization
    return
  endif

  # The server must get the changes made just before the write (e.g. by a
  # BufWritePre autocmd) before the notification.  Vim passes them to the
  # listeners only before redrawing.
  bnr->listener_flush()

  # Notification: 'textDocument/didSave'
  # Params: DidSaveTextDocumentParams
  var params: dict<any> = {textDocument: {uri: util.LspBufnrToUri(bnr)}}

  var textDocumentSync = lspserver.caps.textDocumentSync
  if textDocumentSync->type() == v:t_dict && textDocumentSync->has_key('save')
    var save = textDocumentSync.save
    if save->type() == v:t_dict && save->has_key('includeText') && save.includeText
      params.text = BufferText(bnr)
    endif
  endif

  lspserver.sendNotification('textDocument/didSave', params)
enddef

# get the hover information
# Request: "textDocument/hover"
# Param: HoverParams
def ShowHoverInfo(lspserver: dict<any>, cmdmods: string): void
  # Check whether LSP server supports getting hover information.
  # caps->hoverProvider can be a "boolean" or "HoverOptions"
  if !lspserver.isHoverProvider
    return
  endif

  var reqctx = hover.HoverRequestContextGet(lspserver)
  if hover.HoverShowCached(reqctx, lspserver, cmdmods)
    return
  endif

  # interface HoverParams
  #   interface TextDocumentPositionParams
  var params = lspserver.getTextDocPosition(false)
  AsyncRpcSupersede(lspserver, 'textDocument/hover', 'textDocument/hover',
		    params, (_: dict<any>, reply, error) => {
    hover.HoverReply(lspserver, reply, error, cmdmods, reqctx)
  })
enddef

# Request: "textDocument/references"
# Param: ReferenceParams
def ShowReferences(lspserver: dict<any>, peek: bool): void
  # Check whether LSP server supports getting reference information
  if !lspserver.isReferencesProvider
    util.ErrMsg('LSP server does not support showing references')
    return
  endif

  # interface ReferenceParams
  #   interface TextDocumentPositionParams
  var param: dict<any>
  param = lspserver.getTextDocPosition(true)
  param.context = {includeDeclaration: true}
  AsyncRpcInContext(lspserver, util.RequestContextGet('cursor'),
		    'textDocument/references', 'textDocument/references', param,
		    (_: dict<any>, result: any, _) => {
    ShowLocationsReply(lspserver, result, peek, 'Symbol References',
		       'No references found')
  })
enddef

# send custom locations request
def FindLocations(lspserver: dict<any>, peek: bool, method: string, args: dict<any>): void
  var param: dict<any>
  param = lspserver.getTextDocPosition(true)->extend(args)
  AsyncRpcInContext(lspserver, util.RequestContextGet('cursor'), method,
		    method, param, (_: dict<any>, result: any, _) => {
    ShowLocationsReply(lspserver, result, peek, 'Symbol Locations',
		       'No location found')
  })
enddef

# Display the locations in the reply "result" to a references or a custom
# locations request in a list titled "title", or in the preview window if
# "peek" is true.  When there are none, warn with "emptyMsg".
# Result: Location[] | null
def ShowLocationsReply(lspserver: dict<any>, result: any, peek: bool,
		       title: string, emptyMsg: string)
  if result->empty()
    util.WarnMsg(emptyMsg)
    return
  endif

  if lspserver.needOffsetEncoding
    # Decode the position encoding in all the reference locations
    result->map((_, loc) => {
      lspserver.decodeLocation(loc)
      return loc
    })
  endif

  symbol.ShowLocations(lspserver, result, peek, title)
enddef

# send a custom request to the server
# Name: name of the server
# Request: any
# Params: any
def g:LspRequestCustom(name: string, msg: string, params: any): string
  var lspserver: dict<any> = buf.CurbufGetServerByName(name)
  if lspserver->empty()
    return ''
  endif

  lspserver.rpc_a(msg, params, (_: dict<any>, reply, error) => WorkspaceExecuteReply(lspserver, reply, error))
  return ''
enddef

# process the 'textDocument/documentHighlight' reply from the LSP server
# Result: DocumentHighlight[] | null
def DocHighlightReply(lspserver: dict<any>, docHighlightReply: any,
                      docHighlightError: dict<any>, bnr: number,
                      cmdmods: string): void
  # Handle document highlight error
  if !docHighlightError->empty()
    if cmdmods !~ 'silent'
      util.ErrMsg($'Document highlight failed: {docHighlightError.message}')
    endif
    return
  endif

  if docHighlightReply->empty()
    if cmdmods !~ 'silent'
      util.WarnMsg($'No highlight for the current position')
    endif
    return
  endif

  for docHL in docHighlightReply
    lspserver.decodeRange(bnr, docHL.range)
    var kind: number = docHL->get('kind', 1)
    var propName: string
    if kind == 2
      # Read-access
      propName = 'LspReadRef'
    elseif kind == 3
      # Write-access
      propName = 'LspWriteRef'
    else
      # textual reference
      propName = 'LspTextRef'
    endif
    try
      var docHL_range = docHL.range
      var docHL_start = docHL_range.start
      var docHL_end = docHL_range.end
      prop_add(docHL_start.line + 1,
                  util.GetLineByteFromPos(bnr, docHL_start) + 1,
                  {end_lnum: docHL_end.line + 1,
                    end_col: util.GetLineByteFromPos(bnr, docHL_end) + 1,
                    bufnr: bnr,
                    type: propName})
    catch /E966\|E964/ # Invalid lnum | Invalid col
      # Highlight replies arrive asynchronously and the document might have
      # been modified in the mean time.  As the reply is stale, ignore invalid
      # line number and column number errors.
    endtry
  endfor
enddef

# Request: "textDocument/documentHighlight"
# Param: DocumentHighlightParams
def DocHighlight(lspserver: dict<any>, bnr: number, cmdmods: string): void
  # Check whether LSP server supports getting highlight information
  if !lspserver.isDocumentHighlightProvider
    util.ErrMsg('LSP server does not support document highlight')
    return
  endif

  # interface DocumentHighlightParams
  #   interface TextDocumentPositionParams
  var params = lspserver.getTextDocPosition(false)
  AsyncRpcSupersede(lspserver, $'textDocument/documentHighlight {bnr}',
		    'textDocument/documentHighlight', params, (_: dict<any>, reply, error) => {
    DocHighlightReply(lspserver, reply, error, bnr, cmdmods)
  })
enddef

# Request: "textDocument/documentSymbol"
# Param: DocumentSymbolParams
def GetDocSymbols(lspserver: dict<any>, fname: string, showOutline: bool): void
  # Check whether LSP server supports getting document symbol information
  if !lspserver.isDocumentSymbolProvider
    util.ErrMsg('LSP server does not support getting list of symbols')
    return
  endif

  # interface DocumentSymbolParams
  # interface TextDocumentIdentifier
  var params = {textDocument: {uri: util.LspFileToUri(fname)}}
  lspserver.rpc_a('textDocument/documentSymbol', params, (_: dict<any>, reply, error) => {
    if showOutline
      symbol.DocSymbolOutline(lspserver, reply, error, fname)
    else
      symbol.DocSymbolPopup(lspserver, reply, error, fname)
    endif
  })
enddef

# Format the current buffer, or the lines "start_lnum" to "end_lnum" in it if
# "rangeFormat" is true.  When "sync" is true, the buffer is formatted before
# returning, otherwise when the reply arrives, unless the buffer was changed.
# Request: "textDocument/formatting"
# Param: DocumentFormattingParams
# or
# Request: "textDocument/rangeFormatting"
# Param: DocumentRangeFormattingParams
def TextDocFormat(lspserver: dict<any>, fname: string, rangeFormat: bool,
		  start_lnum: number, end_lnum: number, sync: bool = false)
  # Check whether LSP server supports required formatting
  if rangeFormat
    if !lspserver.isDocumentRangeFormattingProvider
      util.ErrMsg('LSP server does not support range formatting')
      return
    endif
  elseif !lspserver.isDocumentFormattingProvider
    util.ErrMsg('LSP server does not support formatting documents')
    return
  endif

  var cmd: string
  if rangeFormat
    cmd = 'textDocument/rangeFormatting'
  else
    cmd = 'textDocument/formatting'
  endif

  # interface DocumentFormattingParams
  #   interface TextDocumentIdentifier
  #   interface FormattingOptions
  var fmtopts: dict<any> = {
    tabSize: shiftwidth(),
    insertSpaces: &expandtab ? true : false,
  }
  var param = {
    textDocument: {
      uri: util.LspFileToUri(fname)
    },
    options: fmtopts
  }

  var bnr: number = bufnr()

  if rangeFormat
    var r: dict<dict<number>> = {
	start: {line: start_lnum - 1, character: 0},
	end: {
	  line: end_lnum - 1,
	  character: util.GetCharIdxWithCompChar(getline(end_lnum),
						 charcol([end_lnum, '$']) - 1)
	}}
    lspserver.encodeRange(bnr, r)
    param.range = r
  endif

  # A request supersedes the pending one for the buffer
  var key = $'textDocument/formatting {bnr}'
  if !sync
    AsyncRpcInContext(lspserver, util.RequestContextGet('buffer', bnr), key,
		      cmd, param, (_: dict<any>, result: any, _) => {
      TextDocFormatReply(lspserver, bnr, result)
    })
    return
  endif

  CancelSupersedableRequest(lspserver, key)
  var reply = lspserver.rpc(cmd, param)
  TextDocFormatReply(lspserver, bnr, reply->get('result', null))
enddef

# Apply the formatting edits in the reply "result" to buffer "bnr".
# Result: TextEdit[] | null
def TextDocFormatReply(lspserver: dict<any>, bnr: number, result: any)
  if result->empty()
    # nothing to format
    return
  endif

  if lspserver.needOffsetEncoding
    # Decode the position encoding in all the reference locations
    result->map((_, textEdit) => {
      lspserver.decodeRange(bnr, textEdit.range)
      return textEdit
    })
  endif

  # interface TextEdit
  # Apply each of the text edit operations
  textedit.ApplyTextEdits(bnr, result)
enddef

# Adjust 'origPos' (a decoded, 0-indexed {line, character} position) to
# account for having applied 'edits' (also decoded, in original-document
# order/coordinates) to the buffer.
#
# textedit.ApplyTextEdits() does not track cursor movement.  On-type
# formatting edits routinely insert text immediately before the just-typed
# character (e.g. indenting the line the server just reformatted), so the
# cursor needs to be moved past that inserted text to keep typing naturally.
# Only edits that end at or before 'origPos' are relevant here: on-type
# formatting edits are always local to the trigger point.
def AdjustPositionForOnTypeEdits(origPos: dict<number>,
				 edits: list<dict<any>>): dict<number>
  var sorted = edits->copy()->sort((a, b) => {
    if a.range.start.line != b.range.start.line
      return a.range.start.line - b.range.start.line
    endif
    return a.range.start.character - b.range.start.character
  })

  var lineDelta = 0
  var character = origPos.character
  var adjustedOnOrigLine = false

  for e in sorted
    var s = e.range.start
    var en = e.range.end
    if en.line > origPos.line
	|| (en.line == origPos.line && en.character > origPos.character)
      # This edit is at or after 'origPos'; on-type formatting edits are
      # expected to precede the just-typed character.
      continue
    endif

    var newTextLines = e.newText->split("\n", true)
    lineDelta += (newTextLines->len() - 1) - (en.line - s.line)

    if en.line == origPos.line
      if newTextLines->len() == 1
	character = character - en.character + s.character +
					newTextLines[0]->strcharlen()
      else
	character = character - en.character + newTextLines[-1]->strcharlen()
      endif
      adjustedOnOrigLine = true
    endif
  endfor

  return {line: origPos.line + lineDelta,
	  character: adjustedOnOrigLine ? character : origPos.character}
enddef

# Request on-type formatting edits for the character just typed and apply
# them to the buffer, then place the cursor after any inserted text so that
# typing can continue naturally.
# Request: "textDocument/onTypeFormatting"
# Param: DocumentOnTypeFormattingParams
def TextDocOnTypeFormat(lspserver: dict<any>, ch: string)
  if !lspserver.isDocumentOnTypeFormattingProvider
    util.ErrMsg('LSP server does not support on-type formatting')
    return
  endif

  var bnr: number = bufnr()

  # interface DocumentOnTypeFormattingParams
  #   interface TextDocumentIdentifier
  #   interface Position
  #   ch: string
  #   interface FormattingOptions
  var param = lspserver.getTextDocPosition(false)
  param.ch = ch
  param.options = {
    tabSize: shiftwidth(),
    insertSpaces: &expandtab ? true : false,
  }
  var origPos = param.position->copy()

  AsyncRpcInContext(lspserver, util.RequestContextGet('cursor', bnr),
		    $'textDocument/onTypeFormatting {bnr}',
		    'textDocument/onTypeFormatting', param,
		    (_: dict<any>, result: any, _) => {
    TextDocOnTypeFormatReply(lspserver, bnr, origPos, result)
  })
enddef

# Apply the edits in the reply "result" to the on-type formatting request for
# the character typed before "origPos" in the current buffer "bnr", and place
# the cursor after any text inserted before it.
# Result: TextEdit[] | null
def TextDocOnTypeFormatReply(lspserver: dict<any>, bnr: number,
			     origPos: dict<number>, result: any)
  if result->empty()
    return
  endif

  if lspserver.needOffsetEncoding
    result->map((_, textEdit) => {
      lspserver.decodeRange(bnr, textEdit.range)
      return textEdit
    })
    lspserver.decodePosition(bnr, origPos)
  endif

  var newPos = AdjustPositionForOnTypeEdits(origPos, result)

  # interface TextEdit
  # Apply each of the text edit operations
  textedit.ApplyTextEdits(bnr, result)

  var byteIdx = util.GetLineByteFromPos(bnr, newPos)
  cursor(newPos.line + 1, byteIdx + 1)
enddef

def DecodeCallHierarchyItem(lspserver: dict<any>, item: dict<any>)
  if !lspserver.needOffsetEncoding
    return
  endif

  var bnr = util.LspUriToBufnr(item.uri)
  lspserver.decodeRange(bnr, item.range)
  lspserver.decodeRange(bnr, item.selectionRange)
enddef

def EncodeCallHierarchyItem(lspserver: dict<any>, item: dict<any>)
  if !lspserver.needOffsetEncoding
    return
  endif

  var bnr = util.LspUriToBufnr(item.uri)
  lspserver.encodeRange(bnr, item.range)
  lspserver.encodeRange(bnr, item.selectionRange)
enddef

# Get the call hierarchy items for the symbol under the cursor and pass them
# to "Cbfunc", with their ranges decoded, when the cursor didn't move.
# Request: "textDocument/prepareCallHierarchy"
def PrepareCallHierarchy(lspserver: dict<any>,
			 Cbfunc: func)
  # interface CallHierarchyPrepareParams
  #   interface TextDocumentPositionParams
  var param: dict<any>
  param = lspserver.getTextDocPosition(false)
  AsyncRpcInContext(lspserver, util.RequestContextGet('cursor'),
		    'textDocument/prepareCallHierarchy',
		    'textDocument/prepareCallHierarchy', param,
		    (_: dict<any>, result: any, _) => {
    # Result: CallHierarchyItem[] | null
    var items: list<dict<any>> = result->type() == v:t_list ? result : []
    for item in items
      DecodeCallHierarchyItem(lspserver, item)
    endfor
    Cbfunc(items)
  })
enddef

# Request: "callHierarchy/incomingCalls"
def IncomingCalls(lspserver: dict<any>, fname: string)
  # Check whether LSP server supports call hierarchy
  if !lspserver.isCallHierarchyProvider
    util.ErrMsg('LSP server does not support call hierarchy')
    return
  endif

  callhier.IncomingCalls(lspserver)
enddef

# Get the calls to the call hierarchy item "item_arg" and pass them to
# "Cbfunc", with their ranges decoded.
def GetIncomingCalls(lspserver: dict<any>, item_arg: dict<any>,
		     Cbfunc: func)
  GetHierarchyCalls(lspserver, 'callHierarchy/incomingCalls', 'from',
		    item_arg, Cbfunc)
enddef

# Get the calls of call hierarchy item "item_arg" with method "method"
# ("callHierarchy/incomingCalls" or "callHierarchy/outgoingCalls") and pass
# them to "Cbfunc", with the ranges of their "itemKey" item decoded.  "Cbfunc"
# gets no calls when the request fails.
# Param: CallHierarchyIncomingCallsParams | CallHierarchyOutgoingCallsParams
# Result: CallHierarchyIncomingCall[] | CallHierarchyOutgoingCall[] | null
def GetHierarchyCalls(lspserver: dict<any>, method: string, itemKey: string,
		      item_arg: dict<any>, Cbfunc: func)
  var requestItem = item_arg->deepcopy()
  EncodeCallHierarchyItem(lspserver, requestItem)

  var param = {
    item: requestItem
  }
  var id = lspserver.rpc_a(method, param, (_: dict<any>, result: any, _) => {
    var calls: list<dict<any>> = result->type() == v:t_list ? result : []
    if lspserver.needOffsetEncoding
      # Decode the position encoding in all the call locations
      for call in calls
	var callItem: dict<any> = call[itemKey]
	var bnr = util.LspUriToBufnr(callItem.uri)
	lspserver.decodeRange(bnr, callItem.range)
	lspserver.decodeRange(bnr, callItem.selectionRange)
      endfor
    endif
    Cbfunc(calls)
  })
  if id < 0
    Cbfunc([])
  endif
enddef

# Request: "callHierarchy/outgoingCalls"
def OutgoingCalls(lspserver: dict<any>, fname: string)
  # Check whether LSP server supports call hierarchy
  if !lspserver.isCallHierarchyProvider
    util.ErrMsg('LSP server does not support call hierarchy')
    return
  endif

  callhier.OutgoingCalls(lspserver)
enddef

# Get the calls made by the call hierarchy item "item_arg" and pass them to
# "Cbfunc", with their ranges decoded.
def GetOutgoingCalls(lspserver: dict<any>, item_arg: dict<any>,
		     Cbfunc: func)
  GetHierarchyCalls(lspserver, 'callHierarchy/outgoingCalls', 'to',
		    item_arg, Cbfunc)
enddef

# Request: "textDocument/inlayHint"
# Inlay hints.
def InlayHintsShow(lspserver: dict<any>, bnr: number)
  # Check whether LSP server supports type hierarchy
  if !lspserver.isInlayHintProvider && !lspserver.isClangdInlayHintsProvider
    util.ErrMsg('LSP server does not support inlay hint')
    return
  endif

  var binfo = bnr->getbufinfo()
  if binfo->empty()
    return
  endif
  var lastlnum = binfo[0].linecount
  var param = {
      textDocument: {uri: util.LspBufnrToUri(bnr)},
      range:
      {
	start: {line: 0, character: 0},
	end: {
	  line: lastlnum - 1,
	  character: bnr->getbufline(lastlnum)->get(0, '')->strchars()
	}
      }
  }

  lspserver.encodeRange(bnr, param.range)

  var msg: string
  if lspserver.isClangdInlayHintsProvider
    # clangd-style inlay hints
    msg = 'clangd/inlayHints'
  else
    msg = 'textDocument/inlayHint'
  endif
  AsyncRpcSupersede(lspserver, $'textDocument/inlayHint {bnr}', msg, param,
		    (_: dict<any>, reply, error) => {
    inlayhints.InlayHintsReply(lspserver, reply, error, bnr)
  })
enddef

# Recursively decode the parent/children type hierarchy items.
def DecodeTypeHierarchy(lspserver: dict<any>, isSuper: bool, typeHier: dict<any>)
  if !lspserver.needOffsetEncoding
    return
  endif
  var bnr = util.LspUriToBufnr(typeHier.uri)
  lspserver.decodeRange(bnr, typeHier.range)
  lspserver.decodeRange(bnr, typeHier.selectionRange)
  var subType: list<dict<any>>
  if isSuper
    subType = typeHier->get('parents', [])
  else
    subType = typeHier->get('children', [])
  endif
  if !subType->empty()
    # Decode the position encoding in all the type hierarchy items
    subType->map((_, typeHierItem) => {
        DecodeTypeHierarchy(lspserver, isSuper, typeHierItem)
	return typeHierItem
      })
  endif
enddef

# Recursively get all the parent/children type items of "typeHierItem" from
# the language server, and add them to it.  "fetch.pending" counts the
# requests that are not answered yet, and "fetch.Done" is invoked when all
# are.
def GetTypeHierarchy(lspserver: dict<any>, typeHierItem: dict<any>,
		     isSuper: bool, fetch: dict<any>)
  var msg = isSuper ? 'typeHierarchy/supertypes' : 'typeHierarchy/subtypes'
  fetch.pending += 1
  var id = lspserver.rpc_a(msg, {item: typeHierItem},
			   (_: dict<any>, result: any, _) => {
    if result->type() == v:t_list && !result->empty()
      typeHierItem[isSuper ? 'parents' : 'children'] = result
      for item in result
	GetTypeHierarchy(lspserver, item, isSuper, fetch)
      endfor
    endif
    TypeHierarchyRequestDone(fetch)
  })
  if id < 0
    TypeHierarchyRequestDone(fetch)
  endif
enddef

# Count a type hierarchy request sent by GetTypeHierarchy() as answered.
def TypeHierarchyRequestDone(fetch: dict<any>)
  fetch.pending -= 1
  if fetch.pending == 0
    fetch.Done()
  endif
enddef

# Request: "textDocument/typehierarchy"
# Support the clangd version of type hierarchy retrieval method.
# The method described in the LSP 3.17.0 standard is not supported as clangd
# doesn't support that method.
def TypeHierarchy(lspserver: dict<any>, direction: number)
  # Check whether LSP server supports type hierarchy
  if !lspserver.isTypeHierarchyProvider
    util.ErrMsg('LSP server does not support type hierarchy')
    return
  endif

  # interface TypeHierarchyPrepareParams
  #   interface TextDocumentPositionParams
  var param: dict<any>
  param = lspserver.getTextDocPosition(false)
  var reqctx = util.RequestContextGet('cursor')
  AsyncRpcInContext(lspserver, reqctx, 'textDocument/prepareTypeHierarchy',
		    'textDocument/prepareTypeHierarchy', param,
		    (_: dict<any>, result: any, _) => {
    TypeHierarchyPrepareReply(lspserver, reqctx, direction == 1, result)
  })
enddef

# Process the reply "result" to the "textDocument/prepareTypeHierarchy"
# request sent for the editor state "reqctx": get the super types of the
# first item if "isSuper" is true, otherwise its sub types, and display them
# when the state did not change in the meantime.
# Result: TypeHierarchyItem[] | null
def TypeHierarchyPrepareReply(lspserver: dict<any>, reqctx: dict<number>,
			      isSuper: bool, result: any)
  if result->empty()
    util.WarnMsg('No type hierarchy available')
    return
  endif

  if result->type() != v:t_list
    util.ErrMsg('prepareTypeHierarchy response from the language server is not a List')
    return
  endif

  var typeHierItem: dict<any> = result[0]
  var Show = () => {
    if !util.RequestContextMatches(reqctx)
      return
    endif

    if isSuper && !typeHierItem->has_key('parents')
      util.WarnMsg('No supertype hierarchy available')
      return
    elseif !isSuper && !typeHierItem->has_key('children')
      util.WarnMsg('No subtype hierarchy available')
      return
    endif

    DecodeTypeHierarchy(lspserver, isSuper, typeHierItem)

    typehier.ShowTypeHierarchy(lspserver, isSuper, typeHierItem)
  }
  GetTypeHierarchy(lspserver, typeHierItem, isSuper, {pending: 0, Done: Show})
enddef

# Request: "textDocument/rename"
# Param: RenameParams
def RenameSymbol(lspserver: dict<any>, newName: string)
  # Check whether LSP server supports rename operation
  if !lspserver.isRenameProvider
    util.ErrMsg('LSP server does not support rename operation')
    return
  endif

  # interface RenameParams
  #   interface TextDocumentPositionParams
  var param: dict<any> = {}
  param = lspserver.getTextDocPosition(true)
  param.newName = newName

  AsyncRpcInContext(lspserver, util.RequestContextGet('buffer'),
		    'textDocument/rename', 'textDocument/rename', param,
		    (_: dict<any>, result: any, _) => {
    # Result: WorkspaceEdit | null
    if result->empty()
      # nothing to rename
      return
    endif

    textedit.ApplyWorkspaceEdit(result, lspserver)
  })
enddef

# Parse a code action query for request-side filtering.
#
# Supported query syntax:
#   only:<kind[,kind...]>
#   kind:<kind[,kind...]>
# Optional selector:
#   ...#<selector>
#
# Example:
#   only:quickfix#1
def ParseCodeActionQuery(query: string): dict<any>
  var q = query->trim()
  var result = {only: [], query: query}

  if q !~? '^\%(only\|kind\):'
    return result
  endif

  var payload = q->substitute('^\c\%(only\|kind\):', '', '')
  var selector = ''
  var hashIdx = payload->stridx('#')
  if hashIdx >= 0
    selector = payload[hashIdx + 1 : ]
    payload = payload[0 : hashIdx - 1]
  endif

  var onlyKinds = payload->split(',')
  onlyKinds->map((_, kind) => kind->trim())
  onlyKinds->filter((_, kind) => kind != '')
  if onlyKinds->empty()
    return result
  endif

  for kind in onlyKinds
    if kind !~ '^[A-Za-z][A-Za-z0-9_.-]*$'
      return result
    endif
  endfor

  result.only = onlyKinds
  result.query = selector
  return result
enddef

# Return the "params" of the "textDocument/codeAction" request to "lspserver"
# for lines "line1" to "line2" of the file "fname_arg", with the diagnostics of
# the server on them and the code action kinds in "query", and the
# "selectorQuery" in "query" that picks from the code actions.  When the lines
# are just the cursor line, the range starts at the cursor.
def GetCodeActionParams(lspserver: dict<any>, fname_arg: string, line1: number,
			line2: number, query: string): dict<any>
  # Keep request construction in one place so sync/async code action paths
  # stay behaviorally identical.
  var params: dict<any> = {}
  var fname: string = fname_arg->fnamemodify(':p')
  var bnr: number = util.BufnrExact(fname_arg)
  var r: dict<dict<number>> = {
    start: {
      line: line1 - 1,
      character: line1 == line2 && line1 == line('.')
	? util.GetCharIdxWithCompChar(getline('.'), charcol('.') - 1)
	: 0
    },
    end: {
      line: line2 - 1,
      character: util.GetCharIdxWithCompChar(getline(line2), charcol([line2, '$']) - 1)
    }
  }
  lspserver.encodeRange(bnr, r)
  params->extend({textDocument: {uri: util.LspFileToUri(fname)}, range: r})

  # Diagnostics are scoped per-server so each provider gets context that
  # matches its own diagnostic namespace and offset encoding.
  var d: list<dict<any>> =
    diag.GetDiagsInLineRange(bnr, line1, line2, lspserver)
      ->mapnew((_, di) => codeaction.ContextDiag(lspserver, bnr, di))
  params->extend({context: {diagnostics: d, triggerKind: 1}})

  var queryInfo = ParseCodeActionQuery(query)
  if !queryInfo.only->empty()
    params.context.only = queryInfo.only
  endif

  # Return both params and post-filter selector (text after '#') used by UI.
  return {
    params: params,
    selectorQuery: queryInfo.query
  }
enddef

def CodeActionAsync(lspserver: dict<any>, fname_arg: string, line1: number,
		    line2: number, query: string, Cbfunc: func)
  # Mirror sync semantics for unsupported providers: callback still fires so
  # fan-out aggregators can deterministically count completions.
  if !lspserver.isCodeActionProvider
    Cbfunc(lspserver, [], query, {})
    return
  endif

  var reqInfo = GetCodeActionParams(lspserver, fname_arg, line1, line2, query)
  var params = reqInfo.params

  var reqid = lspserver.rpc_a('textDocument/codeAction', params,
	(_: dict<any>, result, rpcError) => {
	  var actionList: list<dict<any>> = []
	  if rpcError->empty() && result->type() == v:t_list
	    actionList = result
	  endif

	  Cbfunc(lspserver, actionList, reqInfo.selectorQuery, rpcError)
	})

  if reqid < 0
    # Normalize send failures into callback error flow for one-path handling.
    Cbfunc(lspserver, [], reqInfo.selectorQuery, {
	code: -32603,
	message: 'Failed to send code action request'
	})
  endif
enddef

# Request: "textDocument/codeLens"
# Param: CodeLensParams
def CodeLens(lspserver: dict<any>, fname: string)
  # Check whether LSP server supports code lens operation
  if !lspserver.isCodeLensProvider
    util.ErrMsg('LSP server does not support code lens operation')
    return
  endif

  var bnr = bufnr()
  var reqctx = util.RequestContextGet('window', bnr)
  var params = {textDocument: {uri: util.LspFileToUri(fname)}}
  AsyncRpcInContext(lspserver, reqctx, $'textDocument/codeLens {bnr}',
		    'textDocument/codeLens', params,
		    (_: dict<any>, result: any, _) => {
    # Result: CodeLens[] | null
    if result->empty()
      util.WarnMsg($'No code lens actions found for the current file')
      return
    endif

    var codeLensItems: list<dict<any>> = result
    # Decode the position encoding in all the code lens items
    if lspserver.needOffsetEncoding
      for codeLensItem in codeLensItems
	lspserver.decodeRange(bnr, codeLensItem.range)
      endfor
    endif

    ResolveCodeLenses(lspserver, bnr, codeLensItems,
		      (resolvedItems: list<dict<any>>) => {
      if util.RequestContextMatches(reqctx)
	codelens.ProcessCodeLens(lspserver, resolvedItems)
      endif
    })
  })
enddef

# Resolve the items in "codeLensItems" of buffer "bnr" that have no command,
# and then pass the items that have one to "Cbfunc".
def ResolveCodeLenses(lspserver: dict<any>, bnr: number,
		      codeLensItems: list<dict<any>>, Cbfunc: func)
  var items: list<dict<any>> = codeLensItems->copy()
  # One more than the number of items being resolved, until all the requests
  # are sent
  var pending = 1
  var ItemDone = () => {
    pending -= 1
    if pending == 0
      Cbfunc(items->filter((_, item) => item->has_key('command')))
    endif
  }
  for i in items->len()->range()
    if !items[i]->has_key('command')
      pending += 1
      ResolveCodeLens(lspserver, bnr, items[i], (resolved: dict<any>) => {
	items[i] = resolved
	ItemDone()
      })
    endif
  endfor
  ItemDone()
enddef

# Resolve the code action "codeAction" and pass the resolved code action to
# "Cbfunc", or an empty Dict if it cannot be resolved.
# Request: "codeAction/resolve"
# Param: CodeAction
def ResolveCodeAction(lspserver: dict<any>, codeAction: dict<any>,
		      Cbfunc: func)
  if !lspserver.isCodeActionResolveProvider
    Cbfunc({})
    return
  endif

  var id = lspserver.rpc_a('codeAction/resolve', codeAction,
			   (_: dict<any>, result: any, _) => {
    Cbfunc(result->type() == v:t_dict ? result : {})
  })
  if id < 0
    Cbfunc({})
  endif
enddef

# Resolve the code lens item "codeLens" in buffer "bnr" and pass the resolved
# item, with its range decoded, to "Cbfunc", or an empty Dict if it cannot be
# resolved.
# Request: "codeLens/resolve"
# Param: CodeLens
def ResolveCodeLens(lspserver: dict<any>, bnr: number, codeLens: dict<any>,
		    Cbfunc: func)
  if !lspserver.isCodeLensResolveProvider
    Cbfunc({})
    return
  endif

  var params: dict<any> = codeLens->deepcopy()
  if lspserver.needOffsetEncoding
    lspserver.encodeRange(bnr, params.range)
  endif

  var id = lspserver.rpc_a('codeLens/resolve', params,
			   (_: dict<any>, result: any, _) => {
    if result->type() != v:t_dict || result->empty()
      Cbfunc({})
      return
    endif

    var codeLensItem: dict<any> = result
    # Decode the position encoding in the code lens item
    if lspserver.needOffsetEncoding
      lspserver.decodeRange(bnr, codeLensItem.range)
    endif
    Cbfunc(codeLensItem)
  })
  if id < 0
    Cbfunc({})
  endif
enddef

# Get the links in buffer "bnr" and pass them, with their ranges decoded, to
# "Cbfunc", when the editor state in "reqctx" did not change.
# Request: "textDocument/documentLink"
# Param: DocumentLinkParams
def GetDocumentLinks(lspserver: dict<any>, bnr: number, reqctx: dict<number>,
		     Cbfunc: func)
  var params = {textDocument: {uri: util.LspBufnrToUri(bnr)}}
  AsyncRpcInContext(lspserver, reqctx, $'textDocument/documentLink {bnr}',
		    'textDocument/documentLink', params,
		    (_: dict<any>, result: any, _) => {
    # Result: DocumentLink[] | null
    var links: list<dict<any>> = result->type() == v:t_list ? result : []
    if lspserver.needOffsetEncoding
      for link in links
	lspserver.decodeRange(bnr, link.range)
      endfor
    endif
    Cbfunc(links)
  })
enddef

# Display the links in buffer "bnr" in a location or quickfix list.
def ShowDocumentLinks(lspserver: dict<any>, bnr: number)
  if !lspserver.isDocumentLinkProvider
    util.ErrMsg('LSP server does not support document links')
    return
  endif

  GetDocumentLinks(lspserver, bnr, util.RequestContextGet('window', bnr),
		   (links: list<dict<any>>) => {
    if links->empty()
      util.WarnMsg('No document links found')
      return
    endif

    documentlink.ShowLinks(bnr, links)
  })
enddef

# Open the target of the link under the cursor in the current buffer.  The
# user specified window command modifiers (e.g. topleft) are in "cmdmods".
def OpenDocumentLink(lspserver: dict<any>, cmdmods: string)
  if !lspserver.isDocumentLinkProvider
    util.ErrMsg('LSP server does not support document links')
    return
  endif

  var bnr = bufnr()
  GetDocumentLinks(lspserver, bnr, util.RequestContextGet('cursor', bnr),
		   (links: list<dict<any>>) => {
    documentlink.OpenLinkAtCursor(lspserver, links, cmdmods)
  })
enddef

# Resolve the document link "link" in buffer "bnr" and pass the resolved
# copy of it, with its range decoded, to "Cbfunc", or an empty Dict if it
# cannot be resolved.
# Request: "documentLink/resolve"
# Param: DocumentLink
def ResolveDocumentLink(lspserver: dict<any>, bnr: number, link: dict<any>,
			Cbfunc: func)
  if !lspserver.isDocumentLinkResolveProvider
    Cbfunc({})
    return
  endif

  var params: dict<any> = link->deepcopy()
  if lspserver.needOffsetEncoding
    lspserver.encodeRange(bnr, params.range)
  endif

  var id = lspserver.rpc_a('documentLink/resolve', params,
			   (_: dict<any>, result: any, _) => {
    if result->type() != v:t_dict || result->empty()
      Cbfunc({})
      return
    endif

    var resolved: dict<any> = result
    if lspserver.needOffsetEncoding
      lspserver.decodeRange(bnr, resolved.range)
    endif
    Cbfunc(resolved)
  })
  if id < 0
    Cbfunc({})
  endif
enddef

# List project-wide symbols matching query string
# Request: "workspace/symbol"
# Param: WorkspaceSymbolParams
def WorkspaceQuerySymbols(lspserver: dict<any>, query: string, firstCall: bool, cmdmods: string = '')
  # Check whether the LSP server supports listing workspace symbols
  if !lspserver.isWorkspaceSymbolProvider
    util.ErrMsg('LSP server does not support listing workspace symbols')
    return
  endif

  # Param: WorkspaceSymbolParams
  var param = {
    query: query
  }
  var reqctx = util.RequestContextGet('cursor')
  AsyncRpcSupersede(lspserver, 'workspace/symbol', 'workspace/symbol', param,
		    (_: dict<any>, result: any, _) => {
    # The first query is for the cursor position, and the next ones are for
    # the text typed in the symbol popup, which must still be open
    var current = firstCall
      ? util.RequestContextMatches(reqctx)
      : lspserver.workspaceSymbolPopup->winbufnr() != -1
	  && lspserver.workspaceSymbolQuery == query
    if current
      WorkspaceQuerySymbolsReply(lspserver, query, firstCall, cmdmods, result)
    endif
  })
enddef

# Process the reply "result" to the "workspace/symbol" request for "query".
# Result: SymbolInformation[] | WorkspaceSymbol[] | null
def WorkspaceQuerySymbolsReply(lspserver: dict<any>, query: string,
			       firstCall: bool, cmdmods: string, result: any)
  if result->empty()
    util.WarnMsg($'Symbol "{query}" is not found')
    return
  endif

  var symInfo: list<dict<any>> = result

  if firstCall && symInfo->len() == 1
    # If there is only one symbol, then jump to the symbol location
    var symLoc: dict<any> = symInfo[0]->get('location', {})
    if !symLoc->empty()
      # Decode the position encoding in the symbol location
      if lspserver.needOffsetEncoding
	lspserver.decodeLocation(symLoc)
      endif
      symbol.GotoSymbol(lspserver, symLoc, false, cmdmods)
    endif
  else
    # Note: decoding position encoding delayed until jumping to location
    symbol.WorkspaceSymbolPopup(lspserver, query, symInfo, cmdmods)
  endif
enddef

# Return the LSP WorkspaceFolder interface for the directory "dirName"
def GetWorkspaceFolder(dirName: string): dict<any>
  var normalizedDir = dirName->fnamemodify(':p')
  return {
    name: normalizedDir->fnamemodify(':t'),
    uri: util.LspFileToUri(normalizedDir)
  }
enddef

# Add a workspace folder to the language server.
def AddWorkspaceFolder(lspserver: dict<any>, dirName_arg: string): void
  var dirName = dirName_arg->fnamemodify(':p')

  var caps = lspserver.caps
  if !caps->has_key('workspace')
    util.ErrMsg('LSP server does not support workspace folders')
    return
  endif
  var workspace = caps.workspace
  if !workspace->has_key('workspaceFolders')
    util.ErrMsg('LSP server does not support workspace folders')
    return
  endif
  var workspaceFolders = workspace.workspaceFolders
  if !workspaceFolders->has_key('supported') || !workspaceFolders.supported
    util.ErrMsg('LSP server does not support workspace folders')
    return
  endif

  if lspserver.workspaceFolders->index(dirName) != -1
    util.ErrMsg($'{dirName} is already part of this workspace')
    return
  endif

  # Notification: 'workspace/didChangeWorkspaceFolders'
  # Params: DidChangeWorkspaceFoldersParams
  var params = {event: {added: [GetWorkspaceFolder(dirName)], removed: []}}
  lspserver.sendNotification('workspace/didChangeWorkspaceFolders', params)

  lspserver.workspaceFolders->add(dirName)
enddef

# Remove a workspace folder from the language server.
def RemoveWorkspaceFolder(lspserver: dict<any>, dirName_arg: string): void
  var dirName = dirName_arg->fnamemodify(':p')

  var caps = lspserver.caps
  if !caps->has_key('workspace')
    util.ErrMsg('LSP server does not support workspace folders')
    return
  endif
  var workspace = caps.workspace
  if !workspace->has_key('workspaceFolders')
    util.ErrMsg('LSP server does not support workspace folders')
    return
  endif
  var workspaceFolders = workspace.workspaceFolders
  if !workspaceFolders->has_key('supported') || !workspaceFolders.supported
    util.ErrMsg('LSP server does not support workspace folders')
    return
  endif

  var idx: number = lspserver.workspaceFolders->index(dirName)
  if idx == -1
    util.ErrMsg($'{dirName} is not currently part of this workspace')
    return
  endif

  # Notification: "workspace/didChangeWorkspaceFolders"
  # Param: DidChangeWorkspaceFoldersParams
  var params = {event: {added: [], removed: [GetWorkspaceFolder(dirName)]}}
  lspserver.sendNotification('workspace/didChangeWorkspaceFolders', params)

  lspserver.workspaceFolders->remove(idx)
enddef

def DecodeSelectionRange(lspserver: dict<any>, bnr: number, selRange: dict<any>)
  lspserver.decodeRange(bnr, selRange.range)
  if selRange->has_key('parent')
    DecodeSelectionRange(lspserver, bnr, selRange.parent)
  endif
enddef

# select the text around the current cursor location
# Request: "textDocument/selectionRange"
# Param: SelectionRangeParams
def SelectionRange(lspserver: dict<any>, fname: string)
  # Check whether LSP server supports selection ranges
  if !lspserver.isSelectionRangeProvider
    util.ErrMsg('LSP server does not support selection ranges')
    return
  endif

  # clear the previous selection reply
  lspserver.selection = {}

  # interface SelectionRangeParams
  # interface TextDocumentIdentifier
  var param = {
    textDocument: {
      uri: util.LspFileToUri(fname)
    },
    positions: [lspserver.getPosition(false)]
  }
  var bnr = bufnr()
  AsyncRpcInContext(lspserver, util.RequestContextGet('cursor', bnr),
		    'textDocument/selectionRange',
		    'textDocument/selectionRange', param,
		    (_: dict<any>, result: any, _) => {
    # Result: SelectionRange[] | null
    if result->empty()
      return
    endif

    var selRanges: list<dict<any>> = result
    # Decode the position encoding in all the selection range items
    if lspserver.needOffsetEncoding
      for selItem in selRanges
	DecodeSelectionRange(lspserver, bnr, selItem)
      endfor
    endif

    selection.SelectionStart(lspserver, selRanges)
  })
enddef

# Expand the previous selection or start a new one
def SelectionExpand(lspserver: dict<any>)
  # Check whether LSP server supports selection ranges
  if !lspserver.isSelectionRangeProvider
    util.ErrMsg('LSP server does not support selection ranges')
    return
  endif

  selection.SelectionModify(lspserver, true)
enddef

# Shrink the previous selection or start a new one
def SelectionShrink(lspserver: dict<any>)
  # Check whether LSP server supports selection ranges
  if !lspserver.isSelectionRangeProvider
    util.ErrMsg('LSP server does not support selection ranges')
    return
  endif

  selection.SelectionModify(lspserver, false)
enddef

# fold the entire document
# Request: "textDocument/foldingRange"
# Param: FoldingRangeParams
def FoldRange(lspserver: dict<any>, fname: string)
  # Check whether LSP server supports fold ranges
  if !lspserver.isFoldingRangeProvider
    util.ErrMsg('LSP server does not support folding')
    return
  endif

  # interface FoldingRangeParams
  # interface TextDocumentIdentifier
  var params = {textDocument: {uri: util.LspFileToUri(fname)}}
  var bnr = bufnr()
  AsyncRpcInContext(lspserver, util.RequestContextGet('window', bnr),
		    $'textDocument/foldingRange {bnr}',
		    'textDocument/foldingRange', params,
		    (_: dict<any>, result: any, _) => {
    FoldRangeReply(result)
  })
enddef

# Replace the folds in the current window with the ranges in the reply
# "result" to the "textDocument/foldingRange" request.
# Result: FoldingRange[] | null
def FoldRangeReply(result: any)
  # Remove all the current folds
  :normal! zE

  if result->empty()
    return
  endif

  var end_lnum: number
  for foldRange in result
    var start_lnum = foldRange.startLine + 1
    end_lnum = foldRange.endLine + 1

    if end_lnum < start_lnum
      end_lnum = start_lnum
    endif
    exe $':{start_lnum}, {end_lnum}fold'
    # Open all the folds, otherwise the subsequently created folds are not
    # correct.
    :silent! foldopen!
  endfor

  if &foldcolumn == 0
    :setlocal foldcolumn=2
  endif
enddef

# process the 'workspace/executeCommand' reply from the LSP server
# Result: any | null
def WorkspaceExecuteReply(lspserver: dict<any>, execReply: any,
                          execError: dict<any> = {})
  # Handle workspace execute command error
  if !execError->empty()
    lspserver.traceLog($'Execute command failed: {execError.message}')
    return
  endif

  # Nothing to do for the reply
enddef

# Request the LSP server to execute a command
# Request: workspace/executeCommand
# Params: ExecuteCommandParams
def ExecuteCommand(lspserver: dict<any>, cmd: dict<any>)
  # Need to check for lspserver.caps.executeCommandProvider?
  var params: dict<any> = {}
  params.command = cmd->get('command', '')
  if params.command->empty()
    # No specific command to execute received from the server
    return
  endif
  if cmd->has_key('arguments')
    params.arguments = cmd.arguments
  endif

  lspserver.rpc_a('workspace/executeCommand', params, (_: dict<any>, reply, error) => WorkspaceExecuteReply(lspserver, reply, error))
enddef

# Display the LSP server capabilities (received during the initialization
# stage).
def GetCapabilities(lspserver: dict<any>): list<string>
  var l = []
  var heading = $"'{lspserver.name}' Language Server Capabilities"
  var underlines = repeat('=', heading->len())
  l->extend([heading, underlines])
  for k in lspserver.caps->keys()->sort()
    l->add($'{k}: {lspserver.caps[k]->string()}')
  endfor
  return l
enddef

# Display the LSP server initialize request and result
def GetInitializeRequest(lspserver: dict<any>): list<string>
  var l = []
  var heading = $"'{lspserver.path}' Language Server Initialize Request"
  var underlines = repeat('=', heading->len())
  l->extend([heading, underlines])
  if lspserver->has_key('rpcInitializeRequest')
    for k in lspserver.rpcInitializeRequest->keys()->sort()
      l->add($'{k}: {lspserver.rpcInitializeRequest[k]->string()}')
    endfor
  endif
  return l
enddef

# Store a log or trace message received from the language server.
def AddMessage(lspserver: dict<any>, msgType: string, newMsg: string)
  # A single message may contain multiple lines separated by newline
  if newMsg == ''
    return
  endif
  var msgs = newMsg->split("\n")
  lspserver.messages->add($'{strftime("%m/%d/%y %T")}: [{msgType}]: {msgs[0]}')
  lspserver.messages->extend(msgs[1 : ])
  # Keep only the last 500 messages to reduce the memory usage.  Remove the
  # others in place, as a slice has no type (see NewLspServer()).
  if lspserver.messages->len() >= 600
    lspserver.messages->remove(0, -501)
  endif
enddef

# Display the log messages received from the LSP server (window/logMessage)
def GetMessages(lspserver: dict<any>): list<string>
  if lspserver.messages->empty()
    return [$'No messages received from "{lspserver.name}" server']
  endif

  var l = []
  var heading = $"'{lspserver.path}' Language Server Messages"
  var underlines = repeat('=', heading->len())
  l->extend([heading, underlines])
  l->extend(lspserver.messages)
  return l
enddef

# Send a 'textDocument/definition' request to the LSP server to get the
# location where the symbol under the cursor is defined and return a list of
# Dicts in a format accepted by the 'tagfunc' option.
# Returns null if the LSP server doesn't support getting the location of a
# symbol definition or the symbol is not defined.
def TagFunc(lspserver: dict<any>, pat: string, flags: string, info: dict<any>): any
  var taglocations: list<dict<any>> = []

  # For explicit tag lookups (for example: :tag Foo), use workspace/symbol.
  # The definition request uses only the cursor position and may return the
  # wrong symbol for these lookups.
  if pat != '' && pat != expand('<cword>')
    if !lspserver.isWorkspaceSymbolProvider
      return null
    endif

    var wsReply = lspserver.rpc('workspace/symbol', {query: pat}, {handleError: false})
    if !wsReply->has_key('result') || wsReply.result->empty()
      return null
    endif

    for sym in wsReply.result
      if !sym->has_key('location') || !sym.location->has_key('range')
	continue
      endif
      if sym->get('name', '') != pat
	continue
      endif
      taglocations->add(sym.location)
    endfor

    if taglocations->empty()
      return null
    endif
  else
    # Check whether LSP server supports getting the location of a definition.
    if !lspserver.isDefinitionProvider
      return null
    endif

    # interface DefinitionParams
    #   interface TextDocumentPositionParams
    var reply = lspserver.rpc('textDocument/definition',
			      lspserver.getTextDocPosition(false))
    if reply->empty() || reply.result->empty()
      return null
    endif

    if reply.result->type() == v:t_list
      taglocations = reply.result
    else
      taglocations = [reply.result]
    endif
  endif

  if lspserver.needOffsetEncoding
    # Decode the position encoding in all the reference locations
    taglocations->map((_, loc) => {
      lspserver.decodeLocation(loc)
      return loc
    })
  endif

  return symbol.TagFunc(lspserver, taglocations, pat)
enddef

# Returns unique ID used for identifying the various servers
var UniqueServerIdCounter = 0
def GetUniqueServerId(): number
  UniqueServerIdCounter += 1
  return UniqueServerIdCounter
enddef

export def NewLspServer(serverParams: dict<any>): dict<any>
  # The maps and the list that grow with the number of open documents, pending
  # requests and messages are created with a type.  When the server dict is
  # passed to a function, which is on every method call, Vim goes through all
  # its values and all those of the dicts and lists in it that have no type:
  # before patch 9.2.1144 always, after it when the argument type is "any".
  # A "{}" literal or a slice has no type, so change these in place, e.g.
  # with ClearMap(), instead of assigning a new one.  For the same reason, a
  # lambda that is passed the server dict declares it as "dict<any>", even
  # when it doesn't use it.
  var messages: list<string> = []
  var syncRpcReplies: dict<dict<any>> = {}
  var supersedableRequests: dict<dict<number>> = {}
  var diagnosticResultIds: dict<string> = {}
  var pendingPullBufnrs: dict<bool> = {}
  var workDoneProgressTokens: dict<bool> = {}
  var cachedBufferContent: dict<list<string>> = {}
  var cachedBufferEol: dict<bool> = {}
  var docVersions: dict<number> = {}
  var docBufnrs: dict<number> = {}

  var lspserver: dict<any> = {
    id: GetUniqueServerId(),
    name: serverParams.name,
    path: serverParams.path,
    args: serverParams.args->deepcopy(),
    running: false,
    ready: false,
    stoppedByUser: false,
    job: v:none,
    data: '',
    caps: {},
    callHierarchyType: '',
    completionTriggerChars: [],
    onTypeFormattingTriggers: [],
    customNotificationHandlers: serverParams.customNotificationHandlers->deepcopy(),
    customRequestHandlers: serverParams.customRequestHandlers->deepcopy(),
    debug: serverParams.debug,
    features: serverParams.features->deepcopy(),
    forceOffsetEncoding: serverParams.forceOffsetEncoding,
    initializationOptions: serverParams.initializationOptions->deepcopy(),
    languageId: serverParams.languageId,
    messages: messages,
    needOffsetEncoding: false,
    omniCompletePending: false,
    completeItemsIsIncomplete: false,
    nextSyncRpcId: SYNC_RPC_FIRST_ID,
    syncRpcReplies: syncRpcReplies,
    supersedableRequests: supersedableRequests,
    peekSymbolFilePopup: -1,
    peekSymbolPopup: -1,
    processDiagHandler: serverParams.processDiagHandler,
    diagnosticResultIds: diagnosticResultIds,
    diagnosticPullTimer: -1,
    pendingPullBufnrs: pendingPullBufnrs,
    supportsDidOpenClose: false,
    supportsDidSave: false,
    supportsWillSave: false,
    supportsWillSaveWaitUntil: false,
    supportsWorkDoneProgress: false,
    sawWorkDoneProgressEnd: false,
    workDoneProgressTokens: workDoneProgressTokens,
    rootSearchFiles: serverParams.rootSearch->deepcopy(),
    runIfSearchFiles: serverParams.runIfSearch->deepcopy(),
    runUnlessSearchFiles: serverParams.runUnlessSearch->deepcopy(),
    selection: {},
    signaturePopup: -1,
    cachedBufferContent: cachedBufferContent,
    cachedBufferEol: cachedBufferEol,
    docVersions: docVersions,
    docBufnrs: docBufnrs,
    syncInit: serverParams.syncInit,
    traceLevel: serverParams.traceLevel,
    typeHierFilePopup: -1,
    typeHierPopup: -1,
    workspaceConfig: serverParams.workspaceConfig->deepcopy(),
    workspaceSymbolPopup: -1,
    workspaceSymbolQuery: ''
  }
  lspserver.logfile = $'lsp-{lspserver.name}.log'
  lspserver.errfile = $'lsp-{lspserver.name}.err'

  # Add the LSP server functions
  lspserver->extend({
    startServer: function(StartServer, [lspserver]),
    initServer: function(InitServer, [lspserver]),
    stopServer: function(StopServer, [lspserver]),
    shutdownServer: function(ShutdownServer, [lspserver]),
    exitServer: function(ExitServer, [lspserver]),
    setTrace: function(SetTrace, [lspserver]),
    traceLog: function(TraceLog, [lspserver]),
    errorLog: function(ErrorLog, [lspserver]),
    createResponse: function(CreateResponse, [lspserver]),
    sendResponse: function(SendResponse, [lspserver]),
    sendMessage: function(SendMessage, [lspserver]),
    sendNotification: function(SendNotification, [lspserver]),
    cancelRequest: function(CancelRequest, [lspserver]),
    rpc: function(Rpc, [lspserver]),
    rpc_a: function(AsyncRpc, [lspserver]),
    processNotif: function(handlers.ProcessNotif, [lspserver]),
    processRequest: function(handlers.ProcessRequest, [lspserver]),
    processMessage: function(handlers.ProcessMessage, [lspserver]),
    encodePosition: function(offset.EncodePosition, [lspserver]),
    decodePosition: function(offset.DecodePosition, [lspserver]),
    encodeRange: function(offset.EncodeRange, [lspserver]),
    decodeRange: function(offset.DecodeRange, [lspserver]),
    encodeLocation: function(offset.EncodeLocation, [lspserver]),
    decodeLocation: function(offset.DecodeLocation, [lspserver]),
    getPosition: function(GetPosition, [lspserver]),
    getTextDocPosition: function(GetTextDocPosition, [lspserver]),
    featureEnabled: function(FeatureEnabled, [lspserver]),
    textdocDidOpen: function(TextdocDidOpen, [lspserver]),
    textdocDidClose: function(TextdocDidClose, [lspserver]),
    textdocDidChange: function(TextdocDidChange, [lspserver]),
    textdocEolChanged: function(TextdocEolChanged, [lspserver]),
    sendInitializedNotif: function(SendInitializedNotif, [lspserver]),
    sendWorkspaceConfig: function(SendWorkspaceConfig, [lspserver]),
    getCompletion: function(GetCompletion, [lspserver]),
    resolveCompletion: function(ResolveCompletion, [lspserver]),
    cancelCompletion: function(CancelCompletion, [lspserver]),
    gotoDefinition: function(GotoDefinition, [lspserver]),
    gotoDeclaration: function(GotoDeclaration, [lspserver]),
    gotoTypeDef: function(GotoTypeDef, [lspserver]),
    gotoImplementation: function(GotoImplementation, [lspserver]),
    tagFunc: function(TagFunc, [lspserver]),
    switchSourceHeader: function(SwitchSourceHeader, [lspserver]),
    showSignature: function(ShowSignature, [lspserver]),
    willSaveFile: function(WillSaveFile, [lspserver]),
    didSaveFile: function(DidSaveFile, [lspserver]),
    hover: function(ShowHoverInfo, [lspserver]),
    showReferences: function(ShowReferences, [lspserver]),
    findLocations: function(FindLocations, [lspserver]),
    docHighlight: function(DocHighlight, [lspserver]),
    getDocSymbols: function(GetDocSymbols, [lspserver]),
    textDocFormat: function(TextDocFormat, [lspserver]),
    textDocOnTypeFormat: function(TextDocOnTypeFormat, [lspserver]),
    prepareCallHierarchy: function(PrepareCallHierarchy, [lspserver]),
    incomingCalls: function(IncomingCalls, [lspserver]),
    getIncomingCalls: function(GetIncomingCalls, [lspserver]),
    outgoingCalls: function(OutgoingCalls, [lspserver]),
    getOutgoingCalls: function(GetOutgoingCalls, [lspserver]),
    inlayHintsShow: function(InlayHintsShow, [lspserver]),
    typeHierarchy: function(TypeHierarchy, [lspserver]),
    renameSymbol: function(RenameSymbol, [lspserver]),
    codeActionAsync: function(CodeActionAsync, [lspserver]),
    pullDiagnostics: function(PullDiagnostics, [lspserver]),
    queuePullDiagnostics: function(QueuePullDiagnostics, [lspserver]),
    queuePullDiagnosticsAllBuffers: function(QueuePullDiagnosticsAllBuffers, [lspserver]),
    codeLens: function(CodeLens, [lspserver]),
    resolveCodeAction: function(ResolveCodeAction, [lspserver]),
    resolveCodeLens: function(ResolveCodeLens, [lspserver]),
    showDocumentLinks: function(ShowDocumentLinks, [lspserver]),
    openDocumentLink: function(OpenDocumentLink, [lspserver]),
    resolveDocumentLink: function(ResolveDocumentLink, [lspserver]),
    workspaceQuery: function(WorkspaceQuerySymbols, [lspserver]),
    addWorkspaceFolder: function(AddWorkspaceFolder, [lspserver]),
    removeWorkspaceFolder: function(RemoveWorkspaceFolder, [lspserver]),
    selectionRange: function(SelectionRange, [lspserver]),
    selectionExpand: function(SelectionExpand, [lspserver]),
    selectionShrink: function(SelectionShrink, [lspserver]),
    foldRange: function(FoldRange, [lspserver]),
    executeCommand: function(ExecuteCommand, [lspserver]),
    workspaceConfigGet: function(WorkspaceConfigGet, [lspserver]),
    semanticHighlightUpdate: function(SemanticHighlightUpdate, [lspserver]),
    getCapabilities: function(GetCapabilities, [lspserver]),
    getInitializeRequest: function(GetInitializeRequest, [lspserver]),
    addMessage: function(AddMessage, [lspserver]),
    getMessages: function(GetMessages, [lspserver])
  })

  return lspserver
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
