vim9script

# Send the language servers the changes to the files that they watch, with the
# "workspace/didChangeWatchedFiles" notification.  A language server registers
# the files that it watches with the "client/registerCapability" request.  The
# changes that Vim makes to files are sent as Vim makes them, and the changes
# that other programs make as the fswatch program reports them.
#
# Refer to https://microsoft.github.io/language-server-protocol/specification
# for the Language Server Protocol (LSP) specification.

import './options.vim' as opt
import './util.vim'

# FileChangeType
export const FILE_CREATED = 1
export const FILE_CHANGED = 2
export const FILE_DELETED = 3

# WatchKind
const WATCH_CREATE = 1
const WATCH_CHANGE = 2
const WATCH_DELETE = 4

# The WatchKind of each FileChangeType
const WATCH_KINDS: list<number> = [0, WATCH_CREATE, WATCH_CHANGE, WATCH_DELETE]

const METHOD = 'workspace/didChangeWatchedFiles'

# The changes are sent this long after the first one of them, together with
# the ones made in the meantime.  This is longer than fswatch takes to report a
# change that Vim made, so that such a change is usually sent once.
const SEND_DELAY_MSEC = 200

# How long fswatch waits for more events before it reports them, in seconds
const FSWATCH_LATENCY = '0.1'

# The most paths that "knownPaths" holds
const KNOWN_PATHS_MAX = 10000

# The file system watchers that each language server registered, by server
# ID: {lspserver: <server>, regs: {<registration ID>: <watchers>}}.  See
# CompileWatcher() for a watcher.
var servers: dict<dict<any>> = {}

# The changes to send, by path: {type: <FileChangeType>, byVim: <bool>}, and
# their paths in the order of the changes.  A path can be in "pendingPaths"
# more than once, and with no change in "pendingChanges".
var pendingChanges: dict<dict<any>> = {}
var pendingPaths: list<string> = []
var sendTimer: number = -1

# Whether a file exists, by path, after the last change sent for it.  fswatch
# can't tell a created file from a changed one: FSEvents reports a file as
# created for some time after it was.
var knownPaths: dict<bool> = {}

# Whether a file that Vim is writing existed before, by path
var writtenFileExisted: dict<bool> = {}

# The fswatch job and the directories that it watches.  "watchedDirs" are the
# directories that the watchers are for: {path: <directory>, real: <directory
# with its symbolic links resolved>}.  fswatch watches each "real" directory
# that is not in another one, and reports the files in it by their real path.
var fswatchJob: job = null_job
var fswatchDirs: list<string> = []
var watchedDirs: list<dict<string>> = []

# Returns true when the changes that other programs make to files can be sent
# to the language servers: the "watchFiles" option is set and the fswatch
# program is found.  Only then are the language servers offered to register
# the files that they watch, as a language server that can watch files itself,
# like rust-analyzer, does that when the client doesn't.
export def CanWatch(): bool
  return opt.lspOptions.watchFiles && executable('fswatch') == 1
enddef

# Returns the full path "path" without a "/" at the end.
def NormalizePath(path: string): string
  return path->fnamemodify(':p')->substitute('\(.\)/$', '\1', '')
enddef

# Returns true when "path" is in the directory "dir" or below it.  Like Vim,
# this ignores the case of file names, as macOS does.
def InDir(path: string, dir: string): bool
  var prefix: string = dir =~ '/$' ? dir : $'{dir}/'
  return path->strpart(0, prefix->len()) ==? prefix
enddef

# Returns a regular expression for the glob pattern made of the characters
# "chars", taking them from the list.  In a group ("inGroup") this stops at
# the "," or "}" that ends an alternative of the group and leaves it in the
# list.
#
# "*" matches any characters of a path segment, "?" one character of a path
# segment, and "**" as a path segment any number of path segments, also none.
# "{a,b}" matches either alternative, "[a-z]" one of the characters and
# "[!a-z]" a character that is not one of them.
def GlobToRegex(chars: list<string>, inGroup: bool = false): string
  var regex: string = ''
  # The character before the next one, empty at the start of the pattern or
  # of the alternative
  var prev: string = ''
  while !chars->empty()
    var c: string = chars[0]
    if inGroup && (c == ',' || c == '}')
      break
    endif
    chars->remove(0)
    if c == '*' && !chars->empty() && chars[0] == '*'
      chars->remove(0)
      var segmentEnd: bool = chars->empty() || chars[0] == '/'
	|| (inGroup && (chars[0] == ',' || chars[0] == '}'))
      if (prev == '' || prev == '/') && segmentEnd
	if !chars->empty() && chars[0] == '/'
	  chars->remove(0)
	  regex ..= '\%(.*/\)\='
	  prev = '/'
	  continue
	endif
	if prev == '/'
	  # "dir/**" matches "dir" too.
	  regex = $'{regex[: -2]}\%(/.*\)\='
	else
	  regex ..= '.*'
	endif
	prev = c
	continue
      endif
      regex ..= '[^/]*'
    elseif c == '*'
      regex ..= '[^/]*'
    elseif c == '?'
      regex ..= '[^/]'
    elseif c == '['
      regex ..= BracketToRegex(chars)
    elseif c == '{'
      regex ..= GroupToRegex(chars)
    else
      regex ..= c->escape('\.*$^~[]')
    endif
    prev = c
  endwhile
  return regex
enddef

# Returns a regular expression for the bracket expression of a glob pattern,
# which starts with the characters "chars" after its "[", taking them from the
# list.  Without a "]" to end it, the "[" is an ordinary character.
def BracketToRegex(chars: list<string>): string
  var negate: bool = !chars->empty() && chars[0] == '!'
  var first: number = negate ? 1 : 0
  # A "]" right after the "[" or the "[!" is one of the characters.
  var close: number = chars->index(']', first + 1)
  if close == -1
    return '\['
  endif
  var set: string = chars[first : close - 1]
    ->mapnew((_, ch) => ch->escape('\]^'))->join('')
  chars->remove(0, close)
  return negate ? $'[^/{set}]' : $'[{set}]'
enddef

# Returns a regular expression for the group of alternatives of a glob
# pattern, which starts with the characters "chars" after its "{", taking them
# from the list.  Without a "}" to end it, the "{" is an ordinary character.
def GroupToRegex(chars: list<string>): string
  var groupChars: list<string> = chars->copy()
  var alternatives: list<string> = []
  while true
    alternatives->add(GlobToRegex(chars, true))
    if chars->empty()
      chars->extend(groupChars)
      return '{'
    endif
    if chars->remove(0) == '}'
      return $'\%({alternatives->join('\|')}\)'
    endif
  endwhile
  return ''
enddef

# Returns the watcher for the FileSystemWatcher "watcher", or an empty dict
# when it is not valid: {regex: <regular expression for the paths that it
# matches>, kind: <WatchKind>, dir: <directory to watch>, inWorkspace: <the
# paths must be in a workspace folder>}.  A glob pattern that is a string
# matches the full path of a file, and unless it is an absolute path only a
# file in a workspace folder.  For it the workspace folders are watched, as
# Visual Studio Code does: a language server can have a file outside of them
# watched with a relative pattern.  An empty "dir" stands for the workspace
# folders.
def CompileWatcher(watcher: any): dict<any>
  if watcher->type() != v:t_dict
    return {}
  endif
  var kind: any = watcher->get('kind', WATCH_CREATE + WATCH_CHANGE + WATCH_DELETE)
  var globPattern: any = watcher->get('globPattern')
  if kind->type() != v:t_number
    return {}
  endif

  if globPattern->type() == v:t_string
    return {regex: $'^{GlobToRegex(globPattern->split('\zs'))}$', kind: kind,
	    dir: '', inWorkspace: globPattern !~ '^/'}
  endif

  # RelativePattern, with a WorkspaceFolder or a URI for its base
  if globPattern->type() != v:t_dict
    return {}
  endif
  var baseUri: any = globPattern->get('baseUri')
  if baseUri->type() == v:t_dict
    baseUri = baseUri->get('uri')
  endif
  var pattern: any = globPattern->get('pattern')
  if baseUri->type() != v:t_string || pattern->type() != v:t_string
    return {}
  endif
  var dir: string = NormalizePath(util.LspUriToFile(baseUri))
  var dirRegex: string = dir =~ '/$' ? dir : $'{dir}/'
  return {
    regex: $'^{dirRegex->escape('\.*$^~[]')}{GlobToRegex(pattern->split('\zs'))}$',
    kind: kind, dir: dir, inWorkspace: false}
enddef

# Returns true when the watcher "watcher" of language server "lspserver"
# matches the file "path".
def WatcherMatches(watcher: dict<any>, lspserver: dict<any>, path: string): bool
  if path !~# watcher.regex
    return false
  endif
  return !watcher.inWorkspace
    || lspserver->get('workspaceFolders', [])
	->indexof((_, folder) => InDir(path, folder)) != -1
enddef

# Returns true when a watcher of language server "entry" in "servers" matches
# the file "path" for a change of type "type", or for any change when "type"
# is 0.
def ServerWatches(entry: dict<any>, path: string, type: number = 0): bool
  var watchKind: number = WATCH_KINDS[type]
  for watchers in entry.regs->values()
    if watchers->indexof((_, w) => (watchKind == 0 || and(w.kind, watchKind) != 0)
			  && WatcherMatches(w, entry.lspserver, path)) != -1
      return true
    endif
  endfor
  return false
enddef

# Returns true when a watcher of a language server matches the file "path".
def Watched(path: string): bool
  return servers->values()->indexof((_, entry) => ServerWatches(entry, path)) != -1
enddef

# Sends each language server the changes waiting to be sent to the files that
# it watches.
def SendChanges()
  sendTimer = -1
  var changes: list<dict<any>> = []
  for path in pendingPaths
    if pendingChanges->has_key(path)
      changes->add({path: path, type: pendingChanges->remove(path).type})
    endif
  endfor
  pendingPaths = []

  for entry in servers->values()
    if !entry.lspserver.running
      continue
    endif
    var serverChanges: list<dict<any>> = changes->copy()
      ->filter((_, change) => ServerWatches(entry, change.path, change.type))
      ->map((_, change) => ({uri: util.LspPathToUri(change.path),
			     type: change.type}))
    if !serverChanges->empty()
      entry.lspserver.sendNotification(METHOD, {changes: serverChanges})
    endif
  endfor
enddef

# Adds the change of type "type" to the file "path" to the changes to send,
# merging it with a change to the file that waits to be sent as Visual Studio
# Code does.  "byVim" is true for a change that Vim made and false for one
# that fswatch reported, which can be Vim's change again.
def AddChange(path: string, type: number, byVim: bool)
  if knownPaths->len() >= KNOWN_PATHS_MAX
    knownPaths = {}
  endif
  knownPaths[path] = type != FILE_DELETED

  var pending: dict<any> = pendingChanges->get(path, {})
  if pending->empty()
    pendingChanges[path] = {type: type, byVim: byVim}
    pendingPaths->add(path)
  elseif pending.byVim && !byVim && type != FILE_DELETED
    # fswatch reports the change that Vim made
  elseif pending.type == FILE_CREATED && type == FILE_DELETED
    # Created and deleted again: no change
    pendingChanges->remove(path)
  elseif pending.type == FILE_DELETED && type == FILE_CREATED
    pending.type = FILE_CHANGED
    pending.byVim = byVim
  elseif pending.type == FILE_CREATED && type == FILE_CHANGED
    # Still a created file
  else
    pending.type = type
    pending.byVim = byVim
  endif

  if sendTimer == -1
    sendTimer = timer_start(SEND_DELAY_MSEC, (_) => SendChanges())
  endif
enddef

# Sends the language servers that watch the file "path" the change of type
# "type" (FILE_CREATED, FILE_CHANGED or FILE_DELETED) that Vim made to it.
export def VimChangedFile(path: string, type: number)
  var fullPath: string = NormalizePath(path)
  if Watched(fullPath)
    AddChange(fullPath, type, true)
  endif
enddef

# Records whether the file "path" exists, before Vim writes it.
def WriteStarting(path: string)
  writtenFileExisted[path] = !path->getftype()->empty()
enddef

# Sends the language servers that watch the file "path" that Vim wrote it.
def WriteDone(path: string)
  var existed: bool = writtenFileExisted->has_key(path)
    ? writtenFileExisted->remove(path) : true
  VimChangedFile(path, existed ? FILE_CHANGED : FILE_CREATED)
enddef

# Returns the paths of the file "realPath", which fswatch reported by its real
# path, in the watched directories.
def WatchedPaths(realPath: string): list<string>
  var paths: list<string> = []
  for dir in watchedDirs
    if realPath ==? dir.real
      paths->add(dir.path)
    elseif InDir(realPath, dir.real)
      paths->add(dir.path .. realPath->strpart(dir.real->len()))
    endif
  endfor
  return paths->sort()->uniq()
enddef

# Handles the line "line" of fswatch output: the flags of an event, a tab and
# the path of the file.  A file that doesn't exist was deleted.  Otherwise it
# was created when it didn't exist after the change sent before, or changed
# when it did.  When no change was sent for it, the flags tell whether it may
# have been created.
def FswatchOutput(_: channel, line: string)
  var tab: number = line->stridx("\t")
  if tab <= 0
    return
  endif
  var realPath: string = line->strpart(tab + 1)
  var exists: bool = !realPath->getftype()->empty()
  var created: bool = line->strpart(0, tab)->split(',')
    ->indexof((_, flag) => flag =~# '^\%(Created\|Removed\|Renamed\|MovedTo\)$')
    != -1
  for path in WatchedPaths(realPath)
    if !Watched(path)
      continue
    endif
    var type: number = FILE_CHANGED
    if !exists
      type = FILE_DELETED
    elseif knownPaths->has_key(path) ? !knownPaths[path] : created
      type = FILE_CREATED
    endif
    AddChange(path, type, false)
  endfor
enddef

# Reports an error message "msg" of fswatch.
def FswatchError(_: channel, msg: string)
  util.ErrMsg($'fswatch: {msg}')
enddef

# Reports that the fswatch job "job" exited with status "status" when it was
# not stopped.
def FswatchExit(job: job, status: number)
  if job != fswatchJob
    return
  endif
  fswatchJob = null_job
  fswatchDirs = []
  util.ErrMsg($'fswatch exited with status {status}, the changes that other programs make to files are not sent to the language servers')
enddef

# Returns the directories that the watchers are for, see "watchedDirs".  A
# directory that doesn't exist or that is never a workspace root (the
# "workspaceIgnoredPaths" option) is not watched.
def WatcherDirs(): list<dict<string>>
  var dirs: dict<bool> = {}
  for entry in servers->values()
    for watchers in entry.regs->values()
      for watcher in watchers
	if watcher.dir->empty()
	  for folder in entry.lspserver->get('workspaceFolders', [])
	    dirs[NormalizePath(folder)] = true
	  endfor
	else
	  dirs[watcher.dir] = true
	endif
      endfor
    endfor
  endfor
  return dirs->keys()->sort()
    ->filter((_, dir) => dir->isdirectory()
	&& !util.IsIgnoredRoot(dir->fnamemodify(':p'),
			       opt.lspOptions.workspaceIgnoredPaths))
    ->map((_, dir) => ({path: dir, real: dir->resolve()}))
enddef

# Returns the directories "dirs" that are not in another one of them.
def TopDirs(dirs: list<string>): list<string>
  var topDirs: list<string> = []
  for dir in dirs->copy()->sort()->uniq()
    if topDirs->indexof((_, topDir) => dir ==? topDir || InDir(dir, topDir)) == -1
      topDirs->add(dir)
    endif
  endfor
  return topDirs
enddef

# Stops fswatch.
def StopFswatch()
  var job: job = fswatchJob
  fswatchJob = null_job
  fswatchDirs = []
  if job->job_status() == 'run'
    job->job_stop()
  endif
enddef

# Watches the files that the language servers watch: adds the autocmds for the
# files that Vim writes and, when other programs' changes can be watched,
# runs fswatch for the directories of the watchers.  Stops watching when there
# are no watchers.
def UpdateWatch()
  if servers->empty()
    if exists('#LspWatchedFiles')
      autocmd_delete([{group: 'LspWatchedFiles'}])
    endif
  elseif !exists('#LspWatchedFiles')
    autocmd_add([
      {group: 'LspWatchedFiles', pattern: '*',
       event: ['BufWritePre', 'FileWritePre', 'FileAppendPre'],
       cmd: 'WriteStarting(expand("<afile>:p"))'},
      {group: 'LspWatchedFiles', pattern: '*',
       event: ['BufWritePost', 'FileWritePost', 'FileAppendPost'],
       cmd: 'WriteDone(expand("<afile>:p"))'}
    ])
  endif

  watchedDirs = CanWatch() ? WatcherDirs() : []
  var dirs: list<string> = TopDirs(watchedDirs->mapnew((_, dir) => dir.real))
  if dirs == fswatchDirs && (dirs->empty() || fswatchJob->job_status() == 'run')
    return
  endif

  StopFswatch()
  if dirs->empty()
    return
  endif
  fswatchJob = job_start(['fswatch', '--recursive', '--no-defer',
			  $'--latency={FSWATCH_LATENCY}',
			  '--event-flag-separator=,', "--format=%f\t%p", '--']
			 + dirs,
			 {in_io: 'null', out_mode: 'nl', out_cb: FswatchOutput,
			  err_mode: 'nl', err_cb: FswatchError,
			  exit_cb: FswatchExit})
  if fswatchJob->job_status() == 'fail'
    fswatchJob = null_job
    util.ErrMsg('Failed to start fswatch')
    return
  endif
  fswatchDirs = dirs
enddef

# Returns why the "registrations" of a "client/registerCapability" request
# from language server "lspserver" are not valid, or an empty string after
# registering their file system watchers.  Registers none of them when one is
# not valid, and ignores them when the "watchFiles" option is not set or the
# "watchFiles" feature of the language server is off.
export def Register(lspserver: dict<any>, registrations: list<any>): string
  var regs: dict<list<dict<any>>> = {}
  for registration in registrations
    if registration->type() != v:t_dict
	|| registration->get('method')->type() != v:t_string
	|| registration.method != METHOD
      continue
    endif
    var id: any = registration->get('id')
    var registerOptions: any = registration->get('registerOptions')
    if id->type() != v:t_string || registerOptions->type() != v:t_dict
	|| registerOptions->get('watchers')->type() != v:t_list
      return $'{METHOD} registration needs an id and registerOptions.watchers'
    endif
    var watchers: list<dict<any>> = registerOptions.watchers
      ->mapnew((_, watcher) => CompileWatcher(watcher))
    if watchers->indexof((_, watcher) => watcher->empty()) != -1
      return $'{METHOD} registration has a watcher that is not valid'
    endif
    regs[id] = watchers
  endfor

  if regs->empty() || !opt.lspOptions.watchFiles
      || !lspserver->get('features', {})->get('watchFiles', true)
    return ''
  endif
  if !servers->has_key(lspserver.id)
    servers[lspserver.id] = {lspserver: lspserver, regs: {}}
  endif
  servers[lspserver.id].regs->extend(regs)
  UpdateWatch()
  return ''
enddef

# Unregisters the file system watchers of the "unregistrations" of a
# "client/unregisterCapability" request from language server "lspserver".
export def Unregister(lspserver: dict<any>, unregistrations: list<any>)
  if !servers->has_key(lspserver.id)
    return
  endif
  var regs: dict<any> = servers[lspserver.id].regs
  for unregistration in unregistrations
    if unregistration->type() == v:t_dict
	&& unregistration->get('method')->type() == v:t_string
	&& unregistration.method == METHOD
	&& unregistration->get('id')->type() == v:t_string
	&& regs->has_key(unregistration.id)
      regs->remove(unregistration.id)
    endif
  endfor
  if regs->empty()
    servers->remove(lspserver.id)
  endif
  UpdateWatch()
enddef

# Forgets the file system watchers of language server "lspserver", which
# stopped.
export def RemoveServer(lspserver: dict<any>)
  if servers->has_key(lspserver.id)
    servers->remove(lspserver.id)
    UpdateWatch()
  endif
enddef

# Watches the workspace folders of the language servers after they changed.
export def WorkspaceFoldersChanged()
  if !servers->empty()
    UpdateWatch()
  endif
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
