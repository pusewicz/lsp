# pusewicz/lsp

Fork of yegappan/lsp for MacVim / Vim 9.2+ only: no compat code for older Vims or other platforms, nothing is upstreamed.

## Workflow

- Branch from origin/main and open a PR, then enable auto-merge right away: `gh pr merge <n> --auto --merge` (the repo merges with merge commits).
- Open a GitHub issue for every deferred follow-up and link it from the PR.
- User-visible changes update `doc/lsp.txt` and the feature/option lists in `README.md`.
- The required CI check is the aggregating `macvim` job in `.github/workflows/unitests.yml`; keep that job name.

## Tests

- `cd test && ./run_tests.sh <file>|clangd|others` - run single files locally; the full suite starts clangd, gopls, rust-analyzer and tsserver and belongs to CI.
- Never run two test runs in the same `test/` directory at once: they share `results.txt`.
- Async requests reply asynchronously in tests (#124): wait for effects with `g:WaitForAssert()` or `g:WaitForReplies()`.  Keys pending after a command in the same `feedkeys()`, `:normal` or mapping wait for its reply (#123), the next line of a test doesn't.
- Prefer stub-server tests in `test/stub_lspserver_tests.vim` over real servers; `StartStubServerJob()` gives a real job channel.
- CI installs the MacVim release named in `MACVIM_RELEASE` in the workflow, not Homebrew's cask, which lags behind; it can differ from a local build in typeahead and timing behaviour. `test/check_vim_version.sh` holds the oldest Vim patch the plugin needs: raise `MIN_VIM_PATCH` there, and the release, when the plugin starts to use a newer one.
- The runner fails a file whose declared `Test_` functions don't all run (e.g. an `enddef` moved below the next test nests it), so read such a FAIL after a conflict fix as a broken merge.

## Gotchas

- Most server requests are async since #81; code that needs the reply before continuing (e.g. before a write) must request it synchronously, like `textDocFormat()`'s `sync` flag.
- The request of a user command, or of a key in a menu, passes `beforePendingKeys: true` to `rpc_a()` so that keys pending after it wait for its reply; background requests (autocommands, timers, `'foldexpr'`) must not, as they would block macros.
- `setline()` drops every text property on the line; change text with `textedit.ReplaceText()` (`:keeppatterns substitute`) to keep diagnostic and semantic highlights and snippet tabstops.
- Avoid multi-line text properties: a charwise delete across lines and `:join` then raise E340/E685 (Vim bug); mark a range with zero-width properties at both ends, as the snippet tabstops do.
- An unbuffered `listener_add()` callback still fires for the next change after `listener_remove()` (Vim bug; see `autoload/lsp/folding.vim`).
