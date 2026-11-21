vim9script

import '../autoload/lsp/buffer.vim' as buf

def CaptureNotification(notifications: list<dict<any>>, method: string,
			params: any = {}): void
  notifications->add({method: method, params: params->deepcopy()})
enddef

def CaptureResponse(responses: list<dict<any>>, request: dict<any>,
		    result: any, error: dict<any>): void
  responses->add({id: request.id, result: result, error: error->deepcopy()})
enddef

def EncodeLspMessage(msg: dict<any>): string
  var body = msg->json_encode()
  return $"Content-Length: {body->len()}\r\n\r\n{body}"
enddef

def ConfigTestServerInput(logfile: string): string
  return logfile->filereadable() ? logfile->readfile()->join('') : ''
enddef

def ConfigNotification(settings: dict<any>): dict<any>
  return {method: 'workspace/didChangeConfiguration',
	  params: {settings: settings}}
enddef

def g:Test_LspServerConfigSet_RegisteredServer()
  var logfile = tempname()
  g:LspAddServer([{
    name: 'configset',
    filetype: 'lspconfigset',
    path: 'sh',
    args: ['-c', 'head -c 1 >"$2"; printf "%s" "$1"; exec cat >>"$2"', 'sh',
	   EncodeLspMessage({jsonrpc: '2.0', id: 1,
			     result: {capabilities: {}}}),
	   logfile]
  }])

  assert_equal(0, g:LspServerConfigSet('configset-unknown', {stub: {}}))
  var config = {stub: {level: 1}}
  assert_equal(1, g:LspServerConfigSet('configset', config))
  config.stub.level = 9

  silent! edit XConfigSet.txt
  setlocal filetype=lspconfigset
  var lspserver = buf.CurbufGetServers()[0]
  var SendNotification = lspserver.sendNotification
  var SendResponse = lspserver.sendResponse
  try
    g:WaitForAssert(() => assert_true(lspserver.ready))
    g:WaitForAssert(() => assert_match('"settings":{"stub":{"level":1}}',
				       ConfigTestServerInput(logfile)))

    var notifications: list<dict<any>> = []
    var responses: list<dict<any>> = []
    lspserver.sendNotification = function(CaptureNotification, [notifications])
    lspserver.sendResponse = function(CaptureResponse, [responses])

    assert_equal(1, g:LspServerConfigSet('configset', {stub: {level: 2}}))
    assert_equal([ConfigNotification({stub: {level: 2}})], notifications)
    lspserver.processRequest({id: 7, method: 'workspace/configuration',
			      params: {items: [{section: 'stub'}]}})
    assert_equal([{level: 2}], responses[0].result)

    notifications->filter('0')
    lspserver.ready = false
    assert_equal(1, g:LspServerConfigSet('configset', {stub: {level: 3}}))
    assert_equal([], notifications)
    assert_equal({stub: {level: 3}}, lspserver.workspaceConfig)
    lspserver.ready = true

    assert_equal(1, g:LspServerConfigSet('configset', {}))
    assert_equal([ConfigNotification({})], notifications)

    lspserver.sendNotification = SendNotification
    lspserver.sendResponse = SendResponse
    assert_equal(1, g:LspServerConfigSet('configset', {stub: {level: 4}}))
    g:WaitForAssert(() => assert_match('"settings":{"stub":{"level":4}}',
				       ConfigTestServerInput(logfile)))

    job_stop(lspserver.job)
    g:WaitForAssert(() => assert_false(lspserver.running))
    delete(logfile)
    :LspServer restart
    assert_true(lspserver is buf.CurbufGetServers()[0])
    g:WaitForAssert(() => assert_true(lspserver.ready))
    g:WaitForAssert(() => assert_match('"settings":{"stub":{"level":4}}',
				       ConfigTestServerInput(logfile)))
  finally
    lspserver.sendNotification = SendNotification
    lspserver.sendResponse = SendResponse
    job_stop(lspserver.job)
    g:WaitForAssert(() => assert_false(lspserver.running))
    :%bw!
    delete(logfile)
  endtry
enddef

def g:StartLangServer(): bool
  return true
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
