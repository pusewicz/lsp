vim9script

# Functions for the inline completions of a language server
# (textDocument/inlineCompletion): suggestions for the text at the cursor,
# shown as ghost text in Insert mode.  They are independent of the completion
# popup menu, and hidden while it is shown.

import './options.vim' as opt
import './util.vim'
import './buffer.vim' as buf
import './codeaction.vim'
import './snippet.vim'

# InlineCompletionTriggerKind
const TRIGGER_INVOKED = 1
const TRIGGER_AUTOMATIC = 2

# The prefix of the names of the functions of this script, to call them from
# the keys that accept an inline completion
const SID: string = expand('<SID>')

# The inline completions of the last reply, about line "lnum" of buffer
# "bnr" and requested from "lspserver" (see NormalizeItem()).  "current" is
# the one shown, or would be if it fit the text, and "shown" is what is shown
# of it (see Fit()), empty when nothing is.  "invoked" is true when they were
# asked for, and "cycle" is the direction of a Cycle() waiting for such a
# reply.
var session: dict<any> = {
  bnr: -1,
  lnum: 0,
  lspserver: {},
  items: [],
  current: {},
  shown: {},
  invoked: false,
  cycle: 0
}

# The timer of the inline completion request made while typing, and the
# editor state (see util.RequestContextGet()) that the request to be made, or
# waiting for its reply, is about
var requestTimer: number = -1
var requestCtx: dict<number> = {}

# The text that the keys returned by AcceptKeys() insert, the inline
# completion it is from, the text of the inline completion left after it and
# the number of bytes after the cursor that are left for it to replace
var acceptText: string = ''
var acceptItem: dict<any> = {}
var acceptRest: string = ''
var acceptReplacedLen: number = 0

# Define the highlight group and the text property type of the ghost text,
# and the autocmd group of the inline completions, with the autocmd that
# hides them when Insert mode ends.  InsertLeave is not triggered when CTRL-C
# ends it.  Insert mode completion and the expression register don't end it.
export def InitOnce()
  hlset([{name: 'LspInlineCompletion', default: true, linksto: 'Comment'}])
  prop_type_add('LspInlineCompletion', {highlight: 'LspInlineCompletion'})
  autocmd_add([{group: 'LspInlineCompletion',
		event: 'ModeChanged',
		pattern: 'i*:[^ic]*',
		cmd: 'Dismiss()'}])
enddef

# Add the autocmds that request and show the inline completions of the
# language server "lspserver" in buffer "bnr".
export def BufferInit(lspserver: dict<any>, bnr: number)
  if !lspserver.isInlineCompletionProvider
      || !lspserver.featureEnabled('inlineCompletion')
    return
  endif

  var acmds: list<dict<any>> = [
    {event: ['InsertEnter', 'CursorMovedI', 'TextChangedI', 'TextChangedP',
	     'CompleteDone'],
     cmd: $'OnChange({bnr})'},
    {event: 'CompleteChanged', cmd: 'Update()'},
    {event: ['BufLeave', 'WinLeave'], cmd: 'Dismiss()'}
  ]
  autocmd_add(acmds->map((_, acmd) => acmd->extend({bufnr: bnr,
						    replace: true,
						    group: 'LspInlineCompletion'})))
enddef

# Remove the inline completion autocmds of buffer "bnr", and the inline
# completion shown in it.  Called when the buffer is detached from its
# language servers.
export def BufferDeInit(bnr: number)
  if session.bnr == bnr
    Dismiss()
  endif
  if exists('#LspInlineCompletion')
    autocmd_delete([{bufnr: bnr, group: 'LspInlineCompletion'}])
  endif
enddef

# Handle a change of the text or of the cursor in Insert mode in buffer "bnr",
# and the start and the end of Insert mode completion: show what is left of
# the inline completion shown, when the change typed its text, and request
# new ones with the "autoInlineCompletion" option.  A request about the
# current text and cursor is kept: Vim triggers the autocmds only after the
# keys typed before the request.
def OnChange(bnr: number)
  Update()
  if !requestCtx->empty() && util.RequestContextMatches(requestCtx)
    return
  endif
  CancelRequest()
  session.cycle = 0
  if !opt.lspOptions.autoInlineCompletion
    return
  endif
  requestCtx = util.RequestContextGet('cursor', bnr)
  requestTimer = timer_start(opt.lspOptions.inlineCompletionDelay, (_) => {
    requestTimer = -1
    requestCtx = {}
    Request(bnr, TRIGGER_AUTOMATIC)
  })
enddef

# Request the inline completions at the cursor in buffer "bnr" from its
# language server.  "triggerKind" is the InlineCompletionTriggerKind.  Not
# done outside Insert mode, in another buffer, or during Insert mode
# completion.
def Request(bnr: number, triggerKind: number)
  if mode() !=# 'i' || bufnr() != bnr
    return
  endif
  var lspserver: dict<any> = buf.BufLspServerGet(bnr, 'inlineCompletion')
  if lspserver->empty() || !lspserver.running
    return
  endif

  if session.bnr != bnr
    ForgetItems()
  endif
  session.bnr = bnr
  session.lspserver = lspserver
  requestCtx = util.RequestContextGet('cursor', bnr)
  lspserver.getInlineCompletion(triggerKind)
enddef

# Cancel the inline completion request about to be made or waiting for its
# reply, if any.
def CancelRequest()
  requestCtx = {}
  if requestTimer != -1
    requestTimer->timer_stop()
    requestTimer = -1
  endif
  if !session.lspserver->empty()
    session.lspserver.cancelInlineCompletion(session.bnr)
  endif
enddef

# Process the reply "reply" of the language server "lspserver" to the inline
# completion request made with "triggerKind", which is about the current
# editor state: show the first inline completion that fits the text.  After a
# Cycle(), show the one after the inline completion shown before.
# Result: InlineCompletionItem[] | InlineCompletionList | null
export def InlineCompletionReply(lspserver: dict<any>, reply: any,
				 error: dict<any>, triggerKind: number)
  requestCtx = {}
  if !error->empty() || mode() !~# '^i'
    return
  endif

  var items: any = reply
  if items->type() == v:t_dict
    items = items->get('items', [])
  endif
  if items->type() != v:t_list
    items = []
  endif

  var bnr: number = bufnr()
  var lnum: number = line('.')
  var prev: dict<any> = session.current
  var cycle: number = session.cycle
  Clear()
  session = {
    bnr: bnr,
    lnum: lnum,
    lspserver: lspserver,
    items: items
      ->mapnew((_, item) => NormalizeItem(lspserver, bnr, lnum, item))
      ->filter((_, item) => !item->empty()),
    current: {},
    shown: {},
    invoked: triggerKind == TRIGGER_INVOKED,
    cycle: 0
  }

  if cycle != 0 && !prev->empty()
    var fitting: list<dict<any>> = FittingItems()
    var idx: number = fitting->indexof((_, item) => item.text ==# prev.text)
    if idx != -1
      session.current = fitting[(idx + cycle + fitting->len()) % fitting->len()]
    endif
  endif

  Update()
enddef

# Return the inline completion item "item" of a reply of the language server
# "lspserver" about line "lnum" of buffer "bnr", which has the cursor, in the
# form used to show and accept it.  "text" is its text, and "filterText" the
# text that must start with the text typed in its range.  The range, which is
# in the line, is kept as the byte index "start" of its start, the line text
# "prefix" before it, which must not change, and the number of bytes
# "endFromEol" from its end to the end of the line, which don't change while
# the text in the range is typed.  "command" is the command to execute after
# the item is accepted.  Returns an empty dict for an item that isn't valid
# or has a range in another line.
def NormalizeItem(lspserver: dict<any>, bnr: number, lnum: number,
		  item: any): dict<any>
  if item->type() != v:t_dict
    return {}
  endif

  # interface InlineCompletionItem
  var insertText: any = item->get('insertText', null)
  var text: string
  if insertText->type() == v:t_string
    text = insertText
  elseif insertText->type() == v:t_dict
      && insertText->get('kind', '') ==# 'snippet'
      && insertText->get('value', null)->type() == v:t_string
    # interface StringValue
    text = snippet.SnippetToText(insertText.value)
  else
    return {}
  endif
  text = text->substitute("\r\n\\=", "\n", 'g')

  var line: string = getline(lnum)
  var start: number = col('.') - 1
  var end: number = start
  var range: any = item->get('range', null)
  if range != null
    if range->type() != v:t_dict
	|| range->get('start', null)->type() != v:t_dict
	|| range->get('end', null)->type() != v:t_dict
	|| range.start->get('line', -1) != lnum - 1
	|| range.end->get('line', -1) != lnum - 1
      return {}
    endif
    var r: dict<dict<number>> = {
      start: {line: lnum - 1, character: range.start->get('character', 0)},
      end: {line: lnum - 1, character: range.end->get('character', 0)}
    }
    lspserver.decodeRange(bnr, r)
    start = util.GetLineByteFromPos(bnr, r.start)
    end = util.GetLineByteFromPos(bnr, r.end)
    if end < start
      return {}
    endif
  endif

  var filterText: any = item->get('filterText', null)
  var command: any = item->get('command', null)
  return {
    text: text,
    filterText: filterText->type() == v:t_string ? filterText : text,
    start: start,
    prefix: line->strpart(0, start),
    endFromEol: line->len() - end,
    command: command->type() == v:t_dict ? command : {}
  }
enddef

# Return how the inline completion "item" (see NormalizeItem()) fits the line
# text "line" with the cursor at byte index "col": "rest" is its text after
# the text typed before the cursor, "existing" the characters after the
# cursor that it replaces, and "matched" the byte index in "rest" of each of
# them.  Returns an empty dict when it doesn't fit: the text before its range
# changed, the cursor is not in its range, the typed text doesn't start its
# text, it doesn't keep the characters it replaces, or it adds nothing.
def Fit(item: dict<any>, line: string, col: number): dict<any>
  if line->strpart(0, item.start) !=# item.prefix
    return {}
  endif
  var end: number = line->len() - item.endFromEol
  if col < item.start || col > end
    return {}
  endif

  var typed: string = line->strpart(item.start, col - item.start)
  if item.text->stridx(typed) != 0 || item.filterText->stridx(typed) != 0
    return {}
  endif

  var rest: string = item.text->strpart(typed->len())
  var existing: list<string> = line->strpart(col, end - col)->split('\zs')
  if rest->len() == end - col
    return {}
  endif
  var matched: list<number> = MatchCharacters(existing,
					      rest->split("\n", true)[0])
  if matched->len() != existing->len()
    return {}
  endif

  return {rest: rest, existing: existing, matched: matched}
enddef

# Return the byte index in "text" of each of the characters "chars", in the
# same order, matching each one with its last possible occurrence.  Returns
# fewer indexes than characters when "text" doesn't contain them all in that
# order.
def MatchCharacters(chars: list<string>, text: string): list<number>
  var matched: list<number> = []
  var end: number = text->len()
  for ch in chars->copy()->reverse()
    var idx: number = end < ch->len() ? -1
      : text->strridx(ch, end - ch->len())
    if idx == -1
      break
    endif
    matched->insert(idx)
    end = idx
  endfor
  return matched
enddef

# Return the inline completions that fit the text at the cursor.
def FittingItems(): list<dict<any>>
  var line: string = getline('.')
  var col: number = col('.') - 1
  return session.items->copy()
    ->filter((_, item) => !Fit(item, line, col)->empty())
enddef

# Return what Fit() returns for the inline completion shown, for the text at
# the cursor, or an empty dict when none is shown.
def ShownFit(): dict<any>
  if session.shown->empty() || mode() !=# 'i' || bufnr() != session.bnr
      || line('.') != session.lnum
    return {}
  endif
  return Fit(session.current, getline('.'), col('.') - 1)
enddef

# Show the inline completion that fits the text at the cursor as ghost text,
# instead of the one shown before: the inline completion shown before if it
# still fits, else the first one that fits.  Nothing is shown outside Insert
# mode, in another buffer or line than the one of the inline completions, or
# during Insert mode completion.
def Update()
  Clear()
  if session.items->empty() || mode() !=# 'i' || pumvisible()
      || bufnr() != session.bnr || line('.') != session.lnum
    return
  endif

  var line: string = getline('.')
  var col: number = col('.') - 1
  var fit: dict<any> = session.current->empty() ? {}
    : Fit(session.current, line, col)
  if fit->empty()
    session.current = {}
    for item in session.items
      fit = Fit(item, line, col)
      if !fit->empty()
	session.current = item
	break
      endif
    endfor
  endif
  if fit->empty()
    return
  endif

  ShowGhostText(fit, line, col)
  session.shown = fit
enddef

# Show "fit" (see Fit()) as ghost text in the cursor line "line", with the
# cursor at byte index "col": the first line of its text in the line, around
# the characters it replaces, and the other lines below it.
def ShowGhostText(fit: dict<any>, line: string, col: number)
  var lnum: number = line('.')
  var lines: list<string> = fit.rest->split("\n", true)
  # The text of the line as shown up to the ghost text, to expand its tabs
  var shown: string = line->strpart(0, col)
  var byteIdx: number = col
  var start: number = 0
  for i in range(fit.existing->len())
    shown = AddGhostText(lnum, byteIdx,
			 lines[0]->strpart(start, fit.matched[i] - start), shown)
    shown ..= fit.existing[i]
    byteIdx += fit.existing[i]->len()
    start = fit.matched[i] + fit.existing[i]->len()
  endfor
  AddGhostText(lnum, byteIdx, lines[0]->strpart(start), shown)

  for text in lines[1 :]
    # An empty virtual text is not shown
    prop_add(lnum, 0, {type: 'LspInlineCompletion',
		       text: text->empty() ? ' ' : ExpandTabs(text, 0),
		       text_align: 'below'})
  endfor
enddef

# Add the ghost text "text" before byte index "byteIdx" of line "lnum", which
# is shown as "shown" up to there.  Returns "shown" with the ghost text.
def AddGhostText(lnum: number, byteIdx: number, text: string,
		 shown: string): string
  if text->empty()
    return shown
  endif
  var expanded: string = ExpandTabs(text, shown->strdisplaywidth())
  prop_add(lnum, byteIdx + 1, {type: 'LspInlineCompletion', text: expanded})
  return shown .. expanded
enddef

# Return "text" with its tabs replaced with the spaces that they are shown as
# when it starts at screen column "vcol".  A virtual text shows a tab as a
# space.
def ExpandTabs(text: string, vcol: number): string
  if text->stridx("\t") == -1
    return text
  endif
  var expanded: string = ''
  var col: number = vcol
  for ch in text->split('\zs')
    var width: number = ch->strdisplaywidth(col)
    expanded ..= ch == "\t" ? repeat(' ', width) : ch
    col += width
  endfor
  return expanded
enddef

# Remove the ghost text of the inline completion shown, if any.
def Clear()
  if !session.shown->empty() && session.bnr->bufloaded()
    prop_remove({type: 'LspInlineCompletion', bufnr: session.bnr, all: true})
  endif
  session.shown = {}
enddef

# Forget the inline completions, and remove the one shown.
def ForgetItems()
  Clear()
  session.items = []
  session.current = {}
  session.invoked = false
  session.cycle = 0
enddef

# Hide the inline completion shown, and forget the inline completions until
# the text or the cursor changes.  Cancel the request for new ones.
export def Dismiss()
  CancelRequest()
  ForgetItems()
enddef

# Ask the language server of the current buffer for the inline completions at
# the cursor.
export def Trigger()
  CancelRequest()
  session.cycle = 0
  Request(bufnr(), TRIGGER_INVOKED)
enddef

# Show the next inline completion that fits the text at the cursor when "dir"
# is 1, or the previous one when it is -1.  When the inline completions were
# requested while typing, ask the language server for them first, as it may
# have replied with only one.
export def Cycle(dir: number)
  if mode() !=# 'i'
    return
  endif
  if !session.invoked || bufnr() != session.bnr || line('.') != session.lnum
    CancelRequest()
    session.cycle = dir
    Request(bufnr(), TRIGGER_INVOKED)
    return
  endif

  var fitting: list<dict<any>> = FittingItems()
  if fitting->empty()
    return
  endif
  var idx: number = fitting->indexof((_, item) => item is session.current)
  if idx == -1
    # None is shown: show the first or the last one
    idx = dir > 0 ? -1 : 0
  endif
  session.current = fitting[(idx + dir + fitting->len()) % fitting->len()]
  Update()
enddef

# Returns true when an inline completion is shown.
export def Visible(): bool
  return !ShownFit()->empty()
enddef

# Return the keys that accept the part "what" of the inline completion shown:
# "all" of it, its next "word" or the rest of its "line" (the next line when
# nothing is left of the line).  Returns an empty string when none is shown.
# The keys delete the characters after the cursor that the part replaces,
# insert it literally with the expression register, and then call
# Accepted().
export def AcceptKeys(what: string): string
  var fit: dict<any> = ShownFit()
  if fit->empty()
    return ''
  endif

  var rest: string = fit.rest
  var len: number = rest->len()
  if what ==# 'word'
    # White space and line breaks, and then keyword characters or other
    # characters that are not white space ("." doesn't match a line break)
    len = rest->matchstr('^\_s*\%(\k\+\|\%(\_s\@!\k\@!.\)\+\)\=')->len()
  elseif what ==# 'line'
    var lines: list<string> = rest->split("\n", true)
    len = lines[0]->empty() && lines->len() > 1 ? 1 + lines[1]->len()
						  : lines[0]->len()
  endif
  if len == 0
    return ''
  endif

  acceptText = rest->strpart(0, len)
  acceptItem = session.current
  acceptRest = rest->strpart(len)
  var deleted: number = fit.matched->copy()->filter((_, i) => i < len)->len()
  acceptReplacedLen = fit.existing[deleted :]->join('')->len()
  var keys: string = repeat("\<Del>", deleted)
    .. $"\<C-R>\<C-O>={SID}AcceptedText()\<CR>"
  if acceptText =~ "\n$"
    # The expression register inserts a text ending in a line break as lines
    # above the cursor line.  Add a character and remove it after.
    acceptText ..= 'x'
    keys ..= "\<BS>"
  endif
  var all: number = len == rest->len() ? 1 : 0
  return keys .. $"\<Cmd>call {SID}Accepted({all})\<CR>"
enddef

# Return the text that the keys returned by AcceptKeys() insert.
def AcceptedText(): string
  return acceptText
enddef

# Handle the end of the keys returned by AcceptKeys().  When "all" of the
# inline completion was inserted, forget the inline completions and execute
# its command.  Otherwise, show the rest of it at the cursor, which can be in
# another line now.
def Accepted(all: bool)
  var item: dict<any> = acceptItem
  acceptText = ''
  acceptItem = {}
  if item->empty()
    return
  endif
  if all
    var lspserver: dict<any> = session.lspserver
    ForgetItems()
    if !item.command->empty()
      codeaction.DoCommand(lspserver, item.command)
    endif
    return
  endif

  var line: string = getline('.')
  var col: number = col('.') - 1
  var rest: dict<any> = {
    text: acceptRest,
    filterText: acceptRest,
    start: col,
    prefix: line->strpart(0, col),
    endFromEol: line->len() - col - acceptReplacedLen,
    command: item.command
  }
  Clear()
  session.lnum = line('.')
  session.items = [rest]
  session.current = rest
  Update()
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
