vim9script

export const featureNames: list<string> = [
  'callHierarchy',
  'codeAction',
  'codeLens',
  'completion',
  'declaration',
  'definition',
  'diagnostics',
  'documentColor',
  'documentFormatting',
  'documentHighlight',
  'documentLink',
  'documentOnTypeFormatting',
  'documentRangeFormatting',
  'documentSymbol',
  'fileOperations',
  'foldingRange',
  'hover',
  'implementation',
  'inlayHint',
  'inlineCompletion',
  'linkedEditingRange',
  'references',
  'rename',
  'selectionRange',
  'semanticTokens',
  'signatureHelp',
  'typeDefinition',
  'typeHierarchy',
  'watchFiles',
  'willSaveWaitUntil',
  'workspaceSymbol'
]

export const serverKeys: dict<dict<any>> = {
  args: {types: [v:t_list], action: 'skip'},
  customNotificationHandlers: {types: [v:t_dict], action: 'reset'},
  customRequestHandlers: {types: [v:t_dict], action: 'reset'},
  debug: {types: [v:t_bool], action: 'reset'},
  features: {types: [v:t_dict], action: 'reset'},
  filetype: {types: [v:t_string, v:t_list], action: 'skip'},
  forceOffsetEncoding: {types: [v:t_string], action: 'reset'},
  initializationOptions: {types: [v:t_dict], action: 'reset'},
  languageId: {types: [v:t_func], action: 'reset'},
  name: {types: [v:t_string], action: 'reset'},
  omnicompl: {types: [v:t_bool], action: 'skip'},
  path: {types: [v:t_string], action: 'skip'},
  processDiagHandler: {types: [v:t_func], action: 'skip'},
  rootSearch: {types: [v:t_list], action: 'reset'},
  runIfSearch: {types: [v:t_list], action: 'reset'},
  runUnlessSearch: {types: [v:t_list], action: 'reset'},
  syncInit: {types: [v:t_bool], action: 'report'},
  traceLevel: {types: [v:t_string], action: 'reset'},
  workspaceConfig: {types: [v:t_dict], action: 'reset'}
}

const serverDefaults: dict<any> = {
  args: [],
  customNotificationHandlers: {},
  customRequestHandlers: {},
  debug: false,
  features: {},
  forceOffsetEncoding: '',
  initializationOptions: {},
  languageId: v:none,
  processDiagHandler: null_function,
  rootSearch: [],
  runIfSearch: [],
  runUnlessSearch: [],
  syncInit: false,
  traceLevel: 'off',
  workspaceConfig: {}
}

const serverValues: dict<list<string>> = {
  forceOffsetEncoding: ['utf-8', 'utf-16', 'utf-32'],
  traceLevel: ['off', 'messages', 'verbose']
}

const serverListItemTypes: dict<list<number>> = {
  args: [v:t_string, v:t_number],
  rootSearch: [v:t_string],
  runIfSearch: [v:t_string],
  runUnlessSearch: [v:t_string]
}

const serverDictValueTypes: dict<list<number>> = {
  customNotificationHandlers: [v:t_func],
  customRequestHandlers: [v:t_func],
  features: [v:t_bool]
}

const optionValues: dict<list<string>> = {
  codeActionPopupDetails: ['short', 'server', 'kind', 'kind-and-server',
    'full-kind', 'full-kind-and-server'],
  completionMatcher: ['case', 'icase', 'fuzzy'],
  diagVirtualTextAlign: ['above', 'below', 'after'],
  diagVirtualTextWrap: ['default', 'truncate', 'wrap'],
  documentationFormat: ['markdown', 'plaintext']
}

const popupOptionBases: list<string> = [
  'popupBorder',
  'popupBorderHighlight',
  'popupHighlight',
  'popupOpacity'
]

const popupOptionTypes: list<string> = [
  'CodeAction',
  'Completion',
  'Diag',
  'Hover',
  'Peek',
  'SignatureHelp',
  'SymbolMenu',
  'SymbolMenuInput',
  'TypeHierarchy'
]

const typeNames: dict<string> = {
  [v:t_bool]: 'a Boolean',
  [v:t_dict]: 'a Dict',
  [v:t_func]: 'a Funcref',
  [v:t_list]: 'a List',
  [v:t_none]: 'null',
  [v:t_number]: 'a Number',
  [v:t_string]: 'a String'
}

def TypeProblem(name: string, value: any, types: list<number>): string
  if types->index(value->type()) != -1
    return ''
  endif
  var actual: string = typeNames->get(value->type()->string(), typename(value))
  var expected: string = types
    ->mapnew((_, t) => typeNames[t->string()])
    ->join(' or ')
  return $'"{name}" is {actual}, expected {expected}'
enddef

def ValueProblem(name: string, value: string, allowed: list<string>): string
  if allowed->index(value) != -1
    return ''
  endif
  var expected: string = allowed->mapnew((_, v) => $'"{v}"')->join(', ')
  return $'"{name}" is "{value}", expected one of {expected}'
enddef

def PopupOptionBase(key: string): string
  for base in popupOptionBases
    for type in popupOptionTypes
      if key == base .. type
	return base
      endif
    endfor
  endfor
  return ''
enddef

def OptionStringProblem(name: string, value: any, base: string): string
  var text: string = TypeProblem(name, value, [v:t_string])
  if text->empty() && optionValues->has_key(base)
    text = ValueProblem(name, value, optionValues[base])
  endif
  return text
enddef

export def OptionProblems(options: dict<any>,
			  defaults: dict<any>): list<string>
  var problems: list<string> = []
  for key in options->keys()->sort()
    var base: string = defaults->has_key(key) ? key : PopupOptionBase(key)
    if base->empty()
      problems->add($'"{key}" is not a known option')
      continue
    endif

    var value: any = options[key]
    var types: list<number> = [defaults[base]->type()]
    if base == 'omniComplete'
      types = [v:t_bool, v:t_none]
    endif
    var text: string = TypeProblem(key, value, types)
    if !text->empty()
      problems->add(text)
      continue
    endif

    var texts: list<string> = []
    if value->type() == v:t_list
      for i in range(value->len())
	texts->add(OptionStringProblem($'{key}[{i}]', value[i], base))
      endfor
    elseif value->type() == v:t_dict
      for name in value->keys()->sort()
	texts->add(OptionStringProblem($'{key}.{name}', value[name], base))
      endfor
    elseif value->type() == v:t_string
      texts->add(OptionStringProblem(key, value, base))
    endif
    problems->extend(texts->filter((_, t) => !t->empty()))
  endfor
  return problems
enddef

def ServerName(server: dict<any>): string
  var name: any = server->get('name', '')
  if name->type() == v:t_string && !name->empty()
    return name
  endif
  var path: any = server->get('path', '')
  if path->type() == v:t_string
    return path->fnamemodify(':t:r')
  endif
  return ''
enddef

export def ServerLabel(server: dict<any>, nr: number): string
  var name: string = ServerName(server)
  return name->empty() ? $'#{nr}' : $'"{name}"'
enddef

export def ServerId(server: dict<any>): string
  return [ServerName(server), server->get('filetype', '')]->string()
enddef

def ServerProblem(key: string, text: string, action: string): dict<any>
  return {key: key, text: text, action: action, missing: false}
enddef

export def ServerProblems(server: dict<any>): list<dict<any>>
  var problems: list<dict<any>> = []
  for key in ['filetype', 'path']
    if !server->has_key(key)
      problems->add(ServerProblem(key, $'"{key}" is missing', 'skip'))
    endif
  endfor

  for key in server->keys()->sort()
    if !serverKeys->has_key(key)
      problems->add(ServerProblem(key, $'"{key}" is not a known key',
	'report'))
      continue
    endif

    var value: any = server[key]
    var action: string = serverKeys[key].action
    var text: string = TypeProblem(key, value, serverKeys[key].types)
    if !text->empty()
      problems->add(ServerProblem(key, text, action))
      continue
    endif

    if serverValues->has_key(key)
      text = ValueProblem(key, value, serverValues[key])
      if !text->empty()
	problems->add(ServerProblem(key, text, action))
      endif
    elseif serverListItemTypes->has_key(key)
      for i in range(value->len())
	text = TypeProblem($'{key}[{i}]', value[i], serverListItemTypes[key])
	if !text->empty()
	  problems->add(ServerProblem(key, text, 'report'))
	endif
      endfor
    elseif serverDictValueTypes->has_key(key)
      for name in value->keys()->sort()
	if key == 'features' && featureNames->index(name) == -1
	  problems->add(ServerProblem(key,
	    $'"{key}.{name}" is not a known feature', 'report'))
	  continue
	endif
	text = TypeProblem($'{key}.{name}', value[name],
	  serverDictValueTypes[key])
	if !text->empty()
	  problems->add(ServerProblem(key, text, 'report'))
	endif
      endfor
    elseif key == 'name'
      if value->empty()
	problems->add(ServerProblem(key, $'"{key}" is empty', action))
      endif
    elseif key == 'path'
      var path: string = value->expandcmd()
      if !path->executable()
	problems->add({key: key, text: $'"{key}" is not executable: {path}',
	  action: action, missing: true})
      endif
    elseif key == 'filetype'
      var ftypes: list<any> = value->type() == v:t_list ? value : [value]
      if ftypes->empty()
	problems->add(ServerProblem(key, $'"{key}" is empty', 'report'))
      endif
      for i in range(ftypes->len())
	var name: string = value->type() == v:t_list ? $'{key}[{i}]' : key
	text = TypeProblem(name, ftypes[i], [v:t_string])
	if !text->empty()
	  problems->add(ServerProblem(key, text, action))
	elseif ftypes[i]->empty()
	  problems->add(ServerProblem(key, $'"{name}" is empty', 'report'))
	endif
      endfor
    endif
  endfor
  return problems
enddef

export def ServerNormalize(server: dict<any>, problems: list<dict<any>>)
  var resetKeys: list<string> = []
  for problem in problems
    if problem.action == 'reset'
      resetKeys->add(problem.key)
    endif
  endfor

  for [key, value] in serverDefaults->items()
    if !server->has_key(key) || resetKeys->index(key) != -1
      server[key] = value
    endif
  endfor

  server.path = server.path->expandcmd()
  if !server->has_key('name') || resetKeys->index('name') != -1
    server.name = server.path->fnamemodify(':t:r')
  endif
enddef

export def ConfigProblems(options: dict<any>, defaults: dict<any>,
			  servers: list<dict<any>>): list<string>
  var lines: list<string> = []
  for text in OptionProblems(options, defaults)
    lines->add($'option {text}')
  endfor

  var ignoreMissing: any = options->get('ignoreMissingServer', false)
  for i in range(servers->len())
    var label: string = ServerLabel(servers[i], i + 1)
    for problem in ServerProblems(servers[i])
      if problem.missing && ignoreMissing->type() == v:t_bool && ignoreMissing
	continue
      endif
      lines->add($'server {label}: {problem.text}')
    endfor
  endfor
  return lines
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
