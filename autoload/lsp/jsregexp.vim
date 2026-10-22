vim9script

# Translation of JavaScript regular expressions, as language servers send
# them (e.g. the word pattern of linked editing ranges, the regular expression
# of a snippet transformation), to Vim patterns.

def IsNone(value: any): bool
  return value->type() == v:t_none
enddef

# Returns the character "c" for a Vim collection ("[]").
def CollectionChar(c: string): string
  if c == '['
    # Avoid "[:", "[=" and "[." in a collection
    return '\x5b'
  endif
  return c =~ '^[]^\\-]$' ? $'\{c}' : c
enddef

# Returns the hexadecimal digits of the "\x" (two digits) or "\u" (four
# digits) escape "c" whose digits start at index "i" of "chars", or an empty
# string when they aren't there.
def HexDigits(chars: list<string>, i: number, c: string): string
  var len = c ==# 'x' ? 2 : 4
  var hex = chars[i : i + len - 1]->join('')
  return hex =~ $'^\x\{{{len}}}$' ? hex : ''
enddef

# Returns the Vim pattern for a collection of the character or the escape
# sequence at index "i" of "chars", which is in a JavaScript character class,
# whether it is a single character (and can end a range), and the index after
# it.  Returns v:none when Vim can't express it.
def ClassAtomToVim(chars: list<string>, i: number): any
  if chars[i] != '\'
    return [CollectionChar(chars[i]), true, i + 1]
  endif
  var c = chars->get(i + 1, '')
  if c =~# '^[dws]$'
    return [{d: '0-9', w: '0-9A-Za-z_', s: '[:space:]'}[c], false, i + 2]
  elseif c =~# '^[tnrb]$'
    # "\b" is a backspace in a class, and in a Vim collection.
    return [$'\{c}', true, i + 2]
  elseif c ==# 'f' || c ==# 'v'
    return [c ==# 'f' ? '\x0c' : '\x0b', true, i + 2]
  elseif c ==# 'x' || c ==# 'u'
    var hex = HexDigits(chars, i + 2, c)
    if hex->empty()
      return v:none
    endif
    return [$'\{c}{hex}', true, i + 2 + hex->len()]
  elseif c->empty() || c =~ '^[A-Za-z0-9]$'
    # "\D", "\W", "\S", Unicode properties, ...
    return v:none
  endif
  return [CollectionChar(c), true, i + 2]
enddef

# Returns the Vim pattern for the JavaScript character class that starts at
# index "i" of "chars", at its "[", and the index after the class.  Returns
# v:none when Vim can't express it.
def ClassToVim(chars: list<string>, i: number): any
  var j = i + 1
  var negated = chars->get(j, '') == '^'
  if negated
    j += 1
  endif
  if chars->get(j, '') == ']'
    # "[^]" matches any character, "[]" none.
    return negated ? ['\_.', j + 1] : v:none
  endif

  var items: list<string> = []
  while j < chars->len() && chars[j] != ']'
    var atom = ClassAtomToVim(chars, j)
    if IsNone(atom)
      return v:none
    endif
    var [item, isChar, next] = atom
    j = next
    if chars->get(j, '') == '-' && chars->get(j + 1, ']') != ']'
      # A range
      var endAtom = ClassAtomToVim(chars, j + 1)
      if IsNone(endAtom) || !isChar || !endAtom[1]
	return v:none
      endif
      item = $'{item}-{endAtom[0]}'
      j = endAtom[2]
    endif
    items->add(item)
  endwhile
  if j >= chars->len()
    return v:none
  endif
  return [$'\[{negated ? '^' : ''}{items->join('')}]', j + 1]
enddef

# Returns the Vim pattern for the JavaScript quantifier at index "start" of
# "chars", and the index after it.  Returns v:none when there is no quantifier
# there.
def QuantifierToVim(chars: list<string>, start: number): any
  var ch = chars[start]
  var i = start + 1
  var min: number
  var max: number
  if ch == '*'
    [min, max] = [0, -1]
  elseif ch == '+'
    [min, max] = [1, -1]
  elseif ch == '?'
    [min, max] = [0, 1]
  else
    var spec = chars[i : ]->join('')->matchstr('^\d\+\%(,\d*\)\=}')
    if spec->empty()
      return v:none
    endif
    i += spec->strcharlen()
    var bounds = spec->strpart(0, spec->len() - 1)->split(',', true)
    min = bounds[0]->str2nr()
    max = bounds->len() == 1 ? min
      : bounds[1]->empty() ? -1 : bounds[1]->str2nr()
  endif

  var lazy = chars->get(i, '') == '?'
  if lazy
    i += 1
  elseif max < 0 && min <= 1
    return [min == 0 ? '\*' : '\+', i]
  elseif min == 0 && max == 1
    return ['\=', i]
  endif
  var lazyMark = lazy ? '-' : ''
  var maxText = max < 0 ? '' : string(max)
  return [$'\{{{lazyMark}{min},{maxText}}}', i]
enddef

# Returns the Vim pattern for the JavaScript escape sequence at index "i" of
# "chars", just after a backslash, outside of a character class, and the
# number of characters of the sequence.  Returns v:none when Vim can't
# express it.
def EscapeToVim(chars: list<string>, i: number): any
  var c = chars->get(i, '')
  if c =~# '^[dDwWsStnr1-9]$'
    return [$'\{c}', 1]
  elseif c ==# 'f' || c ==# 'v'
    return [c ==# 'f' ? '\%x0c' : '\%x0b', 1]
  elseif c ==# 'b'
    return ['\%(\<\|\>\)', 1]
  elseif c ==# 'x' || c ==# 'u'
    var hex = HexDigits(chars, i + 1, c)
    if hex->empty()
      return v:none
    endif
    return [$'\%{c}{hex}', 1 + hex->len()]
  elseif c->empty() || c =~ '^[A-Za-z0-9]$'
    # "\B", "\0", named backreferences, Unicode properties, ...
    return v:none
  elseif c == '\'
    return ['\\', 1]
  elseif c == '^' || c == '$'
    # Literally, not as an anchor at the start or the end.
    return [printf('\%%x%02x', char2nr(c)), 1]
  endif
  return [c, 1]
enddef

# Returns the JavaScript regular expression "regex" with the flags "flags" as
# a Vim pattern, or v:none when it uses something that Vim can't express, such
# as a Unicode property, or isn't a valid regular expression.  The pattern
# matches case unless "flags" has "i".  With "s", "." matches a line break.
export def ToVim(regex: string, flags: string = ''): any
  var chars = regex->split('\zs')
  # Very nomagic: only constructs with a backslash are special.
  var pat = flags =~# 'i' ? '\V\c' : '\V\C'
  var groupEnds: list<string> = []
  # Whether the last item can take a quantifier
  var quantifiable = false
  var i = 0
  while i < chars->len()
    var ch = chars[i]
    var atom = true
    if ch == '\'
      var esc = EscapeToVim(chars, i + 1)
      if IsNone(esc)
	return v:none
      endif
      pat ..= esc[0]
      # A word boundary can't take a quantifier.
      atom = chars[i + 1] !=# 'b'
      i += 1 + esc[1]
    elseif ch == '['
      var cls = ClassToVim(chars, i)
      if IsNone(cls)
	return v:none
      endif
      pat ..= cls[0]
      i = cls[1]
    elseif ch == '('
      var ext = chars[i + 1 : i + 3]->join('')
      if ext !~ '^?'
	pat ..= '\('
	groupEnds->add('\)')
	i += 1
      elseif ext =~ '^?:'
	pat ..= '\%('
	groupEnds->add('\)')
	i += 3
      elseif ext =~ '^?[=!]'
	pat ..= '\%('
	groupEnds->add(ext[1] == '=' ? '\)\@=' : '\)\@!')
	i += 3
      elseif ext =~ '^?<[=!]'
	pat ..= '\%('
	groupEnds->add(ext[2] == '=' ? '\)\@<=' : '\)\@<!')
	i += 4
      else
	# A named capture group
	var name = chars[i + 2 : ]->join('')->matchstr('^<\a\w*>')
	if name->empty()
	  return v:none
	endif
	pat ..= '\('
	groupEnds->add('\)')
	i += 2 + name->strcharlen()
      endif
      atom = false
    elseif ch == ')'
      if groupEnds->empty()
	return v:none
      endif
      var groupEnd = groupEnds->remove(-1)
      pat ..= groupEnd
      i += 1
      # A lookaround can't take a quantifier in Vim.
      atom = groupEnd == '\)'
    elseif ch == '|'
      pat ..= '\|'
      i += 1
      atom = false
    elseif ch == '.'
      pat ..= flags =~# 's' ? '\_.' : '\.'
      i += 1
    elseif ch == '^' || ch == '$'
      pat ..= '\_' .. ch
      i += 1
      atom = false
    elseif '*+?{'->stridx(ch) >= 0
      var quantifier = QuantifierToVim(chars, i)
      if !IsNone(quantifier)
	if !quantifiable
	  # Nothing to repeat
	  return v:none
	endif
	pat ..= quantifier[0]
	i = quantifier[1]
	atom = false
      elseif ch == '{'
	# A "{" that doesn't start a quantifier is literal.
	pat ..= ch
	i += 1
      else
	return v:none
      endif
    else
      pat ..= ch
      i += 1
    endif
    quantifiable = atom
  endwhile
  return groupEnds->empty() ? pat : v:none
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
