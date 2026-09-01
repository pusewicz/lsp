vim9script

# Named constants for the numeric enums defined by the Language Server
# Protocol specification, so callers don't have to compare against bare
# integer literals.
# Refer to https://microsoft.github.io/language-server-protocol/specification
# for the Language Server Protocol (LSP) specification.

# TextDocumentSyncKind
export const TextDocumentSyncKind = {
  None: 0,
  Full: 1,
  Incremental: 2
}

# DocumentHighlightKind
export const DocumentHighlightKind = {
  Text: 1,
  Read: 2,
  Write: 3
}

# CompletionTriggerKind
export const CompletionTriggerKind = {
  Invoked: 1,
  TriggerCharacter: 2,
  TriggerForIncompleteCompletions: 3
}

# InsertTextFormat
export const InsertTextFormat = {
  PlainText: 1,
  Snippet: 2
}

# InsertTextMode
export const InsertTextMode = {
  asIs: 1,
  adjustIndentation: 2
}

# MessageType
export const MessageType = {
  Error: 1,
  Warning: 2,
  Info: 3,
  Log: 4
}

# InlayHintKind
export const InlayHintKind = {
  Type: 1,
  Parameter: 2
}

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
