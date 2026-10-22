vim9script

# Functions for linked editing (textDocument/linkedEditingRange).  When the
# cursor is in a range of text that the language server links to other ranges,
# e.g. the name of an HTML tag and the name of its closing tag, the ranges are
# marked with text properties, and a change to the text of one of them is
# made to the others too.  Opt-in via the 'linkedEditing' option.
#
# The text properties move with the text and grow with the text typed at
# either end of a range, so they tell where the ranges are after a change.
# The other ranges are changed with ":substitute", which moves the other text
# properties in the line along, unlike setline(), which removes them.

import './options.vim' as opt
import './buffer.vim' as buf
import './util.vim'
import './jsregexp.vim'

# The text property type and the highlight group of the linked ranges
const PROP_TYPE = 'LspLinkedEditingRange'

# The Vim regexp that the text of the linked ranges must match when the
# language server gives no word pattern: no white space and none of the
# characters around an HTML or XML tag name
const DEFAULT_WORD_REGEXP = '\C\v[^[:space:]<>/=''"`]+'

# The text that RangesReplace() puts in the linked ranges, for the
# ":substitute" command, in which the text cannot have the separator
var replacement: string

# The linked ranges in each buffer, by buffer number:
#   count: the number of ranges
#   text: the text of the ranges since they were last made the same
#   regexp: the Vim regexp that their text must match
var linkedRanges: dict<dict<any>> = {}

# Define the highlight group and the text property type of the linked ranges.
export def InitOnce()
  hlset([{name: PROP_TYPE, default: true, linksto: 'MatchParen'}])
  if prop_type_get(PROP_TYPE)->empty()
    prop_type_add(PROP_TYPE, {highlight: PROP_TYPE, start_incl: true,
			      end_incl: true})
  endif
enddef

# Forget the linked ranges in buffer "bnr".
def RangesClear(bnr: number)
  if !linkedRanges->has_key(bnr)
    return
  endif
  linkedRanges->remove(bnr)
  if bnr->bufloaded()
    prop_remove({type: PROP_TYPE, bufnr: bnr, all: true})
  endif
enddef

# Link the ranges "ranges" (LSP Ranges, decoded) in the current buffer "bnr",
# whose text must match the JavaScript regular expression "wordPattern", or
# a default one when it is empty.  The ranges are linked only when there are
# at least two, each in one line, with the same text, not overlapping, and
# the cursor is in one of them.
export def RangesSet(bnr: number, ranges: list<dict<any>>, wordPattern: string)
  RangesClear(bnr)
  if !opt.lspOptions.linkedEditing || ranges->len() < 2 || bnr != bufnr()
    return
  endif

  # The line, the column and the length in bytes of each range
  var spans: list<list<number>> = []
  var text: string = null_string
  for range in ranges
    if range.start.line != range.end.line || range.start.line >= line('$')
      return
    endif
    var lnum = range.start.line + 1
    var startIdx = util.GetLineByteFromPos(bnr, range.start)
    var endIdx = util.GetLineByteFromPos(bnr, range.end)
    var rangeText = getline(lnum)->strpart(startIdx, endIdx - startIdx)
    if endIdx < startIdx || (text != null_string && rangeText !=# text)
      return
    endif
    text = rangeText
    spans->add([lnum, startIdx + 1, endIdx - startIdx])
  endfor

  spans->sort((a, b) => a[0] != b[0] ? a[0] - b[0] : a[1] - b[1])
  for k in range(1, spans->len() - 1)
    if spans[k][0] == spans[k - 1][0]
	&& spans[k][1] < spans[k - 1][1] + spans[k - 1][2]
      return
    endif
  endfor
  var [curLnum, curCol] = [line('.'), col('.')]
  if spans->indexof((_, s) => s[0] == curLnum && s[1] <= curCol
					      && curCol <= s[1] + s[2]) == -1
    return
  endif

  var regexp: any = wordPattern->empty() ? v:none : jsregexp.ToVim(wordPattern)
  for [lnum, col, length] in spans
    prop_add(lnum, col, {type: PROP_TYPE, length: length, bufnr: bnr})
  endfor
  linkedRanges[bnr] = {
    count: spans->len(),
    text: text,
    regexp: regexp->type() == v:t_none ? DEFAULT_WORD_REGEXP : regexp
  }
enddef

# Returns true when the cursor is in one of the linked ranges of the current
# buffer "bnr", or at the end of one.
def CursorInRange(bnr: number): bool
  if !linkedRanges->has_key(bnr)
    return false
  endif
  var col = col('.')
  return prop_list(line('.'), {bufnr: bnr, types: [PROP_TYPE]})
    ->indexof((_, p) => p.start && p.end && p.col <= col
				     && col <= p.col + p.length) != -1
enddef

# Handle a cursor move in buffer "bnr".  When the cursor left the linked
# ranges, they are no longer linked, and the language server is asked for the
# ranges linked at the cursor.
def OnCursorMoved(bnr: number)
  if !opt.lspOptions.linkedEditing
    RangesClear(bnr)
    return
  endif
  if bnr != bufnr() || CursorInRange(bnr)
    return
  endif

  RangesClear(bnr)
  var lspserver: dict<any> = buf.BufLspServerGet(bnr, 'linkedEditingRange')
  if !lspserver->empty() && lspserver.running
    lspserver.linkedEditingRangesUpdate()
  endif
enddef

# Replace the text "oldText" of the linked ranges "targets" (from prop_list(),
# in the current buffer) with "newText".  The cursor stays at the same text.
def RangesReplace(targets: list<dict<any>>, oldText: string, newText: string)
  var view = winsaveview()
  if mode() !~# '^[iR]'
    # Undo the change in the other ranges with the one made in Normal mode
    try
      :undojoin
    catch /^Vim\%((\a\+)\)\=:E790:/
      # The change was an undo
    endtry
  endif

  replacement = newText
  var newLen = newText->len()
  var widthDelta = newText->strdisplaywidth() - oldText->strdisplaywidth()
  # The ranges at the end first, so that the columns of the others are kept
  for p in targets->copy()->reverse()
    var regexp = $'\%{p.col}c'
    if p.length > 0
      regexp ..= $'.*\%{p.col + p.length}c'
    endif
    exe $'keeppatterns keepjumps silent :{p.lnum}substitute/\m{regexp}'
	.. '/\=replacement/e'
    if p.lnum == view.lnum && p.col <= view.col
      view.col += newLen - p.length
      if view.curswant != v:maxcol
	view.curswant += widthDelta
      endif
    endif
  endfor
  winrestview(view)
enddef

# Handle a text change in buffer "bnr": make the change to the text of one of
# the linked ranges to the other ranges too.  When the change leaves a text
# that doesn't match the word pattern, or the ranges were changed some other
# way, they are no longer linked.  While the popup menu is shown ("inPopup"),
# the ranges are changed after it is closed when one of them is before the
# cursor in the cursor line, as the change would move the completed text.
def RangesSync(bnr: number, inPopup: bool)
  if !linkedRanges->has_key(bnr) || bnr != bufnr()
    return
  endif
  if !opt.lspOptions.linkedEditing
    RangesClear(bnr)
    return
  endif

  var linked = linkedRanges[bnr]
  var props = prop_list(1, {bufnr: bnr, end_lnum: -1, types: [PROP_TYPE]})
  if props->len() != linked.count
      || props->indexof((_, p) => !p.start || !p.end) != -1
    RangesClear(bnr)
    return
  endif

  var texts = props->mapnew((_, p) => getline(p.lnum)->strpart(p.col - 1,
								p.length))
  if texts->indexof((_, t) => t !=# texts[0]) == -1
    # Changed all the same way, e.g. by an undo
    linked.text = texts[0]
    return
  endif
  var changed = range(texts->len())->filter((_, k) => texts[k] !=# linked.text)
  var newText = texts[changed[0]]
  if changed->len() != 1 || newText->matchstr(linked.regexp) !=# newText
    RangesClear(bnr)
    return
  endif

  var targets = props->copy()
  targets->remove(changed[0])
  if inPopup
      && targets->indexof((_, p) => p.lnum == line('.')
				    && p.col < col('.')) != -1
    return
  endif
  RangesReplace(targets, linked.text, newText)
  linked.text = newText
enddef

# Do buffer-local initialization for linked editing.
export def BufferInit(lspserver: dict<any>, bnr: number)
  if !lspserver.isLinkedEditingRangeProvider
      || !lspserver.featureEnabled('linkedEditingRange')
    return
  endif

  var acmds: list<dict<any>> = [
    {event: 'CursorMoved', cmd: $'OnCursorMoved({bnr})'},
    {event: 'CursorMovedI', cmd: $'OnCursorMoved({bnr})'},
    {event: 'TextChanged', cmd: $'RangesSync({bnr}, false)'},
    {event: 'TextChangedI', cmd: $'RangesSync({bnr}, false)'},
    {event: 'TextChangedP', cmd: $'RangesSync({bnr}, true)'},
  ]
  autocmd_add(acmds->map((_, acmd) => acmd->extend({bufnr: bnr,
						    replace: true,
						    group: 'LspLinkedEditing'})))
enddef

# Forget the linked ranges of buffer "bnr" and remove its linked editing
# autocmds.
export def BufferDeInit(bnr: number)
  RangesClear(bnr)
  if exists('#LspLinkedEditing')
    autocmd_delete([{bufnr: bnr, group: 'LspLinkedEditing'}])
  endif
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
