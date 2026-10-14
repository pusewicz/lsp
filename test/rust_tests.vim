vim9script
# Unit tests for LSP rust-analyzer client

source common.vim

var lspOpts = {autoComplete: false}
g:LspOptionsSet(lspOpts)

var lspServers = [{
      filetype: ['rust'],
      path: exepath('rust-analyzer'),
      args: [],
      debug: g:LspServerDebug()
  }]
call LspAddServer(lspServers)
echomsg systemlist($'{lspServers[0].path} --version')

def g:Test_LspGotoDef()
  settagstack(0, {items: []})
  :cd xrust_tests/src
  try
    silent! edit ./main.rs
    deletebufline('%', 1, '$')
    g:WaitForServerFileLoad(0)
    var lines: list<string> =<< trim END
      fn main() {
      }
      fn foo() {
      }
      fn bar() {
        foo();
      }
    END
    setline(1, lines)
    g:WaitForServerFileLoad(0)
    cursor(6, 5)
    :LspGotoDefinition
    g:WaitForReplies()
    assert_equal([3, 4], [line('.'), col('.')])
    :%bw!
  finally
    :cd ../..
  endtry
enddef

# Test for :LspCodeAction creating a file in the current directory
def g:Test_LspCodeAction_CreateFile()
  :cd xrust_tests/src
  try
    silent! edit ./main.rs
    deletebufline('%', 1, '$')
    g:WaitForServerFileLoad(0)
    var lines: list<string> =<< trim END
      mod foo;
      fn main() {
      }
    END
    setline(1, lines)
    g:WaitForServerFileLoad(1)
    cursor(1, 1)
    :LspCodeAction 1
    g:WaitForReplies()
    g:WaitForServerFileLoad(0)
    assert_true(filereadable('foo.rs'))
    :%bw!
    delete('foo.rs')
  finally
    :cd ../..
  endtry
enddef

# Test for :LspCodeAction creating a file in a subdirectory
def g:Test_LspCodeAction_CreateFile_Subdir()
  :cd xrust_tests/src
  try
    silent! edit ./main.rs
    deletebufline('%', 1, '$')
    g:WaitForServerFileLoad(0)
    var lines: list<string> =<< trim END
      mod baz;
      fn main() {
      }
    END
    setline(1, lines)
    g:WaitForServerFileLoad(1)
    cursor(1, 1)
    :LspCodeAction 2
    # Don't wait for the server to clear the diagnostic: rust-analyzer watches
    # each directory on its own and can miss a file created right after its
    # directory, as on macOS.
    g:WaitForAssert(() => assert_true(filereadable('baz/mod.rs')))
    :%bw!
    delete('baz', 'rf')
  finally
    :cd ../..
  endtry
enddef

# Test for :LspCodeAction renaming a file
def g:Test_LspCodeAction_RenameFile()
  :cd xrust_tests/src
  try
    silent! edit ./main.rs
    deletebufline('%', 1, '$')
    g:WaitForServerFileLoad(0)
    writefile([], 'foobar.rs')
    var lines: list<string> =<< trim END
      mod foobar;
      fn main() {
      }
    END
    setline(1, lines)
    g:WaitForServerFileLoad(0)
    cursor(1, 5)
    :LspRename foobaz
    g:WaitForReplies()
    g:WaitForServerFileLoad(0)
    assert_true(filereadable('foobaz.rs'))
    :%bw!
    delete('foobaz.rs')
  finally
    :cd ../..
  endtry
enddef

# Test for omni completion with replace-insert-edit field
# This tests the handling of InsertReplaceEdit where the replace range
# is larger than the insert range
def g:Test_OmniComplete_ReplaceInsertEdit()
  :cd xrust_tests/src
  try
    silent! edit ./main.rs
    deletebufline('%', 1, '$')
    g:WaitForServerFileLoad(0)
    var lines: list<string> =<< trim END
      struct TestData {
          field_name: i32,
          another_field: String,
      }

      fn main() {
          let data = TestData {
              field: 0,
              another_field: String::new(),
          };
      }
    END
    setline(1, lines)
    g:WaitForServerFileLoad(2)
    redraw!

    # Position cursor at "field:" on line 10 and trigger completion
    cursor(8, 10)
    g:FeedOmniCompleteKeys("a\<C-X>\<C-O>")
    # After completion, should have "field_name:" which demonstrates the
    # replace-insert-edit handling
    g:WaitForAssert(() => assert_match('^\s\+field_name: 0,', getline(8)))
    :%bw!
  finally
    :cd ../..
  endtry
enddef

def g:Test_ZZZ_Cleanup()
  delete('./xrust_tests', 'rf')
enddef

# Start the rust-analyzer language server and wait for it to load the
# workspace.  Returns true on success and false on failure.  Until the
# workspace is loaded rust-analyzer reports no diagnostics, which the tests
# wait for, and loading it (fetching the metadata, scanning the sysroot,
# priming the caches) can take longer than a test waits for them.
def g:StartLangServer(): bool
  system('cargo new xrust_tests')
  :cd xrust_tests/src
  var status = false
  try
    status = g:StartLangServerWithFile('./main.rs')
    if status
      silent! edit ./main.rs
      append('$', '-')
      status = g:WaitForCommon(() => lsp#lsp#ErrorCount().Error > 0, v:null,
			       180000) >= 0
      :bw!
    endif
  finally
    :cd ../..
  endtry
  return status
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
