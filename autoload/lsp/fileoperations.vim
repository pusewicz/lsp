vim9script

import './textedit.vim'
import './util.vim'
import './watchedfiles.vim'

const WILL_CREATE = 'workspace/willCreateFiles'
const DID_CREATE = 'workspace/didCreateFiles'
const WILL_RENAME = 'workspace/willRenameFiles'
const DID_RENAME = 'workspace/didRenameFiles'

const CAPABILITY_METHODS: dict<string> = {
  willCreate: WILL_CREATE,
  didCreate: DID_CREATE,
  willRename: WILL_RENAME,
  didRename: DID_RENAME
}
const METHODS: list<string> = CAPABILITY_METHODS->values()

const CREATE_TIMEOUT_MSEC = 1000
const RENAME_TIMEOUT_MSEC = 10000

var servers: dict<dict<any>> = {}

var creating: dict<bool> = {}

def NormalizePath(path: string): string
  return path->fnamemodify(':p')->simplify()->substitute('\(.\)/\+$', '\1', '')
enddef

def CompileFilter(filter: any): dict<any>
  if filter->type() != v:t_dict
    return {}
  endif
  var scheme: any = filter->get('scheme', '')
  var pattern: any = filter->get('pattern')
  if scheme->type() != v:t_string || pattern->type() != v:t_dict
    return {}
  endif
  var glob: any = pattern->get('glob')
  var matches: any = pattern->get('matches', '')
  var options: any = pattern->get('options', {})
  if glob->type() != v:t_string || matches->type() != v:t_string
      || ['', 'file', 'folder']->index(matches) == -1
      || options->type() != v:t_dict
    return {}
  endif
  var ignoreCase: any = options->get('ignoreCase', false)
  if ignoreCase->type() != v:t_bool
    return {}
  endif
  var regex: string = watchedfiles.GlobToRegex(glob->split('\zs'))
  return {scheme: scheme, matches: matches,
	  regex: $'{ignoreCase ? '\c' : '\C'}^{regex}$'}
enddef

def CompileFilters(registerOptions: any): list<dict<any>>
  if registerOptions->type() != v:t_dict
      || registerOptions->get('filters')->type() != v:t_list
    return []
  endif
  return registerOptions.filters->mapnew((_, filter) => CompileFilter(filter))
enddef

def FilterMatches(filter: dict<any>, path: string, isFolder: bool): bool
  if !filter.scheme->empty() && filter.scheme !=# 'file'
    return false
  endif
  if !filter.matches->empty() && filter.matches !=# (isFolder ? 'folder' : 'file')
    return false
  endif
  return path =~ filter.regex
enddef

def ServerWants(entry: dict<any>, method: string, path: string,
		isFolder: bool): bool
  var lspserver: dict<any> = entry.lspserver
  if !lspserver.running || !lspserver.ready
      || !lspserver.featureEnabled('fileOperations')
    return false
  endif
  var registrations: list<dict<any>> = entry.dynamic->values()
  if entry.static->has_key(method)
    registrations->add({method: method, filters: entry.static[method]})
  endif
  for registration in registrations
    if registration.method ==# method
	&& registration.filters->indexof((_, filter) =>
	  FilterMatches(filter, path, isFolder)) != -1
      return true
    endif
  endfor
  return false
enddef

def InterestedServers(method: string, path: string,
		      isFolder: bool): list<dict<any>>
  return servers->values()
    ->filter((_, entry) => ServerWants(entry, method, path, isFolder))
    ->mapnew((_, entry) => entry.lspserver)
    ->sort((a, b) => a.id - b.id)
enddef

def SendWill(method: string, files: list<dict<string>>, path: string,
	     isFolder: bool, timeout: number): bool
  for lspserver in InterestedServers(method, path, isFolder)
    var reply: dict<any> = lspserver.rpc(method, {files: files},
      {timeout: timeout, handleError: false})
    if reply->empty()
      util.WarnMsg($'No reply to {method} from language server "{lspserver.name}"')
      continue
    endif
    if reply->has_key('error')
      util.ErrMsg($'request {method} failed ({reply.error->get("message", "")})')
      continue
    endif
    if reply.result->type() != v:t_dict || reply.result->empty()
      continue
    endif
    if !textedit.ApplyWorkspaceEdit(reply.result, lspserver).applied
      return false
    endif
  endfor
  return true
enddef

def SendDid(method: string, files: list<dict<string>>, path: string,
	    isFolder: bool)
  for lspserver in InterestedServers(method, path, isFolder)
    lspserver.sendNotification(method, {files: files})
  endfor
enddef

def WriteStarting(afile: string)
  if util.LspUriRemote(afile)
    return
  endif
  var path: string = NormalizePath(afile)
  if !path->getftype()->empty()
    if creating->has_key(path)
      creating->remove(path)
    endif
    return
  endif
  creating[path] = true
  SendWill(WILL_CREATE, [{uri: util.LspFileToUri(path)}], path, false,
	   CREATE_TIMEOUT_MSEC)
enddef

def WriteDone(afile: string)
  var path: string = NormalizePath(afile)
  if !creating->has_key(path)
    return
  endif
  creating->remove(path)
  if path->getftype()->empty()
    return
  endif
  SendDid(DID_CREATE, [{uri: util.LspFileToUri(path)}], path, false)
enddef

def UpdateAutocmds()
  if servers->empty()
    if exists('#LspFileOperations')
      autocmd_delete([{group: 'LspFileOperations'}])
    endif
    creating = {}
  elseif !exists('#LspFileOperations')
    autocmd_add([
      {group: 'LspFileOperations', pattern: '*',
       event: ['BufWritePre', 'FileWritePre', 'FileAppendPre'],
       cmd: 'WriteStarting(expand("<afile>"))'},
      {group: 'LspFileOperations', pattern: '*',
       event: ['BufWritePost', 'FileWritePost', 'FileAppendPost'],
       cmd: 'WriteDone(expand("<afile>"))'}
    ])
  endif
enddef

def ServerEntry(lspserver: dict<any>): dict<any>
  if !servers->has_key(lspserver.id)
    servers[lspserver.id] = {lspserver: lspserver, static: {}, dynamic: {}}
  endif
  return servers[lspserver.id]
enddef

def DropEmptyEntry(lspserver: dict<any>)
  var entry: dict<any> = servers->get(lspserver.id, {})
  if !entry->empty() && entry.static->empty() && entry.dynamic->empty()
    servers->remove(lspserver.id)
  endif
  UpdateAutocmds()
enddef

export def ProcessServerCaps(lspserver: dict<any>, caps: dict<any>)
  var workspace: any = caps->get('workspace', {})
  var fileOperations: any = workspace->type() == v:t_dict
    ? workspace->get('fileOperations', {}) : {}
  var staticFilters: dict<list<dict<any>>> = {}
  if fileOperations->type() == v:t_dict
    for [capability, method] in CAPABILITY_METHODS->items()
      var filters: list<dict<any>> = CompileFilters(fileOperations->get(capability))
	->filter((_, filter) => !filter->empty())
      if !filters->empty()
	staticFilters[method] = filters
      endif
    endfor
  endif
  if staticFilters->empty() && !servers->has_key(lspserver->get('id', -1))
    return
  endif
  var entry: dict<any> = ServerEntry(lspserver)
  entry.static = staticFilters
  DropEmptyEntry(lspserver)
enddef

def RegistrationKey(method: string, id: string): string
  return $"{method}\n{id}"
enddef

export def ParseRegistrations(registrations: list<any>): dict<any>
  var regs: dict<dict<any>> = {}
  for registration in registrations
    if registration->type() != v:t_dict
	|| registration->get('method')->type() != v:t_string
	|| METHODS->index(registration.method) == -1
      continue
    endif
    var method: string = registration.method
    var id: any = registration->get('id')
    var filters: list<dict<any>> = CompileFilters(registration->get('registerOptions'))
    if id->type() != v:t_string || filters->empty()
      return {error: $'{method} registration needs an id and registerOptions.filters'}
    endif
    if filters->indexof((_, filter) => filter->empty()) != -1
      return {error: $'{method} registration has a filter that is not valid'}
    endif
    regs[RegistrationKey(method, id)] = {method: method, filters: filters}
  endfor
  return {error: '', regs: regs}
enddef

export def Register(lspserver: dict<any>, regs: dict<dict<any>>)
  if regs->empty()
    return
  endif
  ServerEntry(lspserver).dynamic->extend(regs)
  UpdateAutocmds()
enddef

export def Unregister(lspserver: dict<any>, unregistrations: list<any>)
  if !servers->has_key(lspserver.id)
    return
  endif
  var dynamic: dict<any> = servers[lspserver.id].dynamic
  for unregistration in unregistrations
    if unregistration->type() != v:t_dict
	|| unregistration->get('method')->type() != v:t_string
	|| unregistration->get('id')->type() != v:t_string
      continue
    endif
    var key: string = RegistrationKey(unregistration.method, unregistration.id)
    if dynamic->has_key(key)
      dynamic->remove(key)
    endif
  endfor
  DropEmptyEntry(lspserver)
enddef

export def RemoveServer(lspserver: dict<any>)
  if servers->has_key(lspserver.id)
    servers->remove(lspserver.id)
    UpdateAutocmds()
  endif
enddef

def RenameFailed(reason: string)
  util.ErrMsg($'File rename failed, {reason}')
enddef

def ExistingDir(path: string): string
  var dir: string = path->fnamemodify(':h')
  while !dir->isdirectory() && dir !=# dir->fnamemodify(':h')
    dir = dir->fnamemodify(':h')
  endwhile
  return dir
enddef

export def RenameFile(name: string)
  var bnr: number = bufnr()
  if bnr->bufname()->empty() || !&buftype->empty()
      || util.LspUriRemote(bnr->bufname())
    RenameFailed('the current buffer is not a file')
    return
  endif
  var oldPath: string = NormalizePath(bnr->bufname())
  if oldPath->getftype()->empty()
    RenameFailed($'{oldPath} does not exist')
    return
  endif
  if &modified
    RenameFailed($'{oldPath} has unsaved changes')
    return
  endif

  var newName: string = name
  if newName->empty()
    newName = input('Rename file to: ', oldPath->fnamemodify(':~:.'), 'file')
    if newName->empty()
      return
    endif
    :echo "\r"
  endif
  var newPath: string = NormalizePath(newName)
  if newName =~ '/$' || newPath->isdirectory()
    newPath = NormalizePath($'{newPath}/{oldPath->fnamemodify(':t')}')
  endif
  if newPath ==# oldPath
    return
  endif

  if !newPath->getftype()->empty() && newPath !=? oldPath
    RenameFailed($'{newPath} already exists')
    return
  endif
  var newBnr: number = util.BufnrExact(newPath)
  if newBnr > 0 && newBnr != bnr && newBnr->getbufvar('&modified')
    RenameFailed($'{newPath} has unsaved changes')
    return
  endif
  for dir in [ExistingDir(oldPath), ExistingDir(newPath)]
    if dir->filewritable() != 2
      RenameFailed($'{dir} is not writable')
      return
    endif
  endfor

  var files: list<dict<string>> = [{oldUri: util.LspFileToUri(oldPath),
				    newUri: util.LspFileToUri(newPath)}]
  if !SendWill(WILL_RENAME, files, oldPath, false, RENAME_TIMEOUT_MSEC)
    return
  endif

  var failureReason: string
  try
    failureReason = textedit.FileRename(files[0])
  catch
    failureReason = v:exception
  endtry
  if !failureReason->empty()
    util.ErrMsg(failureReason)
    return
  endif

  if bnr->getbufvar('&modified')
    try
      util.ExecuteInBuffer(bnr, 'silent write!')
    catch
      util.ErrMsg(v:exception)
    endtry
  endif

  SendDid(DID_RENAME, files, oldPath, false)
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
