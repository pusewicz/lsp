vim9script

# Functions related to handling LSP diagnostics.

import './options.vim' as opt
import './buffer.vim' as buf
import './offset.vim'
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
#   sortedDiagnostics: [lspServer1.diags, ...lspServer2.diags]->sort(),
#   changedtick: b:changedtick of the buffer when they were stored,
#   generation: a number that is different each time they are stored
# }
#
# The diagnostics are stored as the language servers sent them.  The lines of
# a buffer can be deleted before a server sends the diagnostics again, so the
# stored diagnostics are used through DiagInBuf().
var diagsMap: dict<dict<any>> = {}

# The last "generation" of "diagsMap"
var diagsGeneration: number = 0

# What DiagsRefresh() last drew in each buffer: [bnr] = {
#   generation: the "generation" of the diagnostics in "diagsMap" it drew, or
#		0 when the buffer had none,
#   changedtick: b:changedtick of the buffer then,
#   drawn: whether it drew anything
# }
# Drawing the same diagnostics again in the same text changes nothing.
var drawnDiags: dict<dict<any>> = {}

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

  # Diag tag highlight groups and text property types.  The text properties
  # combine with the ones for the severity of the diagnostic.
  hlset([
    {name: 'LspDiagInlineUnnecessary', default: true, linksto: 'Comment'}
  ])
  DeprecatedHighlightSet()
  autocmd_add([{group: 'LspCmds',
		event: 'ColorScheme',
		pattern: '*',
		cmd: 'DeprecatedHighlightSet()'}])
  prop_type_add('LspDiagInlineUnnecessary',
		{highlight: 'LspDiagInlineUnnecessary',
		 priority: 6,
		 override: override})
  prop_type_add('LspDiagInlineDeprecated',
		{highlight: 'LspDiagInlineDeprecated',
		 priority: 6,
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

# Define the "LspDiagInlineDeprecated" highlight group to strike through the
# text, unless it is already defined (e.g. in a vimrc or by a color scheme).
# No standard highlight group has that attribute to link to, and unlike a
# default link, ":highlight clear" doesn't keep default attributes, so this is
# done again when a color scheme is loaded.  hlset() with "default" would
# replace a link, so the group is only set when it is cleared.
def DeprecatedHighlightSet()
  if !hlget('LspDiagInlineDeprecated')->get(0, {})->get('cleared', true)
    return
  endif
  hlset([{name: 'LspDiagInlineDeprecated', default: true,
	  term: {strikethrough: true}, cterm: {strikethrough: true},
	  gui: {strikethrough: true}}])
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

# Returns "diag", a diagnostic stored for buffer "bnr", as it applies to the
# current text of the buffer.  Lines may have been deleted since the language
# server computed the diagnostic, so a position on a line past the end of the
# buffer is at the end of its last line: a range ending past the end of the
# buffer ends there, and one starting past it is empty there.  Returns "diag"
# itself when its range is within the buffer, or else a copy of it.
def DiagInBuf(bnr: number, diag: dict<any>): dict<any>
  var range: dict<dict<number>> = diag.range
  if !bnr->getbufline(max([range.start.line, range.end.line]) + 1)->empty()
      || !bnr->bufloaded()
    return diag
  endif
  var lastLnum: number = bnr->getbufinfo()[0].linecount
  var bufEnd: dict<number> = {
    line: lastLnum - 1,
    character: bnr->getbufline(lastLnum)[0]->strchars()
  }
  return diag->extendnew({range: range->mapnew((_, pos) =>
    pos.line < lastLnum ? pos : bufEnd->copy())})
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

# The text property types highlighting the diagnostics inline, indexed by the
# severity minus one.
const inlinePropTypes: list<string> = [
  'LspDiagInlineError',
  'LspDiagInlineWarning',
  'LspDiagInlineInfo',
  'LspDiagInlineHint'
]

# The text property types of the diagnostic virtual text, indexed by the
# severity minus one.
const virtualTextPropTypes: list<string> = [
  'LspDiagVirtualTextError',
  'LspDiagVirtualTextWarning',
  'LspDiagVirtualTextInfo',
  'LspDiagVirtualTextHint'
]

# Returns the name of the text property type highlighting a diagnostic of
# "severity" inline.
def DiagSevToInlineHLName(severity: number): string
  if severity < 1 || severity > 4
    return inlinePropTypes[3]
  endif
  return inlinePropTypes[severity - 1]
enddef

# Returns the name of the text property type of the virtual text of a
# diagnostic of "severity".
def DiagSevToVirtualTextHLName(severity: number): string
  if severity < 1 || severity > 4
    return virtualTextPropTypes[3]
  endif
  return virtualTextPropTypes[severity - 1]
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

# The text property types highlighting the diagnostic tags, indexed by the
# DiagnosticTag value minus one: Unnecessary (1) and Deprecated (2).
const tagPropTypes: list<string> = [
  'LspDiagInlineUnnecessary',
  'LspDiagInlineDeprecated'
]

# Returns the text property types highlighting the tags of "diag", ignoring
# the tags that aren't supported.
def DiagTagPropTypes(diag: dict<any>): list<string>
  var tags: any = diag->get('tags', [])
  if tags->type() != v:t_list
    return []
  endif
  return tags->copy()
    ->filter((_, tag) => tag->type() == v:t_number
			  && tag >= 1 && tag <= tagPropTypes->len())
    ->sort('n')
    ->uniq()
    ->mapnew((_, tag) => tagPropTypes[tag - 1])
enddef

# Returns true if "diag" is displayed only by highlighting its text for its
# tags: a hint with a tag, such as an unused variable or a deprecated
# function, gets no sign, no virtual text and no highlight for its severity,
# as in other clients.  Without the inline highlights, it is displayed like
# any other hint.
def DiagIsTagOnly(diag: dict<any>): bool
  return opt.lspOptions.highlightDiagInline
    && diag->get('severity', 1) == 4
    && !DiagTagPropTypes(diag)->empty()
enddef

# Returns a new List with the diagnostics in "diags" that are listed: all but
# the ones displayed only by their tag highlights (DiagIsTagOnly()).  Those
# hints, often one for every unused import or parameter, are left out of the
# jumps, the counts, the location list and the diagnostics sent to ALE, as
# other clients leave them out of their lists of problems.
def ListedDiags(diags: list<dict<any>>): list<dict<any>>
  return diags->copy()->filter((_, d) => !DiagIsTagOnly(d))
enddef

# Remove signs and text properties for diagnostics in buffer
def RemoveDiagVisualsForBuffer(bnr: number, all: bool = false)
  var lspOpts = opt.lspOptions
  if lspOpts.showDiagWithSign || all
    # Remove all the existing diagnostic signs
    sign_unplace('LSPDiag', {buffer: bnr})
  endif

  # Each prop_remove() walks every line of the buffer, so remove all the
  # types in one call.
  var propTypes: list<string> = []
  if lspOpts.showDiagWithVirtualText || all
    propTypes->extend(virtualTextPropTypes)
  endif
  if lspOpts.highlightDiagInline || all
    propTypes->extend(inlinePropTypes)->extend(tagPropTypes)
  endif
  if !propTypes->empty()
    prop_remove({types: propTypes, bufnr: bnr, all: true})
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

# Returns true if only the tag highlights of the diagnostics are drawn: ALE
# draws the rest, and it has no notion of the diagnostic tags.  The hints
# shown only by their tags (DiagIsTagOnly()) aren't sent to ALE.
def DrawsOnlyTags(): bool
  var lspOpts = opt.lspOptions
  return lspOpts.aleSupport && !lspOpts.autoHighlightDiags
    && lspOpts.highlightDiagInline
enddef

# Refresh the placed diagnostics in buffer "bnr"
# This inline signs, inline props, and virtual text diagnostics
export def DiagsRefresh(bnr: number)
  var lspOpts = opt.lspOptions
  const tagsOnly: bool = DrawsOnlyTags()
  if !lspOpts.autoHighlightDiags && !tagsOnly
    return
  endif

  :silent! bnr->bufload()

  # Reading the text of a buffer, which drops the text properties and the
  # signs, also changes b:changedtick.
  var bufDiags: dict<any> = diagsMap->get(bnr, {})
  var generation: number = bufDiags->get('generation', 0)
  var changedtick: number = bnr->getbufvar('changedtick')
  var drawn: dict<any> = drawnDiags->get(bnr, {})
  if !drawn->empty() && drawn.generation == generation
      && drawn.changedtick == changedtick
    return
  endif
  drawnDiags[bnr] = {generation: generation, changedtick: changedtick,
		     drawn: false}

  if drawn->get('drawn', true)
    RemoveDiagVisualsForBuffer(bnr)
  endif

  var diags: list<dict<any>> = bufDiags->get('sortedDiagnostics', [])
    ->mapnew((_, d) => DiagInBuf(bnr, d))
  if diags->empty()
    return
  endif
  drawnDiags[bnr].drawn = true

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

  var showSigns: bool = lspOpts.showDiagWithSign && !tagsOnly
  var showVirtualText: bool = lspOpts.showDiagWithVirtualText && !tagsOnly
  var mostSevereOnly: bool = showVirtualText
	&& lspOpts.diagVirtualTextMostSevere
  var virtualTextDiags: dict<dict<any>> = mostSevereOnly
	? MostSevereDiagByLine(ListedDiags(diags))
	: {}

  var signs: list<dict<any>> = []
  var inlineHLprops: list<list<list<number>>> = [[], [], [], [], []]
  var tagHLprops: dict<list<list<number>>> = {}
  for diag in diags
    if tagsOnly && DiagTagPropTypes(diag)->empty()
      continue
    endif
    var d_range = diag.range
    var d_start = d_range.start
    var d_end = d_range.end
    var lnum = d_start.line + 1
    const d_severity = diag->get('severity', 1)
    const tagOnly: bool = tagsOnly || DiagIsTagOnly(diag)
    if showSigns && !tagOnly
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
	if !tagOnly
	  inlineHLprops[d_severity]->add(propLocation)
	endif
	for propType in DiagTagPropTypes(diag)
	  if !tagHLprops->has_key(propType)
	    tagHLprops[propType] = []
	  endif
	  tagHLprops[propType]->add(propLocation)
	endfor
      endif

      if showVirtualText && !tagOnly
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
      # DiagInBuf() clamps the range to the buffer, so only a malformed range
      # from the server, such as a negative position, gets here.  Skip it.
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
    for [propType, propLocations] in tagHLprops->items()
      try
	prop_add_list({bufnr: bnr, type: propType}, propLocations)
      catch /E966\|E964/ # Invalid lnum | Invalid col
      endtry
    endfor
  endif

  if showSigns
    signs->sign_placelist()
  endif
enddef

# Returns the related information of "diag": the locations, with a message
# for each, that the diagnostic refers to (e.g. the previous definition for a
# redefinition error).  Returns an empty List if it has none.
def DiagRelatedInfo(diag: dict<any>): list<any>
  var related: any = diag->get('relatedInformation', [])
  return related->type() == v:t_list ? related : []
enddef

# Returns the byte index of the UTF-32 character index "charIdx" in its line,
# as util.GetLineByteFromPos() does in a buffer.  "lines" has the text of the
# line, as util.FileLineGet() returns it.  An index past the end of the line
# is at the end of the line, and one on a line that isn't available is
# returned unchanged.
def LineByteFromCharIdx(lines: list<string>, charIdx: number): number
  if charIdx <= 0 || lines->empty()
    return charIdx
  endif
  var byteIdx: number = lines[0]->byteidxcomp(charIdx)
  return byteIdx == -1 ? lines[0]->strlen() : byteIdx
enddef

# Returns the location list item for "related", an item of the related
# information of "diag".  Its 'user_data' has the diagnostic and the related
# information item.  The file of the location is not loaded in a buffer, see
# util.FileLineGet().
def RelatedInfoLocListItem(diag: dict<any>, related: dict<any>): dict<any>
  var fname: string = util.LspUriToFile(related.location.uri)
  var range: dict<dict<number>> = related.location.range
  var startLines: list<string> = util.FileLineGet(fname, range.start.line + 1)
  var endLines: list<string> = range.end.line == range.start.line
    ? startLines : util.FileLineGet(fname, range.end.line + 1)
  var item: dict<any> = {
    lnum: range.start.line + 1,
    col: LineByteFromCharIdx(startLines, range.start.character) + 1,
    end_lnum: range.end.line + 1,
    end_col: LineByteFromCharIdx(endLines, range.end.character) + 1,
    text: related.message->substitute("\n\\+", "\n", 'g'),
    user_data: {diagnostic: diag, relatedInformation: related}
  }
  var bnr: number = util.BufnrExact(fname)
  if bnr == -1
    item.filename = fname
  else
    item.bufnr = bnr
  endif
  return item
enddef

# Returns the text of "diag" to display: its message, followed by a line for
# each item of its related information, with the location of the item as
# compilers print it: "{file}:{lnum}:{col}: {message}".
def DiagDisplayText(diag: dict<any>): string
  var lines: list<string> = [diag.message]
  for related in DiagRelatedInfo(diag)
    var item: dict<any> = RelatedInfoLocListItem(diag, related)
    var fname: string = item->has_key('bufnr')
      ? item.bufnr->bufname() : item.filename
    lines->add($'{fname->fnamemodify(":~:.")}:{item.lnum}:{item.col}: '
	       .. related.message)
  endfor
  return lines->join("\n")
enddef

# Returns the names of the language servers attached to buffer "bnr", used as
# the ALE linter names for their diagnostics.
def AleLinterNamesGet(bnr: number): list<string>
  return buf.BufLspServersGet(bnr)
    ->mapnew((_, lspserver) => lspserver.name)
    ->sort()
    ->uniq()
enddef

# Returns the type of an ALE loclist entry for the LSP DiagnosticSeverity
# "severity".  ALE has no type for hints and draws and counts an entry of any
# type other than "W" and "I" as an error, so a hint is information to ALE.
# Any other severity is an error.
def DiagSevToAleType(severity: number): string
  return severity == 2 ? 'W' : severity == 3 || severity == 4 ? 'I' : 'E'
enddef

# Returns the ALE loclist entry for diagnostic "diag" in buffer "bnr", as
# returned by DiagInBuf().  ALE highlights up to and including "end_col", so
# the end of the entry is the last byte in the diagnostic range.  An empty
# range highlights the character at its start.  The related information of
# the diagnostic is in the detail of the entry, which ":ALEDetail" displays.
def AleLocListItem(bnr: number, diag: dict<any>): dict<any>
  var range = diag.range
  var lnum = range.start.line + 1
  var col = util.GetLineByteFromPos(bnr, range.start) + 1
  var endLnum = range.end.line + 1
  var endCol: number
  if range.end.character == 0 && endLnum > lnum
    # The range ends with the newline of the previous line
    endLnum -= 1
    endCol = bnr->getbufline(endLnum)[0]->strlen()
  else
    # The byte index of the exclusive end is the column of the last byte in
    # the range
    endCol = util.GetLineByteFromPos(bnr, range.end)
  endif
  if endLnum < lnum || (endLnum == lnum && endCol < col)
    [endLnum, endCol] = [lnum, col]
  endif
  var item: dict<any> = {text: diag.message, lnum: lnum, col: col,
    end_lnum: endLnum, end_col: endCol,
    type: DiagSevToAleType(diag->get('severity', 1))}
  if !DiagRelatedInfo(diag)->empty()
    item.detail = DiagDisplayText(diag)
  endif
  return item
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
    var loclist = ListedDiags(SortDiags(DeduplicateDiags(diags)))
      ->map((_, v) => AleLocListItem(bnr, DiagInBuf(bnr, v)))
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

  # Clearing the results makes ALE track the buffer, so skip a buffer that
  # ALE doesn't track (e.g. one it dropped on BufDelete).  A buffer deleted
  # with ":bdelete" is detached on BufUnload, while ALE still tracks it.
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
  BufDiagsLocListsUpdate(bnr)

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

# Returns the number of the buffer that the diagnostics for "uri" are for, or
# -1 if there is none.  "docBufnrs" holds the buffer numbers of the documents
# open on the language server by the URIs they were opened with, which may
# include a buffer wiped out without autocommands.  A server may escape a URI
# differently (gopls doesn't escape "+"), so the URI is also looked up as this
# plugin escapes it.  Only a document that isn't open on the server is looked
# up by its file name, which takes time proportional to the number of buffers.
def DiagBufnr(docBufnrs: dict<number>, uri: string): number
  var bnr: number = docBufnrs->get(uri, -1)
  if bnr->bufexists()
    return bnr
  endif
  var fname: string = util.LspUriToFile(uri)
  bnr = docBufnrs->get(util.LspFileToUri(fname), -1)
  if bnr->bufexists()
    return bnr
  endif
  return util.BufnrExact(fname)
enddef

# process a diagnostic notification message from the LSP server
# Notification: textDocument/publishDiagnostics
# Param: PublishDiagnosticsParams
export def DiagNotification(lspserver: dict<any>, uri: string, diags_arg: list<dict<any>>, sync_kind: string): void
  # Diagnostics are disabled for this server?
  if !lspserver.featureEnabled('diagnostics')
    return
  endif

  var bnr: number = DiagBufnr(lspserver.docBufnrs, uri)
  if bnr == -1
    return
  endif
  if !bnr->bufloaded()
    # Don't load a buffer just to display its diagnostics: loading it attaches
    # it to the language servers again (e.g. clangd clears the diagnostics of
    # a buffer closed by ":bdelete").
    return
  endif

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
	offset.DecodeRelatedInfo(lspserver, dval)
	return dval
      })
  endif

  if lspserver.processDiagHandler != null_function
    newDiags = lspserver.processDiagHandler(newDiags)
  endif

  # Nothing changes when the server sends the same diagnostics again for the
  # same text, e.g. after the buffer is written or for a pull and a push:
  # skip the update and the LspDiagsUpdated autocommand.
  var changedtick: number = bnr->getbufvar('changedtick')
  if diagsMap->has_key(bnr) && diagsMap[bnr].changedtick == changedtick
      && kindDiags->has_key(sync_kind) && kindDiags[sync_kind] == newDiags
    return
  endif

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
    var lnum = diag.range.start.line + 1
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

  diagsGeneration += 1
  diagsMap[bnr] = {
    sortedDiagnostics: sortedDiags,
    serverDiagnosticsByLnum: serverDiagsByLnum,
    serverMultiLineDiagnostics: serverMultiLineDiags,
    serverDiagnostics: serverDiags,
    changedtick: changedtick,
    generation: diagsGeneration
  }

  ProcessNewDiags(bnr)

  # Notify user scripts that diags has been updated
  if exists('#User#LspDiagsUpdated')
    :doautocmd <nomodeline> User LspDiagsUpdated
  endif
enddef

# Returns the number of the listed diagnostics (see ListedDiags()) in buffer
# "bnr" for each severity.
export def DiagsGetErrorCount(bnr: number): dict<number>
  var diagSevCount: list<number> = [0, 0, 0, 0, 0]
  if diagsMap->has_key(bnr)
    for diag in ListedDiags(diagsMap[bnr].sortedDiagnostics)
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

# The title of the location list with the diagnostics of the buffer displayed
# in a window.  It identifies the list in the window's location list stack:
# splitting a window copies the stack with new list IDs.
const diagsLocListTitle: string = 'Language Server Diagnostics'

# Returns the ID of the diagnostics location list in the location list stack
# of window "winid", or 0 if the window has none.
def DiagsLocListId(winid: number): number
  for nr in range(getloclist(winid, {nr: '$'}).nr, 1, -1)
    var qfl: dict<any> = getloclist(winid, {nr: nr, id: 0, title: 0})
    if qfl.title == diagsLocListTitle
      return qfl.id
    endif
  endfor
  return 0
enddef

# Returns the location list item for "diag", a diagnostic stored for buffer
# "bnr", at the position returned by DiagInBuf().  The 'user_data' of the item
# has the diagnostic as the language server sent it.
def DiagLocListItem(bnr: number, diag: dict<any>): dict<any>
  var range = DiagInBuf(bnr, diag).range
  return {
    bufnr: bnr,
    lnum: range.start.line + 1,
    col: util.GetLineByteFromPos(bnr, range.start) + 1,
    end_lnum: range.end.line + 1,
    end_col: util.GetLineByteFromPos(bnr, range.end) + 1,
    text: diag.message->substitute("\n\\+", "\n", 'g'),
    type: DiagSevToQfType(diag->get('severity', 1)),
    user_data: {diagnostic: diag}
  }
enddef

# Returns the location list items for the listed diagnostics (see
# ListedDiags()) in buffer "bnr".  The item of a diagnostic is followed by the
# items of its related information.
def DiagsLocListItems(bnr: number): list<dict<any>>
  if !diagsMap->has_key(bnr)
    return []
  endif
  var items: list<dict<any>> = []
  for diag in ListedDiags(diagsMap[bnr].sortedDiagnostics)
    items->add(DiagLocListItem(bnr, diag))
    for related in DiagRelatedInfo(diag)
      items->add(RelatedInfoLocListItem(diag, related))
    endfor
  endfor
  return items
enddef

# Set the items of the diagnostics location list of window "winid" to
# "items".  The list is replaced in place, keeping the current location list
# of the window.  When the window has no diagnostics list, one is added to the
# end of its location list stack, becoming the current list, only if "create"
# is true and "items" is not empty.  Returns the ID of the diagnostics list,
# or 0 if the window has none.
def DiagsLocListSet(winid: number, items: list<dict<any>>, create: bool): number
  var id: number = DiagsLocListId(winid)
  if id != 0
    setloclist(winid, [], 'r', {id: id, items: items})
  elseif create && !items->empty()
    setloclist(winid, [], ' ',
	       {nr: '$', title: diagsLocListTitle, items: items})
    id = getloclist(winid, {nr: '$', id: 0}).id
  endif
  return id
enddef

# Update the diagnostics location list of window "winid" with the diagnostics
# in the buffer it displays.  A location list window doesn't have a list of
# its own.  See DiagsLocListSet() for "create" and the return value.
def WinDiagsLocListUpdate(winid: number, create: bool): number
  if winid->win_gettype() != '' || (!create && DiagsLocListId(winid) == 0)
    return 0
  endif
  return DiagsLocListSet(winid, DiagsLocListItems(winid->winbufnr()), create)
enddef

# Update the diagnostics location lists of all the windows displaying buffer
# "bnr", in all the tab pages, with its diagnostics.  The lists are created
# only if the "autoPopulateDiags" option is set.  The windows of a hidden
# buffer are updated when it is displayed again (BufferDisplayed()).
def BufDiagsLocListsUpdate(bnr: number)
  var create: bool = opt.lspOptions.autoPopulateDiags
  var winids: list<number> = bnr->win_findbuf()
    ->filter((_, winid) => winid->win_gettype() == ''
	&& (create || DiagsLocListId(winid) != 0))
  if winids->empty()
    return
  endif
  var items: list<dict<any>> = DiagsLocListItems(bnr)
  for winid in winids
    DiagsLocListSet(winid, items, create)
  endfor
enddef

# Buffer "bnr" is displayed in the current window (BufWinEnter).  Update the
# diagnostics location list of the window with the diagnostics of the buffer,
# replacing the diagnostics of the buffer it displayed before.
export def BufferDisplayed(bnr: number)
  if winbufnr(0) != bnr
    return
  endif
  WinDiagsLocListUpdate(win_getid(), opt.lspOptions.autoPopulateDiags)
enddef

# Display the diagnostic messages from the LSP server for the current buffer
# in a location list
export def ShowAllDiags(): void
  var save_winid: number = win_getid()
  var id: number = WinDiagsLocListUpdate(save_winid, true)
  if id == 0 || getloclist(save_winid, {id: id, size: 0}).size == 0
    util.WarnMsg($'No diagnostic messages found for {@%}')
    return
  endif

  # make the diagnostics error list the active one and open it
  execute($':{getloclist(save_winid, {id: id, nr: 0}).nr} lhistory', 'silent')
  :lopen
  if !opt.lspOptions.keepFocusInDiags
    save_winid->win_gotoid()
  endif
enddef

# Display the message of "diag", a diagnostic of the current buffer as returned
# by DiagInBuf(), in a popup window right below the start of the diagnostic,
# or below the cursor if the diagnostic starts on another line.
def ShowDiagInPopup(diag: dict<any>)
  var d_start = diag.range.start
  var dlnum = d_start.line + 1

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
  var msg = DiagDisplayText(diag)->split("\n")
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

# Display the "diag" message and its related information in a popup or in the
# status message area
def DisplayDiag(diag: dict<any>)
  if opt.lspOptions.showDiagInPopup
    # Display the diagnostic message in a popup window.
    ShowDiagInPopup(diag)
  else
    # Display the diagnostic message in the status message area
    :echo DiagDisplayText(diag)
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
# offset in a file, as returned by DiagInBuf().  If "atPos" is true, return the
# innermost diagnostic whose range contains the position.  Otherwise, return
# the first diagnostic covering the line that starts at or after the position,
# or the last one starting before it.
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
# "endLnum" in buffer "bnr", as returned by DiagInBuf().  Returns a new list
# sorted by the start position.
export def GetDiagsInLineRange(bnr: number, startLnum: number, endLnum: number,
			       lspserver: dict<any> = null_dict): list<dict<any>>
  if !diagsMap->has_key(bnr)
    return []
  endif

  var bufferDiags = diagsMap[bnr]
  var serverIds: list<any> = lspserver == null_dict
    ? bufferDiags.serverDiagnosticsByLnum->keys()
    : [lspserver.id]
  var toBufEnd: bool = bnr->getbufline(endLnum + 1)->empty()

  var diags: list<dict<any>> = []
  for serverId in serverIds
    var diagsByLnum = bufferDiags.serverDiagnosticsByLnum->get(serverId, {})
    for lnum in range(startLnum, endLnum)
      if diagsByLnum->has_key(lnum)
	diags->extend(diagsByLnum[lnum])
      endif
    endfor

    if toBufEnd
      # Diagnostics starting past the end of the buffer start on its last line
      for [lnum, lnumDiags] in diagsByLnum->items()
	if lnum->str2nr() > endLnum
	  diags->extend(lnumDiags)
	endif
      endfor
    endif

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

  # The diagnostics are found by their stored lines.  Keep the ones that still
  # cover the range once kept within the buffer.
  return SortDiags(diags->map((_, d) => DiagInBuf(bnr, d))
    ->filter((_, d) => d.range.start.line < endLnum
		       && DiagLastLnum(d) >= startLnum))
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

# Jump to the next/previous/first/last listed diagnostic (see ListedDiags())
# in the current buffer.
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
  var diags: list<dict<any>> = ListedDiags(diagsMap[bnr].sortedDiagnostics)
    ->map((_, d) => DiagInBuf(bnr, d))
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

# Return the sorted diagnostics for buffer "bnr", as returned by DiagInBuf().
# Default is the current buffer.  A copy of the diagnostics is returned so
# that the caller can modify the diagnostics.
export def GetDiagsForBuf(bnr: number = bufnr()): list<dict<any>>
  if !diagsMap->has_key(bnr)
    return []
  endif
  return diagsMap[bnr].sortedDiagnostics
    ->mapnew((_, d) => DiagInBuf(bnr, d))
    ->deepcopy()
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
  return DiagDisplayText(diagFound)->split("\n")
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
    if drawnDiags->has_key(binfo.bufnr)
      drawnDiags->remove(binfo.bufnr)
    endif
    if binfo.loaded
      DiagsRefresh(binfo.bufnr)
    endif
  endfor
enddef

# Update the diagnostics location lists of every buffer with diagnostics, and
# the diagnostics sent to ALE for it, for a change in which diagnostics are
# listed (see ListedDiags()).  Only the buffers that ALE got diagnostics for
# are sent them again.
def DiagListsUpdateAll()
  for bnr in diagsMap->keys()->mapnew((_, key) => key->str2nr())
    BufDiagsLocListsUpdate(bnr)
    if opt.lspOptions.aleSupport && aleLinterNames->has_key(bnr)
      SendAleDiags(bnr, -1)
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

# The options that change how the diagnostics are displayed or which ones are
# listed, each with the function applying a change in them.  The other diagnostics options are read
# whenever they are used.
const displayOptionAppliers: list<dict<any>> = [
  {Apply: DiagSignsDefine, options: signTextOptions},
  {
    Apply: DiagsRedrawAll,
    options: [
      'aleSupport', 'autoHighlightDiags', 'diagVirtualTextAlign',
      'diagVirtualTextMostSevere', 'diagVirtualTextWrap',
      'highlightDiagInline', 'showDiagWithSign', 'showDiagWithVirtualText'
    ] + signTextOptions
  },
  {
    Apply: BuffersFeaturesSet,
    options: ['showDiagInBalloon', 'showDiagOnStatusLine']
  },
  {Apply: DiagListsUpdateAll, options: ['highlightDiagInline']}
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
