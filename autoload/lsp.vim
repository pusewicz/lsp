vim9script

# Need Vim 8.2.2082 and higher
if v:version < 802 || !has('patch-8.2.2082')
  finish
endif

# Vim LSP client

var lsp_servers: dict<dict<any>> = {}

var lsp_log_dir: string = '/tmp/'

prop_type_add('LSPTextRef', {'highlight': 'Search'})
prop_type_add('LSPReadRef', {'highlight': 'DiffChange'})
prop_type_add('LSPWriteRef', {'highlight': 'DiffDelete'})

# process the 'initialize' method reply from the LSP server
def LSPprocessInitializeReply(ftype: string, reply: dict<any>): void
  if reply.result->len() <= 0
    return
  endif

  # interface 'InitializeResult'
  var caps: dict<any> = reply.result.capabilities
  lsp_servers[ftype].caps = caps
  if caps->has_key('signatureHelpProvider')
    var triggers = caps.signatureHelpProvider.triggerCharacters
    for ch in triggers
      exe 'inoremap <buffer> <silent> ' .. ch .. ' ' .. ch .. "<C-R>=lsp#showSignature()<CR>"
    endfor
  endif

  # send a "initialized" notification to server
  lsp#send_initialized(ftype)
enddef

# process the 'textDocument/definition' / 'textDocument/declaration' method
# replies from the LSP server
def LSPprocessDefDeclReply(reply: dict<any>): void
  if reply.result->empty()
    echomsg "Error: definition is not found"
    return
  endif

  var result: dict<any> = reply.result[0]
  var file = result.uri[7:]
  var wid = bufwinid(file)
  if wid != -1
    win_gotoid(wid)
  else
    exe 'split ' .. file
  endif
  cursor(result.range.start.line + 1, result.range.start.character + 1)
  redraw!
enddef

# process the 'textDocument/signatureHelp' reply from the LSP server
def LSPprocessSignaturehelpReply(reply: dict<any>): void
  var result: dict<any> = reply.result
  if result.signatures->len() <= 0
    echomsg 'No signature help available'
    return
  endif

  var sig: dict<any> = result.signatures[result.activeSignature]
  var text = sig.label
  var hllen = 0
  var startcol = 0
  var params_len = sig.parameters->len()
  if params_len > 0 && result.activeParameter < params_len
    var label = sig.parameters[result.activeParameter].label
    hllen = label->len()
    startcol = text->stridx(label)
  endif
  var popupID = popup_atcursor(text, {})
  prop_type_add('signature', {'bufnr': popupID->winbufnr(), 'highlight': 'Title'})
  if hllen > 0
    prop_add(1, startcol + 1, {'bufnr': popupID->winbufnr(), 'length': hllen, 'type': 'signature'})
  endif
enddef

def LspCompleteItemKindChar(kind: number): string
  var kindMap: list<string> = ['',
                    't', # Text
                    'm', # Method
                    'f', # Function
                    'C', # Constructor
                    'F', # Field
                    'v', # Variable
                    'c', # Class
                    'i', # Interface
                    'M', # Module
                    'p', # Property
                    'u', # Unit
                    'V', # Value
                    'e', # Enum
                    'k', # Keyword
                    'S', # Snippet
                    'C', # Color
                    'f', # File
                    'r', # Reference
                    'F', # Folder
                    'E', # EnumMember
                    'd', # Contant
                    's', # Struct
                    'E', # Event
                    'o', # Operator
                    'T'  # TypeParameter
                    ]
  if kind > 25
    return ''
  endif
  return kindMap[kind]
enddef

# process the 'textDocument/completion' reply from the LSP server
def LSPprocessCompletionReply(ftype: string, reply: dict<any>): void
  var items: list<dict<any>> = reply.result.items

  for item in items
    var d: dict<any> = {}
    if item->has_key('insertText')
      d.word = item.insertText
    elseif item->has_key('textEdit')
      d.word = item.textEdit.newText
    else
      continue
    endif
    if item->has_key('kind')
      # namespace CompletionItemKind
      # map LSP kind to complete-item-kind
      d.kind = LspCompleteItemKindChar(item.kind)
    endif
    lsp_servers[ftype].completeItems->add(d)
  endfor

  lsp_servers[ftype].completePending = v:false
enddef

# process the 'textDocument/hover' reply from the LSP server
def LSPprocessHoverReply(ftype: string, reply: dict<any>): void
  if type(reply.result) == v:t_none
    return
  endif

  if reply.result.contents.kind == 'plaintext'
    reply.result.contents.value->split("\n")->popup_atcursor({'moved': 'word'})
  else
    echomsg 'Error: Unsupported hover contents type (' .. reply.result.contents.kind .. ')'
  endif
enddef

# process the 'textDocument/references' reply from the LSP server
def LSPprocessReferencesReply(ftype: string, reply: dict<any>): void
  if type(reply.result) == v:t_none || reply.result->empty()
    echomsg 'Error: No references found'
    return
  endif

  # create a quickfix list with the location of the references
  var locations: list<dict<any>> = reply.result
  var qflist: list<dict<any>> = []
  for loc in locations
    var fname: string = loc.uri[7:]
    var text: string = fname->getbufline(loc.range.start.line + 1)[0]
                                    ->trim("\t ", 1)
    qflist->add({'filename': fname,
                    'lnum': loc.range.start.line + 1,
                    'col': loc.range.start.character + 1,
                    'text': text})
  endfor
  call setqflist([], ' ', {'title': 'Language Server', 'items': qflist})
  var save_winid = win_getid()
  copen
  win_gotoid(save_winid)
enddef

# process the 'textDocument/documentHighlight' reply from the LSP server
def LSPprocessDocHighlightReply(ftype: string, req: dict<any>, reply: dict<any>): void
  if reply.result->empty()
    return
  endif

  var fname: string = req.params.textDocument.uri[7:]
  var bnum = bufnr(fname)

  for docHL in reply.result
    var kind: number = docHL->get('kind', 1)
    var propName: string
    if kind == 2
      # Read-access
      propName = 'LSPReadRef'
    elseif kind == 3
      # Write-access
      propName = 'LSPWriteRef'
    else
      # textual reference
      propName = 'LSPTextRef'
    endif
    prop_add(docHL.range.start.line + 1, docHL.range.start.character + 1,
               {'end_lnum': docHL.range.end.line + 1,
                'end_col': docHL.range.end.character + 1,
                'bufnr': bnum,
                'type': propName})
  endfor
enddef

def LSPSymbolKindToName(symkind: number): string
  var symbolMap: list<string> = ['', 'File', 'Module', 'Namespace', 'Package',
	'Class', 'Method', 'Property', 'Field', 'Constructor', 'Enum',
        'Interface', 'Function', 'Variable', 'Constant', 'String', 'Number',
        'Boolean', 'Array', 'Object', 'Key', 'Null', 'EnumMember', 'Struct',
        'Event', 'Operator', 'TypeParameter']
  if symkind > 26
    return ''
  endif
  return symbolMap[symkind]
enddef

def lsp#jumpToSymbol()
  var lnum: number = line('.') - 1
  if w:lsp_info.data[lnum]->empty()
    return
  endif

  var slnum: number = w:lsp_info.data[lnum].lnum
  var scol: number = w:lsp_info.data[lnum].col
  var wid: number = bufwinid(w:lsp_info.filename)
  if wid == -1
    :exe 'rightbelow vertical split ' .. w:lsp_info.filename
  else
    win_gotoid(wid)
  endif
  cursor(slnum, scol)
enddef

# process the 'textDocument/documentSymbol' reply from the LSP server
def LSPprocessDocSymbolReply(ftype: string, req: dict<any>, reply: dict<any>): void
  if reply.result->empty()
    echomsg "No symbols are found"
    return
  endif

  var symbols: dict<list<dict<any>>>
  var symbolType: string

  var fname: string = req.params.textDocument.uri[7:]
  for symbol in reply.result
    symbolType = LSPSymbolKindToName(symbol.kind)
    if !symbols->has_key(symbolType)
      symbols[symbolType] = []
    endif
    var name: string = symbol.name
    if symbol->has_key('containerName')
      if symbol.containerName != ''
        name ..= ' [' .. symbol.containerName .. ']'
      endif
    endif
    symbols[symbolType]->add({'name': name,
                              'lnum': symbol.location.range.start.line + 1,
                              'col': symbol.location.range.start.character + 1})
  endfor

  var wid: number = bufwinid('LSP-Symbols')
  if wid == -1
    :20vnew LSP-Symbols
  else
    win_gotoid(wid)
  endif

  :setlocal modifiable
  :silent! :%d _
  :setlocal buftype=nofile
  :setlocal noswapfile
  :setlocal nonumber fdc=0 nowrap winfixheight winfixwidth
  setline(1, ['# Language Server Symbols', '# ' .. fname])
  # First two lines in the buffer display comment information
  var lnumMap: list<dict<number>> = [{}, {}]
  var text: list<string> = []
  for [symType, syms] in items(symbols)
    text->extend(['', symType])
    lnumMap->extend([{}, {}])
    for s in syms
      text->add('  ' .. s.name)
      lnumMap->add({'lnum': s.lnum, 'col': s.col})
    endfor
  endfor
  append(line('$'), text)
  w:lsp_info = {'filename': fname, 'data': lnumMap}
  :nnoremap <silent> <buffer> q :quit<CR>
  :nnoremap <silent> <buffer> <CR> :call lsp#jumpToSymbol()<CR>
  :setlocal nomodifiable
enddef

# Process varous reply messages from the LSP server
def lsp#process_reply(ftype: string, req: dict<any>, reply: dict<any>): void
  if req.method == 'initialize'
    LSPprocessInitializeReply(ftype, reply)
  elseif req.method == 'textDocument/definition'
                || req.method == 'textDocument/declaration'
                || req.method == 'textDocument/typeDefinition'
                || req.method == 'textDocument/implementation'
    LSPprocessDefDeclReply(reply)
  elseif req.method == 'textDocument/signatureHelp'
    LSPprocessSignaturehelpReply(reply)
  elseif req.method == 'textDocument/completion'
    LSPprocessCompletionReply(ftype, reply)
  elseif req.method == 'textDocument/hover'
    LSPprocessHoverReply(ftype, reply)
  elseif req.method == 'textDocument/references'
    LSPprocessReferencesReply(ftype, reply)
  elseif req.method == 'textDocument/documentHighlight'
    LSPprocessDocHighlightReply(ftype, req, reply)
  elseif req.method == 'textDocument/documentSymbol'
    LSPprocessDocSymbolReply(ftype, req, reply)
  else
    echomsg "Error: Unsupported reply received from LSP server: " .. string(reply)
  endif
enddef

def lsp#process_server_msg(ftype: string): void
  while lsp_servers[ftype].data->len() > 0
    var idx = stridx(lsp_servers[ftype].data, 'Content-Length: ')
    if idx == -1
      return
    endif

    var len = str2nr(lsp_servers[ftype].data[idx + 16:])
    if len == 0
      echomsg "Error: Content length is zero"
      return
    endif

    # Header and contents are separated by '\r\n\r\n'
    idx = stridx(lsp_servers[ftype].data, "\r\n\r\n")
    if idx == -1
      echomsg "Error: Content separator is not found"
      return
    endif

    idx = idx + 4

    if lsp_servers[ftype].data->len() - idx < len
      echomsg "Error: Didn't receive the complete message"
      return
    endif

    var content = lsp_servers[ftype].data[idx : idx + len - 1]
    var reply = content->json_decode()

    if reply->has_key('id')
      var req = lsp_servers[ftype].requests->get(string(reply.id))
      # Remove the corresponding stored request message
      lsp_servers[ftype].requests->remove(string(reply.id))

      if reply->has_key('error')
        var msg: string = reply.error.message
        if reply.error->has_key('data')
          msg = msg .. ', data = ' .. reply.error.message
        endif
        echomsg "Error: request " .. req.method .. " failed (" .. msg .. ")"
      else
        lsp#process_reply(ftype, req, reply)
      endif
    else
      if reply.method == 'textDocument/publishDiagnostics'
        # Todo: process the diagnostics from the LSP server
        lsp_servers[ftype].diags = reply.params.diagnostics
      else
        echomsg 'Error: Unsupported notification received from LSP server ' .. string(reply)
      endif
    endif

    lsp_servers[ftype].data = lsp_servers[ftype].data[idx + len :]
  endwhile
enddef

def lsp#output_cb(ftype: string, chan: channel, msg: string): void
  writefile(split(msg, "\n"), lsp_log_dir .. 'lsp_server.out', 'a')
  lsp_servers[ftype].data = lsp_servers[ftype].data .. msg
  lsp#process_server_msg(ftype)
enddef

def lsp#error_cb(ftype: string, chan: channel, emsg: string,): void
  writefile(split(emsg, "\n"), lsp_log_dir .. 'lsp_server.err', 'a')
enddef

def lsp#exit_cb(ftype: string, job: job, status: number): void
  echomsg "LSP server exited with status " .. status
enddef

# Return the next id for a LSP server request message
def lsp#next_reqid(ftype: string): number
  var id = lsp_servers[ftype].nextID
  lsp_servers[ftype].nextID = id + 1
  return id
enddef

# Send a request message to LSP server
def LSPsendto_server(ftype: string, content: dict<any>): void
  var req_js: string = content->json_encode()
  var msg = "Content-Length: " .. req_js->len() .. "\r\n\r\n"
  var ch = lsp_servers[ftype].job->job_getchannel()
  ch->ch_sendraw(msg)
  ch->ch_sendraw(req_js)
enddef

def lsp#create_reqmsg(ftype: string, method: string): dict<any>
  var req = {}
  req.jsonrpc = '2.0'
  req.id = lsp#next_reqid(ftype)
  req.method = method
  req.params = {}

  # Save the request, so that the corresponding response can be processed
  lsp_servers[ftype].requests->extend({[string(req.id)]: req})

  return req
enddef

def lsp#create_notifmsg(ftype: string, notif: string): dict<any>
  var req = {}
  req.jsonrpc = '2.0'
  req.method = notif
  req.params = {}

  return req
enddef

# Send a "initialize" LSP request
def lsp#init_server(ftype: string)
  var req = lsp#create_reqmsg(ftype, 'initialize')

  # interface 'InitializeParams'
  var initparams: dict<any> = {}
  initparams.processId = getpid()
  initparams.clientInfo = {'name': 'Vim', 'version': string(v:versionlong)}
  req.params->extend(initparams)

  LSPsendto_server(ftype, req)
enddef

# Send a "initialized" LSP notification
def lsp#send_initialized(ftype: string)
  var notif: dict<any> = lsp#create_notifmsg(ftype, 'initialized')
  LSPsendto_server(ftype, notif)
enddef

# Start a LSP server
def lsp#start_server(ftype: string): number
  if lsp_servers[ftype].running
    echomsg "LSP server for " .. ftype .. " is already running"
    return 0
  endif

  var cmd = [lsp_servers[ftype].path]
  cmd->extend(lsp_servers[ftype].args)

  var opts = {'in_mode': 'raw',
              'out_mode': 'raw',
              'err_mode': 'raw',
              'noblock': 1,
              'out_cb': function('lsp#output_cb', [ftype]),
              'err_cb': function('lsp#error_cb', [ftype]),
              'exit_cb': function('lsp#exit_cb', [ftype])}

  writefile([], lsp_log_dir .. 'lsp_server.out')
  writefile([], lsp_log_dir .. 'lsp_server.err')
  lsp_servers[ftype].data = ''
  lsp_servers[ftype].caps = {}
  lsp_servers[ftype].nextID = 1
  lsp_servers[ftype].requests = {}
  lsp_servers[ftype].completePending = v:false

  var job = job_start(cmd, opts)
  if job->job_status() == 'fail'
    echomsg "Error: Failed to start LSP server " .. lsp_servers[ftype].path
    return 1
  endif

  # wait for the LSP server to start
  sleep 10m

  lsp_servers[ftype].job = job
  lsp_servers[ftype].running = v:true

  lsp#init_server(ftype)

  return 0
enddef

# Send a 'shutdown' request to the LSP server
def lsp#shutdown_server(ftype: string): void
  var req = lsp#create_reqmsg(ftype, 'shutdown')
  LSPsendto_server(ftype, req)
enddef

# Send a 'exit' notification to the LSP server
def lsp#exit_server(ftype: string): void
  var notif: dict<any> = lsp#create_notifmsg(ftype, 'exit')
  LSPsendto_server(ftype, notif)
enddef

# Stop a LSP server
def lsp#stop_server(ftype: string): number
  if !lsp_servers[ftype].running
    echomsg "LSP server for " .. ftype .. " is not running"
    return 0
  endif

  lsp#shutdown_server(ftype)

  # Wait for the server to process the shutodwn request
  sleep 1

  lsp#exit_server(ftype)

  lsp_servers[ftype].job->job_stop()
  lsp_servers[ftype].job = v:none
  lsp_servers[ftype].running = v:false
  lsp_servers[ftype].requests = {}
  return 0
enddef

# Send a LSP "textDocument/didOpen" notification
def lsp#textdoc_didopen(bnum: number, ftype: string): void
  var notif: dict<any> = lsp#create_notifmsg(ftype, 'textDocument/didOpen')

  # interface DidOpenTextDocumentParams
  # interface TextDocumentItem
  var tdi = {}
  tdi.uri = 'file://' .. fnamemodify(bufname(bnum), ':p')
  tdi.languageId = ftype
  tdi.version = 1
  tdi.text = getbufline(bnum, 1, '$')->join("\n") .. "\n"
  notif.params->extend({'textDocument': tdi})

  LSPsendto_server(ftype, notif)
enddef

# Send a LSP "textDocument/didClose" notification
def lsp#textdoc_didclose(fname: string, ftype: string): void
  var notif: dict<any> = lsp#create_notifmsg(ftype, 'textDocument/didClose')

  # interface DidCloseTextDocumentParams
  #   interface TextDocumentIdentifier
  var tdid = {}
  tdid.uri = 'file://' .. fname
  notif.params->extend({'textDocument': tdid})

  LSPsendto_server(ftype, notif)
enddef

# Goto a definition using "textDocument/definition" LSP request
def lsp#gotoDefinition(fname: string, ftype: string, lnum: number, col: number)
  if fname == '' || ftype == ''
    return
  endif
  if !lsp_servers->has_key(ftype)
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
    return
  endif
  if !lsp_servers[ftype].running
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
    return
  endif

  # Check whether LSP server supports jumping to a definition
  if !lsp_servers[ftype].caps->has_key('definitionProvider')
              || !lsp_servers[ftype].caps.definitionProvider
    echomsg "Error: LSP server does not support jumping to a definition"
    return
  endif

  var req = lsp#create_reqmsg(ftype, 'textDocument/definition')

  # interface DefinitionParams
  # interface TextDocumentPositionParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': 'file://' .. fname}})
  # interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSPsendto_server(ftype, req)
enddef

# Goto a declaration using "textDocument/declaration" LSP request
def lsp#gotoDeclaration(fname: string, ftype: string, lnum: number, col: number)
  if fname == '' || ftype == ''
    return
  endif
  if !lsp_servers->has_key(ftype)
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
    return
  endif
  if !lsp_servers[ftype].running
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
    return
  endif

  # Check whether LSP server supports jumping to a declaration
  if !lsp_servers[ftype].caps->has_key('declarationProvider')
              || !lsp_servers[ftype].caps.declarationProvider
    echomsg "Error: LSP server does not support jumping to a declaration"
    return
  endif

  var req = lsp#create_reqmsg(ftype, 'textDocument/declaration')

  # interface DeclarationParams
  #   interface TextDocumentPositionParams
  #     interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': 'file://' .. fname}})
  #     interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSPsendto_server(ftype, req)
enddef

# Go to a type definition using "textDocument/typeDefinition" LSP request
def lsp#gotoTypedef(fname: string, ftype: string, lnum: number, col: number)
  if fname == '' || ftype == ''
    return
  endif
  if !lsp_servers->has_key(ftype)
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
    return
  endif
  if !lsp_servers[ftype].running
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
    return
  endif

  # Check whether LSP server supports jumping to a type definition
  if !lsp_servers[ftype].caps->has_key('typeDefinitionProvider')
              || !lsp_servers[ftype].caps.typeDefinitionProvider
    echomsg "Error: LSP server does not support jumping to a type definition"
    return
  endif

  var req = lsp#create_reqmsg(ftype, 'textDocument/typeDefinition')

  # interface TypeDefinitionParams
  #   interface TextDocumentPositionParams
  #     interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': 'file://' .. fname}})
  #     interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSPsendto_server(ftype, req)
enddef

# Go to a implementation using "textDocument/implementation" LSP request
def lsp#gotoImplementation(fname: string, ftype: string, lnum: number, col: number)
  if fname == '' || ftype == ''
    return
  endif
  if !lsp_servers->has_key(ftype)
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
    return
  endif
  if !lsp_servers[ftype].running
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
    return
  endif

  # Check whether LSP server supports jumping to a type definition
  if !lsp_servers[ftype].caps->has_key('implementationProvider')
              || !lsp_servers[ftype].caps.implementationProvider
    echomsg "Error: LSP server does not support jumping to an implementation"
    return
  endif

  var req = lsp#create_reqmsg(ftype, 'textDocument/implementation')

  # interface ImplementationParams
  #   interface TextDocumentPositionParams
  #     interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': 'file://' .. fname}})
  #     interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSPsendto_server(ftype, req)
enddef

# Show the signature using "textDocument/signatureHelp" LSP method
# Invoked from an insert-mode mapping, so return an empty string.
def lsp#showSignature(): string

  # first send all the changes in the current buffer to the LSP server
  listener_flush()

  var ftype: string = &filetype
  if ftype == ''
    return ''
  endif

  if !lsp_servers->has_key(ftype)
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
    return ''
  endif
  if !lsp_servers[ftype].running
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
    return ''
  endif

  var fname: string = expand('%:p')
  if fname == ''
    return ''
  endif

  var lnum: number = line('.') - 1
  var col: number = col('.') - 1

  var req = lsp#create_reqmsg(ftype, 'textDocument/signatureHelp')
  # interface SignatureHelpParams
  #   interface TextDocumentPositionParams
  #     interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': 'file://' .. fname}})
  #     interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSPsendto_server(ftype, req)
  return ''
enddef

# buffer change notification listener
def lsp#bufchange_listener(bnum: number, start: number, end: number, added: number, changes: list<dict<number>>)
  var ftype = getbufvar(bnum, '&filetype')
  var notif: dict<any> = lsp#create_notifmsg(ftype, 'textDocument/didChange')

  # interface DidChangeTextDocumentParams
  #   interface VersionedTextDocumentIdentifier
  var vtdid: dict<any> = {}
  vtdid.uri = 'file://' .. fnamemodify(bufname(bnum), ':p')
  # Use Vim 'changedtick' as the LSP document version number
  vtdid.version = getbufvar(bnum, 'changedtick')
  notif.params->extend({'textDocument': vtdid})
  #   interface TextDocumentContentChangeEvent
  var changeset: list<dict<any>>

  ##### FIXME: Sending specific buffer changes to the LSP server doesn't
  ##### work properly as the computed line range numbers is not correct.
  ##### For now, send the entire content of the buffer to LSP server.
  # #     Range
  # for change in changes
  #   var lines: string
  #   var start_lnum: number
  #   var end_lnum: number
  #   var start_col: number
  #   var end_col: number
  #   if change.added == 0
  #     # lines changed
  #     start_lnum =  change.lnum - 1
  #     end_lnum = change.end - 1
  #     lines = getbufline(bnum, change.lnum, change.end - 1)->join("\n") .. "\n"
  #     start_col = 0
  #     end_col = 0
  #   elseif change.added > 0
  #     # lines added
  #     start_lnum = change.lnum - 1
  #     end_lnum = change.lnum - 1
  #     start_col = 0
  #     end_col = 0
  #     lines = getbufline(bnum, change.lnum, change.lnum + change.added - 1)->join("\n") .. "\n"
  #   else
  #     # lines removed
  #     start_lnum = change.lnum - 1
  #     end_lnum = change.lnum + (-change.added) - 1
  #     start_col = 0
  #     end_col = 0
  #     lines = ''
  #   endif
  #   var range: dict<dict<number>> = {'start': {'line': start_lnum, 'character': start_col}, 'end': {'line': end_lnum, 'character': end_col}}
  #   changeset->add({'range': range, 'text': lines})
  # endfor
  changeset->add({'text': getbufline(bnum, 1, '$')->join("\n") .. "\n"})
  notif.params->extend({'contentChanges': changeset})

  LSPsendto_server(ftype, notif)
enddef

# A new buffer is opened. If LSP is supported for this buffer, then add it
def lsp#add_file(bnum: number, ftype: string): void
  if ftype == '' || !lsp_servers->has_key(ftype)
    return
  endif
  if !lsp_servers[ftype].running
    lsp#start_server(ftype)
  endif
  lsp#textdoc_didopen(bnum, ftype)

  # Display hover information
  autocmd CursorHold <buffer> call LSPhover()

  # add a listener to track changes to this buffer
  listener_add(function('lsp#bufchange_listener'), bnum)
  setbufvar(bnum, '&completefunc', 'lsp#completeFunc')
enddef

def lsp#remove_file(fname: string, ftype: string): void
  if fname == '' || ftype == '' || !lsp_servers->has_key(ftype)
    return
  endif
  lsp#textdoc_didclose(fname, ftype)
enddef

def lsp#stop_all_servers()
  for [ftype, server] in items(lsp_servers)
    if server.running
      lsp#stop_server(ftype)
    endif
  endfor
enddef

def lsp#addServer(serverList: list<dict<any>>)
  var sinfo: dict<any>
  for server in serverList
    if !server->has_key('filetype') || !server->has_key('path') || !server->has_key('args')
      echomsg 'Error: LSP server information is missing filetype or path or args'
      continue
    endif
    sinfo.ftype = server.filetype
    sinfo.path = server.path
    if !file_readable(sinfo.path)
      echomsg 'Error: LSP server ' .. sinfo.path .. ' is not found'
      continue
    endif
    sinfo.args = server.args
    if type(sinfo.args) != v:t_list
      echomsg 'Error: Arguments for LSP server ' .. sinfo.path .. ' is not a List'
      continue
    endif
    sinfo.running = v:false
    sinfo.job = v:none
    sinfo.data = ''
    sinfo.nextID = 1
    sinfo.caps = {}
    sinfo.requests = {}
    sinfo.diags = {}
    sinfo.completePending = v:false
    lsp_servers->extend({[sinfo.ftype]: sinfo})
  endfor
enddef

def lsp#showServers()
  for [ftype, server] in items(lsp_servers)
    var msg = ftype .. "    "
    if server.running
      msg ..= 'running'
    else
      msg ..= 'not running'
    endif
    msg ..= '    ' .. server.path
    echomsg msg
  endfor
enddef

def lsp#showDiagnostics(): void
  var ftype: string = &filetype
  var msgs: list<string> = []

  for diag in lsp_servers[ftype].diags
    diag.message = diag.message->substitute("\n\\+", "\n", 'g')
    msgs->extend(split(diag.message, "\n"))
  endfor
  setqflist([], ' ', {'lines': msgs, 'title': 'Language Server'})
  cwindow
enddef

def LSPgetCompletion(): void
  var ftype = &filetype
  if ftype == ''
    return
  endif
  if !lsp_servers->has_key(ftype)
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
    return
  endif
  if !lsp_servers[ftype].running
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
    return
  endif

  var fname = expand('%:p')
  if fname == ''
    return
  endif

  var lnum = line('.') - 1
  var col = col('.') - 1

  var req = lsp#create_reqmsg(ftype, 'textDocument/completion')

  # interface CompletionParams
  # interface TextDocumentPositionParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': 'file://' .. fname}})
  # interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSPsendto_server(ftype, req)
enddef

def lsp#completeFunc(findstart: number, base: string): any
  var ftype: string = &filetype

  if findstart
    if !lsp_servers->has_key(ftype)
      echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
      return -2
    endif
    if !lsp_servers[ftype].running
      echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
      return -2
    endif

    # first send all the changes in the current buffer to the LSP server
    listener_flush()

    lsp_servers[ftype].completePending = v:true
    lsp_servers[ftype].completeItems = []
    # initiate a request to LSP server to get list of completions
    LSPgetCompletion()

    # locate the start of the word
    var line = getline('.')
    var start = col('.') - 1
    while start > 0 && line[start - 1] =~ '\k'
      start -= 1
    endwhile
    return start
  else
    while lsp_servers[ftype].completePending
      sleep 2m
    endwhile
    var res: list<dict<any>> = []
    for item in lsp_servers[ftype].completeItems
      res->add(item)
    endfor
    return res
  endif
enddef

def LSPhover()
  var ftype = &filetype
  if ftype == ''
    return
  endif

  if !lsp_servers->has_key(ftype)
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
    return
  endif
  if !lsp_servers[ftype].running
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
    return
  endif

  # Check whether LSP server supports getting hover information
  if !lsp_servers[ftype].caps->has_key('hoverProvider')
              || !lsp_servers[ftype].caps.hoverProvider
    return
  endif

  var fname = expand('%:p')
  if fname == ''
    return
  endif
  var lnum = line('.') - 1
  var col = col('.') - 1

  var req = lsp#create_reqmsg(ftype, 'textDocument/hover')
  # interface HoverParams
  # interface TextDocumentPositionParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': 'file://' .. fname}})
  # interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSPsendto_server(ftype, req)
enddef

def lsp#showReferences()
  var ftype = &filetype
  if ftype == ''
    return
  endif

  if !lsp_servers->has_key(ftype)
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
    return
  endif
  if !lsp_servers[ftype].running
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
    return
  endif

  # Check whether LSP server supports getting reference information
  if !lsp_servers[ftype].caps->has_key('referencesProvider')
              || !lsp_servers[ftype].caps.referencesProvider
    echomsg "Error: LSP server does not support showing references"
    return
  endif

  var fname = expand('%:p')
  if fname == ''
    return
  endif
  var lnum = line('.') - 1
  var col = col('.') - 1

  var req = lsp#create_reqmsg(ftype, 'textDocument/references')
  # interface ReferenceParams
  # interface TextDocumentPositionParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': 'file://' .. fname}})
  # interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})
  req.params->extend({'context': {'includeDeclaration': v:true}})

  LSPsendto_server(ftype, req)
enddef

def lsp#docHighlight()
  var ftype = &filetype
  if ftype == ''
    return
  endif

  if !lsp_servers->has_key(ftype)
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
    return
  endif
  if !lsp_servers[ftype].running
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
    return
  endif

  # Check whether LSP server supports getting reference information
  if !lsp_servers[ftype].caps->has_key('documentHighlightProvider')
              || !lsp_servers[ftype].caps.documentHighlightProvider
    echomsg "Error: LSP server does not support document highlight"
    return
  endif

  var fname = expand('%:p')
  if fname == ''
    return
  endif
  var lnum = line('.') - 1
  var col = col('.') - 1

  var req = lsp#create_reqmsg(ftype, 'textDocument/documentHighlight')
  # interface DocumentHighlightParams
  # interface TextDocumentPositionParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': 'file://' .. fname}})
  # interface Position
  req.params->extend({'position': {'line': lnum, 'character': col}})

  LSPsendto_server(ftype, req)
enddef

def lsp#docHighlightClear()
  prop_remove({'type': 'LSPTextRef', 'all': v:true}, 1, line('$'))
  prop_remove({'type': 'LSPReadRef', 'all': v:true}, 1, line('$'))
  prop_remove({'type': 'LSPWriteRef', 'all': v:true}, 1, line('$'))
enddef

def lsp#showDocSymbols()
  var ftype = &filetype
  if ftype == ''
    return
  endif

  if !lsp_servers->has_key(ftype)
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not found'
    return
  endif
  if !lsp_servers[ftype].running
    echomsg 'Error: LSP server for "' .. ftype .. '" filetype is not running'
    return
  endif

  # Check whether LSP server supports getting reference information
  if !lsp_servers[ftype].caps->has_key('documentSymbolProvider')
              || !lsp_servers[ftype].caps.documentSymbolProvider
    echomsg "Error: LSP server does not support getting list of symbols"
    return
  endif

  var fname = expand('%:p')
  if fname == ''
    return
  endif

  var req = lsp#create_reqmsg(ftype, 'textDocument/documentSymbol')
  # interface DocumentSymbolParams
  # interface TextDocumentIdentifier
  req.params->extend({'textDocument': {'uri': 'file://' .. fname}})

  LSPsendto_server(ftype, req)
enddef

# vim: shiftwidth=2 sts=2 expandtab
