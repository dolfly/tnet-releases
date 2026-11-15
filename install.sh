#!/bin/bash
# Install tnet from the public release mirror.
#
# The tnet source repository stays private. Every release is mirrored to the
# artifact-only public repository dolfly/tnet-releases, which ships nothing but
# the per-platform binaries and SHA256SUMS: no source, and no GitHub account,
# token or cookie is needed to install from it.
#
#   bash install.sh --install             # latest release
#   bash install.sh --install v3.3.3      # one specific tag
#   bash install.sh --list                # print available versions
#   bash install.sh                       # pick a tag from a menu
#
# Artifact layout, produced by .github/workflows/release.yml:
#
#   tnet-<os>-<arch>-<version>.gz         linux, darwin
#   tnet-<os>-<arch>-<version>.zip        windows
#   SHA256SUMS                            every file above
#
# for example tnet-linux-amd64-3.3.3.gz. The download is only installed after
# its sha256 matched SHA256SUMS.
#
# Optional environment:
#   TNET_DEST   install directory (default /usr/local/bin). Setting it skips the
#               root check, for a per-user install such as ~/.local/bin.
#   TNET_OS     force the OS   (linux|darwin|windows)
#   TNET_ARCH   force the arch (amd64|armv8|armv7|386|arm64)
#   TNET_TAG    tag to install when --install is given without one
#
# TNET_OS/TNET_ARCH also make the other platform branches testable from a single
# machine, e.g. TNET_OS=linux TNET_ARCH=armv8 install.sh --install v3.3.3.

set -u

REPO="dolfly/tnet-releases"
API="https://api.github.com/repos/${REPO}"
DL="https://github.com/${REPO}/releases/download"
BIN="tnet"
DEST="${TNET_DEST:-/usr/local/bin}"
# Set by fetch() below; declared here so `set -u` never trips over it.
FETCH_CODE=""

die() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    sed -n '2,31p' "$0" | sed -e 's/^#//' -e 's/^ //'
}

# fetch <url> <out> downloads url into out, leaves the HTTP status code in
# FETCH_CODE and returns curl's own status. The two are needed separately: a 404
# means "this release does not publish that file", while a non-zero curl status
# means the transfer itself broke (a truncated download would otherwise be
# reported later as a checksum mismatch, which is misleading).
#
# The retry loop is in the shell rather than curl's --retry-all-errors, which
# only exists from curl 7.71 on; nodes still run older curl than that.
fetch() {
    local attempt=1
    while :; do
        FETCH_CODE="$(curl -sSL -o "$2" -w '%{http_code}' "$1" 2>/dev/null)"
        case "$?" in
        0) return 0 ;;
        esac
        if [ "$attempt" -ge 3 ]; then
            return 1
        fi
        sleep "$attempt"
        attempt=$((attempt + 1))
    done
}

# latest_tag reads the tag out of the /releases/latest redirect, which needs no
# API call and therefore does not consume the anonymous rate limit.
latest_tag() {
    local url
    url="$(curl -sSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest" 2>/dev/null)" ||
        return 1
    case "$url" in
    */releases/tag/*) echo "${url##*/releases/tag/}" ;;
    *) return 1 ;;
    esac
}

# version_list prints release tags, newest first (GitHub sorts them that way).
# Parsed with sed rather than `grep -oP`, which BSD grep does not support.
version_list() {
    local body
    body="$(curl -sSL --retry 3 --retry-delay 2 "${API}/releases?per_page=30" 2>/dev/null)" || return 1
    case "$body" in
    *'"message"'*) return 1 ;; # GitHub API error, e.g. rate limited
    esac
    echo "$body" |
        tr ',' '\n' |
        sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p'
}

detect_os() {
    if [ -n "${TNET_OS:-}" ]; then
        echo "$TNET_OS"
        return 0
    fi
    case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *) return 1 ;;
    esac
}

# arch_candidates prints the arch tokens the mirror may ship for this machine,
# most specific first. The Makefile spells arm64 archives "armv8" on linux
# (historical naming), so both spellings are tried.
arch_candidates() {
    local os="$1" arch
    if [ -n "${TNET_ARCH:-}" ]; then
        echo "$TNET_ARCH"
        return 0
    fi
    case "$(uname -m)" in
    x86_64 | amd64) arch="amd64" ;;
    i386 | i486 | i586 | i686) arch="386" ;;
    aarch64 | arm64 | armv8*) arch="armv8" ;;
    armv7*) arch="armv7" ;;
    armv6*) arch="armv6" ;;
    *) return 1 ;;
    esac

    echo "$arch"
    case "${os}:${arch}" in
    linux:armv8) echo "arm64" ;;
    darwin:armv8) echo "arm64" ;;
    linux:arm64) echo "armv8" ;;
    esac
}

# sha256_of prints the sha256 of a file with whatever tool the system has.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        return 1
    fi
}

# fetch_checksums <tag> <dir> downloads SHA256SUMS for one tag. A missing file
# means the tag is not in the mirror, which is a different problem from a
# network failure, so both get their own message.
fetch_checksums() {
    local tag="$1" dir="$2"
    if ! fetch "${DL}/${tag}/SHA256SUMS" "${dir}/SHA256SUMS"; then
        die "download of ${DL}/${tag}/SHA256SUMS was interrupted; check network access to github.com and re-run"
    fi
    case "$FETCH_CODE" in
    200) ;;
    404)
        die "release ${tag} not found in ${REPO} (no SHA256SUMS at ${DL}/${tag}/SHA256SUMS)
no token or login is needed for the public mirror, so a 404 here means the tag
does not exist. Run '$0 --list' for the versions that are published."
        ;;
    *)
        die "cannot download ${DL}/${tag}/SHA256SUMS (HTTP ${FETCH_CODE}); check network access to github.com"
        ;;
    esac
}

# pick_asset <tag> <os> <checksums> prints the artifact name for this machine.
# The name comes from SHA256SUMS, so a name that is not published cannot be
# guessed and then fail later at download time.
pick_asset() {
    local tag="$1" os="$2" checksums="$3" arch candidates name available wanted
    candidates="$(arch_candidates "$os")"
    for arch in $candidates; do
        name="$(awk -v pat="^${BIN}-${os}-${arch}(-[^/]*)?\\.(gz|zip)\$" '$2 ~ pat { print $2; exit }' "$checksums")"
        if [ -n "$name" ]; then
            echo "$name"
            return 0
        fi
    done
    available="$(awk '{ print "  " $2 }' "$checksums")"
    wanted="$(echo "$candidates" | awk -v os="$os" 'BEGIN { ORS = "" } { printf "%s%s/%s", (NR > 1 ? ", " : ""), os, $1 }')"
    die "release ${tag} has no artifact for ${wanted} (this machine: $(uname -s)/$(uname -m))
published files:
${available}
Set TNET_OS/TNET_ARCH to pick another target explicitly."
}

install_tnet() {
    local tag="$1" os name dir expected actual url native="" target
    # The target is a system directory unless TNET_DEST overrides it, so the root
    # check only applies to the default destination.
    [ "$(id -u)" -eq 0 ] || [ -n "${TNET_DEST:-}" ] ||
        die "run this script as root (it installs to ${DEST}), or set TNET_DEST to a writable directory"
    os="$(detect_os)" || die "unsupported operating system: $(uname -s)"
    dir="$(mktemp -d)" || die "cannot create a temporary directory"
    # shellcheck disable=SC2064 # expand dir now, not at trap run time
    trap "rm -rf '${dir}'" EXIT

    fetch_checksums "$tag" "$dir"
    # pick_asset reports the full reason itself, so a failure only has to stop
    # this shell: inside $( ) its `exit` would just end the substitution.
    name="$(pick_asset "$tag" "$os" "${dir}/SHA256SUMS")" || exit 1
    url="${DL}/${tag}/${name}"

    echo "Downloading ${tag}: ${name}"
    if ! fetch "$url" "${dir}/${name}"; then
        die "download of ${url} was interrupted; nothing was installed, re-run the installer"
    fi
    [ "$FETCH_CODE" = "200" ] ||
        die "cannot download ${url} (HTTP ${FETCH_CODE}); the mirror lists this file but github.com did not serve it"

    expected="$(awk -v f="$name" '$2 == f { print $1 }' "${dir}/SHA256SUMS")"
    [ -n "$expected" ] || die "SHA256SUMS for ${tag} does not cover ${name}"
    actual="$(sha256_of "${dir}/${name}")" ||
        die "cannot verify ${name}: no sha256 tool found (need sha256sum, shasum or openssl)"
    if [ "$expected" != "$actual" ]; then
        die "checksum verification failed for ${name}
  expected ${expected}
  actual   ${actual}
nothing was installed; re-run the installer and, if it fails again, report the
mismatch instead of installing."
    fi
    echo "Checksum verified: ${actual}"

    case "$name" in
    *.gz) gzip -dc "${dir}/${name}" >"${dir}/${BIN}" || die "cannot unpack ${name}" ;;
    *.zip)
        command -v unzip >/dev/null 2>&1 || die "unzip is required to install the windows build"
        unzip -o -q "${dir}/${name}" -d "$dir" || die "cannot unpack ${name}"
        ;;
    *) die "unexpected artifact type: ${name}" ;;
    esac

    # The windows archives keep the versioned file name inside the zip
    # (tnet-windows-amd64-3.3.3.exe), the unix ones are a plain gzip stream, so
    # look for the binary under every name the packaging may have used.
    native=""
    for candidate in "${dir}/${BIN}" "${dir}/${BIN}.exe" "${dir}/${name%.*}" "${dir}/${name%.*}.exe"; do
        if [ -f "$candidate" ]; then
            native="$candidate"
            break
        fi
    done
    [ -n "$native" ] || die "artifact ${name} does not contain ${BIN}"

    target="${DEST}/${BIN}"
    case "$native" in
    # Windows only executes files that keep the .exe suffix.
    *.exe) if [ "$os" = windows ]; then target="${DEST}/${BIN}.exe"; fi ;;
    esac

    echo "Installing to ${target}"
    mkdir -p "${DEST}" || die "cannot create ${DEST}"
    [ -w "${DEST}" ] || die "no write permission for ${DEST}; run as root or set TNET_DEST"
    install -m 0755 "$native" "$target" || die "cannot install to ${target}"

    echo "tnet installed: $("$target" -V 2>/dev/null || echo "$target")"
}

# list_versions prints the published tags or dies with the reason. The mirror is
# public, so a failure here is the network or the anonymous API rate limit, never
# a credential problem; the message has to say that instead of looking like an
# empty release list.
list_versions() {
    local versions
    versions="$(version_list)" || die "cannot read the version list from ${API}/releases
The public mirror needs no token, so this is a network problem or the anonymous
GitHub API rate limit. Install a known version directly instead:
  bash $0 --install ${TNET_TAG:-v3.3.3}"
    [ -n "$versions" ] || die "${REPO} lists no releases; nothing to install yet"
    echo "$versions"
}

main() {
    local action="menu" tag="" versions
    case "${1:-}" in
    --install | -i) action="install" tag="${2:-${TNET_TAG:-}}" ;;
    --list | -l) action="list" ;;
    --help | -h)
        usage
        return 0
        ;;
    "") action="menu" ;;
    *) die "unknown option: $1 (try --help)" ;;
    esac

    case "$action" in
    list)
        list_versions
        ;;
    menu)
        echo "Available tnet versions:"
        versions="$(list_versions)" || exit 1
        select tag in $versions; do
            if [ -n "$tag" ]; then
                install_tnet "$tag"
                break
            fi
            echo "Invalid choice, pick a number from the list." >&2
        done
        ;;
    install)
        # A pinned tag installs without touching the API at all, so an anonymous
        # rate limit cannot break a scripted install.
        if [ -z "$tag" ]; then
            tag="$(latest_tag)" || die "cannot resolve the latest tag from https://github.com/${REPO}/releases/latest
check network access to github.com, or pin a version:
  bash $0 --install v3.3.3"
        fi
        install_tnet "$tag"
        ;;
    esac
}

main "$@"
