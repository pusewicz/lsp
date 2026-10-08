vim9script

# Functions related to handling LSP range selection.

import './util.vim'

# Visually (character-wise) select the text in the LSP range "range" in the
# current buffer "bnr".  Returns the start and the end of the selection, as
# getpos('v') and getpos('.') return them.
def SelectText(bnr: number, range: dict<dict<number>>): list<list<number>>
  var rstart = range.start
  var rend = range.end
  var startPos: list<number> =
    [rstart.line + 1, util.GetLineByteFromPos(bnr, rstart) + 1]
  # The end of an LSP range is exclusive.  The end of a Visual selection is
  # included in it, unless 'selection' is "exclusive".
  var endPos: list<number>
  if &selection == 'exclusive'
    endPos = [rend.line + 1, util.GetLineByteFromPos(bnr, rend) + 1]
    if endPos[0] > line('$')
      # The range ends at the end of the buffer
      endPos = [line('$'), col([line('$'), '$'])]
    endif
  else
    endPos = [rend.line + 1, util.GetLineByteFromPos(bnr, rend)]
    if endPos[1] == 0 && endPos[0] > startPos[0]
      # The range ends at the start of a line.  Select up to the line break
      # of the previous line, which is past the end of that line.
      endPos[0] -= 1
      endPos[1] = col([endPos[0], '$'])
    endif
  endif
  if endPos[0] < startPos[0]
      || (endPos[0] == startPos[0] && endPos[1] < startPos[1])
    # The range is empty.  Select the character at its start.
    endPos = startPos
  endif

  :normal! v"_y
  setpos("'<", [0, startPos[0], startPos[1], 0])
  setpos("'>", [0, endPos[0], endPos[1], 0])
  :normal! gv
  return [getpos('v'), getpos('.')]
enddef

# Process the range selection reply from LSP server and start a new selection
export def SelectionStart(lspserver: dict<any>, sel: list<dict<any>>)
  if sel->empty()
    return
  endif

  var bnr: number = bufnr()

  # save the reply for expanding or shrinking the selected text.
  lspserver.selection = {bnr: bnr, selRange: sel[0], index: 0}

  lspserver.selection.visual = SelectText(bnr, sel[0].range)
enddef

# Locate the range in the LSP reply at a specified level
def GetSelRangeAtLevel(selRange: dict<any>, level: number): dict<any>
  var r: dict<any> = selRange
  var idx: number = 0

  while idx != level
    if !r->has_key('parent')
      break
    endif
    r = r.parent
    idx += 1
  endwhile

  return r
enddef

# Returns true if the current visual selection is the one that SelectText()
# made and returned "visual" for, with the cursor at either end.
def SelectionFromLSP(visual: list<list<number>>): bool
  var cur: list<list<number>> = [getpos('v'), getpos('.')]
  return cur == visual || cur->reverse() == visual
enddef

# Expand or Shrink the current selection or start a new one.
export def SelectionModify(lspserver: dict<any>, expand: bool)
  var fname: string = @%
  var bnr: number = bufnr()

  if mode() == 'v' && !lspserver.selection->empty()
					&& lspserver.selection.bnr == bnr
					&& !lspserver.selection->empty()
    # Already in characterwise visual mode and the previous LSP selection
    # reply for this buffer is available. Modify the current selection.

    var selRange: dict<any> = lspserver.selection.selRange
    var idx: number = lspserver.selection.index

    # Locate the range in the LSP reply for the current selection
    selRange = GetSelRangeAtLevel(selRange, lspserver.selection.index)

    # If the current selection is present in the LSP reply, then modify the
    # selection
    if SelectionFromLSP(lspserver.selection.visual)
      if expand
	# expand the selection
        if selRange->has_key('parent')
          selRange = selRange.parent
          lspserver.selection.index = idx + 1
        endif
      else
	# shrink the selection
	if idx > 0
	  idx -= 1
          selRange = GetSelRangeAtLevel(lspserver.selection.selRange, idx)
	  lspserver.selection.index = idx
	endif
      endif

      lspserver.selection.visual = SelectText(bnr, selRange.range)
      return
    endif
  endif

  # Start a new selection
  lspserver.selectionRange(fname)
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
