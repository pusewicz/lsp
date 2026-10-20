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

# Apply the edit operations in a semantic tokens delta update message
# (SemanticTokensDelta) from the language server.
#
# The previous list of tokens are stored in the buffer-local
# LspSemanticTokensData variable.  After applying the edits in
# semTokens.edits, the new set of tokens are returned in semTokens.data.
def ApplySemanticTokenEdits(bnr: number, semTokens: dict<any>)
  if semTokens.edits->empty()
    return
  endif

  # Need to sort the edits and apply the them sequentially.
  semTokens.edits->sort((a: dict<any>, b: dict<any>) => a.start - b.start)

  # TODO: Remove this code
  # var d = bnr->getbufvar('LspSemanticTokensData', [])
  # for e in semTokens.edits
  #   var insertData = e->get('data', [])
  #   d = (e.start > 0 ? d[: e.start - 1] : []) + insertData +
  #     					d[e.start + e.deleteCount :]
  # endfor
  # semTokens.data = d

  var oldTokens = bnr->getbufvar('LspSemanticTokensData', [])
  var newTokens = []
  var idx = 0
  for e in semTokens.edits
    if e.start > 0
      newTokens->extend(oldTokens[idx : e.start - 1])
    endif
    newTokens->extend(e->get('data', []))
    idx = e.start + e.deleteCount
  endfor
  newTokens->extend(oldTokens[idx : ])
  semTokens.data = newTokens
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
# tokens on a line are converted to byte indexes with that line only.
def ProcessSemanticTokens(lspserver: dict<any>, bnr: number, tokens: list<number>): dict<list<list<number>>>
  var props: dict<list<list<number>>> = {}
  var prevTokenLine = 0
  var lnum = 1
  var charIdx = 0

  var lspserverTokenTypes: list<string> =
					lspserver.semanticTokensLegend.tokenTypes
  var tokenTypesLen = lspserverTokenTypes->len()
  var posEncoding: number = lspserver.posEncoding

  :silent! bnr->bufload()
  var lines: list<string> = bnr->getbufline(1, '$')
  var linesLen = lines->len()

  var text = ''
  var nChars = 0
  var encodedLen = 0

  # Each semantic token uses 5 items in the tokens List
  var i = 0
  var tokensLen = tokens->len()
  while i + 4 < tokensLen
    # tokenLine is relative to the previous token line number
    lnum += tokens[i]
    if prevTokenLine != lnum
      # this token is on a different line from the previous token
      charIdx = 0
      prevTokenLine = lnum
      if lnum <= linesLen
	text = lines[lnum - 1]
	nChars = text->strchars()
	encodedLen = offset.EncodedLineLen(lspserver, text)
      endif
    endif
    charIdx += tokens[i + 1]
    var length = tokens[i + 2]
    var tokenType = tokens[i + 3]
    i += 5

    if tokenType < 0 || tokenType >= tokenTypesLen || lnum > linesLen
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

def ClearSemanticHighlightProps(bnr: number)
  prop_remove({types: TokenPropTypes, bufnr: bnr, all: true})
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
enddef

# Stop the pending semantic highlight update for buffer "bnr" and drop its
# cached semantic tokens.  Called when the buffer is detached from the
# language server.
export def BufferDeInit(bnr: number)
  StopSemanticHighlightTimer(bnr)
  SemanticHighlightCleanup(bnr)
  if exists('#LspSemanticRefresh')
    autocmd_delete([{bufnr: bnr, group: 'LspSemanticRefresh'}])
  endif
enddef

# Parse the semantic highlight reply from the language server and update the
# text properties.  Without a result ("semTokens" is null), as when the
# request was cancelled or the content was modified, the semantic highlighting
# is left as it is.
# Result: SemanticTokens | SemanticTokensDelta | null
export def UpdateTokens(lspserver: dict<any>, semTokens: any,
                        updateError: dict<any>, bnr: number,
                        requestTick: number)
  # Handle semantic tokens error
  if !updateError->empty()
    lspserver.traceLog($'Semantic tokens update failed: {updateError.message}')
    return
  endif

  # Validate buffer hasn't changed since request
  if getbufvar(bnr, 'changedtick') != requestTick
    # Clear the data as our local copy will be out of sync
    SemanticHighlightCleanup(bnr)
    ClearSemanticHighlightProps(bnr)
    return
  endif

  if semTokens->type() != v:t_dict
    return
  endif

  if semTokens->has_key('edits')
    # Delta semantic update.  Need to sort the edits and apply them
    # sequentially.
    ApplySemanticTokenEdits(bnr, semTokens)
  endif

  # Cache the semantic tokens in a buffer-local variable, it will be used
  # later for a delta update.
  setbufvar(bnr, 'LspSemanticResultId', semTokens->get('resultId', ''))
  if !semTokens->has_key('data')
    return
  endif
  setbufvar(bnr, 'LspSemanticTokensData', semTokens.data)

  var props: dict<list<list<number>>>
  props = ProcessSemanticTokens(lspserver, bnr, semTokens.data)

  # First clear all the previous text properties
  ClearSemanticHighlightProps(bnr)

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

# Initialize the semantic highlighting for the buffer 'bnr'
export def BufferInit(lspserver: dict<any>, bnr: number)
  if !opt.lspOptions.semanticHighlight || !lspserver.isSemanticTokensProvider
    # no support for semantic highlighting
    return
  endif

  # Highlight all the semantic tokens
  LspUpdateSemanticHighlight(bnr)

  # buffer-local autocmds for semantic highlighting
  var acmds: list<dict<any>> = []

  acmds->add({bufnr: bnr,
	      event: 'TextChanged',
	      group: 'LSPBufferAutocmds',
	      replace: true,
	      cmd: $'LspUpdateSemanticHighlight({bnr})'})

  autocmd_add(acmds)
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
