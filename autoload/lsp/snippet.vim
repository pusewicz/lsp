vim9script

# Snippet support: the expansion of the LSP snippets of completion items, and
# the integration with the UltiSnips and vim-vsnip plugins.

import './snippetparser.vim' as parser
import './textedit.vim'

# An expanded snippet is a session, which ends when the cursor goes to its
# final tabstop or leaves it.  A snippet expanded in another one is a session
# nested in the session of that snippet.  The sessions in a buffer, the
# innermost one last, by buffer number.  A session is a dict:
#   bnr:	 the buffer number
#   spanStart:	 the id of the marker at the start of the snippet
#   spanEnd:	 the id of the marker at the end of the snippet
#   spanLnum:	 the line where the snippet started when last looked up
#   occurrences: the occurrences of the tabstops in the snippet, in text
#		 order, see Expand()
#   order:	 the tabstop indexes in jump order, the final tabstop last
#   current:	 the index in "order" of the tabstop the cursor went to, -1
#		 before the first jump
var sessions: dict<list<dict<any>>> = {}

# The snippet and each occurrence of a tabstop in it have a marker at their
# start and one at their end: a zero-width text property with a unique id.
# Vim keeps a zero-width text property where it is when the text around it
# changes, while a text property over text across lines gets in a state that
# makes joining lines fail (E340, E685).
# Text typed at a marker of the "stay" type goes after it.  Text typed at a
# marker of the "move" type goes before it: it grows over the text, and
# MarkerPositions() makes it zero-width again after the text.  The markers of
# the current tabstop and of the tabstops around it are at the start of the
# "stay" type and at the end of the "move" type, so that they get the text
# typed at their start and end.  The markers of the other tabstops are the
# other way round, so that they don't.
const stayType = 'LspSnippetStay'
const moveType = 'LspSnippetMove'
var lastMarkerId: number = 0

# The choices of the tabstop the cursor goes to, for ShowChoices(): {col,
# words}
var pendingChoices: dict<any> = {}

# True while SyncMirrors() changes the text
var syncing: bool = false

# Add the text property types of the snippet markers, if not done already.
def InitPropTypes()
  if prop_type_get(stayType)->empty()
    prop_type_add(stayType, {start_incl: true})
    prop_type_add(moveType, {end_incl: true})
  endif
enddef

# Return a new unique marker id.
def NewMarkerId(): number
  lastMarkerId += 1
  return lastMarkerId
enddef

# Return the innermost snippet session in buffer "bnr", or an empty dict when
# there is none.
def TopSession(bnr: number): dict<any>
  return sessions->get(string(bnr), [])->get(-1, {})
enddef

# Add a marker with id "id" and type "type" in buffer "bnr" at the position
# "pos": [lnum, col], with a byte column.
def AddMarker(bnr: number, id: number, type: string, pos: list<number>)
  prop_add(pos[0], pos[1], {bufnr: bnr, id: id, type: type, length: 0})
enddef

# Remove the marker with id "id" and type "type" from buffer "bnr", looking
# for it from line "lnum" to line "endLnum", by default in all the lines.
def RemoveMarker(bnr: number, id: number, type: string, lnum: number = 0,
		 endLnum: number = 0)
  var props = {bufnr: bnr, id: id, type: type, both: true, all: true}
  if lnum > 0
    prop_remove(props, lnum, endLnum)
  else
    prop_remove(props)
  endif
enddef

# Return the line of the marker with id "id" and type "type" in buffer "bnr",
# or zero when there is none.  It is looked for in line "lnumHint" first.
def FindMarkerLnum(bnr: number, id: number, type: string,
		   lnumHint: number): number
  if lnumHint >= 1 && lnumHint <= bnr->getbufinfo()[0].linecount
      && !prop_list(lnumHint, {bufnr: bnr, ids: [id], types: [type]})->empty()
    return lnumHint
  endif
  var found = prop_find({bufnr: bnr, id: id, type: type, both: true,
			 lnum: 1, col: 1}, 'f')
  return found->empty() ? 0 : found.lnum
enddef

# Return the positions of the markers of snippet session "session", as for
# AddMarker(), keyed by their id.  Makes a "move" marker that text was typed
# at zero-width again after the text.  Returns an empty dict when a marker of
# the snippet is gone.
def MarkerPositions(session: dict<any>): dict<list<number>>
  var bnr: number = session.bnr
  var lnum = FindMarkerLnum(bnr, session.spanStart, stayType, session.spanLnum)
  if lnum == 0
    return {}
  endif
  session.spanLnum = lnum
  var spanEnd = prop_find({bufnr: bnr, id: session.spanEnd, type: moveType,
			   both: true, lnum: lnum, col: 1}, 'f')
  if spanEnd->empty()
    return {}
  endif
  # A "move" marker that grew over a line break is in the next line too.
  var endLnum: number = spanEnd.lnum
  var lastLnum = bnr->getbufinfo()[0].linecount
  while endLnum < lastLnum
      && !prop_list(endLnum + 1, {bufnr: bnr, ids: [session.spanEnd],
				  types: [moveType]})->empty()
    endLnum += 1
  endwhile

  var ids = [session.spanStart, session.spanEnd]
  for occ in session.occurrences
    ids += [occ.startId, occ.endId]
  endfor
  var positions: dict<list<number>> = {}
  var grown: dict<bool> = {}
  for seg in prop_list(lnum, {bufnr: bnr, end_lnum: endLnum, ids: ids,
			      types: [stayType, moveType]})
    var key = string(seg.id)
    if seg.type == stayType
      if !positions->has_key(key)
	positions[key] = [seg.lnum, seg.col]
      endif
      continue
    endif
    if seg.length > 0 || positions->has_key(key)
      grown[key] = true
    endif
    # A segment that doesn't end the text property includes the line break.
    positions[key] = seg.end ? [seg.lnum, seg.col + seg.length]
      : [seg.lnum + 1, 1]
  endfor

  for key in grown->keys()
    RemoveMarker(bnr, key->str2nr(), moveType, lnum, endLnum)
    AddMarker(bnr, key->str2nr(), moveType, positions[key])
  endfor
  if !positions->has_key(string(session.spanStart))
      || !positions->has_key(string(session.spanEnd))
    return {}
  endif
  return positions
enddef

# Return the ranges of snippet session "session": {span, occurrences}, with
# the range of the whole snippet and a List with the range of each occurrence
# of a tabstop, or an empty List when one of its markers is gone.  A range is
# [lnum, col, endLnum, endCol], with byte columns, the end exclusive.
# Returns an empty dict when a marker of the snippet is gone.
def SessionRanges(session: dict<any>): dict<any>
  var positions = MarkerPositions(session)
  if positions->empty()
    return {}
  endif
  var occurrences: list<list<number>> = []
  for occ in session.occurrences
    var start = positions->get(string(occ.startId), [])
    var end = positions->get(string(occ.endId), [])
    if start->empty() || end->empty()
      occurrences->add([])
    elseif ComparePos(start, end) <= 0
      occurrences->add(start + end)
    else
      # Text typed where the text of a tabstop that the cursor didn't go to
      # was deleted is after its end marker and before its start marker.
      occurrences->add(end + start)
    endif
  endfor
  return {
    span: positions[string(session.spanStart)]
	  + positions[string(session.spanEnd)],
    occurrences: occurrences,
  }
enddef

# Return the text of the current buffer in the range "range", as for
# SessionRanges().
def RangeText(range: list<number>): string
  var [lnum, col, endLnum, endCol] = range
  var lines = getline(lnum, endLnum)
  if lnum == endLnum
    return lines[0]->strpart(col - 1, endCol - col)
  endif
  lines[0] = lines[0]->strpart(col - 1)
  lines[-1] = lines[-1]->strpart(0, endCol - 1)
  return lines->join("\n")
enddef

# Return the range, as for SessionRanges(), of "text" put in the current
# buffer at line "lnum", byte column "col".
def TextRange(lnum: number, col: number, text: string): list<number>
  var lines = text->split("\n", true)
  if lines->len() == 1
    return [lnum, col, lnum, col + text->len()]
  endif
  return [lnum, col, lnum + lines->len() - 1, lines[-1]->len() + 1]
enddef

# Return the value of the snippet variable "name", or v:none for an unknown
# variable.  "ctx" is where the snippet is expanded: {bnr, lnum, line, col,
# workspaceFolder}, with "line" the text of line "lnum" and "col" the byte
# column of the cursor in it.
def ResolveVariable(ctx: dict<any>, name: string): any
  var path = ctx.bnr->bufname()->fnamemodify(':p')
  var folder: string = ctx.workspaceFolder->substitute('.\zs/$', '', '')
  if name == 'TM_SELECTED_TEXT'
    return ''
  elseif name == 'TM_CURRENT_LINE'
    return ctx.line
  elseif name == 'TM_CURRENT_WORD'
    return ctx.line->strpart(0, ctx.col - 1)->matchstr('\k*$')
      .. ctx.line->strpart(ctx.col - 1)->matchstr('^\k*')
  elseif name == 'TM_LINE_INDEX'
    return string(ctx.lnum - 1)
  elseif name == 'TM_LINE_NUMBER'
    return string(ctx.lnum)
  elseif name == 'TM_FILENAME'
    return path->fnamemodify(':t')
  elseif name == 'TM_FILENAME_BASE'
    return path->fnamemodify(':t:r')
  elseif name == 'TM_DIRECTORY'
    return path->fnamemodify(':h')
  elseif name == 'TM_FILEPATH'
    return path
  elseif name == 'RELATIVE_FILEPATH'
    return !folder->empty() && path->stridx($'{folder}/') == 0
      ? path->strpart(folder->len() + 1) : path
  elseif name == 'CLIPBOARD'
    return has('clipboard_working') ? getreg('+') : ''
  elseif name == 'WORKSPACE_NAME'
    return folder->fnamemodify(':t')
  elseif name == 'WORKSPACE_FOLDER'
    return folder
  elseif name == 'CURRENT_SECONDS_UNIX'
    return string(localtime())
  elseif name == 'CURRENT_TIMEZONE_OFFSET'
    return strftime('%z')->substitute('\d\d$', ':&', '')
  elseif name == 'RANDOM'
    return printf('%06d', rand() % 1000000)
  elseif name == 'RANDOM_HEX'
    return printf('%06x', rand() % 0x1000000)
  elseif name == 'UUID'
    return printf('%08x-%04x-4%03x-%04x-%04x%08x', rand(), rand() % 0x10000,
		  rand() % 0x1000, 0x8000 + rand() % 0x4000, rand() % 0x10000,
		  rand())
  elseif ['BLOCK_COMMENT_START', 'BLOCK_COMMENT_END',
	  'LINE_COMMENT']->index(name) >= 0
    return CommentMarkers(ctx.bnr)[name]
  endif

  var timeFormats = {
    CURRENT_YEAR: '%Y',
    CURRENT_YEAR_SHORT: '%y',
    CURRENT_MONTH: '%m',
    CURRENT_MONTH_NAME: '%B',
    CURRENT_MONTH_NAME_SHORT: '%b',
    CURRENT_DATE: '%d',
    CURRENT_DAY_NAME: '%A',
    CURRENT_DAY_NAME_SHORT: '%a',
    CURRENT_HOUR: '%H',
    CURRENT_MINUTE: '%M',
    CURRENT_SECOND: '%S',
  }
  if timeFormats->has_key(name)
    return strftime(timeFormats[name])
  endif
  return v:none
enddef

# Return the comment markers of buffer "bnr" for the snippet variables:
# {BLOCK_COMMENT_START, BLOCK_COMMENT_END, LINE_COMMENT}, from its
# 'commentstring' and 'comments' options.  A marker is empty when the options
# don't give it.
def CommentMarkers(bnr: number): dict<string>
  var markers = {BLOCK_COMMENT_START: '', BLOCK_COMMENT_END: '',
		 LINE_COMMENT: ''}
  var cms: list<string> = bnr->getbufvar('&commentstring')
    ->matchlist('^\s*\(.\{-}\)\s*%s\s*\(.\{-}\)\s*$')
  if !cms->empty()
    if !cms[2]->empty()
      markers.BLOCK_COMMENT_START = cms[1]
      markers.BLOCK_COMMENT_END = cms[2]
    else
      markers.LINE_COMMENT = cms[1]
    endif
  endif

  # In 'comments', the start and the end of a three-piece comment have the
  # "s" and "e" flags, and a comment that only has a leader has no flags
  # other than "b" or "n".  An "O" flag marks one only for the "O" command.
  for part in bnr->getbufvar('&comments')->split('\\\@<!,')
    var [flags, str] = part->matchlist('^\([^:]*\):\(.*\)$')[1 : 2]
    if flags =~# 'O' || str->empty()
      continue
    endif
    str = str->substitute('\\,', ',', 'g')
    if flags =~# 's' && markers.BLOCK_COMMENT_START->empty()
      markers.BLOCK_COMMENT_START = str
    elseif flags =~# 'e' && markers.BLOCK_COMMENT_END->empty()
      markers.BLOCK_COMMENT_END = str
    elseif flags =~# '^[bn]*$' && markers.LINE_COMMENT->empty()
      markers.LINE_COMMENT = str
    endif
  endfor
  return markers
enddef

# Return the leading white space of "line" with each tab replaced with the
# white space of an indent when 'expandtab' is set, which a snippet means a
# tab for.
def NormalizeIndent(line: string): string
  var indent = line->matchstr('^\s*')
  if !&expandtab
    return indent
  endif
  return indent->substitute('\t', repeat(' ', shiftwidth()), 'g')
enddef

# Return the snippet text "text" rendered by the snippet parser as lines to
# insert in a line with indent "indent", and a function that returns the
# position of a byte offset in "text" in the lines: [line index, byte index].
# With "adjust" each line after the first one gets "indent" and its indent
# normalized, else the lines are as in "text".
def LayOutLines(text: string, indent: string, adjust: bool): list<any>
  # The indent of a line of "text" as in the lines
  var Indent = adjust ? (line: string): string => indent .. NormalizeIndent(line)
    : (line: string): string => line->matchstr('^\s*')

  var origLines = text->split("\n", true)
  var lines: list<string> = []
  var lineStarts: list<number> = []
  var leadLens: list<number> = []
  var offset = 0
  for i in origLines->len()->range()
    var line = origLines[i]
    lineStarts->add(offset)
    offset += line->len() + 1
    leadLens->add(line->matchstr('^\s*')->len())
    lines->add(i == 0 ? line : Indent(line) .. line->strpart(leadLens[i]))
  endfor

  var Position = (textOffset: number): list<number> => {
    var i = lineStarts->len() - 1
    while i > 0 && lineStarts[i] > textOffset
      i -= 1
    endwhile
    var col = textOffset - lineStarts[i]
    if i == 0
      return [0, col]
    endif
    if col <= leadLens[i]
      return [i, Indent(origLines[i]->strpart(0, col))->len()]
    endif
    return [i, Indent(origLines[i])->len() + col - leadLens[i]]
  }
  return [lines, Position]
enddef


# Compare the buffer positions [lnum, col] "a" and "b": return a negative
# number when "a" is before "b", zero when they are the same and a positive
# number when "a" is after "b".
def ComparePos(a: list<number>, b: list<number>): number
  return a[0] != b[0] ? a[0] - b[0] : a[1] - b[1]
enddef

# Return true when the position [lnum, col] "pos" is in the snippet of
# session "session", including its start and its end.
def PosInSession(session: dict<any>, pos: list<number>): bool
  var span: list<number> = SessionRanges(session)->get('span', [])
  return !span->empty() && ComparePos(pos, span[0 : 1]) >= 0
    && ComparePos(pos, span[2 : 3]) <= 0
enddef

# Add the autocmds that keep the snippet sessions of buffer "bnr" going.
def AddSessionAutocmds(bnr: number)
  autocmd_add([{
    bufnr: bnr,
    event: ['TextChanged', 'TextChangedI', 'TextChangedP'],
    group: 'LspSnippet',
    cmd: $'SyncMirrors({bnr})',
    replace: true,
  }, {
    bufnr: bnr,
    event: ['CursorMoved', 'CursorMovedI'],
    group: 'LspSnippet',
    cmd: $'EndSessionsLeft({bnr})',
    replace: true,
  }, {
    bufnr: bnr,
    event: 'BufUnload',
    group: 'LspSnippet',
    cmd: $'ForgetSessions({bnr})',
    replace: true,
  }])
enddef

# Forget the snippet sessions of buffer "bnr", without removing their markers,
# as when the buffer is unloaded.
def ForgetSessions(bnr: number)
  if sessions->has_key(string(bnr))
    sessions->remove(string(bnr))
  endif
  autocmd_delete([{bufnr: bnr, group: 'LspSnippet'}])
enddef

# End the innermost snippet session in buffer "bnr", removing its markers.
def EndSession(bnr: number)
  var stack = sessions->get(string(bnr), [])
  if stack->empty()
    return
  endif
  var session = stack->remove(-1)
  if stack->empty()
    ForgetSessions(bnr)
    if bnr->bufloaded()
      prop_remove({bufnr: bnr, types: [stayType, moveType], all: true})
    endif
    return
  endif
  RemoveMarker(bnr, session.spanStart, stayType)
  RemoveMarker(bnr, session.spanEnd, moveType)
  for occ in session.occurrences
    RemoveMarker(bnr, occ.startId, occ.startType)
    RemoveMarker(bnr, occ.endId, occ.endType)
  endfor
enddef

# End the snippet sessions in buffer "bnr" that the position [lnum, col]
# "pos" is not in, by default the cursor position.
def EndSessionsLeft(bnr: number, pos: list<number> = [line('.'), col('.')])
  while !TopSession(bnr)->empty() && !PosInSession(TopSession(bnr), pos)
    EndSession(bnr)
  endwhile
enddef

# Insert the LSP snippet "snippetText" in the current buffer in place of the
# text from byte column "col" up to byte column "endCol" (exclusive) on line
# "lnum", and start a snippet session for its tabstops, which Jump() goes to.
# When "adjustIndent" is true, the lines after the first one get the indent of
# line "lnum", and a tab in their indent is an indent, else they are inserted
# as they are.  "workspaceFolder" is the folder of the language server
# workspace, for the snippet variables.
export def Expand(snippetText: string, lnum: number, col: number,
		  endCol: number, adjustIndent: bool, workspaceFolder: string)
  InitPropTypes()
  var bnr = bufnr()
  var line = getline(lnum)
  # A snippet expanded outside of the snippets of the sessions ends them.
  EndSessionsLeft(bnr, [lnum, col])

  var ctx = {bnr: bnr, lnum: lnum, line: line, col: endCol,
	     workspaceFolder: workspaceFolder}
  var rendered = parser.Render(
    parser.Parse(snippetText->substitute('\r\n\=', '\n', 'g')),
    (name) => ResolveVariable(ctx, name))
  var [lines, Position] = LayOutLines(rendered.text, line->matchstr('^\s*'),
				      adjustIndent)
  var text = lines->join("\n")

  # The buffer position of a byte offset in the rendered text
  var BufPos = (offset: number): list<number> => {
    var [i, byteIdx] = Position(offset)
    return [lnum + i, i == 0 ? col + byteIdx : byteIdx + 1]
  }

  textedit.ReplaceText(lnum, col, lnum, endCol, text)

  var span = TextRange(lnum, col, text)
  var session: dict<any> = {
    bnr: bnr,
    spanStart: NewMarkerId(),
    spanEnd: NewMarkerId(),
    spanLnum: lnum,
    occurrences: [],
    order: [],
    current: -1,
  }
  AddMarker(bnr, session.spanStart, stayType, span[0 : 1])
  AddMarker(bnr, session.spanEnd, moveType, span[2 : 3])
  for tabstop in rendered.tabstops
    # No tabstop is the current one yet.
    var empty = tabstop.start == tabstop.end
    var occ: dict<any> = {
      startId: NewMarkerId(),
      endId: NewMarkerId(),
      startType: empty ? stayType : moveType,
      endType: stayType,
      index: tabstop.index,
      primary: tabstop.primary,
      parent: tabstop.parent,
    }
    for key in ['choices', 'transform']
      if tabstop->has_key(key)
	occ[key] = tabstop[key]
      endif
    endfor
    session.occurrences->add(occ)
    AddMarker(bnr, occ.startId, occ.startType, BufPos(tabstop.start))
    AddMarker(bnr, occ.endId, occ.endType, BufPos(tabstop.end))
    if session.order->index(tabstop.index) < 0
      session.order->add(tabstop.index)
    endif
  endfor
  session.order->sort('n')
  # The final tabstop comes last
  session.order->add(session.order->remove(0))

  if !sessions->has_key(string(bnr))
    sessions[string(bnr)] = []
    AddSessionAutocmds(bnr)
  endif
  sessions[string(bnr)]->add(session)
  cursor(span[2 : 3])
enddef

# Return the index in "session.occurrences" of the primary occurrence of the
# tabstop at index "i" of "session.order".
def PrimaryOccurrence(session: dict<any>, i: number): number
  var index = session.order[i]
  return session.occurrences->indexof((_, occ) => occ.index == index
					&& occ.primary)
enddef

# Return the index in "session.order" of the tabstop the cursor goes to from
# the current one in direction "dir" (1 or -1), skipping a tabstop whose text
# is gone.  "ranges" are the SessionRanges() of "session".  Returns -1 when
# there is none.
def TargetTabstop(session: dict<any>, ranges: dict<any>, dir: number): number
  var i = session.current + dir
  while i >= 0 && i < session.order->len()
    var primary = PrimaryOccurrence(session, i)
    if primary >= 0 && !ranges.occurrences[primary]->empty()
      return i
    endif
    i += dir
  endwhile
  return -1
enddef

# Give the markers of the occurrences of the current tabstop of session
# "session" and of the tabstops they are in the types that get the text typed
# at them, and the others the types that don't, see "stayType".  "ranges" are
# the SessionRanges() of "session".
def SetActiveTabstop(session: dict<any>, ranges: dict<any>)
  var index = session.order[session.current]
  var occurrences: list<dict<any>> = session.occurrences
  var active: dict<bool> = {}
  for i in occurrences->len()->range()
    if occurrences[i].index == index
      var j = i
      while j >= 0
	active[string(j)] = true
	j = occurrences[j].parent
      endwhile
    endif
  endfor
  var primary = PrimaryOccurrence(session, session.current)

  for i in occurrences->len()->range()
    var range: list<number> = ranges.occurrences[i]
    if range->empty()
      continue
    endif
    var types: list<string>
    if active->has_key(string(i))
      types = [stayType, moveType]
    elseif range[0 : 1] == range[2 : 3]
      # Text typed at an empty tabstop goes to the current one, before or
      # after it.
      types = i > primary ? [moveType, moveType] : [stayType, stayType]
    else
      types = [moveType, stayType]
    endif
    var occ = occurrences[i]
    RemoveMarker(session.bnr, occ.startId, occ.startType, range[0], range[2])
    RemoveMarker(session.bnr, occ.endId, occ.endType, range[0], range[2])
    [occ.startType, occ.endType] = types
    AddMarker(session.bnr, occ.startId, occ.startType, range[0 : 1])
    AddMarker(session.bnr, occ.endId, occ.endType, range[2 : 3])
  endfor
enddef

# Show the choices of the tabstop the cursor went to in the completion menu.
# Called in Insert mode with the cursor after the text of the tabstop.
def ShowChoices()
  if mode() =~# '^i' && !pendingChoices->empty()
    complete(pendingChoices.col, pendingChoices.words)
  endif
  pendingChoices = {}
enddef

# Return the keys that end Insert, Select or Visual mode.
def ToNormalModeKeys(): string
  return mode() ==# 'n' ? '' : "\<C-\>\<C-N>"
enddef

# Return the keys that move the cursor to the end of the Visual selection of
# the range "range", as for SessionRanges(), with the cursor at its start.
def SelectionEndKeys(range: list<number>): string
  var [lnum, col, endLnum, endCol] = range
  if &selection ==# 'exclusive'
    return $"\<Cmd>call cursor({endLnum}, {endCol})\<CR>"
  endif
  if endCol == 1
    # Up to and including the line break
    return $"\<Cmd>call cursor({endLnum - 1}, 1)\<CR>$"
  endif
  var lastChar = getline(endLnum)->strpart(0, endCol - 1)->matchstr('.$')
  return $"\<Cmd>call cursor({endLnum}, {endCol - lastChar->len()})\<CR>"
enddef

# Move the cursor to a tabstop with the text in the range "range", as for
# SessionRanges(): select its text in Select mode, so that typing replaces
# it, or when it has no text start Insert mode there.  For a tabstop with
# "choices", start Insert mode after its text and show the choices.
def GoToTabstop(range: list<number>, choices: list<string>)
  var [lnum, col, endLnum, endCol] = range
  var inInsertMode = mode() =~# '^[iR]'
  if !choices->empty() && lnum == endLnum
    pendingChoices = {col: col, words: choices}
    feedkeys((inInsertMode ? '' : ToNormalModeKeys() .. 'i')
	     .. $"\<Cmd>call cursor({endLnum}, {endCol})\<CR>"
	     .. $"\<Cmd>call {function(ShowChoices)->get('name')}()\<CR>", 'ni')
  elseif [lnum, col] == [endLnum, endCol]
    if inInsertMode
      cursor(lnum, col)
    else
      feedkeys($"{ToNormalModeKeys()}i\<Cmd>call cursor({lnum}, {col})\<CR>",
	       'ni')
    endif
  else
    feedkeys($"{ToNormalModeKeys()}\<Cmd>call cursor({lnum}, {col})\<CR>gh"
	     .. SelectionEndKeys(range), 'ni')
  endif
enddef

# Move the cursor to the next ("dir" 1) or the previous ("dir" -1) tabstop of
# the innermost snippet session in the current buffer.  Going to the final
# tabstop ends the session.
export def Jump(dir: number)
  var bnr = bufnr()
  var session = TopSession(bnr)
  if session->empty()
    return
  endif
  SyncMirrors(bnr)
  var ranges = SessionRanges(session)
  if ranges->empty()
    EndSession(bnr)
    return
  endif
  var target = TargetTabstop(session, ranges, dir)
  if target < 0
    if dir > 0
      EndSession(bnr)
    endif
    return
  endif

  session.current = target
  var primary = session.occurrences[PrimaryOccurrence(session, target)]
  var range = ranges.occurrences[PrimaryOccurrence(session, target)]
  if primary.index == 0
    EndSession(bnr)
  else
    SetActiveTabstop(session, ranges)
  endif
  GoToTabstop(range, primary->get('choices', []))
enddef

# Return true when Jump() can move the cursor in direction "dir" (1 or -1)
# in the current buffer: to a tabstop of a snippet session.
export def Jumpable(dir: number): bool
  var session = TopSession(bufnr())
  if session->empty()
    return false
  endif
  var ranges = SessionRanges(session)
  return !ranges->empty() && (dir > 0 || TargetTabstop(session, ranges, dir) >= 0)
enddef

# Join the next change with the previous undo block, so that undo reverts a
# mirror together with the change it mirrors.  Returns false when the last
# change was an undo, which is not to be redone.
def UndoJoin(): bool
  try
    :undojoin
  catch /^Vim\%((\a\+)\)\=:E790:/
    return false
  endtry
  return true
enddef

# After a change in buffer "bnr": put the snippet markers that text was typed
# at in place, see MarkerPositions(), and make the mirrors of the current
# tabstop of each snippet session have the text of the tabstop, transformed
# for a mirror with a transformation.
def SyncMirrors(bnr: number)
  if syncing || bnr != bufnr()
    return
  endif
  syncing = true
  try
    for session in sessions->get(string(bnr), [])->copy()->reverse()
      var ranges = SessionRanges(session)
      if ranges->empty() || session.current < 0
	continue
      endif
      var occurrences: list<dict<any>> = session.occurrences
      var primary = PrimaryOccurrence(session, session.current)
      if ranges.occurrences[primary]->empty()
	continue
      endif
      # The last mirror first, so that changing a mirror doesn't move the
      # ones left.
      var mirrors = occurrences->len()->range()
	->filter((_, i) => occurrences[i].index == occurrences[primary].index
		 && i != primary && !ranges.occurrences[i]->empty())
	->sort((a, b) => ComparePos(ranges.occurrences[b], ranges.occurrences[a]))
      var text = RangeText(ranges.occurrences[primary])
      for i in mirrors
	var occ = occurrences[i]
	var mirrorText = occ->has_key('transform')
	  ? parser.ApplyTransform(text, occ.transform) : text
	if RangeText(ranges.occurrences[i]) ==# mirrorText
	  continue
	endif
	if !UndoJoin()
	  return
	endif
	var [lnum, col, endLnum, endCol] = ranges.occurrences[i]
	textedit.ReplaceText(lnum, col, endLnum, endCol, mirrorText)
	var range = TextRange(lnum, col, mirrorText)
	RemoveMarker(bnr, occ.startId, occ.startType, lnum,
		     [endLnum, range[2]]->max())
	RemoveMarker(bnr, occ.endId, occ.endType, lnum,
		     [endLnum, range[2]]->max())
	AddMarker(bnr, occ.startId, occ.startType, range[0 : 1])
	AddMarker(bnr, occ.endId, occ.endType, range[2 : 3])
      endfor
    endfor
  finally
    syncing = false
  endtry
enddef

# Integration with the UltiSnips plugin
export def CompletionUltiSnips(prefix: string, items: list<dict<any>>)
  call UltiSnips#SnippetsInCurrentScope(1)
  for key in matchfuzzy(g:current_ulti_dict_info->keys(), prefix)
    var item = g:current_ulti_dict_info[key]
    var parts = split(item.location, ':')
    var txt = parts[0]->readfile()[parts[1]->str2nr() : parts[1]->str2nr() + 20]
    var restxt = item.description .. "\n\n"
    for line in txt
      if line->empty() || line[0 : 6] == "snippet"
	break
      else
	restxt = restxt .. line .. "\n"
      endif
    endfor
    items->add({
      label: key,
      data: {
	entryNames: [key],
      },
      kind: 15,
      documentation: restxt,
    })
  endfor
enddef

# Integration with the vim-vsnip plugin
export def CompletionVsnip(items: list<dict<any>>)
  def Pattern(abbr: string): string
    var chars = escape(abbr, '\/?')->split('\zs')
    var chars_pattern = '\%(\V' .. chars->join('\m\|\V') .. '\m\)'
    var separator = chars[0] =~ '\a' ? '\<' : ''
    return $'{separator}\V{chars[0]}\m{chars_pattern}*$'
  enddef

  if charcol('.') == 1
    return
  endif
  var starttext = getline('.')->slice(0, charcol('.') - 1)
  for item in vsnip#get_complete_items(bufnr())
    var match = starttext->matchstrpos(Pattern(item.abbr))
    if match[0] != ''
      var user_data = item.user_data->json_decode()
      var documentation = []
      for line in vsnip#to_string(user_data.vsnip.snippet)->split("\n")
	documentation->add(line)
      endfor
      items->add({
	label: item.abbr,
	filterText: item.word,
	insertTextFormat: 2,
	textEdit: {
	  newText: user_data.vsnip.snippet->join("\n"),
	  range: {
	    start: {
	      line: line('.'),
	      character: match[1],
	    },
	    ['end']: {
	      line: line('.'),
	      character: match[2],
	    },
	  },
	},
	data: {
	  entryNames: [item.word],
	},
	kind: 15,
	documentation: {
	  kind: 'markdown',
	  value: documentation->join("\n"),
	},
      })
    endif
  endfor
enddef

# Return the text that the LSP snippet "snippet" inserts when nothing is typed
# in it: tabstops insert nothing, placeholders and variables with a default
# their default text and choices their first option.  Variables are not
# resolved, so the ones without a default insert nothing.
export def SnippetToText(snippet: string): string
  return parser.Render(parser.Parse(snippet), (_) => '').text
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
