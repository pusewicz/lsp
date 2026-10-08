vim9script

import './util.vim'

# Functions for encoding and decoding the LSP position offsets.  Language
# servers support either UTF-8 or UTF-16 or UTF-32 position offsets.  The
# character related Vim functions use the UTF-32 position offset.  The
# encoding used is negotiated during the language server initialization.

# Return the length of "text" in the position encoding negotiated with the
# language server: in bytes for UTF-8, in code units for UTF-16 and in
# characters, counting the composing characters separately, for UTF-32.
export def EncodedLineLen(lspserver: dict<any>, text: string): number
  if lspserver.posEncoding == 8
    return text->strlen()
  elseif lspserver.posEncoding == 16
    return text->strutf16len(true)
  endif
  return text->strchars()
enddef

# Encode the UTF-32 character offset "character" from the start of "text" to
# the encoding negotiated with the language server.  An offset past the end of
# "text" is at its end, as the LSP specification requires, so the result is at
# most the encoded length of "text".
export def EncodeCharacter(lspserver: dict<any>, text: string,
			   character: number): number
  # LSP client plugin also uses utf-32 encoding
  if lspserver.posEncoding == 32
    return character
  endif

  if character >= text->strchars()
    return EncodedLineLen(lspserver, text)
  endif
  return lspserver.posEncoding == 16
    ? text->utf16idx(character, true, true) : text->byteidxcomp(character)
enddef

# Encode the UTF-32 character offset in the LSP position "pos" to the encoding
# negotiated with the language server.
#
# Modifies in-place the UTF-32 offset in pos.character to a UTF-8 or UTF-16 or
# UTF-32 offset.  A position past the end of its line is at the end of the
# line, as the LSP specification requires.  When the line is not available,
# because it is past the end of the buffer or the buffer cannot be loaded, the
# offset is left unchanged.
export def EncodePosition(lspserver: dict<any>, bnr: number, pos: dict<number>)
  if lspserver.posEncoding == 32 || bnr <= 0
    # LSP client plugin also uses utf-32 encoding
    return
  endif

  :silent! bnr->bufload()
  var lines: list<string> = bnr->getbufline(pos.line + 1)
  if lines->empty()
    return
  endif
  pos.character = EncodeCharacter(lspserver, lines[0], pos.character)
enddef

# Decode the character offset "character" from the start of "text" using the
# encoding negotiated with the language server to a UTF-32 offset.  An offset
# past the end of "text" is at its end, as the LSP specification requires, so
# the result is at most the number of characters in "text", counting the
# composing characters separately.
export def DecodeCharacter(lspserver: dict<any>, text: string,
			   character: number): number
  # LSP client plugin also uses utf-32 encoding
  if lspserver.posEncoding == 32
    return character
  endif

  if character >= EncodedLineLen(lspserver, text)
    return text->strchars()
  endif
  return lspserver.posEncoding == 16
    ? text->charidx(character, true, true) : text->charidx(character, true)
enddef

# Decode the character offset in the LSP position "pos" using the encoding
# negotiated with the language server to a UTF-32 offset.
#
# Modifies in-place the UTF-8 or UTF-16 or UTF-32 offset in pos.character to a
# UTF-32 offset.  A position past the end of its line is at the end of the
# line, as the LSP specification requires.  When the line is not available,
# because it is past the end of the buffer or the buffer cannot be loaded, the
# offset is left unchanged.
export def DecodePosition(lspserver: dict<any>, bnr: number, pos: dict<number>)
  if lspserver.posEncoding == 32 || bnr <= 0
    # LSP client plugin also uses utf-32 encoding
    return
  endif

  :silent! bnr->bufload()
  var lines: list<string> = bnr->getbufline(pos.line + 1)
  if lines->empty()
    return
  endif
  pos.character = DecodeCharacter(lspserver, lines[0], pos.character)
enddef

# Encode the start and end UTF-32 character offsets in the LSP range "range"
# to the encoding negotiated with the language server.
#
# Modifies in-place the UTF-32 offset in range.start.character and
# range.end.character to a UTF-8 or UTF-16 or UTF-32 offset.
export def EncodeRange(lspserver: dict<any>, bnr: number,
		       range: dict<dict<number>>)
  if lspserver.posEncoding == 32
    return
  endif

  EncodePosition(lspserver, bnr, range.start)
  EncodePosition(lspserver, bnr, range.end)
enddef

# Decode the start and end character offsets in the LSP range "range" to
# UTF-32 offsets.
#
# Modifies in-place the offset value in range.start.character and
# range.end.character to a UTF-32 offset.
export def DecodeRange(lspserver: dict<any>, bnr: number,
		       range: dict<dict<number>>)
  if lspserver.posEncoding == 32
    return
  endif

  DecodePosition(lspserver, bnr, range.start)
  DecodePosition(lspserver, bnr, range.end)
enddef

# Encode the range in the LSP position "location" to the encoding negotiated
# with the language server.
#
# Modifies in-place the UTF-32 offset in location.range to a UTF-8 or UTF-16
# or UTF-32 offset.
export def EncodeLocation(lspserver: dict<any>, location: dict<any>)
  if lspserver.posEncoding == 32
    return
  endif

  var bnr = 0
  if location->has_key('targetUri')
    # LocationLink
    bnr = util.LspUriToBufnr(location.targetUri)
    if bnr > 0
      # We use only the "targetSelectionRange" item.  The
      # "originSelectionRange" and the "targetRange" items are not used.
      lspserver.encodeRange(bnr, location.targetSelectionRange)
    endif
  else
    # Location
    bnr = util.LspUriToBufnr(location.uri)
    if bnr > 0
      lspserver.encodeRange(bnr, location.range)
    endif
  endif
enddef

# Decode the range in the LSP location "location" to UTF-32.
#
# Modifies in-place the offset value in location.range to a UTF-32 offset.
export def DecodeLocation(lspserver: dict<any>, location: dict<any>)
  if lspserver.posEncoding == 32
    return
  endif

  var bnr = 0
  if location->has_key('targetUri')
    # LocationLink
    bnr = util.LspUriToBufnr(location.targetUri)
    # We use only the "targetSelectionRange" item.  The
    # "originSelectionRange" and the "targetRange" items are not used.
    lspserver.decodeRange(bnr, location.targetSelectionRange)
  else
    # Location
    bnr = util.LspUriToBufnr(location.uri)
    lspserver.decodeRange(bnr, location.range)
  endif
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
