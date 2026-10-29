vim9script

# LSP semantic highlighting functions

import './offset.vim'
import './options.vim' as opt
import './buffer.vim' as buf

# Map token type names to higlight group/text property type names
var TokenTypeMap: dict<string> = {
  'namespace': 'LspSemanticNamespace',
  'type': 'LspSemanticType',
  'class': 'LspSemanticClass',
  'enum': 'LspSemanticEnum',
  'interface': 'LspSemanticInterface',
  'struct': 'LspSemanticStruct',
  'typeParameter': 'LspSemanticTypeParameter',
  'parameter': 'LspSemanticParameter',
  'variable': 'LspSemanticVariable',
  'property': 'LspSemanticProperty',
  'enumMember': 'LspSemanticEnumMember',
  'event': 'LspSemanticEvent',
  'function': 'LspSemanticFunction',
  'method': 'LspSemanticMethod',
  'macro': 'LspSemanticMacro',
  'keyword': 'LspSemanticKeyword',
  'modifier': 'LspSemanticModifier',
  'comment': 'LspSemanticComment',
  'string': 'LspSemanticString',
  'number': 'LspSemanticNumber',
  'regexp': 'LspSemanticRegexp',
  'operator': 'LspSemanticOperator',
  'decorator': 'LspSemanticDecorator'
}

# Cache text property type names to avoid rebuilding this list on each update.
var TokenPropTypes: list<string> = TokenTypeMap->values()

export def InitOnce()
  # Define the default semantic token type highlight groups
  hlset([
    {name: 'LspSemanticNamespace', default: true, linksto: 'Type'},
    {name: 'LspSemanticType', default: true, linksto: 'Type'},
    {name: 'LspSemanticClass', default: true, linksto: 'Type'},
    {name: 'LspSemanticEnum', default: true, linksto: 'Type'},
    {name: 'LspSemanticInterface', default: true, linksto: 'TypeDef'},
    {name: 'LspSemanticStruct', default: true, linksto: 'Type'},
    {name: 'LspSemanticTypeParameter', default: true, linksto: 'Type'},
    {name: 'LspSemanticParameter', default: true, linksto: 'Identifier'},
    {name: 'LspSemanticVariable', default: true, linksto: 'Identifier'},
    {name: 'LspSemanticProperty', default: true, linksto: 'Identifier'},
    {name: 'LspSemanticEnumMember', default: true, linksto: 'Constant'},
    {name: 'LspSemanticEvent', default: true, linksto: 'Identifier'},
    {name: 'LspSemanticFunction', default: true, linksto: 'Function'},
    {name: 'LspSemanticMethod', default: true, linksto: 'Function'},
    {name: 'LspSemanticMacro', default: true, linksto: 'Macro'},
    {name: 'LspSemanticKeyword', default: true, linksto: 'Keyword'},
    {name: 'LspSemanticModifier', default: true, linksto: 'Type'},
    {name: 'LspSemanticComment', default: true, linksto: 'Comment'},
    {name: 'LspSemanticString', default: true, linksto: 'String'},
    {name: 'LspSemanticNumber', default: true, linksto: 'Number'},
    {name: 'LspSemanticRegexp', default: true, linksto: 'String'},
    {name: 'LspSemanticOperator', default: true, linksto: 'Operator'},
    {name: 'LspSemanticDecorator', default: true, linksto: 'Macro'}
  ])

  for hlName in TokenTypeMap->values()
    prop_type_add(hlName, {highlight: hlName, combine: true})
  endfor
enddef

# Return the lines of the tokens at the indexes "indexes" in "tokens", as a
# Dict from the index to the line, in one pass over the tokens.  An index that
# is not the start of a token in "tokens" is left out.
def TokenLines(tokens: list<number>, indexes: list<number>): dict<number>
  var tokensLen = tokens->len()
  var lineOf: dict<number> = {}
  var lnum = 1
  var i = 0
  for idx in indexes->copy()->filter((_, v) => v >= 0 && v % 5 == 0
					&& v + 4 < tokensLen)->sort('n')->uniq()
    while i <= idx
      lnum += tokens[i]
      i += 5
    endwhile
    lineOf[idx] = lnum
  endfor
  return lineOf
enddef

# Map the line "lnum" of the buffer when its text properties were added to
# the line it is now, after the changes "changed" ([first, last, added] of
# the lines that changed and the number of lines added, empty when nothing
# changed, see BufferChanged()).  A line in the changed lines maps to "first"
# when "toFirst" is true and to "last" otherwise.
def MapOldLine(lnum: number, changed: list<number>, toFirst: bool): number
  if changed->empty() || lnum < changed[0]
    return lnum
  endif
  if lnum > changed[1] - changed[2]
    return lnum + changed[2]
  endif
  return toFirst ? changed[0] : changed[1]
enddef

# Return true when the text properties of the tokens from the line "first" to
# the line "last" when they were added, which the edits of a delta reply moved
# by "shift" lines, are still where the tokens are: as the changes "changed"
# (see MapOldLine()) moved them with their text, apart from the changed
# lines, which are updated anyway.
def TokensStayed(first: number, last: number, shift: number,
		 changed: list<number>): bool
  if changed->empty()
    return shift == 0
  endif
  return (first >= changed[0] || shift == 0)
    && (last <= changed[1] - changed[2] || shift == changed[2])
enddef

# Return the lines that the tokens from the line "first" to the line "last"
# when the text properties were added are on now, after an edit moved them by
# "shift" lines, for those of them in the lines that the changes "changed"
# replaced (see MapOldLine()), as [first, last], or an empty List.  Their old
# text properties are in the changed lines, which are updated anyway, but the
# tokens can be outside them.
def TokensInChangedLines(first: number, last: number, shift: number,
			 changed: list<number>): list<number>
  if changed->empty()
    return []
  endif
  var from = max([first, changed[0]])
  var to = min([last, changed[1] - changed[2]])
  return from > to ? [] : [from + shift, to + shift]
enddef

# Apply the edit operations in a semantic tokens delta update message
# (SemanticTokensDelta) from the language server.
#
# The previous list of tokens are stored in the buffer-local
# LspSemanticTokensData variable.  After applying the edits in
# semTokens.edits, the new set of tokens are returned in semTokens.data.
#
# With "wantRanges", returns the [first, last] ranges of the buffer lines
# whose semantic highlighting the edits changed, when the text properties
# matched the previous tokens before the changes "changed" (see MapOldLine())
# and the buffer now has "lastLine" lines.  These are the lines from the token
# before an edit to the token after it, where it removed and added tokens,
# before and after the edit.  The tokens between two edits are the same, and
# their text properties moved with their text, unless the edit before them
# moved them to other lines than the changes did.  Then their lines before and
# after the edit are added too.
def ApplySemanticTokenEdits(bnr: number, semTokens: dict<any>,
			    wantRanges: bool, changed: list<number>,
			    lastLine: number): list<list<number>>
  var tokens: list<number> = bnr->getbufvar('LspSemanticTokensData', [])
  var edits: list<dict<any>> = semTokens.edits
  # Need to sort the edits and apply the them sequentially.
  edits->sort((a: dict<any>, b: dict<any>) => a.start - b.start)
  # Keep the edits in the tokens
  var oldLen = tokens->len()
  for e in edits
    e.start = min([max([e.start, 0]), oldLen])
    e.deleteCount = min([max([e.deleteCount, 0]), oldLen - e.start])
  endfor

  # The indexes of the tokens before and after each edit, before and after
  # the edits; a token is 5 numbers.
  var oldBefore: list<number> = edits->mapnew((_, e) => e.start - e.start % 5 - 5)
  var oldAfter: list<number> = edits->mapnew((_, e) =>
	  e.start + e.deleteCount + (5 - (e.start + e.deleteCount) % 5) % 5)
  var oldLines: dict<number> = {}
  if wantRanges
    oldLines = TokenLines(tokens, oldBefore + oldAfter)
  endif

  var newBefore: list<number> = []
  var newAfter: list<number> = []
  # Whether the tokens after each edit are still the same tokens: an edit that
  # inserts or deletes a part of a token changes the tokens after it.
  var sameTokensAfter: list<bool> = []
  var shift = 0
  for e in edits
    var start = e.start + shift
    var end = start + e->get('data', [])->len()
    newBefore->add(start - start % 5 - 5)
    newAfter->add(end + (5 - end % 5) % 5)
    shift += e->get('data', [])->len() - e.deleteCount
    sameTokensAfter->add(shift % 5 == 0)
  endfor

  # Apply the edits to the cached tokens in place, from the last one, so that
  # the indexes of the others stay valid.  Copying the tokens would cost as
  # much as the edits for a one-line change.
  for e in edits->copy()->reverse()
    if e.deleteCount > 0
      tokens->remove(e.start, e.start + e.deleteCount - 1)
    endif
    var data: list<number> = e->get('data', [])
    if !data->empty()
      tokens->extend(data, e.start)
    endif
  endfor
  semTokens.data = tokens
  if !wantRanges
    return []
  endif

  var newLines = TokenLines(tokens, newBefore + newAfter)

  # The last line of the buffer when the text properties were added; the
  # tokens after the last edit are up to there.  Finding the line of the last
  # token would take going through all the tokens.
  var oldLastLine = lastLine - (changed->empty() ? 0 : changed[2])

  var ranges: list<list<number>> = []
  var nEdits = edits->len()
  # The tokens before the first edit, or all of them without an edit, did not
  # move.
  var segOldLast = nEdits > 0 ? oldLines->get(oldBefore[0], 0) : oldLastLine
  var segNewLast = nEdits > 0 ? newLines->get(newBefore[0], 0) : lastLine
  if segOldLast > 0
    if !TokensStayed(1, segOldLast, 0, changed)
      ranges->add([1, max([segNewLast,
			    MapOldLine(segOldLast, changed, false)])])
    endif
    var inChanged = TokensInChangedLines(1, segOldLast, 0, changed)
    if !inChanged->empty()
      ranges->add(inChanged)
    endif
  endif

  for k in range(nEdits)
    var oldFirst = oldLines->get(oldBefore[k], 1)
    var newFirst = newLines->get(newBefore[k], 1)
    var oldEnd = oldLines->get(oldAfter[k], 0)
    var newEnd = newLines->get(newAfter[k], 0)
    ranges->add([newFirst, newEnd > 0 ? newEnd : lastLine])
    ranges->add([MapOldLine(oldFirst, changed, true),
		 oldEnd > 0 ? MapOldLine(oldEnd, changed, false) : lastLine])

    # The tokens up to the next edit or to the end
    if oldEnd == 0 || newEnd == 0
      continue
    endif
    var isLast = k == nEdits - 1
    if !isLast && oldAfter[k] > oldBefore[k + 1]
      continue
    endif
    segOldLast = isLast ? max([oldLastLine, oldEnd])
			: oldLines->get(oldBefore[k + 1], oldEnd)
    segNewLast = isLast ? max([lastLine, newEnd])
			: newLines->get(newBefore[k + 1], newEnd)
    if !sameTokensAfter[k]
	|| !TokensStayed(oldEnd, segOldLast, newEnd - oldEnd, changed)
      ranges->add([newEnd, segNewLast])
      ranges->add([MapOldLine(oldEnd, changed, true),
		   MapOldLine(segOldLast, changed, false)])
    endif
    var inChanged = TokensInChangedLines(oldEnd, segOldLast, newEnd - oldEnd,
					 changed)
    if !inChanged->empty()
      ranges->add(inChanged)
    endif
  endfor

  if !changed->empty()
    ranges->add(changed[0 : 1])
  endif
  return ranges->mapnew((_, r) => {
    var first = min([max([r[0], 1]), lastLine])
    return [first, min([max([r[1], first]), lastLine])]
  })
enddef

# Return the line ranges "ranges", each [first, last], sorted and with the
# ranges that overlap or touch merged.
def MergeLineRanges(ranges: list<list<number>>): list<list<number>>
  var merged: list<list<number>> = []
  for [first, last] in ranges->copy()->sort((a, b) => a[0] - b[0])
    if !merged->empty() && first <= merged[-1][1] + 1
      merged[-1][1] = max([merged[-1][1], last])
    else
      merged->add([first, last])
    endif
  endfor
  return merged
enddef

# Return the byte index in "text" of the character at the offset "col" of the
# position encoding "posEncoding".  "nChars" is the number of characters in
# "text" and "encodedLen" its length in the position encoding.  An offset past
# the end of "text" is at its end.
def TokenByteIdx(text: string, posEncoding: number, nChars: number,
		 encodedLen: number, col: number): number
  if col <= 0
    return 0
  endif
  var charIdx = col
  if col >= encodedLen
    charIdx = nChars
  elseif posEncoding == 16
    charIdx = text->charidx(col, true, true)
  elseif posEncoding == 8
    charIdx = text->charidx(col, true)
  endif
  var byteIdx = text->byteidxcomp(charIdx)
  return byteIdx == -1 ? text->strlen() : byteIdx
enddef

# Process a list of semantic tokens and return the corresponding text
# properties for highlighting.  The buffer is read once, and the offsets of the
# tokens on a line are converted to byte indexes with that line only.  With
# "ranges", sorted [first, last] line ranges, only the tokens on those lines
# are processed and only those lines are read.
def ProcessSemanticTokens(lspserver: dict<any>, bnr: number,
			  tokens: list<number>,
			  ranges: list<list<number>> = []): dict<list<list<number>>>
  var props: dict<list<list<number>>> = {}
  var prevTokenLine = 0
  var lnum = 1
  var charIdx = 0

  var lspserverTokenTypes: list<string> =
					lspserver.semanticTokensLegend.tokenTypes
  var tokenTypesLen = lspserverTokenTypes->len()
  var posEncoding: number = lspserver.posEncoding

  :silent! bnr->bufload()
  var allLines: bool = ranges->empty()
  var lines: list<string> = allLines ? bnr->getbufline(1, '$') : []
  var linesLen = allLines ? lines->len() : bnr->getbufinfo()[0].linecount
  var rangeIdx = 0
  var inRange: bool = allLines

  var text = ''
  var nChars = 0
  var encodedLen = 0

  # Each semantic token uses 5 items in the tokens List
  var i = 0
  var tokensLen = tokens->len()
  if !allLines
    # Skip the tokens on the lines before the first range quickly.  The next
    # token is on another line than the skipped ones.
    while i + 4 < tokensLen && lnum + tokens[i] < ranges[0][0]
      lnum += tokens[i]
      i += 5
    endwhile
  endif
  while i + 4 < tokensLen
    # tokenLine is relative to the previous token line number
    lnum += tokens[i]
    if prevTokenLine != lnum
      # this token is on a different line from the previous token
      charIdx = 0
      prevTokenLine = lnum
      if !allLines
	while rangeIdx < ranges->len() && lnum > ranges[rangeIdx][1]
	  rangeIdx += 1
	endwhile
	if rangeIdx >= ranges->len()
	  # No tokens are needed after the last range
	  break
	endif
	inRange = lnum >= ranges[rangeIdx][0]
      endif
      if inRange && lnum <= linesLen
	text = allLines ? lines[lnum - 1] : bnr->getbufoneline(lnum)
	nChars = text->strchars()
	encodedLen = offset.EncodedLineLen(lspserver, text)
      endif
    endif
    charIdx += tokens[i + 1]
    var length = tokens[i + 2]
    var tokenType = tokens[i + 3]
    i += 5

    if !inRange || tokenType < 0 || tokenType >= tokenTypesLen
	|| lnum > linesLen
      continue
    endif

    var typeStr = lspserverTokenTypes[tokenType]
    if !props->has_key(typeStr)
      props[typeStr] = []
    endif

    var startByteIdx = TokenByteIdx(text, posEncoding, nChars, encodedLen, charIdx)
    var endByteIdx = TokenByteIdx(text, posEncoding, nChars, encodedLen, charIdx + length)
    props[typeStr]->add([lnum, startByteIdx + 1, lnum, endByteIdx + 1])
  endwhile

  return props
enddef

# Remove the semantic highlighting of buffer "bnr": of all of it, or of the
# lines in "ranges", each [first, last].
def ClearSemanticHighlightProps(bnr: number, ranges: list<list<number>> = [])
  if ranges->empty()
    prop_remove({types: TokenPropTypes, bufnr: bnr, all: true})
    return
  endif
  for [first, last] in ranges
    prop_remove({types: TokenPropTypes, bufnr: bnr, all: true}, first, last)
  endfor
enddef

# Listener callback for buffer "bnr": add the lines that a change replaced to
# the lines that changed since the text properties were added
# (b:LspSemanticChangedLines: [first, last, added], with the number of lines
# added, or empty).  A change can drop the text properties of a line, as when
# its text is replaced by a filter, and the semantic tokens of an unchanged
# text are not sent again in a delta reply.  The lines before "first" and
# after "last" did not change; those after "last" moved by "added" lines.
def BufferChanged(bnr: number, _start: number, _end: number, _added: number,
		  changes: list<dict<any>>)
  var changed: list<number> = bnr->getbufvar('LspSemanticChangedLines', [])
  # Each change in the order they were made, as the lines of a change are
  # those of the buffer after the changes before it
  for change in changes
    # The lines from "lnum" to "end" - 1 are now from "lnum" to
    # "end" - 1 + "added"; a deletion joins its neighbours at "lnum".
    var first: number = change.lnum
    var last: number = max([first, change.end - 1 + change.added])
    var totalAdded: number = change.added
    if !changed->empty()
      first = min([first, changed[0]])
      var prevLast = changed[1] >= change.end ? changed[1] + change.added
					      : changed[1]
      last = max([last, prevLast])
      totalAdded += changed[2]
    endif
    changed = [first, last, totalAdded]
  endfor
  setbufvar(bnr, 'LspSemanticChangedLines', changed)
enddef

def AddBufferListener(bnr: number)
  if bnr->getbufvar('LspSemanticListener', 0) == 0
    setbufvar(bnr, 'LspSemanticListener',
	      listener_add(BufferChanged, bnr))
  endif
  setbufvar(bnr, 'LspSemanticChangedLines', [])
enddef

def RemoveBufferListener(bnr: number)
  var listenerId: number = bnr->getbufvar('LspSemanticListener', 0)
  if listenerId != 0
    listener_remove(listenerId)
    setbufvar(bnr, 'LspSemanticListener', 0)
  endif
  setbufvar(bnr, 'LspSemanticChangedLines', [])
enddef

def SemanticHighlightTimerCb(lspserver: dict<any>, bnr: number, _: number)
  if !bufexists(bnr)
    return
  endif
  setbufvar(bnr, 'LspSemanticTimer', 0)
  lspserver.semanticHighlightUpdate(bnr)
enddef

def StopSemanticHighlightTimer(bnr: number)
  var timerId = getbufvar(bnr, 'LspSemanticTimer', 0)
  if timerId > 0
    timer_stop(timerId)
    setbufvar(bnr, 'LspSemanticTimer', 0)
  endif
enddef

def SemanticHighlightCleanup(bnr: number)
  setbufvar(bnr, 'LspSemanticTokensData', [])
  setbufvar(bnr, 'LspSemanticResultId', '')
  setbufvar(bnr, 'LspSemanticTokensShown', false)
enddef

# Stop the pending semantic highlight update for buffer "bnr" and drop its
# cached semantic tokens.  Called when the buffer is detached from the
# language server.
export def BufferDeInit(bnr: number)
  StopSemanticHighlightTimer(bnr)
  SemanticHighlightCleanup(bnr)
  RemoveBufferListener(bnr)
  if exists('#LspSemanticRefresh')
    autocmd_delete([{bufnr: bnr, group: 'LspSemanticRefresh'}])
  endif
enddef

# Parse the semantic highlight reply from the language server and update the
# text properties.  Without a result ("semTokens" is null), as when the
# request was cancelled or the content was modified, the semantic highlighting
# is left as it is.  A reply about an older version of the buffer is only
# cached, as the base of the next delta request, and the current text
# properties are kept until the reply to that request.
#
# A delta reply applied to the tokens that are shown only updates the lines
# that its edits change and the lines that the buffer changes replaced since
# the last update (see BufferChanged()); the text properties of the other
# lines moved with their text and still match the tokens.
# Result: SemanticTokens | SemanticTokensDelta | null
export def UpdateTokens(lspserver: dict<any>, semTokens: any,
                        updateError: dict<any>, bnr: number,
                        requestTick: number)
  # Handle semantic tokens error
  if !updateError->empty()
    lspserver.traceLog($'Semantic tokens update failed: {updateError.message}')
    return
  endif

  if semTokens->type() != v:t_dict
    return
  endif

  var isDelta = semTokens->has_key('edits')
  if isDelta && semTokens.edits->type() != v:t_list
    return
  endif

  # Whether the text properties match the cached tokens, which the edits of
  # a delta reply apply to, apart from the lines that changed since, which
  # the listener knows.  Only then can the lines that a delta reply changes
  # be updated alone.
  var wasShown: bool = bnr->getbufvar('LspSemanticTokensShown', false)
  setbufvar(bnr, 'LspSemanticTokensShown', false)
  var tracked = bnr->getbufvar('LspSemanticListener', 0) != 0
  var partial = isDelta && wasShown && tracked
		&& getbufvar(bnr, 'changedtick') == requestTick
  var changedLines: list<number> = []
  if tracked
    bnr->listener_flush()
    changedLines = bnr->getbufvar('LspSemanticChangedLines', [])
  endif

  var ranges: list<list<number>> = []
  if isDelta
    # Delta semantic update.  Need to sort the edits and apply them
    # sequentially.
    ranges = ApplySemanticTokenEdits(bnr, semTokens, partial, changedLines,
				     partial ? bnr->getbufinfo()[0].linecount
					     : 0)
  endif

  # Cache the semantic tokens in a buffer-local variable, it will be used
  # later for a delta update.
  setbufvar(bnr, 'LspSemanticResultId', semTokens->get('resultId', ''))
  if !semTokens->has_key('data')
    return
  endif
  setbufvar(bnr, 'LspSemanticTokensData', semTokens.data)

  # The buffer changed after the request: the tokens are about text that is
  # gone.  The text properties moved with the text, so they are still closer
  # to it than these tokens.
  if getbufvar(bnr, 'changedtick') != requestTick
    return
  endif

  setbufvar(bnr, 'LspSemanticChangedLines', [])
  setbufvar(bnr, 'LspSemanticTokensShown', true)

  if partial
    ranges = MergeLineRanges(ranges)
    if ranges->empty()
      return
    endif
  else
    ranges = []
  endif

  var props: dict<list<list<number>>>
  props = ProcessSemanticTokens(lspserver, bnr, semTokens.data, ranges)

  # First clear the previous text properties
  ClearSemanticHighlightProps(bnr, ranges)

  if props->empty()
    return
  endif

  # Apply the new text properties
  for [tokenType, tokenProps] in props->items()
    if TokenTypeMap->has_key(tokenType)
      prop_add_list({bufnr: bnr, type: TokenTypeMap[tokenType]}, tokenProps)
    endif
  endfor
enddef

# Update the semantic highlighting for buffer "bnr"
def LspUpdateSemanticHighlight(bnr: number)
  var lspserver: dict<any> = buf.BufLspServerGet(bnr, 'semanticTokens')
  if lspserver->empty()
    return
  endif

  # Cancel existing timer if any
  StopSemanticHighlightTimer(bnr)

  if !bufexists(bnr)
    return
  endif

  # Start new debounced timer
  var timerId = timer_start(opt.lspOptions.semanticHighlightDelay,
    function('SemanticHighlightTimerCb', [lspserver, bnr]))
  setbufvar(bnr, 'LspSemanticTimer', timerId)
enddef

# Refresh the semantic highlighting from "lspserver", which asked for it with a
# "workspace/semanticTokens/refresh" request: now in the buffers shown in a
# window, and in the other buffers when they are shown in one again.
export def Refresh(lspserver: dict<any>)
  if !opt.lspOptions.semanticHighlight
    return
  endif

  for bnr in lspserver.docBufnrs->values()
    var semanticServer: dict<any> = buf.BufLspServerGet(bnr, 'semanticTokens')
    if semanticServer->empty() || semanticServer.id != lspserver.id
      continue
    endif
    if bnr->win_findbuf()->empty()
      autocmd_add([{bufnr: bnr,
		    event: 'BufWinEnter',
		    group: 'LspSemanticRefresh',
		    once: true,
		    replace: true,
		    cmd: $'LspUpdateSemanticHighlight({bnr})'}])
    else
      LspUpdateSemanticHighlight(bnr)
    endif
  endfor
enddef

# Buffer "bnr" was reloaded: its text properties are gone, so update all of
# its semantic highlighting.
def BufferReloaded(bnr: number)
  setbufvar(bnr, 'LspSemanticTokensShown', false)
  LspUpdateSemanticHighlight(bnr)
enddef

# Initialize the semantic highlighting for the buffer 'bnr'
export def BufferInit(lspserver: dict<any>, bnr: number)
  if !opt.lspOptions.semanticHighlight || !lspserver.isSemanticTokensProvider
    # no support for semantic highlighting
    return
  endif

  # Highlight all the semantic tokens
  AddBufferListener(bnr)
  LspUpdateSemanticHighlight(bnr)

  # buffer-local autocmds for semantic highlighting
  var acmds: list<dict<any>> = []

  acmds->add({bufnr: bnr,
	      event: 'TextChanged',
	      group: 'LSPBufferAutocmds',
	      replace: true,
	      cmd: $'LspUpdateSemanticHighlight({bnr})'})
  # Reloading the buffer removes the text properties without calling the
  # listener, so the next reply updates all the lines.
  acmds->add({bufnr: bnr,
	      event: 'BufReadPost',
	      group: 'LSPBufferAutocmds',
	      replace: true,
	      cmd: $'BufferReloaded({bnr})'})

  autocmd_add(acmds)
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
