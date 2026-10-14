vim9script

import './buffer.vim' as buf
import './codeaction.vim'
import './options.vim' as opt

# Functions related to handling LSP code lens

# Initialize the highlight group and the text property type used to show the
# code lenses.
export def InitOnce()
  hlset([{name: 'LspCodeLens', default: true, linksto: 'Comment'}])
  prop_type_add('LspCodeLens', {highlight: 'LspCodeLens'})

  autocmd_add([{group: 'LspCmds',
		event: 'User',
		pattern: 'LspOptionsChanged',
		cmd: 'LspCodeLensOptionsChanged()'}])
enddef

# Let the user select one of the resolved code lens items "codeLensItems" in
# the current buffer and run its command.
export def ProcessCodeLens(lspserver: dict<any>, codeLensItems: list<dict<any>>)
  var text: list<string> = []
  for i in codeLensItems->len()->range()
    var item = codeLensItems[i]
    text->add(printf("%d. %s\t| L%s:%s", i + 1, item.command.title,
			item.range.start.line + 1,
			getline(item.range.start.line + 1)))
  endfor

  var choice = inputlist(['Code Lens:'] + text)
  if choice < 1 || choice > codeLensItems->len()
    return
  endif

  codeaction.DoCommand(lspserver, codeLensItems[choice - 1].command)
enddef

# Run the command of the resolved code lens item in "codeLensItems", the code
# lenses of a line in the current buffer, or let the user select one when
# there are several.
export def RunCodeLens(lspserver: dict<any>, codeLensItems: list<dict<any>>)
  if codeLensItems->len() == 1
    codeaction.DoCommand(lspserver, codeLensItems[0].command)
  else
    ProcessCodeLens(lspserver, codeLensItems)
  endif
enddef

# Returns the text of the code lenses "lineItems" of line "lnum" in buffer
# "bnr" shown above the line: their titles, on one line and indented like the
# line.  Returns an empty string when none of them has a title.
def LineCodeLensText(bnr: number, lnum: number,
		     lineItems: list<dict<any>>): string
  var titles = lineItems
    ->mapnew((_, item) =>
      item.command.title->substitute('\_s\+', ' ', 'g')->trim())
    ->filter((_, title) => !title->empty())
  if titles->empty()
    return ''
  endif

  var tabstop: number = bnr->getbufvar('&tabstop')
  var indent = 0
  for c in bnr->getbufline(lnum)[0]->matchstr('^\s*')
    indent += c == "\t" ? tabstop - indent % tabstop : 1
  endfor
  return $'{repeat(' ', indent)}{titles->join(' | ')}'
enddef

# Remove the code lenses shown in buffer "bnr".
def CodeLensClear(bnr: number)
  if bnr->getbufvar('LspCodeLensShown', false)
    prop_remove({type: 'LspCodeLens', bufnr: bnr, all: true})
    setbufvar(bnr, 'LspCodeLensShown', false)
  endif
enddef

# Show the resolved code lens items "codeLensItems" of buffer "bnr" above
# their lines, in place of the ones shown before.  Only in Normal mode, as
# adding the lines above the text while typing would move it.  In another mode
# the code lenses are requested again when the cursor rests (CursorHold).
export def ShowCodeLenses(bnr: number, codeLensItems: list<dict<any>>)
  if !opt.lspOptions.showCodeLens
    return
  endif
  if mode() != 'n'
    CodeLensChanged(bnr)
    return
  endif

  CodeLensClear(bnr)

  var itemsByLine: dict<list<dict<any>>> = {}
  for item in codeLensItems
    var lnum = item.range.start.line + 1
    if !itemsByLine->has_key(lnum)
      itemsByLine[lnum] = []
    endif
    itemsByLine[lnum]->add(item)
  endfor

  var lastlnum: number = bnr->getbufinfo()[0].linecount
  for [key, lineItems] in itemsByLine->items()
    var lnum = key->str2nr()
    if lnum > lastlnum
      continue
    endif
    lineItems->sort((a, b) => a.range.start.character - b.range.start.character)
    var text = LineCodeLensText(bnr, lnum, lineItems)
    if text->empty()
      continue
    endif
    prop_add(lnum, 0, {type: 'LspCodeLens', bufnr: bnr, text_align: 'above',
		       text: text})
    setbufvar(bnr, 'LspCodeLensShown', true)
  endfor
enddef

# Request the code lenses of buffer "bnr" to show them, if they need to be
# updated after a change.
def CodeLensUpdate(bnr: number)
  if !bnr->getbufvar('LspCodeLensNeedsUpdate', true)
    return
  endif

  var lspserver: dict<any> = buf.BufLspServerGet(bnr, 'codeLens')
  if lspserver->empty()
    return
  endif

  setbufvar(bnr, 'LspCodeLensNeedsUpdate', false)
  lspserver.codeLensShow(bnr)
enddef

# The text of buffer "bnr" changed, so its code lenses need to be updated.
def CodeLensChanged(bnr: number)
  setbufvar(bnr, 'LspCodeLensNeedsUpdate', true)
enddef

# Request the code lenses of buffer "bnr" to show them now.
def CodeLensUpdateNow(bnr: number)
  CodeLensChanged(bnr)
  CodeLensUpdate(bnr)
enddef

# Refresh the code lenses from "lspserver", which asked for it with a
# "workspace/codeLens/refresh" request: now in the buffers shown in a window,
# when in Normal mode, and in the other buffers when the cursor rests in them
# (CursorHold), as after a change.
export def Refresh(lspserver: dict<any>)
  if !opt.lspOptions.showCodeLens
    return
  endif

  for bnr in lspserver.docBufnrs->values()
    var codeLensServer: dict<any> = buf.BufLspServerGet(bnr, 'codeLens')
    if codeLensServer->empty() || codeLensServer.id != lspserver.id
      continue
    endif
    CodeLensChanged(bnr)
    if mode() == 'n' && !bnr->win_findbuf()->empty()
      CodeLensUpdate(bnr)
    endif
  endfor
enddef

# Show the code lenses from "lspserver" in buffer "bnr" above their lines, and
# keep them updated, if the "showCodeLens" option is set.
export def BufferInit(lspserver: dict<any>, bnr: number)
  if !opt.lspOptions.showCodeLens || !lspserver.isCodeLensProvider
    return
  endif

  # Each autocmd replaces the one added when the buffer was attached to the
  # language servers before.
  var acmds: list<dict<any>> = []
  # Update the code lenses after a change when the cursor rests.
  acmds->add({bufnr: bnr,
	      event: 'TextChanged',
	      group: 'LspCodeLens',
	      replace: true,
	      cmd: $'CodeLensChanged({bnr})'})
  acmds->add({bufnr: bnr,
	      event: 'CursorHold',
	      group: 'LspCodeLens',
	      replace: true,
	      cmd: $'CodeLensUpdate({bnr})'})
  # Reloading the buffer removes the code lenses.
  acmds->add({bufnr: bnr,
	      event: 'BufReadPost',
	      group: 'LspCodeLens',
	      replace: true,
	      cmd: $'CodeLensUpdateNow({bnr})'})
  autocmd_add(acmds)

  CodeLensChanged(bnr)
  if !bnr->win_findbuf()->empty()
    CodeLensUpdate(bnr)
  endif
enddef

# Remove the code lenses shown in buffer "bnr" and stop updating them.  Called
# when the buffer is detached from the language server, or when the
# "showCodeLens" option is reset.
export def BufferDeInit(bnr: number)
  CodeLensClear(bnr)
  CodeLensChanged(bnr)
  if exists('#LspCodeLens')
    autocmd_delete([{bufnr: bnr, group: 'LspCodeLens'}])
  endif
enddef

# Track the "showCodeLens" option value, to act on its change.
var save_showCodeLens: bool = opt.lspOptions.showCodeLens

# Some options are changed.  When the "showCodeLens" option is changed, start
# or stop showing the code lenses in every buffer with a language server
# providing them.
def LspCodeLensOptionsChanged()
  if opt.lspOptions.showCodeLens == save_showCodeLens
    return
  endif
  save_showCodeLens = opt.lspOptions.showCodeLens

  for binfo in getbufinfo({bufloaded: true})
    var lspserver: dict<any> = buf.BufLspServerGet(binfo.bufnr, 'codeLens')
    if lspserver->empty()
      continue
    endif
    if save_showCodeLens
      BufferInit(lspserver, binfo.bufnr)
    else
      BufferDeInit(binfo.bufnr)
    endif
  endfor
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
