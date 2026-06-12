#!/bin/bash
# common.sh — shared infrastructure for the PJSIP xcframework build scripts.
#
# Sourced by build.sh. Targets the macOS system bash (3.2): no associative
# arrays, no ${var,,}, no mapfile. `set -u` is on, so empty-array expansions
# use the ${arr[@]+"${arr[@]}"} guard.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

# All build state lives under one disposable directory (gitignored).
BUILD_ROOT="${PJSIP_BUILD_ROOT:-${REPO_ROOT}/.build-pjsip}"
META_DIR="${BUILD_ROOT}/meta"
OUTPUT_DIR="${BUILD_ROOT}/output"

# Upstream coordinates.
PJSIP_GH_REPO="pjsip/pjproject"
BCG729_GH_REPO="BelledonneCommunications/bcg729"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log_info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
log_success() { printf "${GREEN}[OK]${NC}    %s\n" "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }

error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

# ---------------------------------------------------------------------------
# Prerequisites & toolchain detection
# ---------------------------------------------------------------------------

# Download/extract tooling only — intentionally separate from the macOS build
# checks so the download phase also works on a plain Linux box (e.g. to
# pre-fetch sources or test source selection).
check_download_prerequisites() {
    local missing=()
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        missing+=("curl or wget")
    fi
    command -v unzip &>/dev/null || missing+=("unzip")
    command -v git   &>/dev/null || missing+=("git")
    if [[ ${#missing[@]} -gt 0 ]]; then
        error_exit "Missing prerequisites: ${missing[*]}"
    fi
}

# Everything the compile phases need. Resolves toolchain paths via
# xcode-select/xcrun instead of assuming /Applications/Xcode.app.
check_build_prerequisites() {
    log_info "Checking build prerequisites..."

    [[ "$(uname -s)" == "Darwin" ]] || error_exit "PJSIP iOS builds require macOS (found $(uname -s))."

    command -v xcode-select &>/dev/null || error_exit "xcode-select not found. Install Xcode."

    local dev_dir
    dev_dir="$(xcode-select -p 2>/dev/null)" \
        || error_exit "No active developer directory. Run: xcode-select --install (or select Xcode)."

    # configure-iphone and -create-xcframework need full Xcode, not just the
    # Command Line Tools (which have no iPhoneOS/iPhoneSimulator platforms).
    if ! xcodebuild -version &>/dev/null; then
        error_exit "Full Xcode required (found CLT-only at ${dev_dir}). Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    fi
    if [[ ! -d "${dev_dir}/Platforms/iPhoneOS.platform" ]]; then
        error_exit "iPhoneOS platform not found under ${dev_dir}. Is the active developer dir a full Xcode?"
    fi

    command -v cmake &>/dev/null || error_exit "cmake not found (needed for bcg729). Install: brew install cmake"
    xcrun --find libtool &>/dev/null || error_exit "libtool not found via xcrun."
    xcrun --find lipo    &>/dev/null || error_exit "lipo not found via xcrun."

    log_success "Build prerequisites OK (developer dir: ${dev_dir})"
}

# Platform "Developer" dir for a given SDK, detected — never hardcoded.
#   detect_platform_devpath iphonesimulator
detect_platform_devpath() {
    local sdk="$1"
    local platform_path
    platform_path="$(xcrun --sdk "${sdk}" --show-sdk-platform-path 2>/dev/null)" \
        || error_exit "Cannot locate platform path for SDK '${sdk}' via xcrun."
    echo "${platform_path}/Developer"
}

# ---------------------------------------------------------------------------
# GitHub helpers. Deliberately avoid the REST API where possible: it is
# rate-limited for unauthenticated callers and blocked by some proxies. The
# `releases/latest` redirect and `git ls-remote` need only plain HTTPS git
# access. The API remains as a fallback. No jq dependency.
# ---------------------------------------------------------------------------

fetch_url() {
    # fetch_url URL [OUTPUT_FILE]; without OUTPUT_FILE prints to stdout.
    local url="$1" out="${2:-}"
    if command -v curl &>/dev/null; then
        if [[ -n "$out" ]]; then curl -fSL --retry 3 -o "$out" "$url"; else curl -fsSL --retry 3 "$url"; fi
    else
        if [[ -n "$out" ]]; then wget -q -O "$out" "$url"; else wget -q -O - "$url"; fi
    fi
}

# Latest release tag of a GitHub repo ("" if unresolvable).
gh_latest_release_tag() {
    local repo="$1" tag="" final=""
    # Primary: follow the /releases/latest redirect to /releases/tag/<tag>.
    if command -v curl &>/dev/null; then
        final="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            "https://github.com/${repo}/releases/latest" 2>/dev/null || true)"
        case "$final" in
            */releases/tag/*) tag="${final##*/releases/tag/}" ;;
        esac
    fi
    # Fallback: the REST API.
    if [[ -z "$tag" ]]; then
        tag="$(fetch_url "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | grep -m1 '"tag_name"' \
            | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    fi
    echo "$tag"
}

# Most recent (highest version-sorted) tag — for repos without releases.
gh_latest_tag() {
    local repo="$1" tag=""
    tag="$(git ls-remote --tags --sort=-v:refname "https://github.com/${repo}.git" 2>/dev/null \
        | awk -F/ '$NF !~ /\^\{\}$/ {print $NF; exit}' || true)"
    if [[ -z "$tag" ]]; then
        tag="$(fetch_url "https://api.github.com/repos/${repo}/tags?per_page=1" 2>/dev/null \
            | grep -m1 '"name"' \
            | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    fi
    echo "$tag"
}

# Commit SHA a ref (tag or branch) points at ("" if unresolvable). For
# annotated tags, prefers the peeled (^{}) line — the actual commit.
gh_ref_commit() {
    local repo="$1" ref="$2" out="" sha=""
    out="$(git ls-remote "https://github.com/${repo}.git" \
        "refs/tags/${ref}" "refs/tags/${ref}^{}" "refs/heads/${ref}" 2>/dev/null || true)"
    sha="$(echo "$out" | awk '/\^\{\}$/ {print $1; exit}')"
    [[ -n "$sha" ]] || sha="$(echo "$out" | awk 'NR==1 {print $1}')"
    if [[ -z "$sha" ]]; then
        sha="$(fetch_url "https://api.github.com/repos/${repo}/commits/${ref}" 2>/dev/null \
            | grep -m1 '"sha"' \
            | sed -E 's/.*"sha"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    fi
    echo "$sha"
}

# ---------------------------------------------------------------------------
# Source selection
#
# A source spec is one of:
#   latest          — latest GitHub release (falls back to latest tag)
#   tag=<tag>       — a specific tag, e.g. tag=2.16
#   branch=<name>   — a branch head, e.g. branch=master
#   archive=<path>  — a local .zip / .tar.gz / .tgz / .tar.bz2
#
# Specs come from (highest precedence first): CLI flag, environment variable
# (PJSIP_SOURCE / BCG729_SOURCE), interactive prompt, default "latest".
# Prompts only appear on a TTY and never with --non-interactive.
# ---------------------------------------------------------------------------

validate_source_spec() {
    local spec="$1" what="$2"
    case "$spec" in
        latest|tag=?*|branch=?*|archive=?*) ;;
        *) error_exit "Invalid ${what} source spec '${spec}'. Use: latest | tag=<tag> | branch=<name> | archive=<path>" ;;
    esac
}

# Interactively ask for a source spec; echoes the chosen spec.
# Reads from /dev/tty so it works even when stdout is piped.
prompt_source_spec() {
    local what="$1" default_desc="$2"
    local choice detail
    {
        echo ""
        echo "Select ${what} source:"
        echo "  1) ${default_desc} (default)"
        echo "  2) Specific tag"
        echo "  3) Branch (development build)"
        echo "  4) Local source archive (.zip / .tar.gz)"
        printf "Choice [1]: "
    } > /dev/tty
    read -r choice < /dev/tty || choice=""
    case "${choice:-1}" in
        1|"") echo "latest" ;;
        2)
            printf "Tag (e.g. 2.16): " > /dev/tty
            read -r detail < /dev/tty
            [[ -n "$detail" ]] || error_exit "No tag given."
            echo "tag=${detail}"
            ;;
        3)
            printf "Branch (e.g. master): " > /dev/tty
            read -r detail < /dev/tty
            [[ -n "$detail" ]] || error_exit "No branch given."
            echo "branch=${detail}"
            ;;
        4)
            printf "Path to archive: " > /dev/tty
            read -r detail < /dev/tty
            [[ -f "$detail" ]] || error_exit "Archive not found: ${detail}"
            echo "archive=${detail}"
            ;;
        *) error_exit "Invalid choice '${choice}'." ;;
    esac
}

# Resolve the spec for a component, honoring flag/env/prompt/default.
#   resolve_source_spec "PJSIP" "$PJSIP_SOURCE_FLAG" "PJSIP_SOURCE" "latest GitHub release"
resolve_source_spec() {
    local what="$1" flag_value="$2" env_name="$3" default_desc="$4"
    local spec=""
    if [[ -n "$flag_value" ]]; then
        spec="$flag_value"
    elif [[ -n "$(eval "echo \${${env_name}:-}")" ]]; then
        spec="$(eval "echo \$${env_name}")"
    elif [[ "${NONINTERACTIVE}" == "0" && -t 0 && -e /dev/tty ]]; then
        spec="$(prompt_source_spec "$what" "$default_desc")"
    else
        spec="latest"
    fi
    validate_source_spec "$spec" "$what"
    echo "$spec"
}

# ---------------------------------------------------------------------------
# Download / extract
# ---------------------------------------------------------------------------

extract_archive_to() {
    # extract_archive_to ARCHIVE DEST_DIR — extracts and echoes the single
    # top-level directory inside DEST_DIR.
    local archive="$1" dest="$2"
    rm -rf "$dest"
    mkdir -p "$dest"
    case "$archive" in
        *.zip)            unzip -oq "$archive" -d "$dest" || error_exit "unzip failed for ${archive}" ;;
        *.tar.gz|*.tgz)   tar -xzf "$archive" -C "$dest"  || error_exit "tar failed for ${archive}" ;;
        *.tar.bz2|*.tbz2) tar -xjf "$archive" -C "$dest"  || error_exit "tar failed for ${archive}" ;;
        *) error_exit "Unsupported archive format: ${archive} (use .zip, .tar.gz, .tgz, .tar.bz2)" ;;
    esac
    local top
    top="$(find "$dest" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [[ -n "$top" ]] || error_exit "Archive ${archive} contained no top-level directory."
    echo "$top"
}

# Download + extract PJSIP per spec into ${BUILD_ROOT}/pjproject, record
# provenance into meta/sources.env. Idempotent per (spec) — re-running with
# the same spec reuses the cached archive but re-extracts fresh.
fetch_pjsip_source() {
    local spec="$1"
    local kind ref url archive commit=""

    case "$spec" in
        latest)
            ref="$(gh_latest_release_tag "${PJSIP_GH_REPO}")"
            [[ -n "$ref" ]] || ref="$(gh_latest_tag "${PJSIP_GH_REPO}")"
            [[ -n "$ref" ]] || error_exit "Could not resolve the latest PJSIP release from the GitHub API. Pass --pjsip-source tag=<tag> explicitly."
            kind="release"
            log_info "Latest PJSIP release: ${ref}"
            url="https://github.com/${PJSIP_GH_REPO}/archive/refs/tags/${ref}.zip"
            ;;
        tag=*)
            ref="${spec#tag=}"; kind="tag"
            url="https://github.com/${PJSIP_GH_REPO}/archive/refs/tags/${ref}.zip"
            ;;
        branch=*)
            ref="${spec#branch=}"; kind="branch"
            url="https://github.com/${PJSIP_GH_REPO}/archive/refs/heads/${ref}.zip"
            ;;
        archive=*)
            ref="$(basename "${spec#archive=}")"; kind="archive"
            url="file://${spec#archive=}"
            ;;
    esac

    mkdir -p "${BUILD_ROOT}"
    if [[ "$kind" == "archive" ]]; then
        archive="${spec#archive=}"
        [[ -f "$archive" ]] || error_exit "PJSIP archive not found: ${archive}"
    else
        local safe_ref
        safe_ref="$(echo "$ref" | tr '/' '-')"
        archive="${BUILD_ROOT}/pjproject-${safe_ref}.zip"
        if [[ -f "$archive" ]]; then
            log_info "PJSIP ${ref} already downloaded: ${archive}"
        else
            log_info "Downloading PJSIP ${kind} '${ref}'..."
            fetch_url "$url" "$archive" || error_exit "Failed to download ${url}"
        fi
        commit="$(gh_ref_commit "${PJSIP_GH_REPO}" "$ref")"
    fi

    log_info "Extracting PJSIP source..."
    rm -rf "${BUILD_ROOT}/pjproject"
    local top
    top="$(extract_archive_to "$archive" "${BUILD_ROOT}/.extract-pjsip")"
    mv "$top" "${BUILD_ROOT}/pjproject"
    rm -rf "${BUILD_ROOT}/.extract-pjsip"
    [[ -x "${BUILD_ROOT}/pjproject/configure-iphone" || -f "${BUILD_ROOT}/pjproject/configure-iphone" ]] \
        || error_exit "Extracted tree does not look like pjproject (configure-iphone missing)."
    log_success "PJSIP source ready: ${BUILD_ROOT}/pjproject"

    mkdir -p "${META_DIR}"
    {
        echo "PJSIP_SOURCE_SPEC=\"${spec}\""
        echo "PJSIP_SOURCE_KIND=\"${kind}\""
        echo "PJSIP_REF=\"${ref}\""
        echo "PJSIP_COMMIT=\"${commit}\""
        echo "PJSIP_URL=\"${url}\""
        echo "PJSIP_FETCH_DATE=\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\""
    } > "${META_DIR}/pjsip-source.env"
}

# Fetch bcg729 per spec into ${BUILD_ROOT}/bcg729-source, record provenance.
fetch_bcg729_source() {
    local spec="$1"
    local kind ref commit="" url="https://github.com/${BCG729_GH_REPO}.git"
    local dest="${BUILD_ROOT}/bcg729-source"

    mkdir -p "${BUILD_ROOT}"
    rm -rf "$dest"

    case "$spec" in
        latest)
            ref="$(gh_latest_release_tag "${BCG729_GH_REPO}")"
            [[ -n "$ref" ]] || ref="$(gh_latest_tag "${BCG729_GH_REPO}")"
            if [[ -n "$ref" ]]; then
                kind="release"
                log_info "Latest bcg729 tag: ${ref}"
                git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$url" "$dest" \
                    || error_exit "Failed to clone bcg729 at ${ref}"
            else
                log_warn "No bcg729 tag resolvable; falling back to default branch HEAD."
                kind="branch"; ref="HEAD"
                git clone --quiet --depth 1 "$url" "$dest" || error_exit "Failed to clone bcg729"
            fi
            ;;
        tag=*|branch=*)
            ref="${spec#*=}"
            kind="${spec%%=*}"
            git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$url" "$dest" \
                || error_exit "Failed to clone bcg729 at ${kind} '${ref}'"
            ;;
        archive=*)
            local archive="${spec#archive=}"
            [[ -f "$archive" ]] || error_exit "bcg729 archive not found: ${archive}"
            kind="archive"; ref="$(basename "$archive")"
            local top
            top="$(extract_archive_to "$archive" "${BUILD_ROOT}/.extract-bcg729")"
            mv "$top" "$dest"
            rm -rf "${BUILD_ROOT}/.extract-bcg729"
            ;;
    esac

    if [[ -d "${dest}/.git" ]]; then
        commit="$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)"
    fi
    [[ -f "${dest}/CMakeLists.txt" ]] || error_exit "Extracted tree does not look like bcg729 (CMakeLists.txt missing)."
    log_success "bcg729 source ready: ${dest}"

    mkdir -p "${META_DIR}"
    {
        echo "BCG729_SOURCE_SPEC=\"${spec}\""
        echo "BCG729_SOURCE_KIND=\"${kind}\""
        echo "BCG729_REF=\"${ref}\""
        echo "BCG729_COMMIT=\"${commit}\""
        echo "BCG729_URL=\"${url}\""
        echo "BCG729_FETCH_DATE=\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\""
    } > "${META_DIR}/bcg729-source.env"
}

# ---------------------------------------------------------------------------
# Metadata helpers
# ---------------------------------------------------------------------------

# Record the toolchain/environment a phase ran with (sourceable env file).
record_build_env() {
    local label="$1"
    mkdir -p "${META_DIR}"
    local xcode_version sdk_ios sdk_sim clang_version cmake_version macos_version
    xcode_version="$( (xcodebuild -version 2>/dev/null | tr '\n' ' ') || echo "unknown")"
    sdk_ios="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo "unknown")"
    sdk_sim="$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || echo "unknown")"
    clang_version="$( (xcrun clang --version 2>/dev/null | head -n 1) || echo "unknown")"
    cmake_version="$( (cmake --version 2>/dev/null | head -n 1) || echo "unknown")"
    macos_version="$( (sw_vers -productVersion 2>/dev/null) || uname -sr)"
    {
        echo "BUILD_DATE=\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\""
        echo "HOST_MACOS=\"${macos_version}\""
        echo "HOST_ARCH=\"$(uname -m)\""
        echo "XCODE_VERSION=\"${xcode_version% }\""
        echo "DEVELOPER_DIR_USED=\"$(xcode-select -p 2>/dev/null || echo unknown)\""
        echo "SDK_IPHONEOS=\"${sdk_ios}\""
        echo "SDK_IPHONESIMULATOR=\"${sdk_sim}\""
        echo "CLANG_VERSION=\"${clang_version}\""
        echo "CMAKE_VERSION=\"${cmake_version}\""
        echo "MIN_IOS_VERSION=\"${MIN_IOS_VERSION}\""
        echo "CONFIGURE_FLAGS=\"${CONFIGURE_FLAGS[*]}\""
        echo "BASE_LDFLAGS=\"${BASE_LDFLAGS}\""
    } > "${META_DIR}/build-${label}.env"
}

# Source every meta file that exists, tolerating absent ones.
load_meta() {
    local f
    for f in "${META_DIR}/pjsip-source.env" "${META_DIR}/bcg729-source.env" \
             "${META_DIR}/build-device.env"; do
        # shellcheck disable=SC1090
        [[ -f "$f" ]] && . "$f"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

sha256_of() {
    if command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

clean_target() {
    local target="$1"
    log_info "Cleaning ${target} build artifacts..."
    rm -rf "${BUILD_ROOT}/${target}" "${BUILD_ROOT}/bcg729-${target}" \
           "${BUILD_ROOT}/bcg729-source/build-${target}"
    log_success "Cleaned ${target}"
}
