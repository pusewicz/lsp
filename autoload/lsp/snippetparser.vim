vim9script

# Parser for the snippet syntax of the Language Server Protocol, and the
# rendering of a parsed snippet to text and tabstop ranges.
#
# A parsed snippet is a List of nodes:
#   text:     {type: 'text', value: string}
#   tabstop:  {type: 'tabstop', index: number, children: list<dict<any>>}
#	      A placeholder has its default value in "children", a choice also
#	      has "choices": list<string>, a tabstop with a transformation of
#	      its text also has "transform".
#   variable: {type: 'variable', name: string}
#	      With a default value also "children", with a transformation also
#	      "transform".
# A transformation is {regex: string, format: list<dict<any>>, options:
# string}, with the regular expression and its options as JavaScript writes
# them.  The format is a List of text nodes and format nodes:
#   format:   {type: 'format', index: number}
#	      With a case modifier also "modifier" ("upcase", "downcase",
#	      "capitalize", "camelcase" or "pascalcase"), conditional on the
#	      capture group also "ifValue" and/or "elseValue".

const caseModifiers = ['upcase', 'downcase', 'capitalize', 'camelcase',
		       'pascalcase']

# Return true when "value" is v:none, which the parse functions return for
# text that is not well-formed.
def IsNone(value: any): bool
  return value->type() == v:t_none
enddef

# Return the parser state for "snippet": its characters and the index of the
# next one to parse.
def NewParser(snippet: string): dict<any>
  return {chars: snippet->split('\zs'), pos: 0}
enddef

# Return the character "offset" characters after the next one to parse, or
# an empty string past the end of the snippet.
def Peek(p: dict<any>, offset: number = 0): string
  return p.chars->get(p.pos + offset, '')
enddef

# Return true when the next character to parse is a backslash that escapes
# one of the characters in "escapable".
def AtEscape(p: dict<any>, escapable: string): bool
  var next = Peek(p, 1)
  return Peek(p) == '\' && !next->empty() && escapable->stridx(next) >= 0
enddef

# Consume the next character when it is "ch" and return true, else return
# false.
def Accept(p: dict<any>, ch: string): bool
  if Peek(p) ==# ch
    p.pos += 1
    return true
  endif
  return false
enddef

# Parse an unsigned decimal number.  Returns -1 when there is none.
def ParseInt(p: dict<any>): number
  var digits = ''
  while Peek(p) =~ '^\d$'
    digits ..= Peek(p)
    p.pos += 1
  endwhile
  return digits->empty() ? -1 : digits->str2nr()
enddef

# Parse a name: a letter or "_" followed by letters, digits and "_".  Returns
# an empty string when there is none.
def ParseName(p: dict<any>): string
  if Peek(p) !~ '^[_a-zA-Z]$'
    return ''
  endif
  var name = ''
  while Peek(p) =~ '^\w$'
    name ..= Peek(p)
    p.pos += 1
  endwhile
  return name
enddef

# Parse text up to one of the characters in "stops", which is not consumed.
# A backslash escapes the characters in "escapable"; before any other
# character it is taken literally.  Returns v:none when the snippet ends
# before a stop character.
def ParseTextUntil(p: dict<any>, stops: string, escapable: string): any
  var text = ''
  while true
    var ch = Peek(p)
    if ch->empty()
      return v:none
    endif
    if AtEscape(p, escapable)
      text ..= Peek(p, 1)
      p.pos += 2
    elseif stops->stridx(ch) >= 0
      return text
    else
      text ..= ch
      p.pos += 1
    endif
  endwhile
  return text
enddef

# Parse the elements of a choice after its opening "|", up to and including
# the closing "|}".  Returns v:none when they are not well-formed.
def ParseChoices(p: dict<any>): any
  var choices: list<string> = []
  while true
    var choice = ParseTextUntil(p, ',|', ',|$}\')
    if IsNone(choice)
      return v:none
    endif
    choices->add(choice)
    if Accept(p, '|')
      return Accept(p, '}') ? choices : v:none
    endif
    # Skip the ","
    p.pos += 1
  endwhile
  return choices
enddef

# Parse a format node of a transformation after its "$".  Returns v:none
# when it is not well-formed.
def ParseFormat(p: dict<any>): any
  var index = ParseInt(p)
  if index >= 0
    return {type: 'format', index: index}
  endif
  if !Accept(p, '{')
    return v:none
  endif
  index = ParseInt(p)
  if index < 0
    return v:none
  endif
  if Accept(p, '}')
    return {type: 'format', index: index}
  endif
  if !Accept(p, ':')
    return v:none
  endif

  var node: dict<any> = {type: 'format', index: index}
  if Accept(p, '/')
    var modifier = ParseName(p)
    if caseModifiers->index(modifier) < 0 || !Accept(p, '}')
      return v:none
    endif
    node.modifier = modifier
    return node
  endif

  var ifValue: any = v:none
  var elseValue: any = v:none
  if Accept(p, '+')
    ifValue = ParseTextUntil(p, '}', '}\$')
    if IsNone(ifValue)
      return v:none
    endif
  elseif Accept(p, '?')
    ifValue = ParseTextUntil(p, ':', ':}\$')
    if IsNone(ifValue) || !Accept(p, ':')
      return v:none
    endif
    elseValue = ParseTextUntil(p, '}', '}\$')
  else
    Accept(p, '-')
    elseValue = ParseTextUntil(p, '}', '}\$')
  endif
  if !IsNone(elseValue)
    node.elseValue = elseValue
  elseif Peek(p)->empty()
    return v:none
  endif
  if !IsNone(ifValue)
    node.ifValue = ifValue
  endif
  return Accept(p, '}') ? node : v:none
enddef

# Parse a transformation after its first "/", up to and including the
# closing "}".  Returns v:none when it is not well-formed.
def ParseTransform(p: dict<any>): any
  # The regular expression keeps its escapes, except for "\/".
  var regex = ''
  while !Accept(p, '/')
    var ch = Peek(p)
    if ch->empty()
      return v:none
    endif
    if ch == '\' && !Peek(p, 1)->empty()
      regex ..= Peek(p, 1) == '/' ? '/' : ch .. Peek(p, 1)
      p.pos += 2
    else
      regex ..= ch
      p.pos += 1
    endif
  endwhile

  var format: list<dict<any>> = []
  var text = ''
  while !Accept(p, '/')
    var ch = Peek(p)
    if ch->empty()
      return v:none
    endif
    if AtEscape(p, '/$}\')
      text ..= Peek(p, 1)
      p.pos += 2
      continue
    endif
    if ch == '$'
      var save = p.pos
      p.pos += 1
      var node = ParseFormat(p)
      if !IsNone(node)
	if !text->empty()
	  format->add({type: 'text', value: text})
	  text = ''
	endif
	format->add(node)
	continue
      endif
      p.pos = save
    endif
    text ..= ch
    p.pos += 1
  endwhile
  if !text->empty()
    format->add({type: 'text', value: text})
  endif

  var options = ''
  while Peek(p) =~ '^\a$'
    options ..= Peek(p)
    p.pos += 1
  endwhile
  if !Accept(p, '}')
    return v:none
  endif
  return {regex: regex, format: format, options: options}
enddef

# Parse a tabstop, placeholder, choice or variable after its "$".  Returns
# v:none when there is none, and the "$" is then text.
def ParseDollar(p: dict<any>): any
  var index = ParseInt(p)
  if index >= 0
    return {type: 'tabstop', index: index, children: []}
  endif
  var name = ParseName(p)
  if !name->empty()
    return {type: 'variable', name: name}
  endif
  if !Accept(p, '{')
    return v:none
  endif

  var node: dict<any>
  index = ParseInt(p)
  if index >= 0
    node = {type: 'tabstop', index: index, children: []}
  else
    name = ParseName(p)
    if name->empty()
      return v:none
    endif
    node = {type: 'variable', name: name}
  endif

  if Accept(p, '}')
    return node
  endif
  if Accept(p, ':')
    var children = ParseNodes(p, true)
    if IsNone(children) || !Accept(p, '}')
      return v:none
    endif
    node.children = children
    return node
  endif
  if node.type == 'tabstop' && Accept(p, '|')
    var choices = ParseChoices(p)
    if IsNone(choices)
      return v:none
    endif
    node.choices = choices
    return node
  endif
  if Accept(p, '/')
    var transform = ParseTransform(p)
    if IsNone(transform)
      return v:none
    endif
    node.transform = transform
    return node
  endif
  return v:none
enddef

# Parse snippet nodes.  In a placeholder or a variable default ("nested"),
# up to the "}" that ends it, which is not consumed; returns v:none when the
# snippet ends before it.  Else up to the end of the snippet, with a "}" that
# doesn't end anything taken as text.
def ParseNodes(p: dict<any>, nested: bool): any
  var nodes: list<dict<any>> = []
  var text = ''
  while true
    var ch = Peek(p)
    if ch->empty()
      if nested
	return v:none
      endif
      break
    endif
    if ch == '}' && nested
      break
    endif
    if AtEscape(p, '$}\')
      text ..= Peek(p, 1)
      p.pos += 2
      continue
    endif
    if ch == '$'
      var save = p.pos
      p.pos += 1
      var node = ParseDollar(p)
      if !IsNone(node)
	if !text->empty()
	  nodes->add({type: 'text', value: text})
	  text = ''
	endif
	nodes->add(node)
	continue
      endif
      p.pos = save
    endif
    text ..= ch
    p.pos += 1
  endwhile
  if !text->empty()
    nodes->add({type: 'text', value: text})
  endif
  return nodes
enddef

# Parse the LSP snippet "snippet" and return its nodes.  Like other clients,
# take text that is not well-formed snippet syntax literally, e.g. a "$" not
# followed by a tabstop or a variable.
export def Parse(snippet: string): list<dict<any>>
  return ParseNodes(NewParser(snippet), false)
enddef

# Return the Vim pattern for the JavaScript character class in "chars" that
# starts after its "[" at index "start", and the index after its "]".
# Returns v:none for a class that Vim can't express.
def JsClassToVim(chars: list<string>, start: number): any
  var i = start
  var negated = chars->get(i, '') == '^'
  if negated
    i += 1
  endif
  var members = ''
  while i < chars->len() && chars[i] != ']'
    var ch = chars[i]
    if ch == '\'
      var esc = chars->get(i + 1, '')
      i += 2
      if esc ==# 'd'
	members ..= '0-9'
      elseif esc ==# 'w'
	members ..= '0-9A-Za-z_'
      elseif esc ==# 's'
	members ..= ' \t\r\n\x0b\x0c'
      elseif esc =~# '^[tnr]$'
	members ..= '\' .. esc
      elseif esc->empty() || esc =~ '^[A-Za-z0-9]$'
	return v:none
      else
	members ..= ']^-\'->stridx(esc) >= 0 ? '\' .. esc : esc
      endif
      continue
    endif
    # A "^" first in a Vim collection negates it.
    members ..= ch == '^' && members->empty() ? '\^' : ch
    i += 1
  endwhile
  if i >= chars->len()
    return v:none
  endif
  if members->empty()
    # "[^]" matches any character, "[]" none.
    return negated ? ['\_.', i + 1] : v:none
  endif
  return [(negated ? '\[^' : '\[') .. members .. ']', i + 1]
enddef

# Return the Vim pattern for the JavaScript quantifier in "chars" at index
# "start", and the index after it.  Returns v:none when there is no
# quantifier there.
def JsQuantifierToVim(chars: list<string>, start: number): any
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

# Return the JavaScript regular expression "regex" with the flags "flags" as
# a Vim pattern.  Returns v:none for an expression that Vim can't express.
export def JsRegexToVim(regex: string, flags: string): any
  var chars = regex->split('\zs')
  # Very nomagic: only constructs with a backslash are special.
  var pat = flags =~# 'i' ? '\V\c' : '\V\C'
  var groupEnds: list<string> = []
  var i = 0
  while i < chars->len()
    var ch = chars[i]
    if ch == '\'
      var esc = chars->get(i + 1, '')
      i += 2
      if esc =~# '^[dDwWsStnr1-9]$'
	pat ..= '\' .. esc
      elseif esc ==# 'b'
	pat ..= '\%(\<\|\>\)'
      elseif esc ==# 'x' && chars[i : i + 1]->join('') =~ '^\x\x$'
	pat ..= '\%x' .. chars[i : i + 1]->join('')
	i += 2
      elseif esc ==# 'u' && chars[i : i + 3]->join('') =~ '^\x\{4}$'
	pat ..= '\%u' .. chars[i : i + 3]->join('')
	i += 4
      elseif esc->empty() || esc =~ '^[A-Za-z0-9]$'
	return v:none
      elseif esc == '\'
	pat ..= '\\'
      elseif esc == '^' || esc == '$'
	# Literally, not as an anchor at the start or the end.
	pat ..= printf('\%%x%02x', char2nr(esc))
      else
	pat ..= esc
      endif
    elseif ch == '['
      var cls = JsClassToVim(chars, i + 1)
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
    elseif ch == ')'
      if groupEnds->empty()
	return v:none
      endif
      pat ..= groupEnds->remove(-1)
      i += 1
    elseif ch == '|'
      pat ..= '\|'
      i += 1
    elseif ch == '.'
      pat ..= flags =~# 's' ? '\_.' : '\.'
      i += 1
    elseif ch == '^' || ch == '$'
      pat ..= '\_' .. ch
      i += 1
    elseif '*+?{'->stridx(ch) >= 0
      var quantifier = JsQuantifierToVim(chars, i)
      if !IsNone(quantifier)
	pat ..= quantifier[0]
	i = quantifier[1]
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
  endwhile
  return groupEnds->empty() ? pat : v:none
enddef

# Return "value" in camel case ("pascal" false) or pascal case: its words of
# letters and digits joined, each with an upper case first letter, except
# for the first word in camel case.
def JoinWordsCased(value: string, pascal: bool): string
  var words: list<string> = []
  value->substitute('[a-zA-Z0-9]\+', (m) => {
    words->add(m[0])
    return ''
  }, 'g')
  if words->empty()
    return value
  endif
  var result = ''
  for i in words->len()->range()
    var first = words[i][0]
    result ..= (i == 0 && !pascal ? first->tolower() : first->toupper())
      .. words[i][1 : ]
  endfor
  return result
enddef

# Return the text for the format "format" of a transformation, for a match
# with the capture groups "groups", as passed to a substitute() function.
def FormatMatch(format: list<dict<any>>, groups: list<string>): string
  var result = ''
  for node in format
    if node.type == 'text'
      result ..= node.value
      continue
    endif
    var group: string = groups->get(node.index, '')
    var modifier = node->get('modifier', '')
    if modifier == 'upcase'
      result ..= group->toupper()
    elseif modifier == 'downcase'
      result ..= group->tolower()
    elseif modifier == 'capitalize'
      result ..= group->strcharpart(0, 1)->toupper() .. group->strcharpart(1)
    elseif modifier == 'camelcase' || modifier == 'pascalcase'
      result ..= JoinWordsCased(group, modifier == 'pascalcase')
    elseif node->has_key('ifValue')
      result ..= !group->empty() ? node.ifValue : node->get('elseValue', '')
    elseif node->has_key('elseValue')
      result ..= !group->empty() ? group : node.elseValue
    else
      result ..= group
    endif
  endfor
  return result
enddef

# Return "value" transformed by the transformation "transform": the matches
# of its regular expression replaced with its format.  Returns "value"
# unchanged when Vim can't express the regular expression.
export def ApplyTransform(value: string, transform: dict<any>): string
  var pat = JsRegexToVim(transform.regex, transform.options)
  if IsNone(pat)
    return value
  endif
  return value->substitute(pat, (m) => FormatMatch(transform.format, m),
			   transform.options =~# 'g' ? 'g' : '')
enddef

# Return "nodes" with each variable replaced with its value, or its default
# value when its value is empty.  "Resolve" returns the value of a variable,
# or v:none for an unknown variable.  An unknown variable becomes a
# placeholder with its default value or else its name, numbered from
# "firstIndex" on in "unknownIndexes" by variable name.
def ResolveVariables(nodes: list<dict<any>>, Resolve: func(string): any,
		     unknownIndexes: dict<number>,
		     firstIndex: number): list<dict<any>>
  var resolved: list<dict<any>> = []
  for node in nodes
    if node.type == 'tabstop'
      resolved->add(node->copy()->extend({
	children: ResolveVariables(node.children, Resolve, unknownIndexes,
				   firstIndex)}))
      continue
    endif
    if node.type != 'variable'
      resolved->add(node)
      continue
    endif

    var value = Resolve(node.name)
    var children: list<dict<any>> =
      ResolveVariables(node->get('children', []), Resolve, unknownIndexes,
		       firstIndex)
    if IsNone(value)
      if !unknownIndexes->has_key(node.name)
	unknownIndexes[node.name] = firstIndex + unknownIndexes->len()
      endif
      resolved->add({type: 'tabstop', index: unknownIndexes[node.name],
		     children: children->empty()
		       ? [{type: 'text', value: node.name}] : children})
    elseif value->empty() && !children->empty()
      resolved->extend(children)
    else
      if node->has_key('transform')
	value = ApplyTransform(value, node.transform)
      endif
      resolved->add({type: 'text', value: value})
    endif
  endfor
  return resolved
enddef

# Return the largest tabstop index in "nodes", or -1 when there is none.
def MaxTabstopIndex(nodes: list<dict<any>>): number
  var max = -1
  for node in nodes
    if node.type == 'tabstop'
      max = [max, node.index]->max()
    endif
    max = [max, MaxTabstopIndex(node->get('children', []))]->max()
  endfor
  return max
enddef

# Add the tabstop nodes in "nodes", in text order, to "tabstops".
def CollectTabstops(nodes: list<dict<any>>, tabstops: list<dict<any>>)
  for node in nodes
    if node.type == 'tabstop'
      tabstops->add(node)
    endif
    CollectTabstops(node->get('children', []), tabstops)
  endfor
enddef

# Return the text of the tabstop "node" before its transformation, if any:
# the default value of its tabstop, see Render().  "visiting" holds the
# indexes of the tabstops whose default value is being rendered, to stop at a
# tabstop nested in itself, which gets its own text.
def TabstopText(node: dict<any>, r: dict<any>, visiting: list<number>): string
  if visiting->index(node.index) >= 0
    return FlatText(node.children, r, visiting)
  endif
  return FlatText(r.defaults->get(string(node.index), []), r,
		  visiting + [node.index])
enddef

# Return the text of "nodes" without tabstop ranges.  "visiting" is as for
# TabstopText().
def FlatText(nodes: list<dict<any>>, r: dict<any>,
	     visiting: list<number>): string
  var text = ''
  for node in nodes
    if node.type == 'text'
      text ..= node.value
      continue
    endif
    var value = TabstopText(node, r, visiting)
    text ..= node->has_key('transform')
      ? ApplyTransform(value, node.transform) : value
  endfor
  return text
enddef

# Render "nodes" at the end of "r.text", adding a range to "r.tabstops" for
# each tabstop, nested in the tabstop range at index "parent" of "r.tabstops"
# (-1 for none).  The primary occurrence of a tabstop holds its default value,
# with the tabstops in it, the other occurrences mirror its text.
# "visiting" is as for TabstopText().
def RenderNodes(nodes: list<dict<any>>, r: dict<any>, parent: number,
		visiting: list<number>)
  for node in nodes
    if node.type == 'text'
      r.text ..= node.value
      continue
    endif

    if visiting->index(node.index) >= 0
      # A tabstop in its own default value is only text.
      r.text ..= FlatText([node], r, visiting)
      continue
    endif

    var key = string(node.index)
    var tabstop: dict<any> = {
      index: node.index,
      start: r.text->len(),
      primary: node is r.primaries[key],
      parent: parent,
    }
    r.tabstops->add(tabstop)
    if tabstop.primary
      if r.choices->has_key(key)
	tabstop.choices = r.choices[key]
      endif
      RenderNodes(r.defaults->get(key, []), r, r.tabstops->len() - 1,
		  visiting + [node.index])
    else
      var value = TabstopText(node, r, visiting)
      if node->has_key('transform')
	tabstop.transform = node.transform
	value = ApplyTransform(value, node.transform)
      endif
      r.text ..= value
    endif
    tabstop.end = r.text->len()
  endfor
enddef

# Render the snippet nodes "nodes" returned by Parse(), with the values of the
# variables returned by "Resolve" (v:none for an unknown variable).  Returns
# the text of the snippet and its tabstops in text order:
#   {text: string, tabstops: list<dict<any>>}
# Each tabstop is {index, start, end, primary, parent}: the byte offsets in
# "text" of its text, from "start" up to "end", "primary" true for the
# occurrence of the tabstop that the cursor goes to and the other occurrences
# mirror, and "parent" the index in "tabstops" of the tabstop it is nested in,
# or -1.  A choice also has "choices", a mirror with a transformation
# "transform".
#
# As in other clients, the first placeholder of a tabstop with a default value
# gives all occurrences of the tabstop that value, the first occurrence
# without a transformation is the primary one, an unknown variable becomes a
# placeholder, and a snippet without a final tabstop ($0) gets one at its end.
export def Render(nodes: list<dict<any>>,
		  Resolve: func(string): any): dict<any>
  var resolved = ResolveVariables(nodes, Resolve, {},
				  MaxTabstopIndex(nodes) + 1)

  var all: list<dict<any>> = []
  CollectTabstops(resolved, all)
  # Keyed by the tabstop index
  var r: dict<any> = {
    text: '',
    tabstops: [],
    defaults: {},
    choices: {},
    primaries: {},
  }
  for node in all
    var key = string(node.index)
    if node->has_key('choices') && !r.choices->has_key(key)
      r.choices[key] = node.choices
    endif
    if !r.defaults->has_key(key)
      if !node.children->empty()
	r.defaults[key] = node.children
      elseif !node->get('choices', [])->empty()
	r.defaults[key] = [{type: 'text', value: node.choices[0]}]
      endif
    endif
  endfor
  for node in all->copy()->filter((_, n) => !n->has_key('transform')) + all
    var key = string(node.index)
    if !r.primaries->has_key(key)
      r.primaries[key] = node
    endif
  endfor

  RenderNodes(resolved, r, -1, [])

  if r.tabstops->indexof((_, t) => t.index == 0) < 0
    r.tabstops->add({index: 0, start: r.text->len(), end: r.text->len(),
		     primary: true, parent: -1})
  endif
  return {text: r.text, tabstops: r.tabstops}
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
