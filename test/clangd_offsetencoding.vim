vim9script
# Unit tests for language server protocol offset encoding using clangd

import '../autoload/lsp/buffer.vim' as buf
import '../autoload/lsp/diag.vim' as diag
import '../autoload/lsp/util.vim' as util

source common.vim

# Start the C language server.  Returns true on success and false on failure.
def g:StartLangServer(): bool
  return g:StartLangServerWithFile('Xtest.c')
enddef

var lspOpts = {autoComplete: false}
g:LspOptionsSet(lspOpts)

var lspServers = [{
      filetype: ['c', 'cpp'],
      path: g:ClangdPath(),
      args: ['--background-index',
	     '--clang-tidy',
	     $'--offset-encoding={$LSP_OFFSET_ENCODING}'],
      debug: g:LspServerDebug()
  }]
call LspAddServer(lspServers)

# Test for :LspCodeAction with symbols containing multibyte and composing
# characters
def g:Test_LspCodeAction_multibyte()
  silent! edit XLspCodeAction_mb.c
  var lines =<< trim END
    #include <stdio.h>
    void fn(int aVar)
    {
        printf("aVar = %d\n", aVar);
        printf("😊😊😊😊 = %d\n", aVar):
        printf("áb́áb́ = %d\n", aVar):
        printf("ą́ą́ą́ą́ = %d\n", aVar):
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(3)
  :redraw!
  cursor(5, 5)
  redraw!
  :LspCodeAction 1
  assert_equal('    printf("😊😊😊😊 = %d\n", aVar);', getline(5))
  cursor(6, 5)
  redraw!
  :LspCodeAction 1
  assert_equal('    printf("áb́áb́ = %d\n", aVar);', getline(6))
  cursor(7, 5)
  redraw!
  :LspCodeAction 1
  assert_equal('    printf("ą́ą́ą́ą́ = %d\n", aVar);', getline(7))

  :%bw!
enddef

# Test for :LspAutoFix with diagnostics after multibyte and composing
# characters
def g:Test_LspAutoFix_multibyte()
  silent! edit XLspAutoFix_mb.c
  var lines =<< trim END
    #include <stdio.h>
    void fn(int aVar)
    {
        printf("aVar = %d\n", aVar);
        printf("😊😊😊😊 = %d\n", aVar):
        printf("áb́áb́ = %d\n", aVar):
        printf("ą́ą́ą́ą́ = %d\n", aVar):
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(3)
  :5,7LspAutoFix
  var fixed = lines[4 : 6]->mapnew((_, l) => l->substitute(':$', ';', ''))
  g:WaitForAssert(() => assert_equal(fixed, getline(5, 7)))

  :%bw!
enddef

# Test for ":LspDiag show" when using multibyte and composing characters
def g:Test_LspDiagShow_multibyte()
  :silent! edit XLspDiagShow_mb.c
  var lines =<< trim END
    #include <stdio.h>
    void fn(int aVar)
    {
        printf("aVar = %d\n", aVar);
        printf("😊😊😊😊 = %d\n". aVar);
        printf("áb́áb́ = %d\n". aVar);
        printf("ą́ą́ą́ą́ = %d\n". aVar);
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(3)
  :redraw!
  :LspDiag show
  var qfl: list<dict<any>> = getloclist(0)
  assert_equal([5, 37], [qfl[0].lnum, qfl[0].col])
  assert_equal([6, 33], [qfl[1].lnum, qfl[1].col])
  assert_equal([7, 41], [qfl[2].lnum, qfl[2].col])
  :lclose
  :%bw!
enddef

# Test for the inline highlight and the location list entry of diagnostics
# whose range starts or ends past the end of a line with multibyte and
# composing characters.  A position past the end of a line is at the end of
# the line.
def g:Test_LspDiag_RangePastEol_multibyte()
  :silent! edit XLspDiagPastEol_mb.c
  setline(1, ['int x;', '// ééé', '// 😊😊', "// a\u0301b\u0301"])
  g:WaitForServerFileLoad(0)
  var bnr = bufnr()
  var lspserver = buf.CurbufGetServer()

  # Length of each line in the UTF-8, UTF-16 and UTF-32 encodings
  var lineLen: dict<list<number>> = {8: [6, 9, 11, 9], 16: [6, 6, 7, 7],
				     32: [6, 6, 5, 7]}
  # The range on the first line starts past the end of the line.  The other
  # ranges start at the first multibyte character.
  var diags: list<dict<any>> = []
  for i in range(4)
    var pastEol = lineLen[lspserver.posEncoding][i] + 1
    diags->add({
      range: {
	start: {line: i, character: i == 0 ? pastEol : 3},
	end: {line: i, character: pastEol}
      },
      severity: 1,
      message: $'Diag {i + 1}'
    })
  endfor
  diag.DiagNotification(lspserver, util.LspBufnrToUri(bnr), diags, 'push')

  assert_equal([[1, 7, 0], [2, 4, 6], [3, 4, 8], [4, 4, 6]],
	       prop_list(1, {end_lnum: line('$')})
		 ->filter((_, p) => p.type == 'LspDiagInlineError')
		 ->mapnew((_, p) => [p.lnum, p.col, p.length]))
  :LspDiag show
  assert_equal([[1, 7, 1, 7], [2, 4, 2, 10], [3, 4, 3, 12], [4, 4, 4, 10]],
	       getloclist(0)->mapnew((_, v) => [v.lnum, v.col, v.end_lnum, v.end_col]))
  :lclose
  :%bw!
enddef

# Test for :LspFormat when using multibyte and composing characters
def g:Test_LspDocumentLink_multibyte()
  writefile(['int xdoclink_mb;'], 'Xdoclink😊.h')
  :silent! edit XLspDocumentLink_mb.c
  setline(1, ['#include "Xdoclink😊.h" // 😊', 'int *x = &xdoclink_mb;'])
  g:WaitForServerFileLoad(0)
  setlocal nomodified
  :LspDocumentLink
  var loclist: list<dict<any>> = getloclist(0)
  assert_equal(1, loclist->len())
  assert_equal([1, 10, 1, 26, 'Xdoclink😊.h'],
	       [loclist[0].lnum, loclist[0].col, loclist[0].end_lnum,
		loclist[0].end_col, loclist[0].text])
  :lclose

  # The cursor is on the closing quote, the last character of the link
  cursor(1, 25)
  :LspDocumentLinkOpen
  assert_equal('Xdoclink😊.h', expand('%:t'))

  :%bw!
  delete('Xdoclink😊.h')
enddef

# Returns [type, lnum, col, length] of the text properties highlighting the
# range and the name of the symbol selected in the :LspDocumentSymbol popup.
def SymbolHighlightProps(): list<list<any>>
  return prop_list(1, {end_lnum: line('$'),
		       types: ['LspSymbolRangeProp', 'LspSymbolNameProp']})
	->mapnew((_, p) => [p.type, p.lnum, p.col, p.length])
enddef

# Test for highlighting the range and the name of the selected symbol in the
# :LspDocumentSymbol popup when using multibyte and composing characters
def g:Test_LspDocumentSymbol_multibyte()
  :silent! edit XLspDocumentSymbol_mb.c
  setline(1, ['/* ééé */ int 😊😊 = 1;', "/* 😊 */ int a\u0301b\u0301 = 2;"])
  g:WaitForServerFileLoad(0)

  var expected: list<list<list<any>>> = [
    [['LspSymbolRangeProp', 1, 14, 16], ['LspSymbolNameProp', 1, 18, 8]],
    [['LspSymbolRangeProp', 2, 12, 14], ['LspSymbolNameProp', 2, 16, 6]]
  ]
  for lnum in [1, 2]
    cursor(lnum, 1)
    :LspDocumentSymbol
    g:WaitForAssert(() => assert_equal(expected[lnum - 1],
				       SymbolHighlightProps()))
    feedkeys("\<Esc>", 'xt')
    assert_equal([], SymbolHighlightProps())
  endfor

  popup_clear()
  :%bw!
enddef

def g:Test_LspFormat_multibyte()
  :silent! edit XLspFormat_mb.c
  var lines =<< trim END
    void fn(int aVar)
    {
	int 😊😊😊😊   =   aVar + 1;
	int áb́áb́   =   aVar + 1;
	int ą́ą́ą́ą́   =   aVar + 1;
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)
  :redraw!
  :LspFormat
  var expected =<< trim END
    void fn(int aVar) {
      int 😊😊😊😊 = aVar + 1;
      int áb́áb́ = aVar + 1;
      int ą́ą́ą́ą́ = aVar + 1;
    }
  END
  assert_equal(expected, getline(1, '$'))
  :%bw!
enddef

# Test for formatting a range of lines with :LspFormat when the last line has
# composing characters.  The range ends at the end of the last line.
def g:Test_LspFormat_range_multibyte()
  :silent! edit XLspFormatRange_mb.c
  setline(1, ['int   x;', "int   a\u0301b\u0301   =   1;", 'int   y;'])
  g:WaitForServerFileLoad(0)
  var lspserver = buf.CurbufGetServer()
  var SavedRpc: func = lspserver.rpc
  var params: dict<any> = {}
  lspserver.rpc = (method: string, p: dict<any>): dict<any> => {
    params = p
    return SavedRpc(method, p)
  }
  try
    :2LspFormat
  finally
    lspserver.rpc = SavedRpc
  endtry

  # Length of the second line in the UTF-8, UTF-16 and UTF-32 encodings
  var lineLen: dict<number> = {8: 21, 16: 19, 32: 19}
  assert_equal({start: {line: 1, character: 0},
		end: {line: 1, character: lineLen[lspserver.posEncoding]}},
	       params.range)
  assert_equal(['int   x;', "int a\u0301b\u0301 = 1;", 'int   y;'],
	       getline(1, '$'))
  :%bw!
enddef

# Test for :LspGotoDefinition when using multibyte and composing characters
def g:Test_LspGotoDefinition_multibyte()
  :silent! edit XLspGotoDefinition_mb.c
  var lines: list<string> =<< trim END
    #include <stdio.h>
    void fn(int aVar)
    {
        printf("aVar = %d\n", aVar);
        printf("😊😊😊😊 = %d\n", aVar);
        printf("áb́áb́ = %d\n", aVar);
        printf("ą́ą́ą́ą́ = %d\n", aVar);
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)
  redraw!

  for [lnum, colnr] in [[4, 27], [5, 39], [6, 35], [7, 43]]
    cursor(lnum, colnr)
    :LspGotoDefinition
    assert_equal([2, 13], [line('.'), col('.')])
  endfor

  :%bw!
enddef

# Test for :LspGotoDefinition when using multibyte and composing characters
def g:Test_LspGotoDefinition_after_multibyte()
  :silent! edit XLspGotoDef_after_mb.c
  var lines =<< trim END
    void fn(int aVar)
    {
        /* αβγδ, 😊😊😊😊, áb́áb́, ą́ą́ą́ą́ */ int αβγδ, bVar;
        /* αβγδ, 😊😊😊😊, áb́áb́, ą́ą́ą́ą́ */ int 😊😊😊😊, cVar;
        /* αβγδ, 😊😊😊😊, áb́áb́, ą́ą́ą́ą́ */ int áb́áb́, dVar;
        /* αβγδ, 😊😊😊😊, áb́áb́, ą́ą́ą́ą́ */ int ą́ą́ą́ą́, eVar;
        bVar = 1;
        cVar = 2;
        dVar = 3;
        eVar = 4;
	aVar = αβγδ + 😊😊😊😊 + áb́áb́ + ą́ą́ą́ą́ + bVar;
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)
  :redraw!
  cursor(7, 5)
  :LspGotoDefinition
  assert_equal([3, 88], [line('.'), col('.')])
  cursor(8, 5)
  :LspGotoDefinition
  assert_equal([4, 96], [line('.'), col('.')])
  cursor(9, 5)
  :LspGotoDefinition
  assert_equal([5, 92], [line('.'), col('.')])
  cursor(10, 5)
  :LspGotoDefinition
  assert_equal([6, 100], [line('.'), col('.')])
  cursor(11, 12)
  :LspGotoDefinition
  assert_equal([3, 78], [line('.'), col('.')])
  cursor(11, 23)
  :LspGotoDefinition
  assert_equal([4, 78], [line('.'), col('.')])
  cursor(11, 42)
  :LspGotoDefinition
  assert_equal([5, 78], [line('.'), col('.')])
  cursor(11, 57)
  :LspGotoDefinition
  assert_equal([6, 78], [line('.'), col('.')])

  :%bw!
enddef

# Test for doing omni completion for symbols with multibyte and composing
# characters
def g:Test_OmniComplete_multibyte()
  :silent! edit XOmniComplete_mb.c
  var lines: list<string> =<< trim END
    void Func1(void)
    {
        int 😊😊😊😊, aVar;
        int áb́áb́, bVar;
        int ą́ą́ą́ą́, cVar;
        
        
        
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)
  redraw!

  cursor(6, 4)
  feedkeys("aaV\<C-X>\<C-O> = 😊😊\<C-X>\<C-O>;", 'xt')
  assert_equal('    aVar = 😊😊😊😊;', getline('.'))
  cursor(7, 4)
  feedkeys("abV\<C-X>\<C-O> = áb́\<C-X>\<C-O>;", 'xt')
  assert_equal('    bVar = áb́áb́;', getline('.'))
  cursor(8, 4)
  feedkeys("acV\<C-X>\<C-O> = ą́ą́\<C-X>\<C-O>;", 'xt')
  assert_equal('    cVar = ą́ą́ą́ą́;', getline('.'))
  feedkeys("oáb́\<C-X>\<C-O> = ą́ą́\<C-X>\<C-O>;", 'xt')
  assert_equal('    áb́áb́ = ą́ą́ą́ą́;', getline('.'))
  feedkeys("oą́ą́\<C-X>\<C-O> = áb́\<C-X>\<C-O>;", 'xt')
  assert_equal('    ą́ą́ą́ą́ = áb́áb́;', getline('.'))
  :%bw!
enddef

# Test for :LspOutline with multibyte and composing characters
def g:Test_Outline_multibyte()
  silent! edit XLspOutline_mb.c
  var lines: list<string> =<< trim END
    typedef void 😊😊😊😊;
    typedef void áb́áb́;
    typedef void ą́ą́ą́ą́;
    
    😊😊😊😊 Func1()
    {
    }
    
    áb́áb́ Func2()
    {
    }
    
    ą́ą́ą́ą́ Func3()
    {
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)
  redraw!

  cursor(1, 1)
  :LspOutline
  assert_equal(2, winnr('$'))
  assert_equal(['Class@', '  😊😊😊😊',
		"  a\u0301b\u0301a\u0301b\u0301",
		"  " .. repeat("a\u0328\u0301", 4), '',
		'Function@', '  Func1', '  Func2', '  Func3'],
	       getbufline('LSP-Outline', 4, '$'))

  :wincmd w
  cursor(10, 1)
  feedkeys("\<CR>", 'xt')
  assert_equal([2, 5, 18], [winnr(), line('.'), col('.')])

  :wincmd w
  cursor(11, 1)
  feedkeys("\<CR>", 'xt')
  assert_equal([2, 9, 14], [winnr(), line('.'), col('.')])

  :wincmd w
  cursor(12, 1)
  feedkeys("\<CR>", 'xt')
  assert_equal([2, 13, 22], [winnr(), line('.'), col('.')])

  :wincmd w
  cursor(5, 1)
  feedkeys("\<CR>", 'xt')
  assert_equal([2, 1, 14], [winnr(), line('.'), col('.')])

  :wincmd w
  cursor(6, 1)
  feedkeys("\<CR>", 'xt')
  assert_equal([2, 2, 14], [winnr(), line('.'), col('.')])

  :wincmd w
  cursor(7, 1)
  feedkeys("\<CR>", 'xt')
  assert_equal([2, 3, 14], [winnr(), line('.'), col('.')])

  :%bw!
enddef

# Test for :LspRename with multibyte and composing characters
def g:Test_LspRename_multibyte()
  silent! edit XLspRename_mb.c
  var lines: list<string> =<< trim END
    #include <stdio.h>
    void fn(int aVar)
    {
        printf("aVar = %d\n", aVar);
        printf("😊😊😊😊 = %d\n", aVar);
        printf("áb́áb́ = %d\n", aVar);
        printf("ą́ą́ą́ą́ = %d\n", aVar);
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)
  redraw!
  cursor(2, 12)
  :LspRename bVar
  redraw!
  var expected: list<string> =<< trim END
    #include <stdio.h>
    void fn(int bVar)
    {
        printf("aVar = %d\n", bVar);
        printf("😊😊😊😊 = %d\n", bVar);
        printf("áb́áb́ = %d\n", bVar);
        printf("ą́ą́ą́ą́ = %d\n", bVar);
    }
  END
  assert_equal(expected, getline(1, '$'))
  :%bw!
enddef

# Test for :LspSelectionExpand and :LspSelectionShrink when using multibyte and
# composing characters
def g:Test_LspSelection_multibyte()
  silent! edit XLspSelection_mb.c
  var lines: list<string> =<< trim END
    void fn(void)
    {
        char *s = "ééé😊 x";
        int 😊😊 = 1, áb́áb́ = 2;
        😊😊 = áb́áb́ + 😊😊;
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)
  xnoremap <silent> le <Cmd>LspSelectionExpand<CR>
  xnoremap <silent> ls <Cmd>LspSelectionShrink<CR>

  var body: string = join(lines[1 : 5], "\n")
  var expected: list<string> = ['"ééé😊 x"', 'char *s = "ééé😊 x"',
				'char *s = "ééé😊 x";', body, join(lines, "\n")]
  for i in range(expected->len())
    cursor(3, 18)
    exe $'normal v{repeat("le", i + 1)}y'
    assert_equal(expected[i], @")
  endfor
  cursor(3, 18)
  normal vlelelelelslsy
  assert_equal('char *s = "ééé😊 x"', @")
  assert_equal([3, 5, 3, 28], [line("'<"), col("'<"), line("'>"), col("'>")])

  expected = ['áb́áb́', 'áb́áb́ + 😊😊', '😊😊 = áb́áb́ + 😊😊', body]
  for i in range(expected->len())
    cursor(5, 21)
    exe $'normal v{repeat("le", i + 1)}y'
    assert_equal(expected[i], @")
  endfor
  cursor(5, 21)
  normal vleleley
  assert_equal([5, 5, 5, 33], [line("'<"), col("'<"), line("'>"), col("'>")])

  xunmap le
  xunmap ls
  :%bw!
enddef

# Test for :LspShowReferences when using multibyte and composing characters
def g:Test_LspShowReferences_multibyte()
  :silent! edit XLspShowReferences_mb.c
  var lines: list<string> =<< trim END
    #include <stdio.h>
    void fn(int aVar)
    {
        printf("aVar = %d\n", aVar);
        printf("😊😊😊😊 = %d\n", aVar);
        printf("áb́áb́ = %d\n", aVar);
        printf("ą́ą́ą́ą́ = %d\n", aVar);
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)
  redraw!
  cursor(4, 27)
  :LspShowReferences
  assert_equal([[2, 13, 2, 17], [4, 27, 4, 31], [5, 39, 5, 43], [6, 35, 6, 39],
		[7, 43, 7, 47]],
	       getloclist(0)->mapnew((_, v) => [v.lnum, v.col, v.end_lnum, v.end_col]))
  :lclose

  :%bw!
enddef

# Test for the range of the :LspShowReferences locations when the symbol name
# contains multibyte and composing characters
def g:Test_LspShowReferences_multibyte_symbol()
  :silent! edit XLspShowReferences_mb_sym.c
  var lines: list<string> =<< trim END
    void fn(void)
    {
        int 😊😊😊😊 = 1, áb́áb́ = 2;
        😊😊😊😊 = áb́áb́ + 😊😊😊😊;
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)
  redraw!
  cursor(4, 5)
  :LspShowReferences
  assert_equal([[3, 9, 3, 25], [4, 5, 4, 21], [4, 39, 4, 55]],
	       getloclist(0)->mapnew((_, v) => [v.lnum, v.col, v.end_lnum, v.end_col]))
  :lclose
  cursor(4, 24)
  :LspShowReferences
  assert_equal([[3, 31, 3, 43], [4, 24, 4, 36]],
	       getloclist(0)->mapnew((_, v) => [v.lnum, v.col, v.end_lnum, v.end_col]))
  :lclose

  :%bw!
enddef

# Test for :LspSymbolSearch when using multibyte and composing characters
def g:Test_LspSymbolSearch_multibyte()
  silent! edit XLspSymbolSearch_mb.c
  var lines: list<string> =<< trim END
    typedef void 😊😊😊😊;
    typedef void áb́áb́;
    typedef void ą́ą́ą́ą́;

    😊😊😊😊 Func1()
    {
    }

    áb́áb́ Func2()
    {
    }

    ą́ą́ą́ą́ Func3()
    {
    }
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)

  cursor(1, 1)
  feedkeys(":LspSymbolSearch Func1\<CR>", "xt")
  assert_equal([5, 18], [line('.'), col('.')])
  cursor(1, 1)
  feedkeys(":LspSymbolSearch Func2\<CR>", "xt")
  assert_equal([9, 14], [line('.'), col('.')])
  cursor(1, 1)
  feedkeys(":LspSymbolSearch Func3\<CR>", "xt")
  assert_equal([13, 22], [line('.'), col('.')])

  :%bw!
enddef

# Test for setting the 'tagfunc' with multibyte and composing characters in
# symbols
def g:Test_LspTagFunc_multibyte()
  var lines =<< trim END
    void fn(int aVar)
    {
        int 😊😊😊😊, bVar;
        int áb́áb́, cVar;
        int ą́ą́ą́ą́, dVar;
        bVar = 10;
        cVar = 10;
        dVar = 10;
    }
  END
  writefile(lines, 'Xtagfunc_mb.c')
  :silent! edit! Xtagfunc_mb.c
  g:WaitForServerFileLoad(0)
  :setlocal tagfunc=lsp#lsp#TagFunc
  cursor(6, 5)
  :exe "normal \<C-]>"
  assert_equal([3, 27], [line('.'), col('.')])
  cursor(7, 5)
  :exe "normal \<C-]>"
  assert_equal([4, 23], [line('.'), col('.')])
  cursor(8, 5)
  :exe "normal \<C-]>"
  assert_equal([5, 31], [line('.'), col('.')])
  :set tagfunc&

  :%bw!
  delete('Xtagfunc_mb.c')
enddef

# Test for the :LspSuperTypeHierarchy and :LspSubTypeHierarchy commands with
# multibyte and composing characters
def g:Test_LspTypeHier_multibyte()
  silent! edit XLspTypeHier_mb.cpp
  var lines =<< trim END
    /* αβ😊😊ááą́ą́ */ class parent {
    };

    /* αβ😊😊ááą́ą́ */ class child : public parent {
    };

    /* αβ😊😊ááą́ą́ */ class grandchild : public child {
    };
  END
  setline(1, lines)
  g:WaitForServerFileLoad(0)
  redraw!

  cursor(1, 42)
  :LspSubTypeHierarchy
  call feedkeys("\<CR>", 'xt')
  assert_equal([1, 36], [line('.'), col('.')])
  cursor(1, 42)

  :LspSubTypeHierarchy
  call feedkeys("\<Down>\<CR>", 'xt')
  assert_equal([4, 42], [line('.'), col('.')])

  cursor(1, 42)
  :LspSubTypeHierarchy
  call feedkeys("\<Down>\<Down>\<CR>", 'xt')
  assert_equal([7, 42], [line('.'), col('.')])

  cursor(7, 42)
  :LspSuperTypeHierarchy
  call feedkeys("\<CR>", 'xt')
  assert_equal([7, 36], [line('.'), col('.')])

  cursor(7, 42)
  :LspSuperTypeHierarchy
  call feedkeys("\<Down>\<CR>", 'xt')
  assert_equal([4, 42], [line('.'), col('.')])

  cursor(7, 42)
  :LspSuperTypeHierarchy
  call feedkeys("\<Down>\<Down>\<CR>", 'xt')
  assert_equal([1, 42], [line('.'), col('.')])

  :%bw!
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 noexpandtab
