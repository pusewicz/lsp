vim9script

# Functions for on-type formatting (textDocument/onTypeFormatting).  As the
# user types, when a character the server designates as a trigger character
# is inserted, request formatting edits for the surrounding text and apply
# them.  Opt-in via the 'onTypeFormatting' option (see options.vim).
#
# The server assumes that the trigger character was just inserted before the
# cursor.  For a "\n" trigger, clangd replaces the text between the previous
# line and the cursor with the indent of the new line.  So a trigger character
# is only reported when the user typed it and the text change inserted it
# before the cursor.  The text before the cursor or a change of the cursor
# line doesn't tell what was typed: Vim triggers TextChangedI right after "cw"
# deleted a word, and the cursor can move to another line in Insert mode.

import './options.vim' as opt
import './buffer.vim' as buf

# The trigger character the user typed last, until the text change it makes
# is handled.  Only one buffer can be in Insert mode, so one is enough.
#   bnr: buffer number
#   ch: the typed character
#   lnum: the cursor line before the character was inserted
#   lineCount: the number of lines in the buffer before the character was
#              inserted
var typedChar: dict<any> = {}

# Pre-create the (empty) augroup used for the buffer-local trigger autocmds.
export def InitOnce()
  augroup LspOnTypeFormatting
    autocmd!
  augroup END
enddef

# Remember that character "ch" is about to be inserted at the cursor in
# buffer "bnr".
def SetTypedChar(bnr: number, ch: string)
  typedChar = {bnr: bnr, ch: ch, lnum: line('.'), lineCount: line('$')}
enddef

# Handle the start of Insert mode (InsertEnter): nothing has been typed yet.
def OnInsertEnter()
  typedChar = {}
enddef

# Handle a key about to be processed in buffer "bnr" (KeyInputPre).  Enter and
# CTRL-J insert a newline, which InsertCharPre doesn't report.  Any other key
# forgets the previously typed character, because the key typed last decides
# whether a trigger character was typed; InsertCharPre, which is triggered
# after this, records a typed character.
def OnKeyInputPre(bnr: number)
  if mode() !~# '^[iR]'
    return
  endif

  if v:char == "\r" || v:char == "\n"
    SetTypedChar(bnr, "\n")
  else
    typedChar = {}
  endif
enddef

# Handle a character typed in Insert mode in buffer "bnr" (InsertCharPre).
def OnInsertCharPre(bnr: number)
  SetTypedChar(bnr, v:char)
enddef

# Return true if the last text change inserted the newline described by
# "typed" (see "typedChar") before the cursor: the cursor is on the next line,
# after nothing but indent, and one line was added.
def NewlineInserted(typed: dict<any>): bool
  return line('.') == typed.lnum + 1
    && line('$') == typed.lineCount + 1
    && getline('.')->strpart(0, col('.') - 1) =~ '^\s*$'
enddef

# Return true if the last text change inserted the character described by
# "typed" (see "typedChar") right before the cursor.  The column isn't
# checked, since Vim can reindent the line for the character (e.g. "}" with
# 'cindent').
def CharInserted(typed: dict<any>): bool
  var len = typed.ch->len()
  var col = col('.')
  return line('.') == typed.lnum && col > len
    && getline('.')->strpart(col - 1 - len, len) ==# typed.ch
enddef

# Handle a text change in Insert mode in buffer "bnr" (TextChangedI): if the
# change inserted the character the user just typed and it is one of the
# server's on-type formatting trigger characters, request on-type formatting
# for it.
def OnTypeFormat(bnr: number)
  var typed = typedChar
  typedChar = {}
  if typed->empty() || typed.bnr != bnr || !opt.lspOptions.onTypeFormatting
    return
  endif

  var lspserver: dict<any> = buf.BufLspServerGet(bnr, 'documentOnTypeFormatting')
  if lspserver->empty() || !lspserver.running || !lspserver.ready
    return
  endif

  if lspserver.onTypeFormattingTriggers->index(typed.ch) == -1
    return
  endif

  var inserted = typed.ch == "\n" ? NewlineInserted(typed) : CharInserted(typed)
  if !inserted
    return
  endif

  lspserver.textDocOnTypeFormat(typed.ch)
enddef

# Do buffer-local initialization for on-type formatting.
export def BufferInit(lspserver: dict<any>, bnr: number)
  if !lspserver.isDocumentOnTypeFormattingProvider
    # no support for on-type formatting
    return
  endif

  if !lspserver.featureEnabled('documentOnTypeFormatting')
    return
  endif

  var acmds: list<dict<any>> = [
    {event: 'InsertEnter', cmd: 'OnInsertEnter()'},
    {event: 'InsertCharPre', cmd: $'OnInsertCharPre({bnr})'},
    {event: 'TextChangedI', cmd: $'OnTypeFormat({bnr})'},
    {event: 'KeyInputPre', cmd: $'OnKeyInputPre({bnr})'},
  ]
  autocmd_add(acmds->map((_, acmd) => acmd->extend({bufnr: bnr,
						    replace: true,
						    group: 'LspOnTypeFormatting'})))
enddef

# Remove the on-type formatting autocmds of buffer "bnr".
export def BufferDeInit(bnr: number)
  if exists('#LspOnTypeFormatting')
    autocmd_delete([{bufnr: bnr, group: 'LspOnTypeFormatting'}])
  endif
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
