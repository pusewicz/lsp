vim9script

# Functions for listing and opening LSP document links

import './options.vim' as opt
import './util.vim'

# Returns true if the LSP position "a" is before the LSP position "b".
def PosBefore(a: dict<number>, b: dict<number>): bool
  return a.line < b.line || (a.line == b.line && a.character < b.character)
enddef

# Returns the text describing "link" in a location list: the link target
# (a file name for a "file:" URI) followed by the link tooltip.
def LinkText(link: dict<any>): string
  var target: string = link->get('target', '')
  if target =~? '^file:'
    target = util.LspUriToFile(target)->fnamemodify(':~:.')
  endif
  var tooltip: string = link->get('tooltip', '')

  if target->empty()
    return tooltip->empty() ? '(unresolved)' : tooltip
  endif
  return tooltip->empty() ? target : $'{target} ({tooltip})'
enddef

# Display the document "links" in buffer "bnr" in a location list, or in the
# quickfix list if the "useQuickfixForLocations" option is set.
export def ShowLinks(bnr: number, links: list<dict<any>>)
  var items: list<dict<any>> = []
  for link in links
    var rstart = link.range.start
    var rend = link.range.end
    items->add({
      bufnr: bnr,
      lnum: rstart.line + 1,
      col: util.GetLineByteFromPos(bnr, rstart) + 1,
      end_lnum: rend.line + 1,
      end_col: util.GetLineByteFromPos(bnr, rend) + 1,
      text: LinkText(link)
    })
  endfor
  items->sort((a, b) => a.lnum == b.lnum ? a.col - b.col : a.lnum - b.lnum)

  var save_winid = win_getid()
  if opt.lspOptions.useQuickfixForLocations
    setqflist([], ' ', {title: 'Document Links', items: items})
    :copen
  else
    setloclist(0, [], ' ', {title: 'Document Links', items: items})
    :lopen
  endif

  if !opt.lspOptions.keepFocusInReferences
    save_winid->win_gotoid()
  endif
enddef

# Returns the link in "links" under the cursor.  If the cursor is not on a
# link, returns the first link on the cursor line.  Returns an empty dict if
# there is no link on the cursor line.
def LinkAtCursor(links: list<dict<any>>): dict<any>
  var curpos = {
    line: line('.') - 1,
    character: util.GetCharIdxWithCompChar(getline('.'), charcol('.') - 1)
  }
  var lineLink: dict<any> = {}

  for link in links
    var rstart = link.range.start
    var rend = link.range.end
    if !PosBefore(curpos, rstart) && PosBefore(curpos, rend)
      return link
    endif
    if rstart.line <= curpos.line && curpos.line <= rend.line
	&& (lineLink->empty() || PosBefore(rstart, lineLink.range.start))
      lineLink = link
    endif
  endfor

  return lineLink
enddef

# Split the "file:" URI "uri" into the URI without the fragment and the
# 1-based line and column numbers specified by a "#L<line>[,<col>]" fragment.
# The line and column numbers default to 1.
export def ParseFileUri(uri: string): list<any>
  var [fileUri, fragment] = uri->matchlist('^\([^#]*\)#\=\(.*\)')[1 : 2]
  var m = fragment->matchlist('^L\=\(\d\+\)\%(,\(\d\+\)\)\=')
  if m->empty()
    return [fileUri, 1, 1]
  endif

  return [fileUri, max([1, m[1]->str2nr()]), max([1, m[2]->str2nr()])]
enddef

# Open the "file:" URI "uri" in a Vim window.  The user specified window
# command modifiers (e.g. topleft) are in "cmdmods".
def OpenFileUri(uri: string, cmdmods: string)
  var [fileUri, lnum, col] = ParseFileUri(uri)
  var pos = {line: lnum - 1, character: col - 1}

  util.PushCursorToTagStack()
  util.JumpToLspLocation({uri: fileUri, range: {start: pos, end: pos}},
			 cmdmods)
enddef

# Open "uri" with the default handler of the system.  Uses dist#vim9#Open()
# from the Vim runtime when available, which honors the "g:Openprg" variable.
def OpenExternalUri(uri: string)
  try
    dist#vim9#Open(uri)
    return
  catch /^Vim\%((\a\+)\)\=:E117:.*dist#vim9#Open/
  endtry

  var cmd: list<string>
  if has('win32')
    cmd = ['rundll32', 'url.dll,FileProtocolHandler', uri]
  elseif executable('xdg-open')
    cmd = ['xdg-open', uri]
  elseif executable('open')
    cmd = ['open', uri]
  else
    util.ErrMsg($'No program found to open "{uri}"')
    return
  endif

  job_start(cmd, {stoponexit: '', in_io: 'null', out_io: 'null',
		  err_io: 'null'})
enddef

# Open the target of the link under the cursor from the document "links" in
# the current buffer.  A "file:" target is opened in Vim using the window
# command modifiers in "cmdmods"; any other target is opened with the default
# handler of the system.  A link without a target is resolved first.
export def OpenLinkAtCursor(lspserver: dict<any>, links: list<dict<any>>,
			    cmdmods: string)
  var link = LinkAtCursor(links)
  if link->empty()
    util.WarnMsg('No document link found at the cursor position')
    return
  endif

  if link->get('target', '')->empty()
    link = lspserver.resolveDocumentLink(bufnr(), link)
  endif
  var target: string = link->get('target', '')
  if target->empty()
    util.WarnMsg('Document link target is not found')
    return
  endif

  if target =~? '^file:'
    OpenFileUri(target, cmdmods)
  else
    OpenExternalUri(target)
  endif
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
