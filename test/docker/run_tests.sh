#!/bin/bash
# Runs the tests in Docker on the Vim versions that the GitHub Actions
# workflow tests, in parallel.  See --help.

set -euo pipefail

# The Vim versions of the workflow matrix (.github/workflows/unitests.yml).
DEFAULT_VERSIONS=(nightly v9.0.0000)
IMAGE=lsp-tests
# A volume for the npm cache, to install the TypeScript language server
# without downloading it on every run.
NPM_CACHE=lsp-tests-npm-cache

# Follow the symlinks to the script, so that it also runs through one.
script=$0
while [[ -L $script ]]; do
  target=$(readlink "$script")
  if [[ $target != /* ]]; then
    target=$(dirname "$script")/$target
  fi
  script=$target
done
here=$(cd "$(dirname "$script")" && pwd)
repo=$(cd "$here/../.." && pwd)
logdir=$here/logs
# Mount the working tree at the same path as on the host and start there,
# which is how entrypoint.sh finds it, and the npm cache.
mounts=(--volume "$repo:$repo:ro" --workdir "$repo"
  --volume "$NPM_CACHE:/home/runner/.npm")

usage() {
  cat <<EOF
Usage: test/docker/run_tests.sh [options] [test_file.vim ...]

Builds a Docker image with the environment of the GitHub Actions workflow for
each Vim version and runs test/run_tests.sh in them in parallel, on a copy of
the working tree.  The test files are passed on to run_tests.sh; without any
the whole suite runs.  The output for each version goes to
test/docker/logs/vim-VERSION.log.

Options:
  -v, --vim VERSION  Vim version to test: "nightly" or a tag of
                     https://github.com/vim/vim.  Repeat it to test more
                     versions.  Default: ${DEFAULT_VERSIONS[*]}, as in CI.
  --no-build         Use the images as they are instead of updating them.
  --refresh          Rebuild the images from scratch.  The language servers
                     and other packages are installed when an image is built,
                     while CI installs the latest ones on every run.
  --shell            Start a shell in the image of the first version instead
                     of running the tests, in a copy of the working tree made
                     when it starts.
  -h, --help         Show this help.

The images are built for the architecture of the Docker host.  To use the
architecture of CI on another one, set DOCKER_DEFAULT_PLATFORM=linux/amd64.
EOF
}

versions=()
build=true
refresh=false
shell=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--vim)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: $1 needs a Vim version" >&2
        exit 2
      fi
      if [[ " ${versions[*]-} " != *" $2 "* ]]; then
        versions+=("$2")
      fi
      shift 2
      ;;
    --no-build) build=false; shift ;;
    --refresh) refresh=true; shift ;;
    --shell) shell=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "ERROR: unknown option $1" >&2
      usage >&2
      exit 2
      ;;
    *) break ;;
  esac
done
if [[ ${#versions[@]} -eq 0 ]]; then
  versions=("${DEFAULT_VERSIONS[@]}")
fi
if $refresh && ! $build; then
  echo "ERROR: --refresh and --no-build can't be used together" >&2
  exit 2
fi

# Prints the commit that Vim "nightly" or a Vim tag points to.
vim_commit() {
  local ref=refs/tags/$1
  if [[ $1 == nightly ]]; then
    ref=HEAD
  fi
  # A peeled annotated tag, listed after the tag, is the commit it points to.
  git ls-remote --exit-code https://github.com/vim/vim "$ref" "$ref^{}" \
    | tail -n 1 | cut -f 1
}

build_image() {
  local version=$1 commit status=0
  echo "==> Looking up Vim $version on GitHub"
  commit=$(vim_commit "$version") || status=$?
  if [[ $status -eq 2 ]]; then
    echo "ERROR: $version is neither \"nightly\" nor a tag of https://github.com/vim/vim" >&2
    return 1
  elif [[ $status -ne 0 ]]; then
    if docker image inspect "$IMAGE:vim-$version" >/dev/null 2>&1; then
      echo "WARNING: can't reach GitHub to update the image for Vim $version, using it as it is" >&2
      return 0
    fi
    echo "ERROR: can't reach GitHub to build the image for Vim $version" >&2
    return 1
  fi
  echo "==> Building $IMAGE:vim-$version (Vim $version at $commit)"
  local args=()
  if $refresh; then
    args=(--pull --no-cache)
  fi
  docker build ${args[@]+"${args[@]}"} --build-arg VIM_VERSION="$version" \
    --build-arg VIM_COMMIT="$commit" --tag "$IMAGE:vim-$version" "$here"
}

duration() {
  printf '%dm%02ds' $(($1 / 60)) $(($1 % 60))
}

container_name() {
  echo "lsp-tests-${1//[^a-zA-Z0-9_.-]/_}-$$"
}

# Runs the tests on Vim version $1 and passes the other arguments on to
# run_tests.sh.  Prints only the progress of run_tests.sh, everything else
# goes to the log.
run_tests_on() {
  local version=$1 log=$logdir/vim-$1.log start=$SECONDS status=0
  shift
  docker run --rm --init --pull never --name "$(container_name "$version")" \
    "${mounts[@]}" "$IMAGE:vim-$version" ${1+"$@"} 2>&1 \
    | tee "$log" \
    | awk -v prefix="[$version] " '/^(===>|RESULT:|SUCCESS:|ERROR:)/ { print prefix $0; fflush() }' \
    || status=$?
  if [[ $status -eq 0 ]]; then
    echo "[$version] PASSED in $(duration $((SECONDS - start)))"
  else
    echo "[$version] FAILED in $(duration $((SECONDS - start)))"
  fi
  return $status
}

if $build; then
  for version in "${versions[@]}"; do
    build_image "$version"
  done
fi

if $shell; then
  exec docker run --rm --interactive --tty --init --pull never \
    "${mounts[@]}" "$IMAGE:vim-${versions[0]}" --shell
fi

pids=()
containers=()
cleanup() {
  if [[ ${#pids[@]} -gt 0 ]]; then
    kill "${pids[@]}" 2>/dev/null || true
  fi
  if [[ ${#containers[@]} -gt 0 ]]; then
    docker rm --force "${containers[@]}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$logdir"
echo "==> Running the tests on Vim ${versions[*]}"
for version in "${versions[@]}"; do
  containers+=("$(container_name "$version")")
  run_tests_on "$version" ${1+"$@"} &
  pids+=($!)
done

failed=()
i=0
for version in "${versions[@]}"; do
  if ! wait "${pids[$i]}"; then
    failed+=("$version")
  fi
  i=$((i + 1))
done
pids=()

for version in ${failed[@]+"${failed[@]}"}; do
  log=$logdir/vim-$version.log
  echo
  echo "==> Vim $version (${log#"$repo"/}):"
  if grep -q '^==> Failures$' "$log"; then
    sed -n '/^==> Failures$/,$p' "$log" | tail -n +2
  else
    tail -n 20 "$log"
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo
  echo "FAILED on Vim ${failed[*]}"
  exit 1
fi
echo
echo "PASSED on Vim ${versions[*]}"
