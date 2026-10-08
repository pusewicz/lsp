vim9script

# Functions related to handling LSP diagnostics.

import './options.vim' as opt
import './buffer.vim' as buf
import './util.vim'

# [bnr] = {
#   serverDiagnostics: {
#     lspServer1Id: {
#       push: [diag, diag, diag],
#       pull: [diag, diag, diag]
#     },
#     lspServer2Id: {
#       push: [diag, diag, diag],
#       pull: [diag, diag, diag]
#     }
#   },
#   serverDiagnosticsByLnum: {
#     lspServer1Id: { [startLnum]: [diag, diag diag] },
#     lspServer2Id: { [startLnum]: [diag, diag diag] },
#   },
#   serverMultiLineDiagnostics: {
#     lspServer1Id: [diags covering more than one line]->sort(),
#     lspServer2Id: [diags covering more than one line]->sort(),
#   },
#   sortedDiagnostics: [lspServer1.diags, ...lspServer2.diags]->sort()
# }
var diagsMap: dict<dict<any>> = {}

# The ALE linter names that diagnostics were sent to ALE under, for each
# buffer: [bnr] = [linterName, ...]
var aleLinterNames: dict<list<string>> = {}

# Initialize the signs and the text property type used for diagnostics.
export def InitOnce()
  # Signs and their highlight groups used for LSP diagnostics
  hlset([
    {name: 'LspDiagLine', default: true, linksto: 'NONE'},
    {name: 'LspDiagSignErrorText', default: true, linksto: 'ErrorMsg'},
    {name: 'LspDiagSignWarningText', default: true, linksto: 'Search'},
    {name: 'LspDiagSignInfoText', default: true, linksto: 'Pmenu'},
    {name: 'LspDiagSignHintText', default: true, linksto: 'Question'}
  ])
  DiagSignsDefine()

  # Diag inline highlight groups and text property types
  hlset([
    {name: 'LspDiagInlineError', default: true, linksto: 'SpellBad'},
    {name: 'LspDiagInlineWarning', default: true, linksto: 'SpellCap'},
    {name: 'LspDiagInlineInfo', default: true, linksto: 'SpellRare'},
    {name: 'LspDiagInlineHint', default: true, linksto: 'SpellLocal'}
  ])

  var override = &cursorline
      && &cursorlineopt =~ '\<line\>\|\<screenline\>\|\<both\>'

  prop_type_add('LspDiagInlineError',
		{highlight: 'LspDiagInlineError',
		 priority: 10,
		 override: override})
  prop_type_add('LspDiagInlineWarning',
		{highlight: 'LspDiagInlineWarning',
		 priority: 9,
		 override: override})
  prop_type_add('LspDiagInlineInfo',
		{highlight: 'LspDiagInlineInfo',
		 priority: 8,
		 override: override})
  prop_type_add('LspDiagInlineHint',
		{highlight: 'LspDiagInlineHint',
		 priority: 7,
		 override: override})

  # Diag virtual text highlight groups and text property types
  hlset([
    {name: 'LspDiagVirtualTextError', default: true, linksto: 'SpellBad'},
    {name: 'LspDiagVirtualTextWarning', default: true, linksto: 'SpellCap'},
    {name: 'LspDiagVirtualTextInfo', default: true, linksto: 'SpellRare'},
    {name: 'LspDiagVirtualTextHint', default: true, linksto: 'SpellLocal'},
  ])
  prop_type_add('LspDiagVirtualTextError',
		{highlight: 'LspDiagVirtualTextError', override: true})
  prop_type_add('LspDiagVirtualTextWarning',
		{highlight: 'LspDiagVirtualTextWarning', override: true})
  prop_type_add('LspDiagVirtualTextInfo',
		{highlight: 'LspDiagVirtualTextInfo', override: true})
  prop_type_add('LspDiagVirtualTextHint',
		{highlight: 'LspDiagVirtualTextHint', override: true})

  autocmd_add([{group: 'LspCmds',
	        event: 'User',
		pattern: 'LspOptionsChanged',
		cmd: 'LspDiagsOptionsChanged()'}])

  # ALE plugin support
  if opt.lspOptions.aleSupport
    opt.lspOptions.autoHighlightDiags = false
    autocmd_add([
      {
	group: 'LspAleCmds',
	event: 'User',
	pattern: 'ALEWantResults',
	cmd: 'AleHook(g:ale_want_results_buffer)'
      }
    ])
  endif

  appliedOptions = DisplayOptionsGet()
enddef

# Define the signs placed for diagnostics, using the sign texts set in the
# options.  Redefining a sign updates the signs already placed.
def DiagSignsDefine()
  sign_define([
    {
      name: 'LspDiagError',
      text: opt.lspOptions.diagSignErrorText,
      texthl: 'LspDiagSignErrorText',
      linehl: 'LspDiagLine'
    },
    {
      name: 'LspDiagWarning',
      text: opt.lspOptions.diagSignWarningText,
      texthl: 'LspDiagSignWarningText',
      linehl: 'LspDiagLine'
    },
    {
      name: 'LspDiagInfo',
      text: opt.lspOptions.diagSignInfoText,
      texthl: 'LspDiagSignInfoText',
      linehl: 'LspDiagLine'
    },
    {
      name: 'LspDiagHint',
      text: opt.lspOptions.diagSignHintText,
      texthl: 'LspDiagSignHintText',
      linehl: 'LspDiagLine'
    }
  ])
enddef

# Initialize the diagnostics features for the buffer 'bnr'
export def BufferInit(lspserver: dict<any>, bnr: number)
  BufferFeaturesSet(bnr)
enddef

# Remove the diagnostics features set up by BufferInit() from buffer "bnr",
# when it is detached from its language servers.
export def BufferDeInit(bnr: number)
  StatusLineDiagDisable(bnr)
enddef

# Set up the diagnostics balloon and the diagnostic message on the status line
# for buffer "bnr" as set in the options, and remove the ones that are
# disabled.
def BufferFeaturesSet(bnr: number)
  if opt.lspOptions.showDiagInBalloon
    :set ballooneval balloonevalterm
    setbufvar(bnr, '&balloonexpr', 'g:LspDiagExpr()')
  elseif bnr->getbufvar('&balloonexpr') == 'g:LspDiagExpr()'
    setbufvar(bnr, '&balloonexpr', '')
  endif

  if opt.lspOptions.showDiagOnStatusLine
    autocmd_add([{bufnr: bnr,
		  event: 'CursorMoved',
		  group: 'LspDiagStatusLine',
		  replace: true,
		  cmd: 'ShowCurrentDiagInStatusLine()'}])
  else
    StatusLineDiagDisable(bnr)
  endif
enddef

# Stop showing the diagnostic message on the status line for buffer "bnr".
def StatusLineDiagDisable(bnr: number)
  if exists('#LspDiagStatusLine')
    autocmd_delete([{bufnr: bnr, group: 'LspDiagStatusLine'}])
  endif
enddef

# Function to sort the diagnostics in ascending order based on the line and
# character offset
def DiagsSortFunc(a: dict<any>, b: dict<any>): number
  var a_start: dict<number> = a.range.start
  var b_start: dict<number> = b.range.start
  var linediff: number = a_start.line - b_start.line
  if linediff == 0
    return a_start.character - b_start.character
  endif
  return linediff
enddef

# Sort diagnostics ascending based on line and character offset
def SortDiags(diags: list<dict<any>>): list<dict<any>>
  return diags->sort(DiagsSortFunc)
enddef

# Return the last buffer line number covered by the range of "diag".  The end
# of an LSP range is exclusive, so a range ending at the first character of a
# later line doesn't cover that line.
def DiagLastLnum(diag: dict<any>): number
  var d_start: dict<number> = diag.range.start
  var d_end: dict<number> = diag.range.end
  if d_end.line <= d_start.line
    return d_start.line + 1
  endif
  return d_end.character == 0 ? d_end.line : d_end.line + 1
enddef

# Deduplicate diagnostics, if the same diagnostic is sent in
# both push and pull channels
def DeduplicateDiags(diags: list<dict<any>>): list<dict<any>>
  var result = []
  var seen = {}
  for d in diags
    var key = string([
      d.range.start.line,
      d.range.start.character,
      d->get('code', ''),
      d.message
    ])
    if !seen->has_key(key)
      seen[key] = true
      result->add(d)
    endif
  endfor

  return result
enddef

# Remove the diagnostics stored for buffer "bnr"
export def DiagRemoveFile(bnr: number)
  if diagsMap->has_key(bnr)
    diagsMap->remove(bnr)
  endif
  ClearAleDiags(bnr)
enddef

def DiagSevToSignName(severity: number): string
  var typeMap: list<string> = ['LspDiagError', 'LspDiagWarning',
						'LspDiagInfo', 'LspDiagHint']
  if severity < 1 || severity > 4
    return 'LspDiagHint'
  endif
  return typeMap[severity - 1]
enddef

def DiagSevToInlineHLName(severity: number): string
  var typeMap: list<string> = [
    'LspDiagInlineError',
    'LspDiagInlineWarning',
    'LspDiagInlineInfo',
    'LspDiagInlineHint'
  ]
  if severity < 1 || severity > 4
    return 'LspDiagInlineHint'
  endif
  return typeMap[severity - 1]
enddef

def DiagSevToVirtualTextHLName(severity: number): string
  var typeMap: list<string> = [
    'LspDiagVirtualTextError',
    'LspDiagVirtualTextWarning',
    'LspDiagVirtualTextInfo',
    'LspDiagVirtualTextHint'
  ]
  if severity < 1 || severity > 4
    return 'LspDiagVirtualTextHint'
  endif
  return typeMap[severity - 1]
enddef

def DiagSevToSymbolText(severity: number): string
  var lspOpts = opt.lspOptions
  var hintText = lspOpts.diagSignHintText
  var typeMap: list<string> = [
    lspOpts.diagSignErrorText,
    lspOpts.diagSignWarningText,
    lspOpts.diagSignInfoText,
    hintText
  ]
  if severity < 1 || severity > 4
    return hintText
  endif
  return typeMap[severity - 1]
enddef

# Remove signs and text properties for diagnostics in buffer
def RemoveDiagVisualsForBuffer(bnr: number, all: bool = false)
  var lspOpts = opt.lspOptions
  if lspOpts.showDiagWithSign || all
    # Remove all the existing diagnostic signs
    sign_unplace('LSPDiag', {buffer: bnr})
  endif

  if lspOpts.showDiagWithVirtualText || all
    # Remove all the existing virtual text
    prop_remove({type: 'LspDiagVirtualTextError', bufnr: bnr, all: true})
    prop_remove({type: 'LspDiagVirtualTextWarning', bufnr: bnr, all: true})
    prop_remove({type: 'LspDiagVirtualTextInfo', bufnr: bnr, all: true})
    prop_remove({type: 'LspDiagVirtualTextHint', bufnr: bnr, all: true})
  endif

  if lspOpts.highlightDiagInline || all
    # Remove all the existing virtual text
    prop_remove({type: 'LspDiagInlineError', bufnr: bnr, all: true})
    prop_remove({type: 'LspDiagInlineWarning', bufnr: bnr, all: true})
    prop_remove({type: 'LspDiagInlineInfo', bufnr: bnr, all: true})
    prop_remove({type: 'LspDiagInlineHint', bufnr: bnr, all: true})
  endif
enddef

# Return the most severe diagnostic on each line in "diags", keyed by line
# number.  Of equally severe diagnostics on a line, the first one in "diags"
# is returned; as "diags" is sorted by position, that is the leftmost one.
def MostSevereDiagByLine(diags: list<dict<any>>): dict<dict<any>>
  var diagByLnum: dict<dict<any>> = {}
  for diag in diags
    var lnum: number = diag.range.start.line + 1
    if !diagByLnum->has_key(lnum)
	|| diag->get('severity', 1) < diagByLnum[lnum]->get('severity', 1)
      diagByLnum[lnum] = diag
    endif
  endfor
  return diagByLnum
enddef

# Returns the screen column (0-based) of the first tab stop after column "col",
# for the 'tabstop' value "tabstop" and the 'vartabstop' values "vartabstop".
def NextTabStop(col: number, tabstop: number,
		vartabstop: list<number>): number
  if vartabstop->empty()
    return (col / tabstop + 1) * tabstop
  endif
  var stop = 0
  for width in vartabstop
    stop += width
    if stop > col
      return stop
    endif
  endfor
  var lastWidth = vartabstop[-1]
  return stop + ((col - stop) / lastWidth + 1) * lastWidth
enddef

# Returns the display width of the text before the character index "charIdx"
# in line "lnum" of buffer "bnr".  Tabs are expanded with the 'tabstop' and
# 'vartabstop' of "bnr": strdisplaywidth() uses those of the current buffer.
def LineTextWidth(bnr: number, lnum: number, charIdx: number): number
  if charIdx <= 0
    return 0
  endif
  var text: string = bnr->getbufline(lnum)->get(0, '')[ : charIdx - 1]
  var tabstop: number = bnr->getbufvar('&tabstop')
  var vartabstop: list<number> = bnr->getbufvar('&vartabstop', '')
    ->split(',')->mapnew((_, width) => width->str2nr())
  var parts: list<string> = text->split("\t", true)
  var width = 0
  for part in parts[ : -2]
    width = NextTabStop(width + part->strdisplaywidth(), tabstop, vartabstop)
  endfor
  return width + parts[-1]->strdisplaywidth()
enddef

# Refresh the placed diagnostics in buffer "bnr"
# This inline signs, inline props, and virtual text diagnostics
export def DiagsRefresh(bnr: number)
  var lspOpts = opt.lspOptions
  if !lspOpts.autoHighlightDiags
    return
  endif

  :silent! bnr->bufload()

  RemoveDiagVisualsForBuffer(bnr)

  if !diagsMap->has_key(bnr)
    return
  endif
  var bufferDiags = diagsMap[bnr]
  var diags: list<dict<any>> = bufferDiags.sortedDiagnostics
  if diags->empty()
    return
  endif

  # Initialize default/fallback properties for diagnostic virtual text:
  var diag_align: string = 'above'
  var diag_wrap: string = 'truncate'
  var diag_symbol: string = '┌─'
  var virtualTextAlign = lspOpts.diagVirtualTextAlign

  if virtualTextAlign == 'below'
    diag_align = 'below'
    diag_wrap = 'truncate'
    diag_symbol = '└─'
  elseif virtualTextAlign == 'after'
    diag_align = 'after'
    diag_wrap = 'wrap'
    diag_symbol = 'E>'
  endif

  if lspOpts.diagVirtualTextWrap != 'default'
    diag_wrap = lspOpts.diagVirtualTextWrap
  endif

  var mostSevereOnly: bool = lspOpts.showDiagWithVirtualText
	&& lspOpts.diagVirtualTextMostSevere
  var virtualTextDiags: dict<dict<any>> =
	mostSevereOnly ? MostSevereDiagByLine(diags) : {}

  var signs: list<dict<any>> = []
  var inlineHLprops: list<list<list<number>>> = [[], [], [], [], []]
  for diag in diags
    var d_range = diag.range
    var d_start = d_range.start
    var d_end = d_range.end
    var lnum = d_start.line + 1
    const d_severity = diag->get('severity', 1)
    if lspOpts.showDiagWithSign
      signs->add({id: 0, buffer: bnr, group: 'LSPDiag',
		  lnum: lnum, name: DiagSevToSignName(d_severity),
		  priority: 10 - d_severity})
    endif

    try
      if lspOpts.highlightDiagInline
	var propLocation: list<number> = [
	  lnum, util.GetLineByteFromPos(bnr, d_start) + 1,
	  d_end.line + 1, util.GetLineByteFromPos(bnr, d_end) + 1
	]
	inlineHLprops[d_severity]->add(propLocation)
      endif

      if lspOpts.showDiagWithVirtualText
	  && (!mostSevereOnly || virtualTextDiags[lnum] is diag)
        var padding: number
        var symbol: string = diag_symbol

        if diag_align == 'after'
          padding = 3
          symbol = DiagSevToSymbolText(d_severity)
        else
	  padding = LineTextWidth(bnr, lnum,
				  util.GetCharIdxWithoutCompChar(bnr, d_start))
        endif

        prop_add(lnum, 0, {bufnr: bnr,
			   type: DiagSevToVirtualTextHLName(d_severity),
                           text: $'{symbol} {diag.message}',
                           text_align: diag_align,
                           text_wrap: diag_wrap,
                           text_padding_left: padding})
      endif
    catch /E966\|E964/ # Invalid lnum | Invalid col
      # Diagnostics arrive asynchronously and the document changed while they
      # were in transit. Ignore this as new once will arrive shortly.
    endtry
  endfor

  if lspOpts.highlightDiagInline
    for i in range(1, 4)
      if !inlineHLprops[i]->empty()
	try
	  prop_add_list({bufnr: bnr, type: DiagSevToInlineHLName(i)},
	    inlineHLprops[i])
	catch /E966\|E964/ # Invalid lnum | Invalid col
	endtry
      endif
    endfor
  endif

  if lspOpts.showDiagWithSign
    signs->sign_placelist()
  endif
enddef

# Returns the names of the language servers attached to buffer "bnr", used as
# the ALE linter names for their diagnostics.
def AleLinterNamesGet(bnr: number): list<string>
  return buf.BufLspServersGet(bnr)
    ->mapnew((_, lspserver) => lspserver.name)
    ->sort()
    ->uniq()
enddef

# Returns the ALE loclist entry for diagnostic "diag" in buffer "bnr".  ALE
# highlights up to and including "end_col", so the end of the entry is the
# last byte in the diagnostic range, kept within the buffer.  An empty range
# highlights the character at its start.
def AleLocListItem(bnr: number, diag: dict<any>): dict<any>
  var range = diag.range
  var lnum = range.start.line + 1
  var col = util.GetLineByteFromPos(bnr, range.start) + 1
  var endLnum = range.end.line + 1
  var endCol: number
  if bnr->getbufline(endLnum)->empty()
    # The range ends past the end of the buffer
    endLnum = bnr->getbufinfo()[0].linecount
    endCol = bnr->getbufline(endLnum)->get(0, '')->strlen()
  elseif range.end.character == 0 && endLnum > lnum
    # The range ends with the newline of the previous line
    endLnum -= 1
    endCol = bnr->getbufline(endLnum)[0]->strlen()
  else
    # The byte index of the exclusive end is the column of the last byte in
    # the range.  A range ending past the end of the line ends with the line.
    var endText = bnr->getbufline(endLnum)[0]
    endCol = endText->byteidxcomp(range.end.character)
    if endCol < 0
      endCol = endText->strlen()
    endif
  endif
  if endLnum < lnum || (endLnum == lnum && endCol < col)
    [endLnum, endCol] = [lnum, col]
  endif
  return {text: diag.message, lnum: lnum, col: col, end_lnum: endLnum,
	  end_col: endCol, type: "EWIH"[get(diag, "severity", 1) - 1]}
enddef

# Sends the diagnostics of every language server attached to buffer "bnr" to
# ALE, using the server name as the ALE linter name.  A server without
# diagnostics gets an empty list, which ends ALE's check for it.
def SendAleDiags(bnr: number, timerid: number)
  var serverDiags: dict<dict<list<any>>> = diagsMap->has_key(bnr)
    ? diagsMap[bnr].serverDiagnostics : {}
  var loclists: dict<list<dict<any>>> = {}
  for lspserver in buf.BufLspServersGet(bnr)
    var diags: list<dict<any>> = []
    for kindDiags in serverDiags->get(lspserver.id->string(), {})->values()
      diags->extend(kindDiags)
    endfor
    # Convert to Ale's diagnostics format (:h ale-loclist-format)
    var loclist = SortDiags(DeduplicateDiags(diags))
      ->mapnew((_, v) => AleLocListItem(bnr, v))
    loclists[lspserver.name] = loclists->get(lspserver.name, [])
      ->extend(loclist)
  endfor

  for [linterName, loclist] in loclists->items()
    ale#other_source#ShowResults(bnr, linterName, loclist)
  endfor
  if !loclists->empty()
    aleLinterNames[bnr] = loclists->keys()
  endif
enddef

# Clears the diagnostics sent to ALE for buffer "bnr".
def ClearAleDiags(bnr: number)
  if !aleLinterNames->has_key(bnr)
    return
  endif
  var linterNames = aleLinterNames->remove(bnr)

  # ALE drops a deleted buffer on BufDelete, before the BufWipeout that
  # detaches it from the language servers.  Clearing its results then would
  # make ALE track the deleted buffer again.
  if !get(g:, 'ale_buffer_info', {})->has_key(bnr)
    return
  endif
  for linterName in linterNames
    ale#other_source#ShowResults(bnr, linterName, [])
  endfor
enddef

# Hook called when ALE wants to retrieve new diagnostics for buffer "bnr".
export def AleHook(bnr: number)
  var linterNames = AleLinterNamesGet(bnr)
  if linterNames->empty()
    return
  endif
  for linterName in linterNames
    ale#other_source#StartChecking(bnr, linterName)
  endfor
  timer_start(0, function('SendAleDiags', [bnr]))
enddef

# Returns true if ALE lints a buffer when its text is changed in insert mode,
# following ALE's handling of "g:ale_lint_on_text_changed".
def AleLintsInInsertMode(): bool
  var lintOnTextChanged: any = get(g:, 'ale_lint_on_text_changed', 'normal')
  var valueType = lintOnTextChanged->type()
  if valueType == v:t_bool
    return lintOnTextChanged
  endif
  if valueType != v:t_number && valueType != v:t_string
    return false
  endif
  var value: string = $'{lintOnTextChanged}'
  return value ==? 'always' || value ==? 'insert' || value == '1'
enddef

# New LSP diagnostic messages received from the server for a file.
# Update the signs placed in the buffer for this file
export def ProcessNewDiags(bnr: number)
  DiagsUpdateLocList(bnr)

  var curmode: string = mode()
  var textChangedMode: bool = (curmode == 'i' || curmode == 'R' || curmode == 'Rv')

  var lspOpts = opt.lspOptions
  if lspOpts.aleSupport && (!textChangedMode || AleLintsInInsertMode())
    SendAleDiags(bnr, -1)
  endif

  if bnr == -1 || !diagsMap->has_key(bnr)
    return
  endif

  if textChangedMode
    # postpone placing signs in insert mode and replace mode. These will be
    # placed after the user returns to Normal mode.
    setbufvar(bnr, 'LspDiagsUpdatePending', true)
    return
  endif

  DiagsRefresh(bnr)
enddef

# process a diagnostic notification message from the LSP server
# Notification: textDocument/publishDiagnostics
# Param: PublishDiagnosticsParams
export def DiagNotification(lspserver: dict<any>, uri: string, diags_arg: list<dict<any>>, sync_kind: string): void
  # Diagnostics are disabled for this server?
  if !lspserver.featureEnabled('diagnostics')
    return
  endif

  var fname: string = util.LspUriToFile(uri)
  if !fname->bufexists() # exact match on fname, not file-pattern
    return
  endif
  var bnr: number = fname->bufnr()

  var serverId = lspserver.id
  var serverDiags: dict<dict<list<any>>> = diagsMap->has_key(bnr) ?
      diagsMap[bnr].serverDiagnostics : {}
  var kindDiags: dict<list<any>> = serverDiags->has_key(serverId) ?
      serverDiags[serverId] : {}

  # Count existing diagnostics from this server for other sync kinds
  var otherDiagCount = kindDiags
      ->keys()
      ->filter((_, k) => k != sync_kind)
      ->reduce((acc, k) => acc + kindDiags[k]->len(), 0)
  var newDiags: list<dict<any>> = diags_arg->slice(0, opt.lspOptions.maxDiagnostics - otherDiagCount)

  if lspserver.needOffsetEncoding
    # Decode the position encoding in all the diags
    newDiags->map((_, dval) => {
	lspserver.decodeRange(bnr, dval.range)
	return dval
      })
  endif

  if lspserver.processDiagHandler != null_function
    newDiags = lspserver.processDiagHandler(newDiags)
  endif

  # TODO: Is the buffer (bnr) always a loaded buffer? Should we load it here?
  var lastlnum: number = bnr->getbufinfo()[0].linecount
  kindDiags[sync_kind] = newDiags
  serverDiags[serverId] = kindDiags

  var dedupedDiags = []
  for diags in kindDiags->values()
    dedupedDiags->extend(diags)
  endfor
  dedupedDiags = DeduplicateDiags(dedupedDiags)

  # store the diagnostic for each line separately
  var diagsByLnum: dict<list<dict<any>>> = {}
  var multiLineDiags: list<dict<any>> = []
  for diag in dedupedDiags
    var d_start = diag.range.start
    if d_start.line + 1 > lastlnum
      # Make sure the line number is a valid buffer line number
      d_start.line = lastlnum - 1
    endif

    var lnum = d_start.line + 1
    if !diagsByLnum->has_key(lnum)
      diagsByLnum[lnum] = []
    endif
    diagsByLnum[lnum]->add(diag)
    if DiagLastLnum(diag) > lnum
      multiLineDiags->add(diag)
    endif
  endfor

  # store the diagnostic for each line separately
  var serverDiagsByLnum: dict<dict<list<any>>> = diagsMap->has_key(bnr) ?
      diagsMap[bnr].serverDiagnosticsByLnum : {}
  serverDiagsByLnum[serverId] = diagsByLnum

  var serverMultiLineDiags: dict<list<dict<any>>> = diagsMap->has_key(bnr) ?
      diagsMap[bnr].serverMultiLineDiagnostics : {}
  serverMultiLineDiags[serverId] = SortDiags(multiLineDiags)

  var joinedServerDiags: list<dict<any>> = []
  for kndDiags in serverDiags->values()
    # De-duplicate diagnostics across push and pull for each server
    var dedupedServerDiags = []
    for diags in kndDiags->values()
      dedupedServerDiags->extend(diags)
    endfor
    dedupedServerDiags = DeduplicateDiags(dedupedServerDiags)

    joinedServerDiags->extend(dedupedServerDiags)
  endfor

  var sortedDiags = SortDiags(joinedServerDiags)

  diagsMap[bnr] = {
    sortedDiagnostics: sortedDiags,
    serverDiagnosticsByLnum: serverDiagsByLnum,
    serverMultiLineDiagnostics: serverMultiLineDiags,
    serverDiagnostics: serverDiags
  }

  ProcessNewDiags(bnr)

  # Notify user scripts that diags has been updated
  if exists('#User#LspDiagsUpdated')
    :doautocmd <nomodeline> User LspDiagsUpdated
  endif
enddef

# get the count of error in the current buffer
export def DiagsGetErrorCount(bnr: number): dict<number>
  var diagSevCount: list<number> = [0, 0, 0, 0, 0]
  if diagsMap->has_key(bnr)
    var diags = diagsMap[bnr].sortedDiagnostics
    for diag in diags
      var severity = diag->get('severity', 0)
      diagSevCount[severity] += 1
    endfor
  endif

  return {
    Error: diagSevCount[1],
    Warn: diagSevCount[2],
    Info: diagSevCount[3],
    Hint: diagSevCount[4]
  }
enddef

# Map the LSP DiagnosticSeverity to a quickfix type character
def DiagSevToQfType(severity: number): string
  var typeMap: list<string> = ['E', 'W', 'I', 'N']

  if severity < 1 || severity > 4
    return ''
  endif

  return typeMap[severity - 1]
enddef

# Update the location list window for the current window with the diagnostic
# messages.
# Returns true if diagnostics is not empty and false if it is empty.
def DiagsUpdateLocList(bnr: number, calledByCmd: bool = false): bool
  var fname: string = bnr->bufname()->fnamemodify(':p')
  if fname->empty()
    return false
  endif

  var LspQfId: number = bnr->getbufvar('LspQfId', 0)
  if LspQfId == 0 && !opt.lspOptions.autoPopulateDiags && !calledByCmd
    # Diags location list is not present. Create the location list only if
    # the 'autoPopulateDiags' option is set or the ":LspDiag show" command is
    # invoked.
    return false
  endif

  if LspQfId != 0 && getloclist(0, {id: LspQfId}).id != LspQfId
    # Previously used location list for the diagnostics is gone
    LspQfId = 0
  endif

  if !diagsMap->has_key(bnr)
    if LspQfId != 0
      setloclist(0, [], 'r', {id: LspQfId, items: []})
    endif
    return false
  endif
  var bufferDiags = diagsMap[bnr]
  var diags: list<dict<any>> = bufferDiags.sortedDiagnostics
  if diags->empty()
    if LspQfId != 0
      setloclist(0, [], 'r', {id: LspQfId, items: []})
    endif
    return false
  endif

  var qflist: list<dict<any>> = []
  var text: string

  for diag in diags
    var d_range = diag.range
    var d_start = d_range.start
    var d_end = d_range.end
    text = diag.message->substitute("\n\\+", "\n", 'g')
    qflist->add({filename: fname,
		    lnum: d_start.line + 1,
		    col: util.GetLineByteFromPos(bnr, d_start) + 1,
		    end_lnum: d_end.line + 1,
                    end_col: util.GetLineByteFromPos(bnr, d_end) + 1,
		    text: text,
		    type: DiagSevToQfType(diag->get('severity', 1)),
		    user_data: { diagnostic: diag }})
  endfor

  var op: string = ' '
  var props = {title: 'Language Server Diagnostics', items: qflist}
  if LspQfId != 0
    op = 'r'
    props.id = LspQfId
  endif
  setloclist(0, [], op, props)
  if LspQfId == 0
    setbufvar(bnr, 'LspQfId', getloclist(0, {id: 0}).id)
  endif

  return true
enddef

# Display the diagnostic messages from the LSP server for the current buffer
# in a location list
export def ShowAllDiags(): void
  var bnr: number = bufnr()
  if !DiagsUpdateLocList(bnr, true)
    util.WarnMsg($'No diagnostic messages found for {@%}')
    return
  endif

  var save_winid = win_getid()
  # make the diagnostics error list the active one and open it
  var LspQfId: number = bnr->getbufvar('LspQfId', 0)
  var LspQfNr: number = getloclist(0, {id: LspQfId, nr: 0}).nr
  execute($':{LspQfNr} lhistory', 'silent')
  :lopen
  if !opt.lspOptions.keepFocusInDiags
    save_winid->win_gotoid()
  endif
enddef

# Display the message of "diag" in a popup window right below the start of the
# diagnostic, or below the cursor if the diagnostic starts on another line.
def ShowDiagInPopup(diag: dict<any>)
  var d_start = diag.range.start
  var dlnum = d_start.line + 1

  var lastline = line('$')
  if dlnum > lastline
    # The line number is outside the last line in the file.
    dlnum = lastline
  endif

  var d: dict<number> = {row: 0, col: 0}
  if dlnum == line('.')
    var ltext = dlnum->getline()
    var dlcol = ltext->byteidxcomp(d_start.character) + 1
    if dlcol < 1
      # The column is outside the last character in line.
      dlcol = ltext->len() + 1
    endif
    d = screenpos(0, dlnum, dlcol)
  endif

  if d.row == 0
    # The diagnostic starts on a different line than the cursor or its start
    # is not visible.  Display the popup below the cursor.
    d = screenpos(0, line('.'), col('.'))
  endif

  # Display a popup right below the diagnostics position
  var msg = diag.message->split("\n")
  var msglen = msg->reduce((acc, val) => max([acc, val->strcharlen()]), 0)

  var popupAttrs = opt.PopupConfigure('Diag', {
    pos: 'topleft',
    line: d.row + 1,
    moved: 'any'
  })

  if msglen > &columns
    popupAttrs.wrap = true
    popupAttrs.col = 1
  else
    popupAttrs.wrap = false
    popupAttrs.col = d.col
  endif

  popup_create(msg, popupAttrs)
enddef

# Display the "diag" message in a popup or in the status message area
def DisplayDiag(diag: dict<any>)
  if opt.lspOptions.showDiagInPopup
    # Display the diagnostic message in a popup window.
    ShowDiagInPopup(diag)
  else
    # Display the diagnostic message in the status message area
    :echo diag.message
  endif
enddef

# Show the diagnostic message for the current line
export def ShowCurrentDiag(atPos: bool)
  var bnr: number = bufnr()
  var lnum: number = line('.')
  var col: number = charcol('.')
  var diag: dict<any> = GetDiagByPos(bnr, lnum, col, atPos)
  if diag->empty()
    util.WarnMsg($'No diagnostic messages found for current {atPos ? "position" : "line"}')
  else
    DisplayDiag(diag)
  endif
enddef

# Show the diagnostic message for the current line without linebreak
def ShowCurrentDiagInStatusLine()
  var bnr: number = bufnr()
  var lnum: number = line('.')
  var col: number = charcol('.')
  var diag: dict<any> = GetDiagByPos(bnr, lnum, col)
  if !diag->empty()
    # 15 is a enough length not to cause line break
    var max_width = &columns - 15
    var code = ''
    if diag->has_key('code')
      code = $'[{diag.code}] '
    endif
    var msgNoLineBreak = code ..
	diag.message->substitute("[[:cntrl:]]", ' ', 'g')
    :echo msgNoLineBreak[ : max_width]
  else
    # clear the previous message
    :echo ''
  endif
enddef

# Return true if the position at line "lnum" and character index "col" (both
# 1-based, composing characters not counted separately) in buffer "bnr" is
# inside the range of "diag".
def DiagRangeHasPos(bnr: number, diag: dict<any>, lnum: number,
		    col: number): bool
  var r = diag.range
  var startLnum = r.start.line + 1
  var endLnum = r.end.line + 1
  if lnum < startLnum || lnum > endLnum
    return false
  endif
  if lnum == startLnum
      && col < util.GetCharIdxWithoutCompChar(bnr, r.start) + 1
    return false
  endif
  if lnum == endLnum
      && col >= util.GetCharIdxWithoutCompChar(bnr, r.end) + 1
    return false
  endif
  return true
enddef

# Get the diagnostic from the LSP server for a particular line and character
# offset in a file.  If "atPos" is true, return the innermost diagnostic whose
# range contains the position.  Otherwise, return the first diagnostic covering
# the line that starts at or after the position, or the last one starting
# before it.
export def GetDiagByPos(bnr: number, lnum: number, col: number,
			atPos: bool = false): dict<any>
  var diags_in_line = GetDiagsByLine(bnr, lnum)

  if atPos
    var found: dict<any> = {}
    for diag in diags_in_line
      if DiagRangeHasPos(bnr, diag, lnum, col)
	  && (found->empty() || DiagsSortFunc(diag, found) > 0)
	found = diag
      endif
    endfor
    return found
  endif

  for diag in diags_in_line
    var d_start = diag.range.start
    if d_start.line + 1 == lnum
	&& col <= util.GetCharIdxWithoutCompChar(bnr, d_start) + 1
      return diag
    endif
  endfor

  # No diagnostic to the right of the position, return the last one instead
  return diags_in_line->empty() ? {} : diags_in_line[-1]
enddef

# Get all the diagnostics from the LSP server "lspserver" (or from all the
# servers if not specified) covering any of the lines from "startLnum" to
# "endLnum" in buffer "bnr".  Returns a new list sorted by the start position.
export def GetDiagsInLineRange(bnr: number, startLnum: number, endLnum: number,
			       lspserver: dict<any> = null_dict): list<dict<any>>
  if !diagsMap->has_key(bnr)
    return []
  endif

  var bufferDiags = diagsMap[bnr]
  var serverIds: list<any> = lspserver == null_dict
    ? bufferDiags.serverDiagnosticsByLnum->keys()
    : [lspserver.id]

  var diags: list<dict<any>> = []
  for serverId in serverIds
    var diagsByLnum = bufferDiags.serverDiagnosticsByLnum->get(serverId, {})
    for lnum in range(startLnum, endLnum)
      if diagsByLnum->has_key(lnum)
	diags->extend(diagsByLnum[lnum])
      endif
    endfor

    # Diagnostics starting before the range but extending into it
    for diag in bufferDiags.serverMultiLineDiagnostics->get(serverId, [])
      if diag.range.start.line + 1 >= startLnum
	break
      endif
      if DiagLastLnum(diag) >= startLnum
	diags->add(diag)
      endif
    endfor
  endfor

  return SortDiags(diags)
enddef

# Get all diagnostics from the LSP server for a particular line in a file,
# including the diagnostics that start on a previous line and extend to it.
export def GetDiagsByLine(bnr: number, lnum: number, lspserver: dict<any> = null_dict): list<dict<any>>
  return GetDiagsInLineRange(bnr, lnum, lnum, lspserver)
enddef

# Utility function to do the actual jump
def JumpDiag(diag: dict<any>)
  var startPos: dict<number> = diag.range.start
  setcursorcharpos(startPos.line + 1,
		   util.GetCharIdxWithoutCompChar(bufnr(), startPos) + 1)
  :normal! zv
  if !opt.lspOptions.showDiagWithVirtualText
    :redraw
    DisplayDiag(diag)
  endif
enddef

# jump to the next/previous/first diagnostic message in the current buffer
export def LspDiagsJump(which: string, a_count: number = 0): void
  var fname: string = expand('%:p')
  if fname->empty()
    return
  endif
  var bnr: number = bufnr()

  if !diagsMap->has_key(bnr)
    util.WarnMsg($'No diagnostic messages found for {fname}')
    return
  endif
  var bufferDiags = diagsMap[bnr]
  var diags = bufferDiags.sortedDiagnostics
  if diags->empty()
    util.WarnMsg($'No diagnostic messages found for {fname}')
    return
  endif

  if which == 'first'
    JumpDiag(diags[0])
    return
  endif

  if which == 'last'
    JumpDiag(diags[-1])
    return
  endif

  # Find the entry just before the current line (binary search)
  var count = a_count > 1 ? a_count : 1
  var curlnum: number = line('.')
  var curcol: number = charcol('.')
  for diag in (which == 'next' || which == 'nextWrap' || which == 'here') ?
					diags : diags->copy()->reverse()
    var d_start = diag.range.start
    var lnum = d_start.line + 1
    var col = util.GetCharIdxWithoutCompChar(bnr, d_start) + 1
    if ((which == 'next' || which == 'nextWrap') && (lnum > curlnum || lnum == curlnum && col > curcol))
	  || ((which == 'prev' || which == 'prevWrap') && (lnum < curlnum || lnum == curlnum
							&& col < curcol))
	  || (which == 'here' && (lnum == curlnum && col >= curcol))

      # Skip over as many diags as "count" dictates
      count = count - 1
      if count > 0
        continue
      endif

      JumpDiag(diag)
      return
    endif
  endfor

  # If [count] exceeded the remaining diags
  if ((which == 'next' || which == 'nextWrap') && a_count > 1 && a_count != count)
    JumpDiag(diags[-1])
    return
  endif

  # If [count] exceeded the previous diags
  if ((which == 'prev' || which == 'prevWrap') && a_count > 1 && a_count != count)
    JumpDiag(diags[0])
    return
  endif

  if which == 'nextWrap' || which == 'prevWrap'
    JumpDiag(diags[which == 'nextWrap' ? 0 : -1])
    return
  endif

  if which == 'here'
    util.WarnMsg('No more diagnostics found on this line')
  else
    util.WarnMsg('No more diagnostics found')
  endif
enddef

# Return the sorted diagnostics for buffer "bnr".  Default is the current
# buffer.  A copy of the diagnostics is returned so that the caller can modify
# the diagnostics.
export def GetDiagsForBuf(bnr: number = bufnr()): list<dict<any>>
  if !diagsMap->has_key(bnr)
    return []
  endif
  var bufferDiags = diagsMap[bnr]
  var diags = bufferDiags.sortedDiagnostics
  if diags->empty()
    return []
  endif

  return diags->deepcopy()
enddef

# Return the diagnostic text from the LSP server for the current mouse line to
# display in a balloon
def g:LspDiagExpr(): any
  if !opt.lspOptions.showDiagInBalloon
    return ''
  endif

  var ltext: string = v:beval_bufnr->getbufline(v:beval_lnum)->get(0, '')
  var charIdx: number = ltext->charidx(v:beval_col - 1)
  if charIdx < 0
    charIdx = ltext->strcharlen()
  endif
  var diagFound: dict<any> =
	GetDiagByPos(v:beval_bufnr, v:beval_lnum, charIdx + 1, true)
  if diagFound->empty()
    # mouse is outside of the diagnostics range
    return ''
  endif

  # return the found diagnostic
  return diagFound.message->split("\n")
enddef

# Redraw the diagnostics in every buffer with the current options, removing
# the ones drawn with the previous options.  The diagnostics of an unloaded
# buffer are drawn when it is displayed in a window again.
def DiagsRedrawAll()
  for binfo in getbufinfo()
    if !diagsMap->has_key(binfo.bufnr)
      continue
    endif
    RemoveDiagVisualsForBuffer(binfo.bufnr, true)
    if binfo.loaded
      DiagsRefresh(binfo.bufnr)
    endif
  endfor
enddef

# Set up the diagnostics features again in every buffer with a language
# server, with the current options.
def BuffersFeaturesSet()
  for binfo in getbufinfo()
    if !buf.BufLspServersGet(binfo.bufnr)->empty()
      BufferFeaturesSet(binfo.bufnr)
    endif
  endfor
enddef

# The options with the text of the diagnostic signs, also used as the symbol
# of the virtual text placed after a line.
const signTextOptions: list<string> = [
  'diagSignErrorText', 'diagSignWarningText', 'diagSignInfoText',
  'diagSignHintText'
]

# The options that change how the diagnostics are displayed, each with the
# function applying a change in them.  The other diagnostics options are read
# whenever they are used.
const displayOptionAppliers: list<dict<any>> = [
  {Apply: DiagSignsDefine, options: signTextOptions},
  {
    Apply: DiagsRedrawAll,
    options: [
      'autoHighlightDiags', 'diagVirtualTextAlign',
      'diagVirtualTextMostSevere', 'diagVirtualTextWrap',
      'highlightDiagInline', 'showDiagWithSign', 'showDiagWithVirtualText'
    ] + signTextOptions
  },
  {
    Apply: BuffersFeaturesSet,
    options: ['showDiagInBalloon', 'showDiagOnStatusLine']
  }
]

# The values of the options in "displayOptionAppliers" when they were last
# applied, as returned by DisplayOptionsGet().  Empty until InitOnce() applies
# them for the first time.
var appliedOptions: dict<string> = {}

# Returns the current values of the options in "displayOptionAppliers".  The
# values are converted to strings, so that a value can be compared with one of
# another type (e.g. v:true with 1).
def DisplayOptionsGet(): dict<string>
  var values: dict<string> = {}
  for applier in displayOptionAppliers
    for name in applier.options
      values[name] = opt.lspOptions[name]->string()
    endfor
  endfor
  return values
enddef

# Enable the LSP diagnostics highlighting
export def DiagsHighlightEnable()
  opt.lspOptions.autoHighlightDiags = true
  LspDiagsOptionsChanged()
enddef

# Disable the LSP diagnostics highlighting in all the buffers
export def DiagsHighlightDisable()
  opt.lspOptions.autoHighlightDiags = false
  LspDiagsOptionsChanged()
enddef

# Toggle the LSP diagnostics highlighting in all the buffers
export def DiagsHighlightToggle()
  if opt.lspOptions.autoHighlightDiags
    DiagsHighlightDisable()
  else
    DiagsHighlightEnable()
  endif
enddef

# Some options are changed.  Apply the changes in the options that affect how
# the diagnostics are displayed.  Before InitOnce(), there is nothing to
# update: it applies the options then.
export def LspDiagsOptionsChanged()
  if appliedOptions->empty()
    return
  endif
  var options: dict<string> = DisplayOptionsGet()
  var changed: list<string> = options->keys()
    ->filter((_, name) => options[name] != appliedOptions[name])
  appliedOptions = options
  for applier in displayOptionAppliers
    if applier.options->indexof((_, name) => changed->index(name) != -1) != -1
      applier.Apply()
    endif
  endfor
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
