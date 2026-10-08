vim9script

import './util.vim'

# sort the list of edit operations in the descending order of line and column
# numbers.
# 'a': {'A': [lnum, col], 'B': [lnum, col]}
# 'b': {'A': [lnum, col], 'B': [lnum, col]}
def Edit_sort_func(a: dict<any>, b: dict<any>): number
  # line number
  if a.A[0] != b.A[0]
    return b.A[0] - a.A[0]
  endif
  # column number
  if a.A[1] != b.A[1]
    return b.A[1] - a.A[1]
  endif

  # Assume that the LSP sorted the lines correctly to begin with
  return b.idx - a.idx
enddef

# Replaces text in a range with new text.
#
# CAUTION: Changes in-place!
#
# 'lines': Original list of strings
# 'A': Start position; [line, col]
# 'B': End position [line, col]
# 'new_lines' A list of strings to replace the original
#
# returns the modified 'lines'
def Set_lines(lines: list<string>, A: list<number>, B: list<number>,
					new_lines: list<string>): list<string>
  var i_0: number = A[0]

  # If it extends past the end, truncate it to the end. This is because the
  # way the LSP describes the range including the last newline is by
  # specifying a line number after what we would call the last line.
  var numlines: number = lines->len()
  var i_n = [B[0], numlines - 1]->min()

  if i_0 < 0 || i_0 >= numlines || i_n < 0 || i_n >= numlines
    #util.WarnMsg("set_lines: Invalid range, A = " .. A->string()
    #		.. ", B = " ..  B->string() .. ", numlines = " .. numlines
    #		.. ", new lines = " .. new_lines->string())
    var msg = $"set_lines: Invalid range, A = {A->string()}"
    msg ..= $", B = {B->string()}, numlines = {numlines}"
    msg ..= $", new lines = {new_lines->string()}"
    util.WarnMsg(msg)
    return lines
  endif

  # save the prefix and suffix text before doing the replacements
  var prefix: string = ''
  var suffix: string = lines[i_n][B[1] :]
  if A[1] > 0
    prefix = lines[i_0][0 : A[1] - 1]
  endif

  var new_lines_len: number = new_lines->len()

  #echomsg $"i_0 = {i_0}, i_n = {i_n}, new_lines = {string(new_lines)}"
  var n: number = i_n - i_0 + 1
  if n != new_lines_len
    if n > new_lines_len
      # remove the deleted lines
      lines->remove(i_0, i_0 + n - new_lines_len - 1)
    else
      # add empty lines for newly the added lines (will be replaced with the
      # actual lines below)
      lines->extend(repeat([''], new_lines_len - n), i_0)
    endif
  endif
  #echomsg $"lines(1) = {string(lines)}"

  # replace the previous lines with the new lines
  for i in new_lines_len->range()
    lines[i_0 + i] = new_lines[i]
  endfor
  #echomsg $"lines(2) = {string(lines)}"

  # append the suffix (if any) to the last line
  if suffix != ''
    var i = i_0 + new_lines_len - 1
    lines[i] = lines[i] .. suffix
  endif
  #echomsg $"lines(3) = {string(lines)}"

  # prepend the prefix (if any) to the first line
  if prefix != ''
    lines[i_0] = prefix .. lines[i_0]
  endif
  #echomsg $"lines(4) = {string(lines)}"

  return lines
enddef

# Apply set of text edits to the specified buffer
# The text edit logic is ported from the Neovim lua implementation
export def ApplyTextEdits(bnr: number, text_edits: list<dict<any>>): void
  if text_edits->empty()
    return
  endif

  # if the buffer is not loaded, load it and make it a listed buffer
  :silent! bnr->bufload()
  setbufvar(bnr, '&buflisted', true)

  var start_line: number = 4294967295		# 2 ^ 32
  var finish_line: number = -1
  var updated_edits: list<dict<any>> = []
  var start_row: number
  var start_col: number
  var end_row: number
  var end_col: number

  # create a list of buffer positions where the edits have to be applied.
  var idx = 0
  for e in text_edits
    # Adjust the start and end columns for multibyte characters
    var r = e.range
    var rstart: dict<any> = r.start
    var rend: dict<any> = r.end
    start_row = rstart.line
    start_col = util.GetCharIdxWithoutCompChar(bnr, rstart)
    end_row = rend.line
    end_col = util.GetCharIdxWithoutCompChar(bnr, rend)
    start_line = [rstart.line, start_line]->min()
    finish_line = [rend.line, finish_line]->max()

    updated_edits->add({A: [start_row, start_col],
			B: [end_row, end_col],
                        idx: idx,
			lines: e.newText->split("\n", true)})
    idx += 1
  endfor

  # Reverse sort the edit operations by descending line and column numbers so
  # that they can be applied without interfering with each other.
  updated_edits->sort('Edit_sort_func')

  # When Vim writes a newline after the last line, the document has one more,
  # empty, line.  Unless an edit reaches that line, an empty last line is
  # taken to be it, so that edits for an empty document apply to a buffer
  # without lines, which Vim shows as one empty line.
  var linecount: number = bnr->getbufinfo()[0].linecount
  var lines: list<string> = bnr->getbufline(start_line + 1, finish_line + 1)
  var set_eol = util.BufWritesEol(bnr) && linecount <= finish_line + 1
  if set_eol && start_line <= linecount
      && (finish_line >= linecount || lines[-1] != '')
    lines->add('')
  endif

  #echomsg $'lines(1) = {string(lines)}'
  #echomsg updated_edits

  for e in updated_edits
    var A: list<number> = [e.A[0] - start_line, e.A[1]]
    var B: list<number> = [e.B[0] - start_line, e.B[1]]
    lines = Set_lines(lines, A, B, e.lines)
  endfor

  #echomsg $'lines(2) = {string(lines)}'

  # If the last line is empty and we need to set EOL, then remove it.
  if !lines->empty() && set_eol && lines[-1]->len() == 0
    lines->remove(-1)
  endif

  #echomsg $'ApplyTextEdits: start_line = {start_line}, finish_line = {finish_line}'
  #echomsg $'lines = {string(lines)}'

  # Now we apply the textedits to the actual buffer.
  # In theory we could just delete all old lines and append the new lines.
  # This would however cause the cursor to change position: It will always be
  # on the last line added.
  #
  # Luckily there is an even simpler solution, that has no cursor sideeffects.
  #
  # Logically this method is split into the following three cases:
  #
  # 1. The number of new lines is equal to the number of old lines:
  #    Just replace the lines inline with setbufline()
  #
  # 2. The number of new lines is greater than the old ones:
  #    First append the missing lines at the **end** of the range, then use
  #    setbufline() again. This does not cause the cursor to change position.
  #
  # 3. The number of new lines is less than before:
  #    First use setbufline() to replace the lines that we can replace.
  #    Then remove superfluous lines.
  #
  # Luckily, the three different cases exist only logically, we can reduce
  # them to a single case practically, because appendbufline() does not append
  # anything if an empty list is passed just like deletebufline() does not
  # delete anything, if the last line of the range is before the first line.
  # We just need to be careful with all indices.
  appendbufline(bnr, finish_line + 1, lines[finish_line - start_line + 1 : -1])
  setbufline(bnr, start_line + 1, lines)

  # Workaround for Vim issues #12568 & #18136
  prop_clear(start_line + 1 + lines->len(), finish_line + 1, {'bufnr': bnr})

  deletebufline(bnr, start_line + 1 + lines->len(), finish_line + 1)
enddef

# interface TextDocumentEdit
# Returns why the edit failed, or an empty string when it did not.
def ApplyTextDocumentEdit(textDocEdit: dict<any>): string
  var bnr: number = util.LspUriToBufnr(textDocEdit.textDocument.uri)
  if bnr <= 0
    return $'Text Document edit, buffer {textDocEdit.textDocument.uri} is not found'
  endif
  ApplyTextEdits(bnr, textDocEdit.edits)
  return ''
enddef

# Returns the number of the buffer for file "fname", or 0 if there is none.
def FileBufnr(fname: string): number
  return fname->bufexists() ? fname->bufadd() : 0
enddef

# Reloads buffer "bnr", which is loaded and has no unsaved changes, from its
# file after the file was changed.  Unlike ":edit!" this works for a hidden
# buffer too, and like it, it keeps the undo history (see 'undoreload').
def ReloadBuffer(bnr: number)
  autocmd_add([{group: 'LspReloadBuffer', event: 'FileChangedShell',
		bufnr: bnr, cmd: 'v:fcs_choice = "reload"'}])
  try
    exe $'checktime {bnr}'
  finally
    autocmd_delete([{group: 'LspReloadBuffer'}])
  endtry
enddef

# interface CreateFile
# Create the "createFile.uri" file.  An existing file is emptied only when
# "overwrite" is set, and then its loaded buffer too, unless it has unsaved
# changes.  Returns why the operation failed, or an empty string when it did
# not.
def FileCreate(createFile: dict<any>): string
  var fname: string = util.LspUriToFile(createFile.uri)
  var opts: dict<bool> = createFile->get('options', {})
  var ignoreIfExists: bool = opts->get('ignoreIfExists', false)
  var overwrite: bool = opts->get('overwrite', false)

  # LSP Spec: Overwrite wins over `ignoreIfExists`
  if !fname->getftype()->empty()
    if !overwrite
      if ignoreIfExists
	return ''
      endif
      return $'File create failed, {fname} already exists'
    endif
    # A file cannot be created at a path that is already a directory.
    if fname->isdirectory()
      return $'File create failed, {fname} is a directory'
    endif
  endif

  var bnr: number = FileBufnr(fname)
  if bnr > 0 && bnr->getbufvar('&modified')
    return $'File create failed, {fname} has unsaved changes'
  endif

  fname->fnamemodify(':p:h')->mkdir('p')
  []->writefile(fname)
  if bnr > 0 && bnr->bufloaded()
    ReloadBuffer(bnr)
  else
    fname->bufadd()
  endif
  return ''
enddef

# interface DeleteFile
# Delete file or directory "deleteFile.uri" and wipe out the buffers of the
# deleted files, unless one of them has unsaved changes.  A directory that is
# not empty is deleted only when "recursive" is set.  Returns why the
# operation failed, or an empty string when it did not.
def FileDelete(deleteFile: dict<any>): string
  var path: string = UriToPath(deleteFile.uri)
  var opts: dict<bool> = deleteFile->get('options', {})
  var recursive: bool = opts->get('recursive', false)
  var ignoreIfNotExists: bool = opts->get('ignoreIfNotExists', false)

  var ftype: string = path->getftype()
  if ftype->empty()
    if ignoreIfNotExists
      return ''
    endif
    return $'File delete failed, {path} does not exist'
  endif

  var bnrs: list<number> = [FileBufnr(path)]->filter((_, bnr) => bnr > 0)
			   + DirBuffers(path)
  for bnr in bnrs
    if bnr->getbufvar('&modified')
      var name: string = bnr->getbufinfo()[0].name
      return $'File delete failed, {name} has unsaved changes'
    endif
  endfor

  var flags: string = ftype != 'dir' ? '' : recursive ? 'rf' : 'd'
  if path->delete(flags) != 0
    return $'File delete failed for {path}'
  endif
  for bnr in bnrs
    exe $'bwipe {bnr}'
  endfor
  return ''
enddef

# Returns the name of the file or directory with URI "uri", without a
# trailing "/".
def UriToPath(uri: string): string
  return util.LspUriToFile(uri)->substitute('\(.\)/\+$', '\1', '')
enddef

# Returns the numbers of the buffers for the files under directory "dir".
# Like Vim, this ignores the case of file names, as macOS does.
def DirBuffers(dir: string): list<number>
  var prefix: string = $'{dir}/'
  return getbufinfo()
    ->filter((_, b) => b.name->strpart(0, prefix->len()) ==? prefix)
    ->map((_, b) => b.bufnr)
enddef

# Executes Ex command "cmd" with loaded buffer "bnr" as the current buffer and
# returns its output.  The command runs in a window that shows the buffer, or
# else in a hidden popup window that leaves no trace: opening and closing it
# triggers no autocommands, and closing it does not unload the buffer
# whatever its 'bufhidden' is.
def ExecuteInBuffer(bnr: number, cmd: string): string
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

# Names loaded buffer "bnr" "fname" after its file was renamed to "fname".
# The buffer keeps its text, its undo history and its unsaved changes.  When
# buffer "tbnr" was for the file the renamed file replaced, the windows that
# showed buffer "tbnr" show buffer "bnr" instead.
def FollowRename(bnr: number, tbnr: number, fname: string)
  if tbnr > 0
    for winid in tbnr->win_findbuf()
      win_execute(winid, $'buffer {bnr}')
    endfor
    if tbnr->bufexists()
      exe $'bwipe {tbnr}'
    endif
  endif

  # ":file" keeps the old name in a new unlisted buffer.
  var oldName: string = bnr->getbufinfo()[0].name
  ExecuteInBuffer(bnr, $'keepalt file {fname->fnameescape()}')
  for b in getbufinfo()
    if b.bufnr != bnr && b.name ==# oldName
      exe $'bwipe {b.bufnr}'
    endif
  endfor

  # Until it is written, ":write" refuses to write a renamed buffer to the
  # existing file (E13).  Writing it is not needed for the rename, so a buffer
  # that cannot be written is left as it is.
  if !bnr->getbufvar('&modified') && !bnr->getbufvar('&readonly')
      && bnr->getbufvar('&buftype')->empty()
    try
      ExecuteInBuffer(bnr, 'noautocmd write!')
    catch
    endtry
  endif
enddef

# Moves the undo file of file "from", if there is one, to file "to".
def MoveUndoFile(from: string, to: string)
  var undoFrom: string = from->undofile()
  if undoFrom->filereadable()
    var undoTo: string = to->undofile()
    undoTo->fnamemodify(':h')->mkdir('p')
    undoFrom->rename(undoTo)
  endif
enddef

# interface RenameFile
# Rename file or directory "renameFile.oldUri" to "renameFile.newUri".  An
# existing file is replaced only when "overwrite" is set, and then not when
# its buffer has unsaved changes.  The buffers of the renamed files follow
# them.  Returns why the operation failed, or an empty string when it did not.
def FileRename(renameFile: dict<any>): string
  var oldPath: string = UriToPath(renameFile.oldUri)
  var newPath: string = UriToPath(renameFile.newUri)

  var opts: dict<bool> = renameFile->get('options', {})
  var overwrite: bool = opts->get('overwrite', false)
  var ignoreIfExists: bool = opts->get('ignoreIfExists', false)

  if oldPath->getftype()->empty()
    return $'File rename failed, {oldPath} does not exist'
  endif
  if oldPath ==# newPath
    return ''
  endif

  # LSP Spec: Overwrite wins over `ignoreIfExists`
  # As macOS ignores the case of file names, when only the case of the name
  # changes, the new name is of the same file.
  if !newPath->getftype()->empty() && oldPath !=? newPath && !overwrite
    if ignoreIfExists
      return ''
    endif
    return $'File rename failed, {newPath} already exists'
  endif

  # The buffer of each renamed file ("bnr") and of the file it replaces
  # ("tbnr").  When a file that replaces a loaded buffer has no loaded buffer,
  # its buffer is loaded to take the place of that buffer.
  var moves: list<dict<any>> = [{bnr: FileBufnr(oldPath), from: oldPath,
				 to: newPath}]
  for bnr in DirBuffers(oldPath)
    var name: string = bnr->getbufinfo()[0].name
    moves->add({bnr: bnr, from: name,
		to: newPath .. name->strpart(oldPath->len())})
  endfor
  for move in moves
    var tbnr: number = FileBufnr(move.to)
    move.tbnr = tbnr == move.bnr ? 0 : tbnr
    if move.tbnr > 0 && move.tbnr->getbufvar('&modified')
      return $'File rename failed, {move.to} has unsaved changes'
    endif
  endfor
  for move in moves
    if move.tbnr > 0 && move.tbnr->bufloaded()
	&& (move.bnr == 0 || !move.bnr->bufloaded())
      move.bnr = move.from->bufadd()
      move.bnr->bufload()
    endif
  endfor

  newPath->fnamemodify(':h')->mkdir('p')
  if oldPath->rename(newPath) != 0
    return $'File rename failed, {oldPath} to {newPath}'
  endif

  for move in moves
    if move.bnr > 0 && move.bnr->bufloaded()
      FollowRename(move.bnr, move.tbnr, move.to)
    elseif move.bnr > 0
      var listed: bool = move.bnr->buflisted()
      exe $'bwipe {move.bnr}'
      if listed
	setbufvar(move.to->bufadd(), '&buflisted', true)
      endif
    endif
    MoveUndoFile(move.from, move.to)
  endfor
  return ''
enddef

# Apply "change", one of the "documentChanges" of a workspace edit.  Returns
# why the change failed, or an empty string when it did not.
def ApplyDocumentChange(change: dict<any>): string
  var kind: string = change->get('kind', '')
  try
    if kind->empty()
      return ApplyTextDocumentEdit(change)
    elseif kind == 'create'
      return FileCreate(change)
    elseif kind == 'delete'
      return FileDelete(change)
    elseif kind == 'rename'
      return FileRename(change)
    endif
  catch
    return v:exception
  endtry
  return $'Unsupported change in workspace edit [{kind}]'
enddef

# interface WorkspaceEdit
# Apply the changes of workspace edit "workspaceEdit" in order, up to the
# first one that fails, which is reported (the "abort" failure handling).
# Returns the ApplyWorkspaceEditResult.
export def ApplyWorkspaceEdit(workspaceEdit: dict<any>): dict<any>
  if workspaceEdit->has_key('documentChanges')
    var documentChanges: list<dict<any>> = workspaceEdit.documentChanges
    for idx in documentChanges->len()->range()
      var failureReason: string = ApplyDocumentChange(documentChanges[idx])
      if !failureReason->empty()
	util.ErrMsg(failureReason)
	return {applied: false, failureReason: failureReason,
		failedChange: idx}
      endif
    endfor
    return {applied: true}
  endif

  for [uri, changes] in workspaceEdit->get('changes', {})->items()
    var bnr: number = util.LspUriToBufnr(uri)
    if bnr == 0
      var failureReason: string = $'Text edit, buffer {uri} is not found'
      util.ErrMsg(failureReason)
      return {applied: false, failureReason: failureReason}
    endif

    # interface TextEdit
    ApplyTextEdits(bnr, changes)
  endfor
  return {applied: true}
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
