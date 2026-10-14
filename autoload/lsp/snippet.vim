vim9script

# Snippet support

# Integration with the UltiSnips plugin
export def CompletionUltiSnips(prefix: string, items: list<dict<any>>)
  call UltiSnips#SnippetsInCurrentScope(1)
  for key in matchfuzzy(g:current_ulti_dict_info->keys(), prefix)
    var item = g:current_ulti_dict_info[key]
    var parts = split(item.location, ':')
    var txt = parts[0]->readfile()[parts[1]->str2nr() : parts[1]->str2nr() + 20]
    var restxt = item.description .. "\n\n"
    for line in txt
      if line->empty() || line[0 : 6] == "snippet"
	break
      else
	restxt = restxt .. line .. "\n"
      endif
    endfor
    items->add({
      label: key,
      data: {
	entryNames: [key],
      },
      kind: 15,
      documentation: restxt,
    })
  endfor
enddef

# Integration with the vim-vsnip plugin
export def CompletionVsnip(items: list<dict<any>>)
  def Pattern(abbr: string): string
    var chars = escape(abbr, '\/?')->split('\zs')
    var chars_pattern = '\%(\V' .. chars->join('\m\|\V') .. '\m\)'
    var separator = chars[0] =~ '\a' ? '\<' : ''
    return $'{separator}\V{chars[0]}\m{chars_pattern}*$'
  enddef

  if charcol('.') == 1
    return
  endif
  var starttext = getline('.')->slice(0, charcol('.') - 1)
  for item in vsnip#get_complete_items(bufnr())
    var match = starttext->matchstrpos(Pattern(item.abbr))
    if match[0] != ''
      var user_data = item.user_data->json_decode()
      var documentation = []
      for line in vsnip#to_string(user_data.vsnip.snippet)->split("\n")
	documentation->add(line)
      endfor
      items->add({
	label: item.abbr,
	filterText: item.word,
	insertTextFormat: 2,
	textEdit: {
	  newText: user_data.vsnip.snippet->join("\n"),
	  range: {
	    start: {
	      line: line('.'),
	      character: match[1],
	    },
	    ['end']: {
	      line: line('.'),
	      character: match[2],
	    },
	  },
	},
	data: {
	  entryNames: [item.word],
	},
	kind: 15,
	documentation: {
	  kind: 'markdown',
	  value: documentation->join("\n"),
	},
      })
    endif
  endfor
enddef

# Return the text that the LSP snippet "snippet" inserts when nothing is typed
# in it: tabstops insert nothing, placeholders and variables with a default
# their default text and choices their first option.  Variables are not
# resolved, so the ones without a default insert nothing.
export def SnippetToText(snippet: string): string
  return SnippetText({chars: snippet->split('\zs'), pos: 0}, false)
enddef

# Return the text that the snippet "state.chars" inserts from index
# "state.pos" (see SnippetToText()), up to the "}" that ends the element it is
# in when "nested" is true, or else up to its end.  Moves "state.pos" to that
# "}" or to the end.
def SnippetText(state: dict<any>, nested: bool): string
  var chars: list<string> = state.chars
  var text: string = ''
  while state.pos < chars->len()
    var c: string = chars[state.pos]
    var next: string = chars->get(state.pos + 1, '')
    if c == '\' && ['$', '}', '\']->index(next) != -1
      text ..= next
      state.pos += 2
    elseif c == '}' && nested
      break
    elseif c == '$'
      text ..= SnippetDollarText(state)
    else
      text ..= c
      state.pos += 1
    endif
  endwhile
  return text
enddef

# Return the text that the snippet element starting with the "$" at index
# "state.pos" of the snippet "state.chars" inserts (see SnippetToText()), and
# move "state.pos" past it.  A "$" that starts no element is text.
def SnippetDollarText(state: dict<any>): string
  var chars: list<string> = state.chars
  var start: number = state.pos
  state.pos += 1
  var c: string = chars->get(state.pos, '')
  if c =~ '^\w$'
    # A tabstop ("$1") or a variable ("$TM_FILENAME")
    SnippetName(state)
    return ''
  elseif c == '{'
    state.pos += 1
    var name: string = SnippetName(state)
    if !name->empty()
      var element: dict<string> = SnippetBracedText(state, name =~ '^\d')
      if !element->empty()
	return element.text
      endif
    endif
  endif

  state.pos = start + 1
  return '$'
enddef

# Return the number of the tabstop or the name of the variable at index
# "state.pos" of the snippet "state.chars", or an empty string when there is
# none there, and move "state.pos" past it.
def SnippetName(state: dict<any>): string
  var chars: list<string> = state.chars
  var pattern: string = chars->get(state.pos, '') =~ '^\d$' ? '^\d$' : '^\w$'
  var name: string = ''
  while chars->get(state.pos, '') =~ pattern
    name ..= chars[state.pos]
    state.pos += 1
  endwhile
  return name
enddef

# Return the text that the rest of the snippet element "${name..." at index
# "state.pos" of the snippet "state.chars" inserts as {text: text}, and move
# "state.pos" past the element.  "isTabstop" is true when "name" is the number
# of a tabstop, false when it is a variable.  Returns an empty dict when the
# element doesn't end.
def SnippetBracedText(state: dict<any>, isTabstop: bool): dict<string>
  var chars: list<string> = state.chars
  var c: string = chars->get(state.pos, '')
  if c == '}'
    # "${1}" or "${TM_FILENAME}"
    state.pos += 1
    return {text: ''}
  elseif c == ':'
    # A placeholder ("${1:text}") or a variable with a default
    state.pos += 1
    var text: string = SnippetText(state, true)
    if chars->get(state.pos, '') != '}'
      return {}
    endif
    state.pos += 1
    return {text: text}
  elseif c == '|' && isTabstop
    # A choice ("${1|one,two|}")
    state.pos += 1
    var first: string = ''
    var inFirst: bool = true
    while state.pos < chars->len()
      c = chars[state.pos]
      var next: string = chars->get(state.pos + 1, '')
      if c == '\' && ['$', '}', '\', ',', '|']->index(next) != -1
	if inFirst
	  first ..= next
	endif
	state.pos += 2
	continue
      endif
      if c == '|' && next == '}'
	state.pos += 2
	return {text: first}
      endif
      if c == ','
	inFirst = false
      elseif inFirst
	first ..= c
      endif
      state.pos += 1
    endwhile
  elseif c == '/'
    # A transform ("${1/regex/format/options}"), whose format can contain
    # elements in braces
    var depth: number = 0
    while state.pos < chars->len()
      c = chars[state.pos]
      if c == '\'
	state.pos += 2
	continue
      endif
      state.pos += 1
      if c == '{'
	depth += 1
      elseif c == '}'
	if depth == 0
	  return {text: ''}
	endif
	depth -= 1
      endif
    endwhile
  endif
  return {}
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
