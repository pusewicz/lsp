vim9script

# Functions for dealing with call hierarchy (incoming/outgoing calls)

import './util.vim'
import './buffer.vim' as buf

# Jump to the location of the symbol under the cursor in the call hierarchy
# tree window.
def CallHierarchyItemJump()
  var item: dict<any> = w:LspCallHierItemMap[line('.')].item
  util.JumpToLspLocation(item, '')
enddef

# Refresh the call hierarchy tree for the symbol at index "idx".
def CallHierarchyTreeItemRefresh(idx: number)
  var treeItem: dict<any> = w:LspCallHierItemMap[idx]

  if treeItem.open
    # Already retrieved the children for this item
    return
  endif

  if treeItem->has_key('children')
    CallHierarchyTreeItemExpand(treeItem)
    return
  endif

  # First time retrieving the children for the item at index "idx"
  var lspserver = buf.BufLspServerGet(w:LspBufnr, 'callHierarchy')
  if lspserver->empty() || !lspserver.running
    return
  endif

  var winid = win_getid()
  var incoming: bool = w:LspCallHierIncoming
  var AddChildren = (calls: list<dict<any>>) => {
    # Drop the calls when the user left the tree window, or the item is not
    # displayed in it any more or already has its children
    if win_getid() != winid || w:LspCallHierIncoming != incoming
	|| treeItem->has_key('children')
	|| w:LspCallHierItemMap->indexof((_, v) => v is treeItem) == -1
      return
    endif

    treeItem.children = calls->mapnew((_, c) =>
      ({item: incoming ? c.from : c.to, open: false}))
    CallHierarchyTreeItemExpand(treeItem)
  }
  if incoming
    lspserver.getIncomingCalls(treeItem.item, AddChildren)
  else
    lspserver.getOutgoingCalls(treeItem.item, AddChildren)
  endif
enddef

# Display the children of "treeItem" in the call hierarchy tree in the
# current window.
def CallHierarchyTreeItemExpand(treeItem: dict<any>)
  # Clear and redisplay the tree in the window
  treeItem.open = true
  var save_cursor = getcurpos()
  CallHierarchyTreeRefresh()
  setpos('.', save_cursor)
enddef

# Open the call hierarchy tree item under the cursor
def CallHierarchyTreeItemOpen()
  CallHierarchyTreeItemRefresh(line('.'))
enddef

# Refresh the entire call hierarchy tree
def CallHierarchyTreeRefreshCmd()
  w:LspCallHierItemMap[2].open = false
  w:LspCallHierItemMap[2]->remove('children')
  CallHierarchyTreeItemRefresh(2)
enddef

# Display the incoming call hierarchy tree
def CallHierarchyTreeIncomingCmd()
  w:LspCallHierItemMap[2].open = false
  w:LspCallHierItemMap[2]->remove('children')
  w:LspCallHierIncoming = true
  CallHierarchyTreeItemRefresh(2)
enddef

# Display the outgoing call hierarchy tree
def CallHierarchyTreeOutgoingCmd()
  w:LspCallHierItemMap[2].open = false
  w:LspCallHierItemMap[2]->remove('children')
  w:LspCallHierIncoming = false
  CallHierarchyTreeItemRefresh(2)
enddef

# Close the call hierarchy tree item under the cursor
def CallHierarchyTreeItemClose()
  var treeItem: dict<any> = w:LspCallHierItemMap[line('.')]
  treeItem.open = false
  var save_cursor = getcurpos()
  CallHierarchyTreeRefresh()
  setpos('.', save_cursor)
enddef

# Recursively add the call hierarchy items to w:LspCallHierItemMap
def CallHierarchyTreeItemShow(incoming: bool, treeItem: dict<any>, pfx: string)
  var item = treeItem.item
  var treePfx: string
  if treeItem.open && treeItem->has_key('children')
    treePfx = has('gui_running') ? '▼' : '-'
  else
    treePfx = has('gui_running') ? '▶' : '+'
  endif
  var fname = util.LspUriToFile(item.uri)
  var s = $'{pfx}{treePfx} {item.name} ({fname->fnamemodify(":t")} [{fname->fnamemodify(":h")}])'
  append('$', s)
  w:LspCallHierItemMap->add(treeItem)
  if treeItem.open && treeItem->has_key('children')
    for child in treeItem.children
      CallHierarchyTreeItemShow(incoming, child, $'{pfx}  ')
    endfor
  endif
enddef

def CallHierarchyTreeRefresh()
  :setlocal modifiable
  :silent! :%d _

  setline(1, $'# {w:LspCallHierIncoming ? "Incoming calls to" : "Outgoing calls from"} "{w:LspCallHierarchyTree.item.name}"')
  w:LspCallHierItemMap = [{}, {}]
  CallHierarchyTreeItemShow(w:LspCallHierIncoming, w:LspCallHierarchyTree, '')
  :setlocal nomodifiable
enddef

# Number of the call hierarchy buffer
var callHierBufnr: number = -1

def CallHierarchyTreeShow(incoming: bool, prepareItem: dict<any>,
			  items: list<dict<any>>)
  var save_bufnr = bufnr()
  var wid = callHierBufnr->bufwinid()
  if wid != -1
    wid->win_gotoid()
  else
    var bnr: number = util.ScratchWindowOpen(callHierBufnr,
					     'LSP-CallHierarchy')
    :setlocal nonumber nornu
    :setlocal fdc=0 signcolumn=no

    if bnr != callHierBufnr
      callHierBufnr = bnr
      :nnoremap <buffer> <CR> <ScriptCmd>CallHierarchyItemJump()<CR>
      :nnoremap <buffer> - <ScriptCmd>CallHierarchyTreeItemOpen()<CR>
      :nnoremap <buffer> + <ScriptCmd>CallHierarchyTreeItemClose()<CR>
      :command -buffer LspCallHierarchyRefresh CallHierarchyTreeRefreshCmd()
      :command -buffer LspCallHierarchyIncoming CallHierarchyTreeIncomingCmd()
      :command -buffer LspCallHierarchyOutgoing CallHierarchyTreeOutgoingCmd()

      :syntax match Comment '^#.*$'
      :syntax match Directory '(.*)$'
    endif
  endif

  w:LspBufnr = save_bufnr
  w:LspCallHierIncoming = incoming
  w:LspCallHierarchyTree = {}
  w:LspCallHierarchyTree.item = prepareItem
  w:LspCallHierarchyTree.open = true
  w:LspCallHierarchyTree.children = []
  for item in items
    w:LspCallHierarchyTree.children->add({item: incoming ? item.from : item.to, open: false})
  endfor

  CallHierarchyTreeRefresh()

  :setlocal nomodified
  :setlocal nomodifiable
enddef

# Let the user select one of the call hierarchy items "items" and return it,
# or an empty Dict when there are none or the user cancels.
def SelectCallHierarchyItem(items: list<dict<any>>): dict<any>
  if items->len() <= 1
    return items->get(0, {})
  endif

  var choices: list<string> = ['Select a Call Hierarchy Item:']
  for i in items->len()->range()
    choices->add(printf("%d. %s", i + 1, items[i].name))
  endfor
  var choice = choices->inputlist()
  if choice < 1 || choice >= choices->len()
    return {}
  endif
  return items[choice - 1]
enddef

# Display the tree of the incoming calls to the symbol under the cursor if
# "incoming" is true, otherwise of the outgoing calls from it.  Nothing is
# displayed when the user moves on before the replies arrive.
def ShowCalls(lspserver: dict<any>, incoming: bool)
  var noCallsMsg = incoming ? 'No incoming calls' : 'No outgoing calls'
  var reqctx = util.RequestContextGet('cursor')
  lspserver.prepareCallHierarchy((items: list<dict<any>>) => {
    var prepareItem = SelectCallHierarchyItem(items)
    if prepareItem->empty()
      util.WarnMsg(noCallsMsg)
      return
    endif

    var ShowTree = (calls: list<dict<any>>) => {
      if !util.RequestContextMatches(reqctx)
	return
      endif
      if calls->empty()
	util.WarnMsg(noCallsMsg)
	return
      endif
      CallHierarchyTreeShow(incoming, prepareItem, calls)
    }
    if incoming
      lspserver.getIncomingCalls(prepareItem, ShowTree)
    else
      lspserver.getOutgoingCalls(prepareItem, ShowTree)
    endif
  })
enddef

# Display the tree of the incoming calls to the symbol under the cursor.
export def IncomingCalls(lspserver: dict<any>)
  ShowCalls(lspserver, true)
enddef

# Display the tree of the outgoing calls from the symbol under the cursor.
export def OutgoingCalls(lspserver: dict<any>)
  ShowCalls(lspserver, false)
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
