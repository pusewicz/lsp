vim9script

# Functions for showing the colors in a document (textDocument/documentColor).
# A language server finds the colors in a document, e.g. the color values in
# a CSS file, and a swatch of each color is shown before it.  Opt-in via the
# 'showDocumentColors' option.

import './options.vim' as opt
import './buffer.vim' as buf
import './util.vim'

# The text shown before a color, in that color
const SWATCH = '■ '

# The time in milliseconds to wait after a change to a buffer before asking
# for the colors in it again
const UPDATE_DELAY = 300

# The colors that have a swatch, as "RRGGBB" hex strings, mapped to the name
# of the highlight group and of the text property type of their swatch
var swatchTypes: dict<string> = {}

# The timers that update the colors in a buffer after a change, by buffer
# number
var updateTimers: dict<number> = {}

# The value of the 'showDocumentColors' option, to tell when it is changed
var save_showDocumentColors: bool = false

var initialized: bool = false

# Add the autocmds that show or hide the colors when the 'showDocumentColors'
# option is changed and that restore the swatch colors after a color scheme
# cleared them.
export def InitOnce()
  if initialized
    return
  endif
  save_showDocumentColors = opt.lspOptions.showDocumentColors
  autocmd_add([
    {group: 'LspCmds', event: 'User', pattern: 'LspOptionsChanged',
     cmd: 'DocumentColorsOptionsChanged()'},
    {group: 'LspCmds', event: 'ColorScheme', pattern: '*',
     cmd: 'SwatchHighlightsDefine()'}
  ])
  initialized = true
enddef

# Returns the squared distance between the colors "a" and "b", each a list of
# red, green and blue components.
def ColorDistance(a: list<number>, b: list<number>): number
  return range(3)->reduce((sum, i) => sum + (a[i] - b[i]) * (a[i] - b[i]), 0)
enddef

# Returns the number of the color in the xterm 256-color palette that is the
# closest to the color "rgb" (red, green and blue from 0 to 255), for a
# terminal that cannot show any color.  The palette has a 6x6x6 color cube
# and 24 grays.
def Xterm256Color(rgb: list<number>): number
  const levels = [0, 95, 135, 175, 215, 255]
  var cube = rgb->mapnew((_, c) => c < 48 ? 0 : c < 114 ? 1 : (c - 35) / 40)
  var cubeRgb = cube->mapnew((_, i) => levels[i])
  var grayIdx = min([23, max([0, (rgb[0] + rgb[1] + rgb[2]) / 3 - 3]) / 10])
  var gray = 8 + 10 * grayIdx
  if ColorDistance([gray, gray, gray], rgb) < ColorDistance(cubeRgb, rgb)
    return 232 + grayIdx
  endif
  return 16 + 36 * cube[0] + 6 * cube[1] + cube[2]
enddef

# Define the highlight group "name" of the swatch of the color "rgb" (an
# "RRGGBB" hex string).
def SwatchHighlightDefine(name: string, rgb: string)
  var components = [0, 2, 4]->mapnew((_, i) => rgb[i : i + 1]->str2nr(16))
  hlset([{name: name, guifg: $'#{rgb}',
	  ctermfg: Xterm256Color(components)->string()}])
enddef

# Define the highlight groups of all the swatches again, after a color scheme
# cleared them.
def SwatchHighlightsDefine()
  for [rgb, name] in swatchTypes->items()
    SwatchHighlightDefine(name, rgb)
  endfor
enddef

# Returns the name of the text property type, and of its highlight group, of
# the swatch of the LSP Color "color".  They are defined the first time a
# swatch of the color is shown.  The alpha component is ignored.
def SwatchType(color: dict<any>): string
  var rgb = [color.red, color.green, color.blue]
    ->mapnew((_, c) => printf('%02X', min([255, max([0,
					  float2nr(round(c * 255.0))])])))
    ->join('')
  if !swatchTypes->has_key(rgb)
    var name = $'LspDocumentColor{rgb}'
    SwatchHighlightDefine(name, rgb)
    if prop_type_get(name)->empty()
      prop_type_add(name, {highlight: name})
    endif
    swatchTypes[rgb] = name
  endif
  return swatchTypes[rgb]
enddef

# Remove the swatches from buffer "bnr".
def SwatchesClear(bnr: number)
  if !swatchTypes->empty() && bnr->bufloaded()
    prop_remove({types: swatchTypes->values(), bufnr: bnr, all: true})
  endif
enddef

# Show the colors "colors" in buffer "bnr" instead of the ones shown before.
# "colors" is a list of LSP ColorInformation, with their ranges decoded.
export def ColorsShow(bnr: number, colors: list<dict<any>>)
  SwatchesClear(bnr)
  var lineCount: number = bnr->getbufinfo()[0].linecount
  for colorInfo in colors
    var start: dict<number> = colorInfo.range.start
    if start.line >= lineCount
      continue
    endif
    prop_add(start.line + 1, util.GetLineByteFromPos(bnr, start) + 1,
	     {type: SwatchType(colorInfo.color), text: SWATCH, bufnr: bnr})
  endfor
enddef

# Stop the pending update of the colors in buffer "bnr".
def UpdateStop(bnr: number)
  if updateTimers->has_key(bnr)
    updateTimers->remove(bnr)->timer_stop()
  endif
enddef

# Ask the language server of buffer "bnr" for the colors in it, and show them.
def ColorsUpdate(bnr: number)
  UpdateStop(bnr)
  var lspserver: dict<any> = buf.BufLspServerGet(bnr, 'documentColor')
  if !lspserver->empty()
    lspserver.documentColorsUpdate(bnr)
  endif
enddef

# Update the colors in buffer "bnr" once it hasn't been changed for a moment.
def ColorsUpdateLater(bnr: number)
  UpdateStop(bnr)
  updateTimers[bnr] = timer_start(UPDATE_DELAY, (_) => ColorsUpdate(bnr))
enddef

# Show the colors in buffer "bnr", which the language server "lspserver"
# finds, and update them after the buffer is changed.
export def BufferInit(lspserver: dict<any>, bnr: number)
  if !opt.lspOptions.showDocumentColors || !lspserver.isColorProvider
      || !lspserver.featureEnabled('documentColor')
    return
  endif

  autocmd_add([{bufnr: bnr,
		event: 'TextChanged',
		group: 'LspDocumentColors',
		replace: true,
		cmd: $'ColorsUpdateLater({bnr})'}])
  ColorsUpdate(bnr)
enddef

# Stop showing the colors in buffer "bnr".  Called when the buffer is detached
# from the language server, or when the 'showDocumentColors' option is reset.
export def BufferDeInit(bnr: number)
  UpdateStop(bnr)
  SwatchesClear(bnr)
  if exists('#LspDocumentColors')
    autocmd_delete([{bufnr: bnr, group: 'LspDocumentColors'}])
  endif
enddef

# Show or stop showing the colors in all the buffers when the
# 'showDocumentColors' option is changed.
def DocumentColorsOptionsChanged()
  if opt.lspOptions.showDocumentColors == save_showDocumentColors
    return
  endif
  save_showDocumentColors = opt.lspOptions.showDocumentColors

  for binfo in getbufinfo({bufloaded: true})
    var lspserver: dict<any> = buf.BufLspServerGet(binfo.bufnr,
						    'documentColor')
    if lspserver->empty()
      continue
    endif
    if save_showDocumentColors
      BufferInit(lspserver, binfo.bufnr)
    else
      BufferDeInit(binfo.bufnr)
    endif
  endfor
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
