#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # stub bodies are single-quoted on purpose; bats runs each test in its own subshell

# list-all and download must go through the npm CLI when it is available, so
# registries that reject anonymous requests (an .npmrc `_authToken`, e.g.
# Artifactory or AWS CodeArtifact) work. See #33. Stubs keep this offline.

setup() {
  PLUGIN_DIR="${ASDF_PNPM_PLUGIN_REPO}"
  STUB_DIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_DIR"
  BASH_BIN=$(command -v bash)
  export PATH="${STUB_DIR}:${PATH}"
}

# stub <name> <body>: an executable on PATH that runs <body> under bash.
stub() {
  printf '#!%s\n%s\n' "$BASH_BIN" "$2" >"${STUB_DIR}/$1"
  chmod +x "${STUB_DIR}/$1"
}

@test "list-all uses npm view when npm is available" {
  stub npm 'case "$1" in
  config) echo "https://registry.invalid/" ;;
  view) printf "[\n  \"1.0.0\",\n  \"10.0.0\",\n  \"2.0.0\"\n]\n" ;;
  *) exit 1 ;;
esac'
  stub curl 'echo "curl must not be called" >&2; exit 99'

  run "${PLUGIN_DIR}/bin/list-all"
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.0 2.0.0 10.0.0" ]
}

@test "list-all falls back to the registry over curl when npm view fails" {
  stub npm 'case "$1" in
  config) echo "https://registry.invalid/" ;;
  *) echo "npm error code E401" >&2; exit 1 ;;
esac'
  stub curl 'printf "{\"versions\":{\"3.0.0\":{\"name\":\"pnpm\"}}}"'

  run "${PLUGIN_DIR}/bin/list-all"
  [ "$status" -eq 0 ]
  [[ $output == *"3.0.0" ]]
  [[ $output == *"E401"* ]]
}

@test "download uses npm pack when npm is available" {
  stub npm 'case "$1" in
  config) echo "https://registry.invalid/" ;;
  pack)
    for arg; do [[ ${prev:-} == --pack-destination ]] && dest=$arg; prev=$arg; done
    work=$(mktemp -d)
    mkdir -p "${work}/package"
    echo "{\"name\":\"pnpm\",\"version\":\"${2#pnpm@}\"}" >"${work}/package/package.json"
    tar czf "${dest}/pnpm-${2#pnpm@}.tgz" -C "$work" package
    echo "pnpm-${2#pnpm@}.tgz"
    ;;
  *) exit 1 ;;
esac'
  stub curl 'echo "curl must not be called" >&2; exit 99'

  export ASDF_INSTALL_VERSION=9.9.9
  export ASDF_DOWNLOAD_PATH="${BATS_TEST_TMPDIR}/download"
  run "${PLUGIN_DIR}/bin/download"
  [ "$status" -eq 0 ]
  grep -q '"version":"9.9.9"' "${ASDF_DOWNLOAD_PATH}/package.json"
}

@test "download with ASDF_PNPM_NO_FALLBACK=1 never contacts the public registry" {
  stub npm 'case "$1" in
  config) echo "https://registry.invalid/" ;;
  *) echo "npm error code E404" >&2; exit 1 ;;
esac'
  stub curl 'echo "$*" >>"${BATS_TEST_TMPDIR}/curl.log"; printf 404'

  export ASDF_PNPM_NO_FALLBACK=1
  export ASDF_INSTALL_VERSION=9.9.9
  export ASDF_DOWNLOAD_PATH="${BATS_TEST_TMPDIR}/download"
  run "${PLUGIN_DIR}/bin/download"
  [ "$status" -ne 0 ]
  [[ $output == *"E404"* ]]
  run grep -q registry.npmjs.org "${BATS_TEST_TMPDIR}/curl.log"
  [ "$status" -ne 0 ]
}

@test "list-all with ASDF_PNPM_NO_FALLBACK=1 never contacts the public registry" {
  stub npm 'case "$1" in
  config) echo "https://registry.invalid/" ;;
  *) echo "npm error code E401" >&2; exit 1 ;;
esac'
  stub curl 'echo "$*" >>"${BATS_TEST_TMPDIR}/curl.log"; echo "curl: (22) 401" >&2; exit 22'

  export ASDF_PNPM_NO_FALLBACK=1
  run "${PLUGIN_DIR}/bin/list-all"
  [ "$status" -ne 0 ]
  run grep -q registry.npmjs.org "${BATS_TEST_TMPDIR}/curl.log"
  [ "$status" -ne 0 ]
}

# stub_npm_pack: an npm whose `pack` builds pnpm (listing native binary
# packages as optional dependencies) or a native binary package.
stub_npm_pack() {
  stub npm 'case "$1" in
  config) echo "https://registry.invalid/" ;;
  pack)
    for arg; do [[ ${prev:-} == --pack-destination ]] && dest=$arg; prev=$arg; done
    spec=$2 name=${2%@*} version=${2##*@}
    work=$(mktemp -d)
    mkdir -p "${work}/package"
    if [[ $name == pnpm ]]; then
      echo "{\"name\":\"pnpm\",\"version\":\"${version}\",\"optionalDependencies\":{\"@pnpm/exe.darwin-arm64\":\"${version}\",\"@pnpm/exe.linux-x64\":\"${version}\",\"@pnpm/exe.linux-x64-musl\":\"${version}\"}}" >"${work}/package/package.json"
    else
      echo "{\"name\":\"${name}\",\"version\":\"${version}\"}" >"${work}/package/package.json"
      printf "#!/bin/sh\n" >"${work}/package/pnpm" && chmod 755 "${work}/package/pnpm"
    fi
    file=$(echo "${name}-${version}.tgz" | tr -d @ | tr / -)
    tar czf "${dest}/${file}" -C "$work" package
    echo "$file"
    ;;
  *) exit 1 ;;
esac'
  stub curl 'echo "curl must not be called" >&2; exit 99'
}

@test "download adds the host's native binary package, as npm install would" {
  stub uname 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac'
  stub_npm_pack

  export ASDF_INSTALL_VERSION=12.0.0
  export ASDF_DOWNLOAD_PATH="${BATS_TEST_TMPDIR}/download"
  run "${PLUGIN_DIR}/bin/download"
  [ "$status" -eq 0 ]
  [ -x "${ASDF_DOWNLOAD_PATH}/node_modules/@pnpm/exe.darwin-arm64/pnpm" ]
  [ ! -e "${ASDF_DOWNLOAD_PATH}/node_modules/@pnpm/exe.linux-x64" ]
}

@test "download picks the musl native binary on musl Linux, whose ldd --version exits 1" {
  stub uname 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac'
  stub ldd 'echo "musl libc (x86_64)" >&2; exit 1'
  stub_npm_pack

  export ASDF_INSTALL_VERSION=12.0.0
  export ASDF_DOWNLOAD_PATH="${BATS_TEST_TMPDIR}/download"
  run "${PLUGIN_DIR}/bin/download"
  [ "$status" -eq 0 ]
  [ -x "${ASDF_DOWNLOAD_PATH}/node_modules/@pnpm/exe.linux-x64-musl/pnpm" ]
  [ ! -e "${ASDF_DOWNLOAD_PATH}/node_modules/@pnpm/exe.linux-x64" ]
}

@test "download fails, rather than reporting success, when the npm pack tarball won't extract" {
  stub npm 'case "$1" in
  config) echo "https://registry.invalid/" ;;
  pack)
    for arg; do [[ ${prev:-} == --pack-destination ]] && dest=$arg; prev=$arg; done
    echo "not a tarball" >"${dest}/pnpm-9.9.9.tgz"
    echo "pnpm-9.9.9.tgz"
    ;;
  *) exit 1 ;;
esac'
  stub curl 'printf 404'

  export ASDF_PNPM_NO_FALLBACK=1
  export ASDF_INSTALL_VERSION=9.9.9
  export ASDF_DOWNLOAD_PATH="${BATS_TEST_TMPDIR}/download"
  run "${PLUGIN_DIR}/bin/download"
  [ "$status" -ne 0 ]
  [[ $output == *"Could not extract pnpm@9.9.9"* ]]
}

@test "download fails when the native binary package can't be fetched, rather than leave pnpm unable to start" {
  stub uname 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac'
  stub_npm_pack
  # Same npm, but packing the native binary package fails.
  mv "${STUB_DIR}/npm" "${STUB_DIR}/npm-real"
  stub npm '[[ $1 == pack && $2 == @pnpm/exe.* ]] && { echo "npm error code E404" >&2; exit 1; }; exec "$(dirname "$0")/npm-real" "$@"'

  export ASDF_INSTALL_VERSION=12.0.0
  export ASDF_DOWNLOAD_PATH="${BATS_TEST_TMPDIR}/download"
  run "${PLUGIN_DIR}/bin/download"
  [ "$status" -ne 0 ]
  [[ $output == *"@pnpm/exe.darwin-arm64"*"E404"* ]]
}
