vim9script

# Functions for highlighting the occurrences of the symbol under the cursor
# (textDocument/documentHighlight), either on request (:LspHighlight) or
# automatically as the cursor moves ('autoHighlight' option).

import './util.vim'
import './options.vim' as opt
import './buffer.vim' as buf

# Text property types for the textual, read and write references.
const propNames = ['LspTextRef', 'LspReadRef', 'LspWriteRef']

# Remove all the symbol occurrence highlights in buffer 'bnr'.
export def DocHighlightClear(bnr: number)
  if has('patch-9.0.0233')
    prop_remove({types: propNames, bufnr: bnr, all: true})
  else
    for propName in propNames
      prop_remove({type: propName, bufnr: bnr, all: true})
    endfor
  endif
enddef

# Return the editor state (buffer, changedtick and cursor position) at the
# time of an automatic highlight request for buffer 'bnr'.
export def DocHighlightRequestContextGet(bnr: number): dict<any>
  return {
    bnr: bnr,
    changedtick: bnr->getbufvar('changedtick', -1),
    lnum: line('.'),
    col: col('.')
  }
enddef

# Return true when 'reqctx' still matches the current editor state.  A reply
# to an automatic request is stale once the cursor has moved or the buffer
# has changed since the request was sent.
def RequestContextMatches(reqctx: dict<any>): bool
  return reqctx.bnr == bufnr()
      && reqctx.changedtick == reqctx.bnr->getbufvar('changedtick', -1)
      && reqctx.lnum == line('.')
      && reqctx.col == col('.')
enddef

# Process the "textDocument/documentHighlight" reply (DocumentHighlight[] |
# null) for buffer 'bnr'.  An :LspHighlight reply ('reqctx' is empty) adds to
# the existing highlights.  An automatic reply ('reqctx' describes the state
# when the request was sent) is dropped when stale, and otherwise replaces the
# existing highlights in one step, so that they don't flicker while the
# cursor stays on the same symbol.
export def DocHighlightReply(lspserver: dict<any>, docHighlightReply: any,
			     docHighlightError: dict<any>, bnr: number,
			     cmdmods: string, reqctx: dict<any> = {}): void
  if !reqctx->empty()
    if !RequestContextMatches(reqctx)
      return
    endif
    DocHighlightClear(bnr)
    setbufvar(bnr, 'LspDocHighlightTick', reqctx.changedtick)
  endif

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

# Return true if the cursor is on one of the symbol occurrences highlighted
# in the current buffer.
def CursorInHighlight(): bool
  var col = col('.')
  return !prop_list(line('.'))->filter((_, prop) =>
	propNames->index(prop.type) != -1
	  && prop.col <= col && col < prop.col + prop.length)->empty()
enddef

# Timer callback fired after the auto-highlight delay.  Requests the
# highlights for the symbol under the cursor, unless the user switched to
# another buffer or left normal mode in the meantime.
def DocHighlightAutoTimerCb(bnr: number, timerid: number)
  setbufvar(bnr, 'LspDocHighlightTimer', -1)

  if bufnr() != bnr || mode() !=# 'n'
    return
  endif

  var lspserver: dict<any> = buf.BufLspServerGet(bnr, 'documentHighlight')
  if lspserver->empty()
    return
  endif

  lspserver.docHighlight(bnr, 'silent', true)
enddef

# Cancel the pending auto-highlight request for buffer 'bnr', if any.
export def DocHighlightAutoStop(bnr: number)
  var timerid = bnr->getbufvar('LspDocHighlightTimer', -1)
  if timerid != -1
    timer_stop(timerid)
    setbufvar(bnr, 'LspDocHighlightTimer', -1)
  endif
enddef

# Schedule a highlight request for the symbol under the cursor in buffer
# 'bnr' after the 'autoHighlightDelay' delay.  Called on every cursor
# movement: a pending request is restarted, so that rapid movement results in
# a single request once the cursor rests.  No request is needed while the
# cursor stays on the highlighted symbol in an unchanged buffer.
export def DocHighlightAutoSchedule(bnr: number)
  DocHighlightAutoStop(bnr)

  if !opt.lspOptions.autoHighlight || bufnr() != bnr
    return
  endif

  if bnr->getbufvar('changedtick', -1)
	== bnr->getbufvar('LspDocHighlightTick', -1)
      && CursorInHighlight()
    return
  endif

  var timerid = timer_start(opt.lspOptions.autoHighlightDelay,
			    function('DocHighlightAutoTimerCb', [bnr]))
  setbufvar(bnr, 'LspDocHighlightTimer', timerid)
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
