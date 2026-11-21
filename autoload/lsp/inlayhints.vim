vim9script

# Functions for dealing with inlay hints

import './util.vim'
import './buffer.vim' as buf
import './options.vim' as opt
import './protocol.vim'
import './textedit.vim'
import './hover.vim'

# Initialize the highlight group and the text property type used for
# inlay hints.
export def InitOnce()
  hlset([
    {name: 'LspInlayHintsType', default: true, linksto: 'Label'},
    {name: 'LspInlayHintsParam', default: true, linksto: 'Conceal'}
  ])
  prop_type_add('LspInlayHintsType', {highlight: 'LspInlayHintsType'})
  prop_type_add('LspInlayHintsParam', {highlight: 'LspInlayHintsParam'})

  autocmd_add([{group: 'LspCmds',
	        event: 'User',
		pattern: 'LspOptionsChanged',
		cmd: 'LspInlayHintsOptionsChanged()'},
	       # The pattern of WinScrolled is a window ID, so this cannot be a
	       # buffer-local autocmd.
	       {group: 'LspCmds',
		event: 'WinScrolled',
		pattern: '*',
		cmd: 'LspInlayHintsWinScrolled()'}])
enddef

# TODO-UPDATE-COMMENT: also drops the inlay hints kept for buffer "bnr"
# ---
# Clear all the inlay hints text properties in the current buffer
def InlayHintsClear(bnr: number)
  prop_remove({type: 'LspInlayHintsType', bufnr: bnr, all: true})
  prop_remove({type: 'LspInlayHintsParam', bufnr: bnr, all: true})
  setbufvar(bnr, 'LspInlayHints', {})
enddef

# LSP inlay hints reply message handler
export def InlayHintsReply(lspserver: dict<any>, inlayHints: any,
                           inlayHintsError: dict<any>, bnr: number,
                           changedtick: number)
  # Handle inlay hints error
  if !inlayHintsError->empty()
    lspserver.traceLog($'Inlay hints failed: {inlayHintsError.message}')
    return
  endif

  # Without a result, as when the request was cancelled or the content was
  # modified, the inlay hints are left as they are.
  if inlayHints->type() != v:t_list
    return
  endif

  if mode() != 'n'
    # Update inlay hints only in normal mode.  Keep the hints shown, and ask
    # for them again when the cursor rests.
    setbufvar(bnr, 'LspInlayHintsNeedsUpdate', true)
    return
  endif

  InlayHintsClear(bnr)

  var hints: dict<dict<any>> = {}
  for hint in inlayHints
    var label = ''
    if hint.label->type() == v:t_list
      label = hint.label->copy()->map((_, v) => v.value)->join('')
    else
      label = hint.label
    endif

    # add a space before or after the label
    var padLeft: bool = hint->get('paddingLeft', false)
    var padRight: bool = hint->get('paddingRight', false)
    if padLeft
      label = $' {label}'
    endif
    if padRight
      label = $'{label} '
    endif

    var kind = hint->has_key('kind') ? hint.kind->string() : protocol.InlayHintKindType->string()
    try
      var pos: dict<number> = hint.position->copy()
      lspserver.decodePosition(bnr, pos)
      var byteIdx = util.GetLineByteFromPos(bnr, pos)
      var propType = ''
      if kind == "'type'" || kind == protocol.InlayHintKindType->string()
	propType = 'LspInlayHintsType'
      elseif kind == "'parameter'" || kind == protocol.InlayHintKindParameter->string()
	propType = 'LspInlayHintsParam'
      endif
      if propType != ''
	var id = prop_add(pos.line + 1, byteIdx + 1,
	  {type: propType, text: label, bufnr: bnr})
	hints[id->string()] = {id: id, type: propType, hint: hint,
			       resolved: false}
      endif
    catch /E966\|E964/ # Invalid lnum | Invalid col
      # Inlay hints replies arrive asynchronously and the document might have
      # been modified in the mean time.  As the reply is stale, ignore invalid
      # line number and column number errors.
    endtry
  endfor
  setbufvar(bnr, 'LspInlayHints',
	    {serverId: lspserver.id, changedtick: changedtick, hints: hints})
enddef

def HintNearCursor(lspserver: dict<any>): dict<any>
  var shown: dict<any> = bufnr()->getbufvar('LspInlayHints', {})
  if shown->empty() || shown.serverId != lspserver.id
    return {}
  endif
  var lnum = line('.')
  var curCol = col('.')
  var nearest: dict<any> = {}
  var nearestDist = -1
  for entry in shown.hints->values()
    var props = prop_list(lnum, {ids: [entry.id]})
    if props->empty() || props[0].type != entry.type
      continue
    endif
    var dist = abs(props[0].col - curCol)
    if nearestDist < 0 || dist < nearestDist
	|| (dist == nearestDist && entry.id > nearest.id)
      nearest = entry
      nearestDist = dist
    endif
  endfor
  return nearest
enddef

def HintForCommand(): list<dict<any>>
  var lspserver: dict<any> = buf.CurbufGetServerChecked('inlayHint')
  if lspserver->empty()
    return [{}, {}]
  endif
  var entry = HintNearCursor(lspserver)
  if entry->empty()
    util.WarnMsg('No inlay hint on the current line')
    return [{}, {}]
  endif
  return [lspserver, entry]
enddef

def HintResolve(lspserver: dict<any>, entry: dict<any>, missing: bool,
		Cbfunc: func)
  if !missing || entry.resolved || !lspserver.isInlayHintResolveProvider
    Cbfunc()
    return
  endif
  lspserver.inlayHintResolve(entry.hint, (resolved: dict<any>) => {
    if !resolved->empty()
      entry.hint = resolved
      entry.resolved = true
    endif
    Cbfunc()
  })
enddef

def HintTooltips(hint: dict<any>): list<any>
  var tooltips: list<any> = []
  if hint->has_key('tooltip')
    tooltips->add(hint.tooltip)
  endif
  if hint.label->type() == v:t_list
    for part in hint.label
      if part->has_key('tooltip')
	tooltips->add(part.tooltip)
      endif
    endfor
  endif
  return tooltips
enddef

def HintTooltipMissing(hint: dict<any>): bool
  if !hint->has_key('tooltip')
    return true
  endif
  if hint.label->type() == v:t_list
    for part in hint.label
      if !part->has_key('tooltip')
	return true
      endif
    endfor
  endif
  return false
enddef

def HintInfoShow(hint: dict<any>, cmdmods: string)
  var texts: list<string> = []
  var kind = 'text'
  for tooltip in HintTooltips(hint)
    var text = ''
    if tooltip->type() == v:t_string
      text = tooltip
    elseif tooltip->type() == v:t_dict
	&& tooltip->get('value', '')->type() == v:t_string
      text = tooltip->get('value', '')
      if tooltip->get('kind', '') == 'markdown'
	kind = 'lspgfm'
      endif
    endif
    if text !~ '^\_s*$'
      texts->add(text)
    endif
  endfor

  if texts->empty()
    util.WarnMsg('The inlay hint has no information to show')
    return
  endif

  var separator = kind == 'lspgfm' ? '- - -' : ''
  var lines: list<string> = []
  for text in texts
    if !lines->empty()
      lines->add(separator)
    endif
    lines->extend(text->split("\n"))
  endfor
  hover.ShowText(lines, kind, cmdmods)
enddef

def HintApply(lspserver: dict<any>, bnr: number, entry: dict<any>)
  var edits: any = entry.hint->get('textEdits', [])
  if edits->type() != v:t_list || edits->empty()
    util.WarnMsg('The inlay hint has no text edits to apply')
    return
  endif

  var decoded: list<dict<any>> = edits->deepcopy()
  for edit in decoded
    lspserver.decodeRange(bnr, edit.range)
  endfor
  textedit.ApplyTextEditsKeepProps(decoded)

  var shown: dict<any> = bnr->getbufvar('LspInlayHints', {})
  var key = entry.id->string()
  if !shown->empty() && shown.hints->get(key, {}) is entry
    shown.hints->remove(key)
    prop_remove({id: entry.id, type: entry.type, both: true, bufnr: bnr,
		 all: true})
  endif
  LspInlayHintsUpdateNow(bnr)
enddef

export def InlayHintInfo(cmdmods: string)
  var [lspserver, entry] = HintForCommand()
  if entry->empty()
    return
  endif
  HintResolve(lspserver, entry, HintTooltipMissing(entry.hint), () => {
    HintInfoShow(entry.hint, cmdmods)
  })
enddef

export def InlayHintApply()
  var [lspserver, entry] = HintForCommand()
  if entry->empty()
    return
  endif
  if !&modifiable
    util.ErrMsg('Cannot apply the inlay hint: the buffer is not modifiable')
    return
  endif
  var bnr = bufnr()
  if bnr->getbufvar('LspInlayHints').changedtick != bnr->getbufvar('changedtick')
    LspInlayHintsUpdateNow(bnr)
    util.WarnMsg('The inlay hint is out of date: the inlay hints are being updated, try again')
    return
  endif
  HintResolve(lspserver, entry, !entry.hint->has_key('textEdits'), () => {
    HintApply(lspserver, bnr, entry)
  })
enddef

# Returns true when the lines of buffer "bnr" shown in a window are within the
# lines whose inlay hints were requested last.
def VisibleLinesRequested(bnr: number): bool
  var requested: list<number> = bnr->getbufvar('LspInlayHintsLines', [])
  if requested->empty()
    return false
  endif
  var visible = util.VisibleLines(bnr, false)
  return visible->empty()
    || (visible[0] >= requested[0] && visible[1] <= requested[1])
enddef

# Timer callback to display the inlay hints.  Only the hints of the lines
# shown in a window, with a margin, are requested: the cost of a reply grows
# with the number of hints.  More are requested when the window is scrolled
# past them.
def InlayHintsTimerCb(lspserver: dict<any>, bnr: number, timerid: number)
  setbufvar(bnr, 'LspInlayHintsTimer', -1)
  if mode() != 'n'
    # A reply in Insert mode would be dropped: request the hints at the next
    # CursorHold.
    setbufvar(bnr, 'LspInlayHintsNeedsUpdate', true)
    return
  endif
  var lines = util.VisibleLines(bnr, true)
  if lines->empty()
    # Not shown in a window: request the hints when it is
    return
  endif
  setbufvar(bnr, 'LspInlayHintsNeedsUpdate', false)
  setbufvar(bnr, 'LspInlayHintsLines', lines)
  lspserver.inlayHintsShow(bnr, lines[0], lines[1])
enddef

# Update all the inlay hints.  A timer is used to throttle the updates.
def LspInlayHintsUpdate(bnr: number)
  if !bnr->getbufvar('LspInlayHintsNeedsUpdate', true)
      && VisibleLinesRequested(bnr)
    return
  endif

  var timerid = bnr->getbufvar('LspInlayHintsTimer', -1)
  if timerid != -1
    timerid->timer_stop()
    setbufvar(bnr, 'LspInlayHintsTimer', -1)
  endif

  var lspserver: dict<any> = buf.BufLspServerGet(bnr, 'inlayHint')
  if lspserver->empty()
    return
  endif

  if get(g:, 'LSPTest')
    # When running tests, update the inlay hints immediately
    InlayHintsTimerCb(lspserver, bnr, -1)
  else
    timerid = timer_start(300, function('InlayHintsTimerCb', [lspserver, bnr]))
    setbufvar(bnr, 'LspInlayHintsTimer', timerid)
  endif
enddef

# A window was scrolled or resized.  In Normal mode, request the inlay hints
# of the lines it now shows, when they were not requested yet.  In the other
# modes, the next CursorHold does.
def LspInlayHintsWinScrolled()
  if !opt.lspOptions.showInlayHints || mode() != 'n'
    return
  endif

  for bnr in util.ScrolledBufnrs()
    if exists($'#LspInlayHints#CursorHold#<buffer={bnr}>')
      LspInlayHintsUpdate(bnr)
    endif
  endfor
enddef

# Text is modified. Need to update the inlay hints.
def LspInlayHintsChanged(bnr: number)
  setbufvar(bnr, 'LspInlayHintsNeedsUpdate', true)
enddef

# Trigger an update of the inlay hints in the current buffer.
export def LspInlayHintsUpdateNow(bnr: number)
  setbufvar(bnr, 'LspInlayHintsNeedsUpdate', true)
  LspInlayHintsUpdate(bnr)
enddef

# Refresh the inlay hints from "lspserver", which asked for it with a
# "workspace/inlayHint/refresh" request: now in the buffers shown in a window,
# when in Normal mode, and in the other buffers when the cursor rests in them
# (CursorHold), as after a change.
export def Refresh(lspserver: dict<any>)
  if !opt.lspOptions.showInlayHints
    return
  endif

  for bnr in lspserver.docBufnrs->values()
    var hintServer: dict<any> = buf.BufLspServerGet(bnr, 'inlayHint')
    if hintServer->empty() || hintServer.id != lspserver.id
      continue
    endif
    LspInlayHintsChanged(bnr)
    if mode() == 'n' && !bnr->win_findbuf()->empty()
      LspInlayHintsUpdate(bnr)
    endif
  endfor
enddef

# Stop updating the inlay hints.
def LspInlayHintsUpdateStop(bnr: number)
  var timerid = bnr->getbufvar('LspInlayHintsTimer', -1)
  if timerid != -1
    timerid->timer_stop()
    setbufvar(bnr, 'LspInlayHintsTimer', -1)
  endif
enddef

# Do buffer-local initialization for displaying inlay hints
export def BufferInit(lspserver: dict<any>, bnr: number)
  if !lspserver.isInlayHintProvider && !lspserver.isClangdInlayHintsProvider
    # no support for inlay hints
    return
  endif

  # Inlays hints are disabled
  if !opt.lspOptions.showInlayHints
      || !lspserver.featureEnabled('inlayHint')
    return
  endif

  # Each autocmd replaces the one added when the buffer was attached to the
  # language servers before.
  var acmds: list<dict<any>> = []

  # Update the inlay hints (if needed) when the cursor is not moved for some
  # time.
  acmds->add({bufnr: bnr,
		event: ['CursorHold'],
		group: 'LspInlayHints',
		replace: true,
		cmd: $'LspInlayHintsUpdate({bnr})'})
  # After the text in the current buffer is modified, the inlay hints need to
  # be updated.
  acmds->add({bufnr: bnr,
		event: ['TextChanged'],
		group: 'LspInlayHints',
		replace: true,
		cmd: $'LspInlayHintsChanged({bnr})'})
  # The hints of a buffer that no window showed were not requested: request
  # them when a window shows it.
  acmds->add({bufnr: bnr,
		event: ['BufWinEnter'],
		group: 'LspInlayHints',
		replace: true,
		cmd: $'LspInlayHintsUpdate({bnr})'})
  # Editing a file should trigger an inlay hint update.
  acmds->add({bufnr: bnr,
		event: ['BufReadPost'],
		group: 'LspInlayHints',
		replace: true,
		cmd: $'LspInlayHintsUpdateNow({bnr})'})
  # Inlay hints need not be updated if a buffer is no longer active.
  acmds->add({bufnr: bnr,
		event: ['BufLeave'],
		group: 'LspInlayHints',
		replace: true,
		cmd: $'LspInlayHintsUpdateStop({bnr})'})

  # Inlay hints maybe a bit delayed if it was a sync init lsp server.
  if lspserver.syncInit
    acmds->add({bufnr: bnr,
		  event: ['User'],
		  group: 'LspAttached',
		  replace: true,
		  cmd: $'LspInlayHintsUpdateNow({bnr})'})
  endif

  autocmd_add(acmds)
enddef

# Stop updating the inlay hints in buffer "bnr" and remove the buffer-local
# inlay hint autocmds.  Called when the buffer is detached from the language
# server.  The hints are refreshed once the buffer is attached again.
export def BufferDeInit(bnr: number)
  LspInlayHintsUpdateStop(bnr)
  LspInlayHintsChanged(bnr)
  if exists('#LspInlayHints')
    autocmd_delete([{bufnr: bnr, group: 'LspInlayHints'}])
  endif
  if exists('#LspAttached')
    autocmd_delete([{bufnr: bnr, group: 'LspAttached'}])
  endif
enddef

# Track the current inlay hints enabled/disabled state.  Used when the
# "showInlayHints" option value is changed.
var save_showInlayHints = opt.lspOptions.showInlayHints

# Enable inlay hints.  For all the buffers with an attached language server
# that supports inlay hints, refresh the inlay hints.
export def InlayHintsEnable()
  opt.lspOptions.showInlayHints = true
  for binfo in getbufinfo()
    var lspservers: list<dict<any>> = buf.BufLspServersGet(binfo.bufnr)
    if lspservers->empty()
      continue
    endif
    for lspserver in lspservers
      if !lspserver.ready
	  || !lspserver.featureEnabled('inlayHint')
	  || (!lspserver.isInlayHintProvider &&
	      !lspserver.isClangdInlayHintsProvider)
	continue
      endif
      BufferInit(lspserver, binfo.bufnr)
      LspInlayHintsUpdateNow(binfo.bufnr)
    endfor
  endfor
  save_showInlayHints = true
enddef

# Disable inlay hints for the current Vim session.  Clear the inlay hints in
# all the buffers.
export def InlayHintsDisable()
  opt.lspOptions.showInlayHints = false
  for binfo in getbufinfo()
    var lspserver: dict<any> = buf.BufLspServerGet(binfo.bufnr, 'inlayHint')
    if lspserver->empty()
      continue
    endif
    LspInlayHintsUpdateStop(binfo.bufnr)
    :silent! autocmd_delete([{bufnr: binfo.bufnr, group: 'LspInlayHints'}])
    InlayHintsClear(binfo.bufnr)
  endfor
  save_showInlayHints = false
enddef

# Toggle (enable or disable) inlay hints.
export def InlayHintsToggle()
  if opt.lspOptions.showInlayHints
    InlayHintsDisable()
  else
    InlayHintsEnable()
  endif
enddef

# Some options are changed.  If 'showInlayHints' option is changed, then
# either enable or disable inlay hints.
export def LspInlayHintsOptionsChanged()
  if save_showInlayHints && !opt.lspOptions.showInlayHints
    InlayHintsDisable()
  elseif !save_showInlayHints && opt.lspOptions.showInlayHints
    InlayHintsEnable()
  endif
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
