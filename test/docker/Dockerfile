# Runs the plugin tests in the environment of the GitHub Actions workflow
# (.github/workflows/unitests.yml): an Ubuntu 24.04 runner with the language
# servers it installs and Vim built from source as rhysd/action-setup-vim
# builds it.  test/docker/run_tests.sh builds one image per Vim version:
#
#   docker build --build-arg VIM_VERSION=v9.0.0000 -t lsp-tests:vim-v9.0.0000 test/docker
#
# Keep it in sync with the workflow.

FROM ubuntu:24.04 AS base

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Vim takes its 'encoding' from the locale.  It is utf-8 in CI, while without
# a locale it would be latin1, and some tests behave differently then.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# Tools the runner image comes with that the workflow and the tests use.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git gnupg sudo \
 && rm -rf /var/lib/apt/lists/*

# CI runs as the "runner" user (uid 1001) with passwordless sudo.
RUN useradd --create-home --uid 1001 --shell /bin/bash runner \
 && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner


FROM base AS vim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libncurses-dev \
 && rm -rf /var/lib/apt/lists/*

USER runner

# "nightly" or a tag of https://github.com/vim/vim, as in the workflow matrix.
ARG VIM_VERSION=nightly
# The commit VIM_VERSION points to.  run_tests.sh passes it so that Vim is
# rebuilt only when the branch or tag moves, like the CI cache key.
ARG VIM_COMMIT=

# The same configure flags and install prefix as rhysd/action-setup-vim.
RUN if [[ $VIM_VERSION == nightly ]]; then ref=HEAD; else ref=refs/tags/$VIM_VERSION; fi \
 && git init -q /tmp/vim \
 && cd /tmp/vim \
 && git fetch -q --depth=1 https://github.com/vim/vim "${VIM_COMMIT:-$ref}" \
 && git -c advice.detachedHead=false checkout -q FETCH_HEAD \
 && ./configure --prefix="$HOME/vim-$VIM_VERSION" --with-features=huge --enable-fail-if-missing \
 && make -j"$(nproc)" \
 && make install \
 && rm -rf /tmp/vim


FROM base AS servers

# The "Install packages" step of the workflow.  The TypeScript language
# server is installed from test/package-lock.json by entrypoint.sh.
RUN apt-get update \
 && apt-get install -y clangd-15 \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y nodejs \
 && apt-get install -y golang gopls cargo rust-src \
 && rm -rf /var/lib/apt/lists/*

USER runner
WORKDIR /home/runner

# The runner image has a rustup toolchain in ~/.cargo/bin, which comes before
# /usr/bin in its PATH, so rust-analyzer uses that toolchain rather than the
# one from apt: the CI logs show it in ~/.rustup/toolchains/stable-*.
ENV PATH=/home/runner/.local/bin:/home/runner/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ARG RUST_TOOLCHAIN=stable
RUN curl -fsSL https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN" \
 && rustup component add rustfmt clippy

# run_tests.sh keeps the npm cache in a volume.  Docker creates the
# directory of a volume as root unless the image has it.
RUN mkdir ~/.npm

RUN mkdir -p ~/.local/bin \
 && curl -fsSL "https://github.com/rust-lang/rust-analyzer/releases/download/2024-06-24/rust-analyzer-$(uname -m)-unknown-linux-gnu.gz" \
    | gunzip -c - > ~/.local/bin/rust-analyzer \
 && chmod +x ~/.local/bin/rust-analyzer


FROM servers

ARG VIM_VERSION=nightly
COPY --from=vim --chown=runner:runner /home/runner/vim-$VIM_VERSION /home/runner/vim-$VIM_VERSION
ENV VIMPRG=/home/runner/vim-$VIM_VERSION/bin/vim

COPY entrypoint.sh /usr/local/lib/lsp-tests/entrypoint.sh
ENTRYPOINT ["/bin/bash", "/usr/local/lib/lsp-tests/entrypoint.sh"]
