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
- Async requests reply asynchronously in tests (#124): wait for effects with `g:WaitForAssert()` or `g:WaitForReplies()`, and wait for the reply before feeding more keys.
- Prefer stub-server tests in `test/stub_lspserver_tests.vim` over real servers; `StartStubServerJob()` gives a real job channel.
- CI's MacVim (Homebrew cask) is older than a local build, so typeahead and timing behaviour can differ.
- After resolving conflicts in a test file, compare the `Test_` counts before and after: a dropped `enddef` nests the next test and it silently stops running.

## Gotchas

- Most server requests are async since #81; code that needs the reply before continuing (e.g. before a write) must request it synchronously, like `textDocFormat()`'s `sync` flag.
- `setline()` drops every text property on the line; use `:keeppatterns substitute` to keep diagnostic and semantic highlights.
- An unbuffered `listener_add()` callback still fires for the next change after `listener_remove()` (Vim bug; see `autoload/lsp/folding.vim`).
