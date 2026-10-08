vim9script

# Display an info message
export def InfoMsg(msg: string)
  :echohl Question
  :echomsg $'Info: {msg}'
  :echohl None
enddef

# Display a warning message
export def WarnMsg(msg: string)
  :echohl WarningMsg
  :echomsg $'Warn: {msg}'
  :echohl None
enddef

# Display an error message
export def ErrMsg(msg: string)
  :echohl Error
  :echomsg $'Error: {msg}'
  :echohl None
enddef

# Lsp server trace log directory
var lsp_log_dir: string

if has('unix')
  # Try /tmp first
  if isdirectory('/tmp') && filewritable('/tmp') == 2
    lsp_log_dir = '/tmp'
  # Fallback to $TMPDIR
  elseif exists('$TMPDIR') && isdirectory($TMPDIR) &&
						filewritable($TMPDIR) == 2
    lsp_log_dir = $TMPDIR
  else
    # Last resort: current directory
    lsp_log_dir = expand('.')
  endif

  # Ensure a trailing slash
  lsp_log_dir = lsp_log_dir->fnamemodify(':p')
else
  # Windows fallback logic
  var win_base = !empty($TEMP) ? $TEMP : $TMP
  lsp_log_dir = (!empty(win_base) ? win_base : 'C:\Temp')->fnamemodify(':p')
endif

# Log a message from the LSP server. stderr is true for logging messages
# from the standard error and false for stdout.
export def TraceLog(fname: string, stderr: bool, msg: string)
  if stderr
    writefile(msg->split("\n"), $'{lsp_log_dir}{fname}', 'a')
  else
    writefile([$'{strftime("%m/%d/%y %T")}: {msg}'], $'{lsp_log_dir}{fname}', 'a')
  endif
enddef

# Empty out the LSP server trace logs
export def ClearTraceLogs(fname: string)
  writefile([], $'{lsp_log_dir}{fname}')
enddef

# Open the LSP server debug messages file.
export def ServerMessagesShow(fname: string)
  var fullname = $'{lsp_log_dir}{fname}'
  if !filereadable(fullname)
    WarnMsg($'File {fullname} is not found')
    return
  endif
  var wid = BufnrExact(fullname)->bufwinid()
  if wid == -1
    exe $'split {fullname->fnameescape()}'
  else
    win_gotoid(wid)
  endif
  setlocal autoread
  setlocal bufhidden=wipe
  setlocal nomodified
  setlocal nomodifiable
enddef

# Parse a LSP Location or LocationLink type and return a List with two items.
# The first item is the DocumentURI and the second item is the Range.
export def LspLocationParse(lsploc: dict<any>): list<any>
  if lsploc->has_key('targetUri')
    # LocationLink
    return [lsploc.targetUri, lsploc.targetSelectionRange]
  else
    # Location
    return [lsploc.uri, lsploc.range]
  endif
enddef

# The text in a URI path for each octet value: an unreserved character (RFC
# 3986), ":" and "/" stand for themselves, any other octet is percent-encoded.
# str2blob() turns a NL into a NUL, which a Vim string cannot hold, so the
# octet 0 is a NL.
const URI_PATH_OCTETS: list<string> = range(256)->mapnew((_, b) =>
  b != 0 && nr2char(b) =~# '^[A-Za-z0-9._~:/-]$' ? nr2char(b)
  : printf('%%%02X', b == 0 ? 10 : b))

# Returns "str" with each octet of its UTF-8 encoding percent-encoded, except
# for an unreserved character (RFC 3986), ":" and "/".  The string is encoded
# octet by octet, as a regexp sees a composing character as a part of the
# character before it, which may be one that is not encoded.
def UriEncode(str: string): string
  return [str]->str2blob()->blob2list()
    ->mapnew((_, b) => URI_PATH_OCTETS[b])->join('')
enddef

# Returns "str" with each percent-encoded octet, "%" followed by two
# hexadecimal digits of either case, replaced by the octet, so that the octets
# of a multibyte character form the character again.  Octets that are not
# valid UTF-8 are kept as they are.  A "%" that is not followed by two
# hexadecimal digits is kept, and so is "%00": a Vim string cannot hold a NUL.
# A "+" is not a space in a URI path and is kept too.  A regexp sees a
# composing character after the second digit as a part of the digit, so the
# match is the digits and any composing characters after them.
def UriDecode(str: string): string
  return str->substitute('%\%(00\)\@!\(\x\x\)',
    '\=printf("%c", str2nr(submatch(1), 16)) .. submatch(1)->strpart(2)', 'g')
enddef

# Convert the LSP URI "uri" to a Vim file name.  A "file:" URI (RFC 8089) of a
# local file, one without a host ("file:///path" or "file:/path") or with the
# host "localhost", is converted to its path with the percent-encoded octets
# (e.g. "%20" for a space) decoded.  Any other URI, with another scheme (e.g.
# "jdt:") or with another host, is returned unchanged: it is the name of the
# buffer for the URI, see LspFileToUri().
export def LspUriToFile(uri: string): string
  # The path starts after "file:", "file://" or "file://localhost", and with
  # "file:" it doesn't start with "//", as that starts a host.
  var pathIdx: number = uri->matchend(
    '\c^file:\%(//\%(localhost\)\=\ze/\|\ze/\%(/\)\@!\)')
  if pathIdx == -1
    return uri
  endif

  var path: string = UriDecode(uri->strpart(pathIdx))
  if (has('win32') || has('win32unix')) && path =~ '^/\a:'
    # MS-Windows path, e.g. file:///C:/path/to/file
    path = path[1 : ]
    if has('win32unix')
      # Cygwin, C:/path/to/file -> /C/path/to/file
      path = path->substitute('^\(\a\):', '/\1', '')
    else
      path = path->tr('/', '\')
    endif
  endif

  return path
enddef

# Convert a LSP file URI (file://<absolute_path>) to a Vim buffer number.
# If the file is not in a Vim buffer, then adds the buffer.
# Returns 0 on error.
export def LspUriToBufnr(uri: string): number
  return LspUriToFile(uri)->bufadd()
enddef

# Returns the number of the buffer for the file "fname", or -1 if there is no
# such buffer.  Unlike bufnr(), which takes a String for a file pattern (so
# that "foo[1].c" finds the buffer for "foo1.c"), the buffer name must match
# "fname" exactly, as for bufexists().  Not for a 'buftype' "nofile" buffer:
# after a change of the current directory bufexists() still finds it by its
# short name, but bufadd() then adds another buffer.
export def BufnrExact(fname: string): number
  return fname->bufexists() ? fname->bufadd() : -1
enddef

# Returns if the URI refers to a remote file (e.g. ssh://)
# Credit: vim-lsp plugin
export def LspUriRemote(uri: string): bool
  var normalized_uri = uri->tr('\', '/')
  return normalized_uri =~ '^\w\+::' || normalized_uri =~ '^[a-z][a-z0-9+.-]*://'
enddef

var resolvedUris = {}

# Convert the Vim file name "fname" to an LSP URI: a "file:" URI of its full
# path.  A name that Vim keeps as a URL, like the name of a buffer for a URI
# that LspUriToFile() does not convert to a path, is the URI itself and is
# returned unchanged.
export def LspFileToUri(fname: string): string
  var fname_full: string = fname->fnamemodify(':p')

  if resolvedUris->has_key(fname_full)
    return resolvedUris[fname_full]
  endif

  if LspUriRemote(fname_full)
    resolvedUris[fname_full] = fname_full
    return fname_full
  endif

  var uri: string = fname_full

  if has("win32unix")
    # We're in Cygwin, convert POSIX style paths to Windows style.
    # The substitution is to remove the '^@' escape character from the end of
    # line.
    uri = system($'cygpath -m {uri->shellescape()}')->substitute('^\(\p*\).*$', '\=submatch(1)', "")
  endif

  var on_windows: bool = false
  if uri =~? '^\a:'
    on_windows = true
  endif

  if on_windows
    # MS-Windows
    uri = uri->tr('\', '/')
  endif

  var uri_encoded: string = UriEncode(uri)

  if on_windows
    uri = $'file:///{uri_encoded}'
  else
    uri = $'file://{uri_encoded}'
  endif

  resolvedUris[fname_full] = uri
  return uri
enddef

# Convert a Vim buffer number to an LSP URI (file://<absolute_path>)
export def LspBufnrToUri(bnr: number): string
  return LspFileToUri(bnr->bufname())
enddef

# Returns true if writing buffer "bnr" ends the file with a newline.  Vim
# writes one after the last line when 'endofline' is set, or when
# 'fixendofline' is set and 'binary' is not.  The document text sent to the
# language server must follow the same rule, so that the server sees what
# will be saved.
export def BufWritesEol(bnr: number): bool
  return bnr->getbufvar('&endofline')
    || (bnr->getbufvar('&fixendofline') && !bnr->getbufvar('&binary'))
enddef

# Returns true if buffer "bnr" has no text: Vim writes it as an empty file.
# A buffer without lines (a new buffer, or one with all its lines deleted) has
# no text, but getbufline() returns one empty line for it, like for a buffer
# with one empty line, which is written as a newline.  Only wordcount() tells
# them apart.  An unloaded buffer is not loaded to find out: it is taken to
# have lines.
export def BufIsEmpty(bnr: number): bool
  if bnr->getbufline(1, 2) != ['']
    return false
  endif
  if !BufWritesEol(bnr)
    return true
  endif
  if bnr == bufnr()
    return wordcount().bytes == 0
  endif
  return ExecuteInBuffer(bnr, 'echo wordcount().bytes')->trim() == '0'
enddef

# Returns a snapshot of the editor state that the reply to an asynchronous
# request is for, so that a reply arriving after the user moved on can be
# dropped (see RequestContextMatches()).  "scope" is one of:
#   'buffer'	the text of buffer "bnr"
#   'window'	also the current window, which shows buffer "bnr"
#   'cursor'	also the cursor position in that window
export def RequestContextGet(scope: string, bnr: number = bufnr()): dict<number>
  var reqctx: dict<number> = {
    bnr: bnr,
    changedtick: bnr->getbufvar('changedtick', -1)
  }
  if scope == 'window' || scope == 'cursor'
    reqctx.winid = win_getid()
  endif
  if scope == 'cursor'
    reqctx.lnum = line('.')
    reqctx.col = charcol('.')
  endif
  return reqctx
enddef

# Returns true when the editor state in "reqctx", as returned by
# RequestContextGet(), did not change.
export def RequestContextMatches(reqctx: dict<number>): bool
  if reqctx.changedtick != reqctx.bnr->getbufvar('changedtick', -1)
    return false
  endif
  if reqctx->has_key('winid')
      && (reqctx.winid != win_getid() || reqctx.bnr != bufnr())
    return false
  endif
  return !reqctx->has_key('lnum')
    || (reqctx.lnum == line('.') && reqctx.col == charcol('.'))
enddef

# Executes Ex command "cmd" with loaded buffer "bnr" as the current buffer and
# returns its output.  The command runs in a window that shows the buffer, or
# else in a hidden popup window that leaves no trace: opening and closing it
# triggers no autocommands, and closing it does not unload the buffer
# whatever its 'bufhidden' is.
export def ExecuteInBuffer(bnr: number, cmd: string): string
  var winids: list<number> = bnr->win_findbuf()
  if !winids->empty()
    return win_execute(winids[0], cmd)
  endif

  var bufhidden: string = bnr->getbufvar('&bufhidden')
  noautocmd setbufvar(bnr, '&bufhidden', '')
  var winid: number
  noautocmd winid = popup_create(bnr, {hidden: true})
  var output: string
  try
    output = win_execute(winid, cmd)
  finally
    noautocmd popup_close(winid)
    noautocmd setbufvar(bnr, '&bufhidden', bufhidden)
  endtry
  return output
enddef

# Returns the byte number of the specified LSP position in buffer "bnr".
# LSP's line and characters are 0-indexed.
# Vim's line and columns are 1-indexed.
# Returns a zero-indexed column.
#
# "pos.character" is a character index that counts the composing characters
# separately.  A position past the end of the line is at the end of the line,
# as the LSP specification requires, so the returned byte index is at most
# the length of the line.  When the line is not available, because it is past
# the end of the buffer or the buffer cannot be loaded, the character index is
# returned unchanged.
export def GetLineByteFromPos(bnr: number, pos: dict<number>): number
  var col: number = pos.character
  # When on the first character, we can ignore the difference between byte and
  # character
  if col <= 0
    return col
  endif

  # Need a loaded buffer to read the line and compute the offset
  :silent! bnr->bufload()

  var lines: list<string> = bnr->getbufline(pos.line + 1)
  if lines->empty()
    return col
  endif

  var ltext: string = lines[0]
  var byteIdx = ltext->byteidxcomp(col)
  if byteIdx != -1
    return byteIdx
  endif

  return ltext->strlen()
enddef

# Get the index of the character at [pos.line, pos.character] in buffer "bnr"
# without counting the composing characters.  The LSP server counts composing
# characters as separate characters whereas Vim string indexing ignores the
# composing characters.
#
# A position past the end of the line is at the end of the line, as the LSP
# specification requires, so the returned character index is at most the
# number of characters in the line.  When the line is not available, because
# it is past the end of the buffer or the buffer cannot be loaded, the
# character index is returned unchanged.
export def GetCharIdxWithoutCompChar(bnr: number, pos: dict<number>): number
  var col: number = pos.character
  # When on the first character, nothing to do.
  if col <= 0
    return col
  endif

  # Need a loaded buffer to read the line and compute the offset
  :silent! bnr->bufload()

  var lines: list<string> = bnr->getbufline(pos.line + 1)
  if lines->empty()
    return col
  endif

  # Convert the character index that includes composing characters as separate
  # characters to a byte index and then back to a character index ignoring the
  # composing characters.
  var ltext: string = lines[0]
  var byteIdx = ltext->byteidxcomp(col)
  if byteIdx != -1
    if byteIdx == ltext->strlen()
      # Byte index points to the byte after the last byte.
      return ltext->strcharlen()
    else
      return ltext->charidx(byteIdx, false)
    endif
  endif

  return ltext->strcharlen()
enddef

# Convert the character index "charIdx" in the line "ltext", which doesn't
# count the composing characters separately, to a character index that counts
# them as separate characters.  The LSP server counts composing characters as
# separate characters whereas Vim string indexing ignores the composing
# characters.
#
# A character index past the end of the line is at the end of the line, so
# the returned character index is at most the number of characters in the
# line, counting the composing characters separately.
export def GetCharIdxWithCompChar(ltext: string, charIdx: number): number
  # When on the first character, nothing to do.
  if charIdx <= 0
    return charIdx
  endif

  # Convert the character index that doesn't include composing characters as
  # separate characters to a byte index and then back to a character index
  # that includes the composing characters as separate characters
  var byteIdx = ltext->byteidx(charIdx)
  if byteIdx != -1
    if byteIdx == ltext->strlen()
      return ltext->strchars()
    else
      return ltext->charidx(byteIdx, true)
    endif
  endif

  return ltext->strchars()
enddef

# push the current location on to the tag stack
export def PushCursorToTagStack()
  settagstack(winnr(), {items: [
			 {
			   bufnr: bufnr(),
			   from: getpos('.'),
			   matchnr: 1,
			   tagname: expand('<cword>')
			 }]}, 't')
enddef

# Jump to the LSP "location".  The "location" contains the file name, line
# number and character number. The user specified window command modifiers
# (e.g. topleft) are in "cmdmods".
export def JumpToLspLocation(location: dict<any>, cmdmods: string)
  var [uri, range] = LspLocationParse(location)
  var fname = LspUriToFile(uri)

  # jump to the file and line containing the symbol
  var bnr: number = BufnrExact(fname)
  if cmdmods->empty()
    if bnr == bufnr()
      # Set the previous cursor location mark. Instead of using setpos(), m' is
      # used so that the current location is added to the jump list.
      :normal m'
    else
      var wid = bnr->bufwinid()
      if wid != -1
        wid->win_gotoid()
      else
        if bnr != -1
          # Reuse an existing buffer. If the current buffer has unsaved changes
          # and 'hidden' is not set or if the current buffer is a special
          # buffer, then open the buffer in a new window.
          if (&modified && !&hidden) || &buftype != ''
            exe $'belowright sbuffer {bnr}'
          else
            exe $'buf {bnr}'
          endif
	  # In case 'buflisted' is not yet set for this buffer, set it now
	  setlocal buflisted
        else
          if (&modified && !&hidden) || &buftype != ''
            # if the current buffer has unsaved changes and 'hidden' is not set,
            # or if the current buffer is a special buffer, then open the file
            # in a new window
            exe $'belowright split {fname->fnameescape()}'
          else
            exe $'edit {fname->fnameescape()}'
          endif
        endif
      endif
    endif
  else
    if bnr == -1
      exe $'{cmdmods} split {fname->fnameescape()}'
    else
      # Use "sbuffer" so that the 'switchbuf' option settings are used.
      exe $'{cmdmods} sbuffer {bnr}'
    endif
  endif
  var rstart = range.start
  setcursorcharpos(rstart.line + 1,
		   GetCharIdxWithoutCompChar(bufnr(), rstart) + 1)
  :normal! zv
enddef

# Find the nearest root directory containing a file or directory name from the
# list of names in "files" starting with the directory "startDir".
# Based on a similar implementation in the vim-lsp plugin.
# Searches upwards starting with the directory "startDir".
# If a file name ends with '/' or '\', then it is a directory name, otherwise
# it is a file name.
# Returns '' if none of the file and directory names in "files" can be found
# in one of the parent directories.
export def FindNearestRootDir(startDir: string, files: list<any>): string
  var foundDirs: dict<bool> = {}

  for file in files
    if file->type() != v:t_string || file->empty()
      continue
    endif
    var isDir = file[-1 : ] == '/' || file[-1 : ] == '\'
    var relPath: string
    if isDir
      relPath = finddir(file, $'{startDir};')
    else
      relPath = findfile(file, $'{startDir};')
    endif
    if relPath->empty()
      continue
    endif
    var rootDir = relPath->fnamemodify(isDir ? ':p:h:h' : ':p:h')
    foundDirs[rootDir] = true
  endfor
  if foundDirs->empty()
    return ''
  endif

  # Sort the directory names by length
  var sortedList: list<string> = foundDirs->keys()->sort((a, b) => {
    return b->len() - a->len()
  })

  # choose the longest matching path (the nearest directory from "startDir")
  return sortedList[0]
enddef

# returns true if rootPath (or its resolved form) matches an ignored path
# in 'workspaceIgnoredPaths' option.
export def IsIgnoredRoot(rootPath: string, ignoredPaths: list<string>): bool
  var rootResolved: string = rootPath->resolve()->fnamemodify(':p')
  for ignored in ignoredPaths
    var globpos: number = ignored->match('[*?[]')
    if globpos != -1
      var patterns: list<string> = [ignored]
      if globpos > 0
        patterns->add($'{ignored[0 : globpos - 1]->resolve()->fnamemodify(':p')}{ignored[globpos : ]}')
      endif
      for pattern in patterns
        var patternRegexp: string = glob2regpat(pattern)
        if rootPath =~ patternRegexp || rootResolved =~ patternRegexp
          return true
        endif
      endfor
    elseif rootPath == ignored || rootResolved == ignored->resolve()->fnamemodify(':p')
      return true
    endif
  endfor
  return false
enddef

# Makes the current buffer a scratch buffer named "bname", or without a name
# when another buffer has that name.  A scratch buffer must be looked up by
# its number: as a buffer name, "bname" can match another buffer, e.g. a file
# of the user.
export def ScratchBufferInit(bname: string)
  :setlocal buftype=nofile bufhidden=wipe noswapfile
  if !bname->bufexists()
    execute $'silent file {bname->fnameescape()}'
  endif
enddef

# Opens a new window, with the Ex command modifiers "mods", for the scratch
# buffer "bnr" and returns "bnr".  When the buffer "bnr" is not loaded, the
# window gets a new scratch buffer named "bname" instead (see
# ScratchBufferInit()) and its number is returned.
export def ScratchWindowOpen(bnr: number, bname: string,
			     mods: string = ''): number
  if bnr->bufloaded()
    silent execute $'{mods} split'
    silent execute $'buffer {bnr}'
    return bnr
  endif

  silent execute $'{mods} new'
  ScratchBufferInit(bname)
  return bufnr()
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
