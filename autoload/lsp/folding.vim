vim9script

# Functions for folding the text with the folding ranges of the language
# server: once with ":LspFold", or kept in sync with the buffer with the
# 'foldexpr' and 'foldtext' functions.

import './buffer.vim' as buf

# The milliseconds to wait after a change to a buffer before requesting its
# folding ranges again.
const UPDATE_DELAY: number = 300

# Replace the folds in the current window with the folding ranges "ranges",
# for ":LspFold".
# Result: FoldingRange[] | null
export def CreateManualFolds(ranges: any)
  # Remove all the current folds
  :normal! zE

  if ranges->empty()
    return
  endif

  var end_lnum: number
  for foldRange in ranges
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

# The folds of a buffer computed by FoldExpr() are kept in the buffer variable
# "LspFoldState", a Dict with these items:
#   levels	FoldExpr()'s value for each line, from the folding ranges, or
#		an empty List until they arrive
#   texts	the collapsed text of the folds that start at each line, a Dict
#		by fold level or null, or an empty List when the folding ranges
#		have no collapsed text
#   adjusted	"levels" and "texts" were adjusted to changes to the buffer,
#		or forgotten, since the folding ranges arrived
#   listenerId	the ID of the listener that adjusts "levels" and "texts" to
#		the changes to the buffer, or 0 when they are not requested
#		from a language server
#   timerId	the ID of the timer to request the folding ranges, or 0
#   changed	the buffer was changed since that timer was started

# Returns the fold level of line v:lnum of the current buffer from the folding
# ranges of its language server, for the 'foldexpr' option.  The first call
# for a buffer requests them, and there are no folds until they arrive.
export def FoldExpr(): any
  var state: dict<any> = get(b:, 'LspFoldState', null_dict)
  if state == null
    state = FoldsStart(bufnr())
  endif
  return state.levels->get(v:lnum - 1, 0)
enddef

# Returns the text to show for the closed fold at line v:foldstart of the
# current buffer, for the 'foldtext' option: the collapsed text of its
# folding range, or else what foldtext() returns.
export def FoldText(): string
  var state: dict<any> = get(b:, 'LspFoldState', null_dict)
  if state != null
    var texts: dict<any> = state.texts->get(v:foldstart - 1, null_dict)
    var level: string = $'{v:foldlevel}'
    if texts != null && texts->has_key(level)
      return texts[level]
    endif
  endif
  return foldtext()
enddef

# Start computing the folds of buffer "bnr" with FoldExpr(), which is
# evaluating 'foldexpr': request the folding ranges once that is done.
# Returns the fold state of the buffer.
def FoldsStart(bnr: number): dict<any>
  var levels: list<any> = []
  var texts: list<any> = []
  var state: dict<any> = {
    levels: levels,
    texts: texts,
    adjusted: false,
    listenerId: 0,
    timerId: 0,
    changed: false
  }
  setbufvar(bnr, 'LspFoldState', state)
  ScheduleUpdate(bnr, state, 0)
  return state
enddef

# Request the folding ranges of buffer "bnr", with the fold state "state", in
# "delay" milliseconds, unless that is already scheduled.
def ScheduleUpdate(bnr: number, state: dict<any>, delay: number)
  if state.timerId == 0
    state.timerId = timer_start(delay, function('UpdateTimerCb', [bnr]))
  endif
enddef

# Timer callback to request the folding ranges of buffer "bnr".  Waits until
# the buffer is not changed for a while, and until Insert mode is left in it,
# so that the folds don't change while the text is typed.  Without a language
# server ready to provide them, BufferInit() requests them later.
def UpdateTimerCb(bnr: number, _: number)
  var state: dict<any> = getbufvar(bnr, 'LspFoldState', null_dict)
  if state == null
    return
  endif
  state.timerId = 0

  if state.changed || (bnr == bufnr() && mode() =~# '^[iR]')
    state.changed = false
    ScheduleUpdate(bnr, state, UPDATE_DELAY)
    return
  endif

  var lspserver: dict<any> = buf.BufLspServerGet(bnr, 'foldingRange')
  if lspserver->empty() || !lspserver.docVersions->has_key(bnr)
    return
  endif

  if state.listenerId == 0
    state.listenerId = listener_add(BufferChanged, bnr, true)
  endif
  lspserver.foldingRangesUpdate(bnr)
enddef

# Listener callback for a change to lines "start" to "end" (exclusive) of
# buffer "bnr" that added "added" lines.  Adjusts the fold levels to it before
# Vim computes the folds of the changed lines again, and requests the folding
# ranges again after a while.
def BufferChanged(bnr: number, start: number, end: number, added: number,
		  _: list<dict<any>>)
  var state: dict<any> = getbufvar(bnr, 'LspFoldState', null_dict)
  # listener_remove() leaves an unbuffered listener to be called for the next
  # change.
  if state == null || state.listenerId == 0
    return
  endif

  if added != 0
    # An added line gets the lower fold level of the lines around it, until
    # the folding ranges arrive.
    AdjustLines(state.levels, start, end, added, -1)
    AdjustLines(state.texts, start, end, added, null_dict)
    state.adjusted = true
  endif

  if state.timerId == 0
    ScheduleUpdate(bnr, state, UPDATE_DELAY)
  else
    state.changed = true
  endif
enddef

# Adjust "lines", which has an item for each line of a buffer, to the change
# of lines "start" to "end" (exclusive) that added "added" lines, as a
# listener callback gets it.  The added lines get the item "item".
def AdjustLines(lines: list<any>, start: number, end: number, added: number,
		item: any)
  if lines->empty()
    return
  endif

  if added > 0
    lines->extend(repeat([item], added), min([end - 1, lines->len()]))
  else
    var first: number = end - 1 + added
    if first < lines->len()
      lines->remove(first, min([first - added, lines->len()]) - 1)
    endif
  endif
enddef

# Returns the fold levels and the collapsed texts for the "levels" and "texts"
# of the fold state of a buffer with "lineCount" lines, from its folding
# ranges "ranges".  The fold level of a line is the number of ranges it is
# in.  It starts with ">" on the first line of a range, so that adjacent
# ranges make separate folds, and else with "<" on the last line of a range,
# so that a range ends before others start on the next line.  A range that
# doesn't span lines, or that is like another, is left out.
def FoldLevels(ranges: list<any>, lineCount: number): list<list<any>>
  # The first and the last line index and the collapsed text of the ranges
  var bounds: list<list<any>> = []
  var seen: dict<bool> = {}
  for foldRange in ranges
    var first: number = foldRange.startLine
    var last: number = min([foldRange.endLine, lineCount - 1])
    var key: string = $'{first} {last}'
    if first < 0 || last <= first || seen->has_key(key)
      continue
    endif
    seen[key] = true
    bounds->add([first, last, foldRange->get('collapsedText', '')])
  endfor

  var depthChanges: list<number> = repeat([0], lineCount + 1)
  for [first, last, _] in bounds
    depthChanges[first] += 1
    depthChanges[last + 1] -= 1
  endfor
  var depths: list<number> = []
  var levels: list<any> = []
  var depth: number = 0
  for idx in range(lineCount)
    depth += depthChanges[idx]
    depths->add(depth)
    levels->add(depth)
  endfor
  for [_, last, _] in bounds
    levels[last] = $'<{depths[last]}'
  endfor
  for [first, _, _] in bounds
    levels[first] = $'>{depths[first]}'
  endfor

  var texts: list<any> = []
  if bounds->indexof((_, bound) => !bound[2]->empty()) != -1
    texts = repeat([null_dict], lineCount)
    # The ranges that start on the same line are folds of consecutive
    # levels, from the longest one to the shortest one.
    bounds->sort((a, b) => a[0] == b[0] ? b[1] - a[1] : a[0] - b[0])
    var startCounts: list<number> = repeat([0], lineCount)
    for [first, _, _] in bounds
      startCounts[first] += 1
    endfor
    var prevFirst: number = -1
    var level: number = 0
    for [first, _, text] in bounds
      level = first == prevFirst ? level + 1
	: depths[first] - startCounts[first] + 1
      prevFirst = first
      if !text->empty()
	if texts[first] == null
	  texts[first] = {}
	endif
	texts[first][$'{level}'] = text
      endif
    endfor
  endif

  return [levels, texts]
enddef

# Process the folding ranges "ranges" of buffer "bnr" that language server
# "lspserver" replied, or the error "error".  The folds of the windows that
# show the buffer are computed again with them.
# Result: FoldingRange[] | null
export def FoldingRangesReply(lspserver: dict<any>, bnr: number, ranges: any,
			      error: dict<any>)
  if !error->empty()
    lspserver.traceLog($'Folding ranges failed: {error.message}')
    return
  endif

  var state: dict<any> = getbufvar(bnr, 'LspFoldState', null_dict)
  if state == null || state.listenerId == 0
    return
  endif

  var [levels, texts] = FoldLevels(ranges ?? [], bnr->getbufinfo()[0].linecount)
  if !state.adjusted && levels == state.levels && texts == state.texts
    return
  endif
  state.levels = levels
  state.texts = texts
  state.adjusted = false

  for winid in bnr->win_findbuf()
    win_execute(winid, 'RefreshWindowFolds()')
  endfor
enddef

# Compute the folds of the current window again with 'foldexpr', keeping the
# folds that are still there open or closed as they were: setting 'foldmethod'
# does that, unlike "zx", which applies 'foldlevel' again.  When the cursor
# line was not in a closed fold before, a new fold doesn't hide it.
def RefreshWindowFolds()
  if &foldmethod != 'expr'
    return
  endif

  var cursorShown: bool = foldclosed('.') == -1
  noautocmd &l:foldmethod = 'expr'
  if cursorShown && foldclosed('.') != -1
    :foldopen!
  endif
enddef

# Request the folding ranges again for the documents open on language server
# "lspserver" whose folds are computed with FoldExpr() from its folding ranges.
export def Refresh(lspserver: dict<any>)
  for bnr in lspserver.docBufnrs->values()
    var state: dict<any> = getbufvar(bnr, 'LspFoldState', null_dict)
    var foldServer: dict<any> = buf.BufLspServerGet(bnr, 'foldingRange')
    if state != null && !foldServer->empty() && foldServer.id == lspserver.id
      ScheduleUpdate(bnr, state, 0)
    endif
  endfor
enddef

# Request the folding ranges of buffer "bnr", if its folds are computed with
# FoldExpr(), now that its language servers are ready.
export def BufferInit(bnr: number)
  var state: dict<any> = getbufvar(bnr, 'LspFoldState', null_dict)
  if state != null
    ScheduleUpdate(bnr, state, 0)
  endif
enddef

# Request the folding ranges of buffer "bnr" again, if its folds are computed
# with FoldExpr(), as it was reloaded from its file, which changed outside of
# Vim.  The listener doesn't get that change, so the fold levels don't match
# the lines until the folding ranges arrive.
export def BufferReloaded(bnr: number)
  var state: dict<any> = getbufvar(bnr, 'LspFoldState', null_dict)
  if state != null && state.listenerId != 0
    state.adjusted = true
    ScheduleUpdate(bnr, state, 0)
  endif
enddef

# Stop updating the folds of buffer "bnr", which is detached from its
# language servers, and forget its folding ranges, which don't follow the
# changes to it any longer.  BufferInit() requests them again.
export def BufferDeInit(bnr: number)
  var state: dict<any> = getbufvar(bnr, 'LspFoldState', null_dict)
  if state == null
    return
  endif

  if state.timerId != 0
    timer_stop(state.timerId)
    state.timerId = 0
  endif
  if state.listenerId != 0
    listener_remove(state.listenerId)
    state.listenerId = 0
  endif
  var levels: list<any> = []
  var texts: list<any> = []
  state.levels = levels
  state.texts = texts
  state.adjusted = true
  state.changed = false
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
