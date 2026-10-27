#!/bin/bash
#
# build.sh — build PJSIP (+ bcg729 + opus) for iOS and package it as the single
# combined PJSIP.xcframework this Swift package distributes as a release asset.
#
# Follows the official PJSIP build guidance:
#   - https://docs.pjsip.org/en/latest/get-started/ios/build_instructions.html
#   - https://docs.pjsip.org/en/latest/pjsua2/building.html
#
# Usage: ./scripts/build.sh [options] <phase> [phase ...]
# Run with --help for the full phase/option reference.

# common.sh sits beside this script, but the path is built at runtime, so shellcheck
# can't statically resolve the include. `source=` points it at the file (so it still
# checks against it); disable=SC1091 drops the "not following" note without needing
# CI to pass `-x`.
# shellcheck source=scripts/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Defaults (every one overridable via flag or environment)
# ---------------------------------------------------------------------------

MIN_IOS_VERSION="${MIN_IOS_VERSION:-15.0}"   # keep in sync with Package.swift `.iOS(.v15)`
CONFIG_SITE="${CONFIG_SITE:-${SCRIPTS_DIR}/config_site-ios.h}"
PATCHES_DIR="${PATCHES_DIR:-${SCRIPTS_DIR}/patches}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
ALLOW_STALE_CITES="${ALLOW_STALE_CITES:-0}"
PJSIP_SOURCE_FLAG=""
BCG729_SOURCE_FLAG=""
OPUS_SOURCE_FLAG=""

# The configure flags that define this distribution: native Darwin SSL (TLS
# via Security/Network frameworks, no OpenSSL), video, G.729 via bcg729, Opus
# via libopus (--with-* live on the configure line, not here), and no
# GSM/Speex. Changing these changes the ABI story documented in the
# README — regenerate the release notes (`notes`) and re-verify (`verify`).
CONFIGURE_FLAGS=(
    --disable-gsm-codec
    --disable-speex-codec
    --disable-speex-aec
    --enable-darwin-ssl
    --enable-video
)
BASE_LDFLAGS="-framework Network -framework Security -framework MetalKit"

# ---------------------------------------------------------------------------
# Target parameters
# ---------------------------------------------------------------------------

get_target_arch() {
    case "$1" in
        device|simulator) echo "arm64" ;;
        *) error_exit "Unknown target: $1" ;;
    esac
}

get_target_sdk() {
    case "$1" in
        device)    echo "iphoneos" ;;
        simulator) echo "iphonesimulator" ;;
        *) error_exit "Unknown target: $1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Source-tree management
# ---------------------------------------------------------------------------

# Apply every *.patch sitting directly in ${PATCHES_DIR} to the extracted
# pjproject tree, in sorted order. A patch that will not apply is a HARD
# FAILURE: the whole point of this step is that a rebuild cannot silently
# lose a fix that upstream has not taken (see patches/README.md). Sources
# the patches were forward-ported for are recorded there too.
#
# Idempotent: a reverse dry-run that succeeds means the hunk is already in
# the tree, so re-running a phase over an already-patched tree is a no-op.
apply_patches() {
    # Truncate before any early return: `notes` reports whatever this file
    # holds, so an unpatched build in a reused build root would otherwise
    # publish the previous build's patch list.
    mkdir -p "${META_DIR}"
    : > "${META_DIR}/patches.txt"

    if [[ ! -d "${PATCHES_DIR}" ]]; then
        log_info "No patches directory (${PATCHES_DIR}) — building unpatched upstream."
        return 0
    fi
    command -v patch &>/dev/null || error_exit "'patch' not found; required to apply ${PATCHES_DIR}/*.patch"

    local patches=()
    while IFS= read -r -d '' p; do
        patches+=("$p")
    done < <(find "${PATCHES_DIR}" -maxdepth 1 -name '*.patch' -type f -print0 | sort -z)

    if [[ ${#patches[@]} -eq 0 ]]; then
        log_warn "${PATCHES_DIR} contains no *.patch — building unpatched upstream."
        return 0
    fi

    local p name
    for p in "${patches[@]}"; do
        name="$(basename "$p")"
        if ( cd "${BUILD_ROOT}/pjproject" && patch -p1 -R -f -s --dry-run -i "$p" ) &>/dev/null; then
            log_info "Patch already applied: ${name}"
        else
            log_info "Applying patch: ${name}"
            ( cd "${BUILD_ROOT}/pjproject" && patch -p1 -f -s -i "$p" ) \
                || error_exit "Patch ${name} did not apply. The PJSIP source has moved under it — forward-port it (patches/README.md) rather than dropping it."
        fi
        echo "${name}  $(sha256_of "$p")" >> "${META_DIR}/patches.txt"
    done
    log_success "Applied ${#patches[@]} patch(es) from ${PATCHES_DIR}"
}

# The config_site.h cites pjproject by file:line for every override it makes.
# Those numbers move with every upstream bump, so check them against the tree
# this build is about to compile. On a fresh extraction that is the pristine
# upstream tree the header's "pjproject master @ <sha>" line names; a tree
# reused from an earlier phase already carries the patches, whose shifts the
# checker's ±2-line tolerance absorbs (a patch that moves a cited block
# further is itself a reason to refresh the citation). Stale is a HARD
# FAILURE for the same reason a patch that will not apply is: the header's
# reasoning must follow the source it is compiled against, not silently point
# elsewhere. --allow-stale-cites turns it into a warning for an exploratory
# build (e.g. branch=master) where moving lines are expected and not yet
# worth fixing.
check_config_site_cites() {
    local checker="${SCRIPTS_DIR}/check-cites.sh"
    if "${checker}" "${CONFIG_SITE}" "${BUILD_ROOT}/pjproject"; then
        return 0
    fi
    if [[ "${ALLOW_STALE_CITES}" == "1" ]]; then
        log_warn "Stale citations in $(basename "${CONFIG_SITE}") tolerated (--allow-stale-cites)."
        return 0
    fi
    error_exit "$(basename "${CONFIG_SITE}") cites lines this PJSIP tree does not have. Fix the numbers (the checker names where each token is now) and the header's '@ <sha>' line, or pass --allow-stale-cites for an exploratory build."
}

apply_config_site() {
    [[ -f "${CONFIG_SITE}" ]] || error_exit "config_site.h not found: ${CONFIG_SITE}"
    log_info "Applying $(basename "${CONFIG_SITE}") -> pjproject/pjlib/include/pj/config_site.h"
    cp "${CONFIG_SITE}" "${BUILD_ROOT}/pjproject/pjlib/include/pj/config_site.h"
    mkdir -p "${META_DIR}"
    cp "${CONFIG_SITE}" "${META_DIR}/config_site.h"
}

# Path of the archive the download phase cached, derived from recorded meta.
pjsip_cached_archive_path() {
    load_meta
    case "${PJSIP_SOURCE_KIND:-}" in
        archive)
            echo "${PJSIP_SOURCE_SPEC#archive=}"
            ;;
        release|tag|branch|commit)
            local safe_ref
            safe_ref="$(echo "${PJSIP_REF:-}" | tr '/' '-')"
            if [[ -n "$safe_ref" ]]; then
                echo "${BUILD_ROOT}/pjproject-${safe_ref}.zip"
            else
                echo ""
            fi
            ;;
        *) echo "" ;;
    esac
}

# Guarantee a pristine ${BUILD_ROOT}/pjproject with our config_site.h in
# place. The simulator phase deletes the tree after the device build, so this
# re-extracts from the archive cached by the download phase.
ensure_pjproject_tree() {
    if [[ ! -d "${BUILD_ROOT}/pjproject" ]]; then
        local archive
        archive="$(pjsip_cached_archive_path)"
        [[ -n "$archive" && -f "$archive" ]] \
            || error_exit "No PJSIP source available. Run the download phase first."
        log_info "Re-extracting PJSIP from cached archive..."
        local top
        top="$(extract_archive_to "$archive" "${BUILD_ROOT}/.extract-pjsip")"
        mv "$top" "${BUILD_ROOT}/pjproject"
        rm -rf "${BUILD_ROOT}/.extract-pjsip"
    fi
    check_config_site_cites
    apply_patches
    apply_config_site
}

# ---------------------------------------------------------------------------
# Component builds
# ---------------------------------------------------------------------------

build_bcg729() {
    local target="$1"
    local arch sdk install_path build_dir
    arch="$(get_target_arch "$target")"
    sdk="$(get_target_sdk "$target")"
    install_path="${BUILD_ROOT}/bcg729-${target}"
    build_dir="${BUILD_ROOT}/bcg729-source/build-${target}"

    log_info "Building bcg729 for ${target}..."
    rm -rf "${build_dir}" "${install_path}"
    mkdir -p "${build_dir}"

    # CMAKE_OSX_SYSROOT takes the SDK *name*; CMake resolves the actual path
    # through xcrun, so nothing here depends on where Xcode is installed.
    (
        cd "${build_dir}" || error_exit "cannot enter ${build_dir}"
        cmake .. \
            -DCMAKE_SYSTEM_NAME=iOS \
            -DCMAKE_OSX_ARCHITECTURES="${arch}" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_IOS_VERSION}" \
            -DCMAKE_OSX_SYSROOT="${sdk}" \
            -DCMAKE_INSTALL_PREFIX="${install_path}" \
            -DENABLE_TESTS=NO \
            -DCMAKE_SKIP_INSTALL_RPATH=ON \
            || error_exit "bcg729 CMake configuration failed"
        make -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" || error_exit "bcg729 build failed"
        make install || error_exit "bcg729 installation failed"
    )

    [[ -f "${install_path}/lib/libbcg729.a" ]] \
        || error_exit "libbcg729.a not found at ${install_path}/lib/"
    log_success "bcg729 ${target} build complete"
}

build_opus() {
    local target="$1"
    local arch sdk install_path build_dir
    arch="$(get_target_arch "$target")"
    sdk="$(get_target_sdk "$target")"
    install_path="${BUILD_ROOT}/opus-${target}"
    build_dir="${BUILD_ROOT}/opus-source/build-${target}"

    log_info "Building opus for ${target}..."
    rm -rf "${build_dir}" "${install_path}"
    mkdir -p "${build_dir}"

    # CMAKE_OSX_SYSROOT takes the SDK *name*; CMake resolves the actual path
    # through xcrun, so nothing here depends on where Xcode is installed.
    # Float build with intrinsics (arm64 NEON) is opus's own default; DRED/OSCE
    # stay off (also defaults). The OPUS_INSTALL_* switches keep the prefix to
    # just lib/ + include/ — nothing else consumes them.
    (
        cd "${build_dir}" || error_exit "cannot enter ${build_dir}"
        cmake .. \
            -DCMAKE_SYSTEM_NAME=iOS \
            -DCMAKE_OSX_ARCHITECTURES="${arch}" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_IOS_VERSION}" \
            -DCMAKE_OSX_SYSROOT="${sdk}" \
            -DCMAKE_INSTALL_PREFIX="${install_path}" \
            -DCMAKE_SKIP_INSTALL_RPATH=ON \
            -DOPUS_BUILD_SHARED_LIBRARY=OFF \
            -DOPUS_BUILD_PROGRAMS=OFF \
            -DOPUS_BUILD_TESTING=OFF \
            -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
            -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF \
            || error_exit "opus CMake configuration failed"
        make -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" || error_exit "opus build failed"
        make install || error_exit "opus installation failed"
    )

    [[ -f "${install_path}/lib/libopus.a" ]] \
        || error_exit "libopus.a not found at ${install_path}/lib/"

    # A wrong-platform libopus.a surfaces only deep inside configure's link
    # test ("OPUS library not found"), nowhere near the real cause — so the
    # slice's arch, platform tag and minos are asserted here, while the target
    # is still known. Mirrors verify-xcframework.sh's LC_BUILD_VERSION check.
    local archs bv platform minos expected_platform
    archs="$(xcrun lipo -archs "${install_path}/lib/libopus.a" 2>/dev/null || echo '?')"
    [[ "$archs" == "$arch" ]] \
        || error_exit "libopus.a arch: expected ${arch}, got '${archs}'"
    expected_platform="IOS"
    [[ "$target" == "simulator" ]] && expected_platform="IOSSIMULATOR"
    bv="$(xcrun otool -l "${install_path}/lib/libopus.a" 2>/dev/null \
        | grep -m1 -A4 'LC_BUILD_VERSION' || true)"
    platform="$(echo "$bv" | awk '/platform/ {print $2; exit}')"
    minos="$(echo "$bv" | awk '/minos/ {print $2; exit}')"
    case "$expected_platform" in
        IOS)
            [[ "$platform" == "2" || "$platform" == "IOS" || "$platform" == "PLATFORM_IOS" ]] \
                || error_exit "libopus.a platform: expected iOS device, got '${platform}'" ;;
        IOSSIMULATOR)
            [[ "$platform" == "7" || "$platform" == "IOSSIMULATOR" || "$platform" == "PLATFORM_IOSSIMULATOR" ]] \
                || error_exit "libopus.a platform: expected iOS simulator, got '${platform}'" ;;
    esac
    [[ "$minos" == "${MIN_IOS_VERSION}" ]] \
        || error_exit "libopus.a minos: expected ${MIN_IOS_VERSION}, got '${minos}'"

    log_success "opus ${target} build complete"
}

build_pjsip() {
    local target="$1"
    local arch bcg729_path opus_path output_dir
    arch="$(get_target_arch "$target")"
    bcg729_path="${BUILD_ROOT}/bcg729-${target}"
    opus_path="${BUILD_ROOT}/opus-${target}"
    output_dir="${BUILD_ROOT}/${target}"

    log_info "Building PJSIP for ${target}..."

    export ARCH="-arch ${arch}"
    if [[ "$target" == "device" ]]; then
        export MIN_IOS="-miphoneos-version-min=${MIN_IOS_VERSION}"
        unset DEVPATH
    else
        # configure-iphone defaults to the iPhoneOS platform; point it at the
        # simulator platform, detected via xcrun rather than hardcoded.
        DEVPATH="$(detect_platform_devpath iphonesimulator)"
        export DEVPATH
        export MIN_IOS="-mios-simulator-version-min=${MIN_IOS_VERSION}"
        log_info "Simulator DEVPATH: ${DEVPATH}"
    fi
    export LDFLAGS="${BASE_LDFLAGS}${EXTRA_LDFLAGS:+ ${EXTRA_LDFLAGS}}"

    rm -rf "${output_dir}"
    ensure_pjproject_tree

    local configure_log="${META_DIR}/configure-${target}.log"
    (
        cd "${BUILD_ROOT}/pjproject" || error_exit "cannot enter ${BUILD_ROOT}/pjproject"
        find . -name "*.depend" -exec rm {} \; 2>/dev/null || true

        log_info "Configuring PJSIP (log: ${configure_log})..."
        # EXTRA_CONFIGURE_FLAGS is deliberately unquoted so several flags in it
        # word-split into separate args; quoting would pass the whole string as one.
        # (The array and path expansions on this command are already quoted.)
        # shellcheck disable=SC2086
        ./configure-iphone \
            "${CONFIGURE_FLAGS[@]}" \
            --with-bcg729="${bcg729_path}" \
            --with-opus="${opus_path}" \
            ${EXTRA_CONFIGURE_FLAGS:-} \
            2>&1 | tee "${configure_log}" \
            || error_exit "PJSIP configure failed"

        # Fail fast if configure silently dropped a critical option — the
        # binary checks in verify-xcframework.sh would catch it later, but
        # catching it here saves a long build.
        #
        # aconfigure.ac reports this check with AC_MSG_RESULT(yes|no); it has
        # never printed "ok", in 2.16 or in master. (The earlier guard here
        # looked for "ok" and so aborted every run — which is why the committed
        # 2.16 artifact was produced by the older buildPJwVideoPatch scripts and
        # not by this one.)
        if ! grep -qE "bcg729 usability\.\.\. (yes|ok)" "${configure_log}"; then
            error_exit "configure did not confirm bcg729 ('bcg729 usability... yes' missing). Check ${configure_log}."
        fi

        # Literal AC_MSG_RESULT from aconfigure.ac's opus section. The failure
        # branch prints 'OPUS library not found, OPUS support disabled' —
        # which is exactly what a wrong-platform libopus.a produces, so
        # build_opus asserts the slice's platform/minos itself.
        if ! grep -qF "OPUS library found, OPUS support enabled" "${configure_log}"; then
            error_exit "configure did not confirm opus ('OPUS library found, OPUS support enabled' missing). Check ${configure_log}."
        fi

        # NOT checked here: TLS. "Checking if SSL support is disabled... yes" in
        # the log refers to OpenSSL and is EXPECTED — we ship none. Nor does
        # --enable-darwin-ssl prove anything: AC_ARG_ENABLE(darwin-ssl) acts only
        # on the "no" case, so passing it SKIPS the autodetect and leaves
        # PJ_HAS_SSL_SOCK / PJ_SSL_SOCK_IMP undefined in os_auto.h. What actually
        # selects Apple TLS is config_site's PJ_SSL_SOCK_IMP_APPLE, since every
        # ssl_sock_*.{c,m} self-gates on that macro. The honest gate is therefore
        # the symbol check on the built binary in verify-xcframework.sh.

        log_info "Building PJSIP (this may take a while)..."
        if ! { make dep && make clean && make; }; then
            error_exit "PJSIP build failed"
        fi
    )

    record_build_env "$target"

    mkdir -p "${output_dir}"
    mv "${BUILD_ROOT}/pjproject" "${output_dir}/pjproject"
    mkdir -p "${output_dir}/bcg729"
    cp -R "${bcg729_path}/." "${output_dir}/bcg729/" 2>/dev/null || true
    mkdir -p "${output_dir}/opus"
    cp -R "${opus_path}/." "${output_dir}/opus/" 2>/dev/null || true

    log_success "PJSIP ${target} build complete"
}

# Merge every static lib in a build tree (all pjproject libs + third_party +
# bcg729 + opus) into ONE libpjproject.a. libtool is the supported macOS tool
# for combining archives; benign "same member name" warnings are kept in a log
# (the linker resolves by symbol).
combine_merge_libs() {
    local target="$1" out="$2"
    local libs=()
    while IFS= read -r -d '' lib; do
        libs+=("$lib")
    done < <(find "${BUILD_ROOT}/${target}/pjproject" -name "*.a" -type f -print0)

    if [[ -f "${BUILD_ROOT}/${target}/bcg729/lib/libbcg729.a" ]]; then
        libs+=("${BUILD_ROOT}/${target}/bcg729/lib/libbcg729.a")
    else
        log_warn "bcg729 static lib not found for ${target}; G.729 symbols will be missing"
    fi

    # libopus is mandatory, not a warn: the release exists for the codec, so an
    # opus-less archive is a broken artifact, not a degraded one.
    if [[ -f "${BUILD_ROOT}/${target}/opus/lib/libopus.a" ]]; then
        libs+=("${BUILD_ROOT}/${target}/opus/lib/libopus.a")
    else
        error_exit "libopus.a not found for ${target}; run the deps phase first"
    fi

    [[ ${#libs[@]} -gt 0 ]] || error_exit "No static libraries found for ${target}"

    log_info "Merging ${#libs[@]} static libs -> ${out}"
    local log="${out}.libtool.log"
    if ! xcrun libtool -static -o "${out}" "${libs[@]}" 2> "${log}"; then
        cat "${log}" >&2
        error_exit "libtool failed to merge ${target} libraries"
    fi
    [[ -f "${out}" ]] || error_exit "libtool produced no output at ${out}"
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

phase_download() {
    log_info "=== DOWNLOAD PHASE ==="
    check_download_prerequisites

    local pjsip_spec bcg729_spec opus_spec
    pjsip_spec="$(resolve_source_spec "PJSIP" "${PJSIP_SOURCE_FLAG}" "PJSIP_SOURCE" "Latest GitHub release")"
    bcg729_spec="$(resolve_source_spec "bcg729" "${BCG729_SOURCE_FLAG}" "BCG729_SOURCE" "Latest tagged release")"
    opus_spec="$(resolve_source_spec "opus" "${OPUS_SOURCE_FLAG}" "OPUS_SOURCE" "Latest tag")"

    log_info "PJSIP source:  ${pjsip_spec}"
    log_info "bcg729 source: ${bcg729_spec}"
    log_info "opus source:   ${opus_spec}"

    fetch_pjsip_source "$pjsip_spec"
    fetch_bcg729_source "$bcg729_spec"
    fetch_opus_source "$opus_spec"
    ensure_pjproject_tree   # patches + config_site, same path every build phase takes

    log_success "Download phase complete"
}

phase_deps() {
    log_info "=== DEPENDENCIES PHASE ==="
    check_build_prerequisites
    [[ -d "${BUILD_ROOT}/bcg729-source" ]] \
        || error_exit "bcg729 source not found. Run the download phase first."
    [[ -d "${BUILD_ROOT}/opus-source" ]] \
        || error_exit "opus source not found. Run the download phase first."
    build_bcg729 "device"
    build_bcg729 "simulator"
    build_opus "device"
    build_opus "simulator"
    log_success "Dependencies phase complete"
}

phase_device() {
    log_info "=== DEVICE BUILD PHASE ==="
    check_build_prerequisites
    [[ -d "${BUILD_ROOT}/bcg729-device" ]] \
        || error_exit "bcg729 device build not found. Run the deps phase first."
    [[ -d "${BUILD_ROOT}/opus-device" ]] \
        || error_exit "opus device build not found. Run the deps phase first."
    build_pjsip "device"
    log_success "Device build phase complete"
}

phase_simulator() {
    log_info "=== SIMULATOR BUILD PHASE ==="
    check_build_prerequisites
    [[ -d "${BUILD_ROOT}/bcg729-simulator" ]] \
        || error_exit "bcg729 simulator build not found. Run the deps phase first."
    [[ -d "${BUILD_ROOT}/opus-simulator" ]] \
        || error_exit "opus simulator build not found. Run the deps phase first."
    # Re-extract fresh: never mix device and simulator build artifacts.
    if [[ -d "${BUILD_ROOT}/pjproject" ]]; then
        log_info "Removing pjproject tree for a clean simulator build..."
        rm -rf "${BUILD_ROOT}/pjproject"
    fi
    build_pjsip "simulator"
    log_success "Simulator build phase complete"
}

# Per-library xcframeworks (~20 of them) for manual Xcode integration.
# Most consumers want `combine` instead — see the README.
phase_package() {
    log_info "=== PACKAGE PHASE (per-library xcframeworks) ==="
    check_build_prerequisites
    [[ -d "${BUILD_ROOT}/device" && -d "${BUILD_ROOT}/simulator" ]] \
        || error_exit "Device or simulator build not found. Run those phases first."

    rm -rf "${OUTPUT_DIR}/per-library"
    mkdir -p "${OUTPUT_DIR}/per-library"

    local libs=()
    while IFS= read -r -d '' lib; do
        libs+=("${lib#"${BUILD_ROOT}/device/"}")
    done < <(find "${BUILD_ROOT}/device" -name "*.a" -type f -print0)

    [[ ${#libs[@]} -gt 0 ]] || error_exit "No libraries found in device build"
    log_info "Found ${#libs[@]} libraries to package"

    local lib_path lib_name clean_name device_lib simulator_lib module_dir include_dir variant
    for lib_path in "${libs[@]}"; do
        lib_name="$(basename "$lib_path" .a)"
        device_lib="${BUILD_ROOT}/device/${lib_path}"
        simulator_lib="${BUILD_ROOT}/simulator/${lib_path}"

        if [[ ! -f "$simulator_lib" ]]; then
            log_warn "Simulator version of ${lib_name} not found, skipping..."
            continue
        fi

        clean_name="${lib_name/-aarch64/}"
        log_info "Creating ${clean_name}.xcframework..."
        xcodebuild -create-xcframework \
            -library "${device_lib}" \
            -library "${simulator_lib}" \
            -output "${OUTPUT_DIR}/per-library/${clean_name}.xcframework" \
            2>&1 | grep -v "warning:" || true

        # Headers live at pjproject/MODULE/include, not next to the .a files.
        module_dir="${lib_path%.a}"
        module_dir="${module_dir%/*}"
        module_dir="${module_dir%/lib}"
        include_dir="${BUILD_ROOT}/device/${module_dir}/include"
        if [[ -d "$include_dir" ]]; then
            for variant in ios-arm64 ios-arm64-simulator; do
                mkdir -p "${OUTPUT_DIR}/per-library/${clean_name}.xcframework/${variant}/Headers"
                cp -R "${include_dir}/." \
                    "${OUTPUT_DIR}/per-library/${clean_name}.xcframework/${variant}/Headers/" \
                    2>/dev/null || true
            done
        fi
    done

    log_success "Package phase complete. Per-library xcframeworks in ${OUTPUT_DIR}/per-library/"
}

# Single PJSIP.xcframework for Swift Package Manager.
#
# WHY a single combined artifact (not the ~20 per-.a xcframeworks from
# `package`): PJSIP is one tightly-coupled C library split into ~20 static
# libs whose PUBLIC headers cross-reference each other via angle brackets
# (<pj/types.h>, <pjsua-lib/pjsua.h>, ...), so they must share ONE include
# path. SwiftPM also copies each binary xcframework's Headers/ into a single
# shared include/ dir and ERRORS when a second module.modulemap appears — so
# SPM needs exactly one combined module: one static lib per slice + one
# unified Headers tree + one module.modulemap.
#   Sources: Apple "Creating a multiplatform binary framework bundle" (static
#   lib = `-library .a -headers <dir>`, one .a per platform); SwiftPM
#   duplicate-module.modulemap reports (SO 75762015, Swift Forums 87227).
#
# bcg729, libopus + all third_party static libs are FOLDED into libpjproject.a
# so the artifact is self-contained; the linker dead-strips unused objects at
# the consuming app's link step.
phase_combine() {
    log_info "=== COMBINE PHASE (single PJSIP.xcframework for SPM) ==="
    check_build_prerequisites
    [[ -d "${BUILD_ROOT}/device" && -d "${BUILD_ROOT}/simulator" ]] \
        || error_exit "Device or simulator build not found. Run those phases first."

    local work="${BUILD_ROOT}/combine"
    rm -rf "${work}"
    mkdir -p "${work}/ios-arm64" "${work}/ios-arm64-simulator" "${work}/Headers"

    # 1. Merge static libs per slice.
    combine_merge_libs "device"    "${work}/ios-arm64/libpjproject.a"
    combine_merge_libs "simulator" "${work}/ios-arm64-simulator/libpjproject.a"

    # 2. Union the PUBLIC headers. Namespaces are disjoint (pj/, pjlib-util/,
    #    pjmedia*/, pjnath/, pjsip*/, pjsua-lib/, pjsua2/, bcg729/), so copies
    #    never clash. This also carries the build-time pj/config_site.h into
    #    the artifact (see ABI note below).
    local inc="${BUILD_ROOT}/device/pjproject"
    cp -R "${inc}/pjlib/include/"*      "${work}/Headers/"
    cp -R "${inc}/pjlib-util/include/"* "${work}/Headers/"
    cp -R "${inc}/pjmedia/include/"*    "${work}/Headers/"
    cp -R "${inc}/pjnath/include/"*     "${work}/Headers/"
    cp -R "${inc}/pjsip/include/"*      "${work}/Headers/"
    if [[ -d "${BUILD_ROOT}/device/bcg729/include" ]]; then
        cp -R "${BUILD_ROOT}/device/bcg729/include/"* "${work}/Headers/"
    fi
    # No opus headers on purpose: <pjmedia-codec/opus.h> includes only
    # <pjmedia-codec/types.h>, and consumers never call raw libopus — shipping
    # include/opus/ would only invite duplicate-symbol surprises with a host's
    # own copy.

    # 3. Umbrella headers. Defining PJ_AUTOCONF=1 makes pj/config.h pull the
    #    autoconf headers (pj/compat/os_auto.h, m_auto.h) generated at build
    #    time, so the headers match the prebuilt binary.
    #
    #    NOTE: the umbrella filenames MUST NOT case-insensitively collide with
    #    PJSIP's own headers (macOS filesystems are case-insensitive). e.g.
    #    "PJSIP.h" would clobber the real "pjsip.h" core umbrella -> missing
    #    types. Hence the "-umbrella.h" suffix.
    #
    #    ABI note (config_site.h): the binary is compiled with a SPECIFIC
    #    config_site.h (video, VideoToolbox, BCG729, PJSIP_MAX_PKT_LEN, Apple
    #    SSL, ...). Those constants fix struct layouts / buffer sizes == ABI.
    #    The artifact ships that exact config_site.h; consumers must NOT
    #    override it (it cannot change the prebuilt binary and would desync
    #    struct layouts -> crashes).
    cat > "${work}/Headers/PJSIP-umbrella.h" <<'EOF'
/* Umbrella for the PJSIP C API (pjsua1 + pjsip / pjmedia / pjnath / pjlib).
 * PJ_AUTOCONF=1 selects the autoconf headers generated at build time so these
 * headers match the prebuilt libpjproject.a ABI. Do NOT override config_site.h. */
#define PJ_AUTOCONF 1
#include <pjsua.h>
#include <PJSIP-errno-swift.h>
EOF

    cat > "${work}/Headers/PJSUA2-umbrella.h" <<'EOF'
/* Umbrella for the PJSUA2 C++ API. The consuming Swift target must enable C++
 * interop (.interoperabilityMode(.Cxx)). pjsua2 headers include <pjsua-lib/pjsua.h>,
 * so the full C API is reachable from C++ contexts as well. */
#define PJ_AUTOCONF 1
#include <pjsua2.hpp>
EOF

    # 4. One module map, two modules. PJSIP's umbrella header owns the whole C
    #    stack; PJSUA2 (C++) implicitly imports PJSIP via its
    #    <pjsua-lib/pjsua.h> include, so the two can be imported together
    #    without duplicate-symbol conflicts. [system] silences PJSIP's many C
    #    warnings; `requires cplusplus` keeps PJSUA2 out of pure-C builds.
    #
    #    The two `textual header` lines are LOAD-BEARING, not tidiness. An
    #    `umbrella header` also registers its own directory (= all of Headers/)
    #    as an umbrella DIRECTORY, and clang then gives every header under it
    #    its own inferred submodule with its own macro scope. When two headers
    #    define the same macro, the importer gets the FIRST definer's value and
    #    the later override is silently dropped -- no warning, not even under
    #    -Wambiguous-macro. config_site.h is exactly that shape: it includes
    #    config_site_sample.h (which sets the PJ_CONFIG_IPHONE preset) and then
    #    overrides it. Result before this fix: the library was built with
    #    PJSUA_MAX_ACC 8 / PJSUA_MAX_CALLS 8 / PJSUA_MAX_CONF_PORTS 254, while
    #    every Swift consumer imported the preset's 4 / 4 / 12 -- and with
    #    them a pjsua_conf_port_info of 136 bytes against the binary's 1104,
    #    i.e. a buffer overflow waiting for the first pjsua_conf_get_port_info()
    #    call. Marking both config headers `textual` keeps them out of the
    #    submodule split, so every override lands in one macro scope and the
    #    module agrees with libpjproject.a. Reproduce either direction with
    #    `clang -E` vs `clang -fmodules -E`; verify-xcframework.sh asserts it.
    cat > "${work}/Headers/module.modulemap" <<'EOF'
module PJSIP [system] {
    umbrella header "PJSIP-umbrella.h"
    textual header "pj/config_site.h"
    textual header "pj/config_site_sample.h"
    export *
}

module PJSUA2 [system] {
    requires cplusplus
    header "PJSUA2-umbrella.h"
    export *
}
EOF

    # 4b. Swift names for the status codes Swift's Clang importer drops. Every
    #    PJSIP_E* code is `(PJSIP_ERRNO_START_PJSIP + n)`, and that base is
    #    itself `(PJSIP_ERRNO_START + 1000)`: Swift imports PJSIP_ERRNO_START
    #    but drops the base and every code defined from it, so a consumer could
    #    not name PJSIP_EBUSY at all. The pjlib-util, pjnath and audio/video
    #    device codes are dropped too, and pjsip-simple/errno.h is not reached
    #    from the umbrella at all. Which macros the importer handles is its own
    #    business and moves between Swift releases, so nothing here predicts
    #    it; each build measures:
    #    - Enumerate: the object-like macros the preprocessor attributes to the
    #      eight errno headers, minus range bounds, sizes and include guards.
    #      Line markers do the attribution, so #if blocks and comments are
    #      already resolved and no name pattern is needed.
    #    - Select: the names the module's synthesized Swift interface does not
    #      declare, measured on this very module before any constant is in it.
    #      Selection is not tidiness: a constant next to a macro Swift already
    #      imports makes every use of the name "ambiguous use of".
    #    - Emit: one typed constant per selected name, which Swift sees under
    #      the macro's own name. C and C++ see only the prefixed one, since a
    #      declaration cannot reuse the name of a macro. No value is computed
    #      here; C evaluates `= NAME`.
    #    A Swift newer than the build's that learns to import one of these
    #    macros hits that ambiguity in the consumer's build;
    #    verify-xcframework.sh --typecheck on that toolchain names them.
    local errno_dir="${work}/errno"
    local errno_target="arm64-apple-ios${MIN_IOS_VERSION}-simulator"
    local errno_headers=(pj/errno.h pjlib-util/errno.h pjnath/errno.h pjmedia/errno.h
                         pjmedia-audiodev/errno.h pjmedia-videodev/errno.h
                         pjsip/sip_errno.h pjsip-simple/errno.h)
    mkdir -p "${errno_dir}"

    {
        echo "#define PJ_AUTOCONF 1"
        printf '#include <%s>\n' "${errno_headers[@]}"
    } > "${errno_dir}/errno-all.c"
    xcrun --sdk iphonesimulator clang -target "${errno_target}" -I "${work}/Headers" \
        -E -dD "${errno_dir}/errno-all.c" > "${errno_dir}/errno-all.i" \
        || error_exit "Could not preprocess the errno headers (step 4b of phase_combine)."
    # "HEADER NAME" per status code, in header order.
    awk -v root="${work}/Headers/" -v files="${errno_headers[*]}" '
        BEGIN { n = split(files, list, " "); for (i = 1; i <= n; i++) header[root list[i]] = list[i] }
        /^# [0-9]+ "/ { file = $0; sub(/^# [0-9]+ "/, "", file); sub(/".*/, "", file); next }
        /^#define [A-Za-z_][A-Za-z0-9_]* / && (file in header) { print header[file], $2 }
    ' "${errno_dir}/errno-all.i" \
        | grep -vE ' [A-Za-z0-9_]*(_ERRNO_START|_ERRNO_END|_ERROR_START|_ERROR_END|_RCODE_START|_SPACE_SIZE|_MSG_SIZE|_BUF_SIZE|_H__)$| PJ_STRERROR_USE_' \
        > "${errno_dir}/codes.txt" \
        || error_exit "No status codes found in the errno headers (step 4b of phase_combine)."
    local sentinel
    for sentinel in PJSIP_EBUSY PJLIB_UTIL_EDNS_NXDOMAIN PJNATH_ESTUNTIMEDOUT \
                    PJMEDIA_EAUD_BADFORMAT PJMEDIA_EVID_INVDEV PJSIP_SIMPLE_ENOPKG; do
        grep -q " ${sentinel}\$" "${errno_dir}/codes.txt" \
            || error_exit "${sentinel} not found among the status codes the errno headers define; update step 4b of phase_combine."
    done

    # The header the module already includes, with no constant in it yet.
    # Written twice on purpose: selection has to see the module without the
    # constants, or every exported name would count as imported.
    local errno_preamble
    errno_preamble="$(
        echo "/* Generated by scripts/build.sh from the errno headers — do not edit."
        echo " * Each status code Swift's Clang importer drops gets a typed constant"
        echo " * that Swift sees under the macro's own name. */"
        echo "#ifndef PJSIP_ERRNO_SWIFT_H"
        echo "#define PJSIP_ERRNO_SWIFT_H"
        printf '#include <%s>\n' "${errno_headers[@]}"
    )"
    printf '%s\n\n#endif\n' "${errno_preamble}" > "${work}/Headers/PJSIP-errno-swift.h"
    xcrun --sdk iphonesimulator swift-synthesize-interface -module-name PJSIP \
        -target "${errno_target}" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
        -I "${work}/Headers" -module-cache-path "${errno_dir}/module-cache" \
        -o "${errno_dir}/PJSIP.swift" \
        || error_exit "swift-synthesize-interface could not read the PJSIP module (step 4b of phase_combine)."
    sed -nE 's/^public var ([A-Za-z_][A-Za-z0-9_]*):.*/\1/p' "${errno_dir}/PJSIP.swift" \
        > "${errno_dir}/imported.txt"
    awk 'NR == FNR { imported[$1]; next } !($2 in imported)' \
        "${errno_dir}/imported.txt" "${errno_dir}/codes.txt" > "${errno_dir}/export.txt"

    {
        printf '%s\n' "${errno_preamble}"
        awk '$1 != last { printf "\n/* %s */\n", $1; last = $1 }
             { printf "static const pj_status_t pjsip_swift_%s __attribute__((swift_name(\"%s\"))) = %s;\n", $2, $2, $2 }' \
            "${errno_dir}/export.txt"
        printf '\n#endif\n'
    } > "${work}/Headers/PJSIP-errno-swift.h"
    local codes exported
    codes="$(wc -l < "${errno_dir}/codes.txt" | tr -d ' ')"
    exported="$(wc -l < "${errno_dir}/export.txt" | tr -d ' ')"
    log_info "Status codes: ${codes} defined, $((codes - exported)) imported by Swift, ${exported} exported to Swift"

    # 5. Assemble the xcframework (static-library form: -library + -headers
    #    per slice).
    rm -rf "${OUTPUT_DIR}/PJSIP.xcframework"
    mkdir -p "${OUTPUT_DIR}"
    xcodebuild -create-xcframework \
        -library "${work}/ios-arm64/libpjproject.a"           -headers "${work}/Headers" \
        -library "${work}/ios-arm64-simulator/libpjproject.a" -headers "${work}/Headers" \
        -output  "${OUTPUT_DIR}/PJSIP.xcframework" \
        || error_exit "xcodebuild -create-xcframework failed"

    log_success "Combine phase complete -> ${OUTPUT_DIR}/PJSIP.xcframework"
    log_info "Folded into libpjproject.a: all pjproject libs + third_party + bcg729 + opus (self-contained; dead-stripped at app link)."
}

phase_verify() {
    log_info "=== VERIFY PHASE ==="
    [[ -d "${OUTPUT_DIR}/PJSIP.xcframework" ]] \
        || error_exit "${OUTPUT_DIR}/PJSIP.xcframework not found. Run the combine phase first."
    # --typecheck: what Swift can import is part of what is being released (the
    # status-code export in phase_combine exists only for Swift), so the build's
    # own verification compiles against the modules the way a consumer does.
    "${SCRIPTS_DIR}/verify-xcframework.sh" \
        --expect-min-ios "${MIN_IOS_VERSION}" \
        --typecheck \
        "${OUTPUT_DIR}/PJSIP.xcframework" \
        || error_exit "Verification FAILED — the binary does not match the requested build parameters."
    log_success "Verification passed"
}

# Generate RELEASE-NOTES.md describing exactly what was built, from what
# sources, with which parameters, by which tools — plus artifact checksums
# and the verification result. Ships next to the xcframework.
phase_notes() {
    log_info "=== NOTES PHASE (release notes) ==="
    [[ -d "${OUTPUT_DIR}/PJSIP.xcframework" ]] \
        || error_exit "${OUTPUT_DIR}/PJSIP.xcframework not found. Run the combine phase first."

    load_meta

    local notes="${OUTPUT_DIR}/RELEASE-NOTES.md"
    local device_lib="${OUTPUT_DIR}/PJSIP.xcframework/ios-arm64/libpjproject.a"
    local sim_lib="${OUTPUT_DIR}/PJSIP.xcframework/ios-arm64-simulator/libpjproject.a"

    # Verification summary (best effort — full report comes from `verify`).
    local verify_result="not run"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if "${SCRIPTS_DIR}/verify-xcframework.sh" --quiet \
            --expect-min-ios "${MIN_IOS_VERSION}" \
            "${OUTPUT_DIR}/PJSIP.xcframework" > "${META_DIR}/verify-report.txt" 2>&1; then
            verify_result="PASSED"
        else
            verify_result="FAILED (see scripts/verify-xcframework.sh output)"
        fi
    else
        verify_result="skipped (notes generated on non-macOS host)"
    fi

    {
        echo "# PJSIP.xcframework — build release notes"
        echo
        echo "Generated by \`scripts/build.sh notes\` on $(date -u '+%Y-%m-%d %H:%M UTC')."
        echo
        echo "## Sources"
        echo
        echo "| Component | Requested | Resolved ref | Commit | Origin |"
        echo "|-----------|-----------|--------------|--------|--------|"
        echo "| PJSIP | \`${PJSIP_SOURCE_SPEC:-unknown}\` | \`${PJSIP_REF:-unknown}\` | \`${PJSIP_COMMIT:-unknown}\` | ${PJSIP_URL:-unknown} |"
        echo "| bcg729 | \`${BCG729_SOURCE_SPEC:-unknown}\` | \`${BCG729_REF:-unknown}\` | \`${BCG729_COMMIT:-unknown}\` | ${BCG729_URL:-unknown} |"
        echo "| opus | \`${OPUS_SOURCE_SPEC:-unknown}\` | \`${OPUS_REF:-unknown}\` | \`${OPUS_COMMIT:-unknown}\` | ${OPUS_URL:-unknown} |"
        echo
        echo "## Build parameters"
        echo
        echo "- Slices: \`ios-arm64\` (device), \`ios-arm64-simulator\`"
        echo "- Minimum iOS: \`${MIN_IOS_VERSION:-unknown}\`"
        echo "- configure flags: \`${BUILT_CONFIGURE_FLAGS:-${CONFIGURE_FLAGS[*]}} --with-bcg729=<bcg729 install> --with-opus=<opus install>\`"
        echo "- Extra configure flags: \`${EXTRA_CONFIGURE_FLAGS:-none}\`"
        echo "- LDFLAGS: \`${BASE_LDFLAGS}${EXTRA_LDFLAGS:+ ${EXTRA_LDFLAGS}}\`"
        echo
        echo "### Local patches applied to the PJSIP source"
        echo
        if [[ -s "${META_DIR}/patches.txt" ]]; then
            echo "Applied by \`build.sh\` before configure, in this order. Rationale and upstream"
            echo "status for each: \`scripts/patches/README.md\`."
            echo
            echo "| Patch | SHA-256 |"
            echo "|-------|---------|"
            while read -r pname psha; do
                [[ -n "$pname" ]] && echo "| \`${pname}\` | \`${psha}\` |"
            done < "${META_DIR}/patches.txt"
        else
            echo "**None** — built from unmodified upstream source."
        fi
        echo
        echo "### config_site.h"
        echo
        echo "The exact compile-time configuration (fixes the ABI — do not override downstream):"
        echo
        echo '```c'
        cat "${META_DIR}/config_site.h" 2>/dev/null || echo "/* config_site.h snapshot missing — re-run the download or device phase */"
        echo '```'
        echo
        echo "## Toolchain & environment"
        echo
        echo "| Item | Value |"
        echo "|------|-------|"
        echo "| Build date (device build) | ${BUILD_DATE:-unknown} |"
        echo "| macOS | ${HOST_MACOS:-unknown} (\`${HOST_ARCH:-unknown}\`) |"
        echo "| Xcode | ${XCODE_VERSION:-unknown} |"
        echo "| Developer dir | ${DEVELOPER_DIR_USED:-unknown} |"
        echo "| iPhoneOS SDK | ${SDK_IPHONEOS:-unknown} |"
        echo "| iPhoneSimulator SDK | ${SDK_IPHONESIMULATOR:-unknown} |"
        echo "| clang | ${CLANG_VERSION:-unknown} |"
        echo "| CMake (bcg729, opus) | ${CMAKE_VERSION:-unknown} |"
        echo
        echo "## Artifacts"
        echo
        echo "| File | Size | SHA-256 |"
        echo "|------|------|---------|"
        if [[ -f "$device_lib" ]]; then
            echo "| ios-arm64/libpjproject.a | $(wc -c < "$device_lib" | tr -d ' ') bytes | \`$(sha256_of "$device_lib")\` |"
        fi
        if [[ -f "$sim_lib" ]]; then
            echo "| ios-arm64-simulator/libpjproject.a | $(wc -c < "$sim_lib" | tr -d ' ') bytes | \`$(sha256_of "$sim_lib")\` |"
        fi
        local zip_name zip_path
        zip_name="$(dist_zip_name)"
        zip_path="${OUTPUT_DIR}/${zip_name}"
        if [[ -f "${zip_path}" ]]; then
            echo "| ${zip_name} (release asset) | $(wc -c < "${zip_path}" | tr -d ' ') bytes | \`$(sha256_of "${zip_path}")\` |"
            echo
            echo "The zip's SHA-256 **is** the SwiftPM checksum — pin it directly:"
            echo
            echo '```swift'
            echo '.binaryTarget('
            echo '    name: "PJSIP",'
            echo "    url: \"https://github.com/laconicman/swift-pjsip/releases/download/<X.Y.Z>/${zip_name}\","
            echo "    checksum: \"$(sha256_of "${zip_path}")\""
            echo ')'
            echo '```'
        fi
        echo
        echo "## Verification"
        echo
        echo "Build-parameter adoption checks (\`scripts/verify-xcframework.sh\`): **${verify_result}**"
        echo
        echo "The checks confirm, against the binary itself: arm64 slices, device/simulator"
        echo "platform tags, minimum iOS version, native Darwin SSL (Network/Security symbol"
        echo "references, no OpenSSL), TLS transport, video + VideoToolbox codec, bcg729"
        echo "G.729, Opus, SRTP, and that disabled codecs (GSM/Speex) are absent."
    } > "${notes}"

    log_success "Release notes written -> ${notes}"
}

# Zip the xcframework and compute the SwiftPM checksum, for distributing via
# `.binaryTarget(url:checksum:)` from a GitHub Release instead of committing
# the binary. (Never use Git LFS for SPM binaries — consumers receive pointer
# files; see docs/SPM-XCFRAMEWORK-EXPERIENCE.md.)
# Name of the release asset: PJSIP.xcframework-<pjsip-version>-<short-sha>.zip.
# Both halves are derived from the build itself — the version from the built
# headers, the SHA from recorded source metadata — so the name cannot drift from
# the contents. Falls back to the bare name when either is unavailable.
# Rationale: docs/Versioning.md "Artifact naming".
dist_zip_name() {
    local hdr="${OUTPUT_DIR}/PJSIP.xcframework/ios-arm64/Headers/pj/config.h"
    local ver="" sha=""
    if [[ -f "$hdr" ]]; then
        local maj min rev
        maj="$(awk '/^#define PJ_VERSION_NUM_MAJOR/ {print $3; exit}' "$hdr")"
        min="$(awk '/^#define PJ_VERSION_NUM_MINOR/ {print $3; exit}' "$hdr")"
        rev="$(awk '/^#define PJ_VERSION_NUM_REV/   {print $3; exit}' "$hdr")"
        [[ -n "$maj" && -n "$min" && -n "$rev" ]] && ver="${maj}.${min}.${rev}"
    fi
    load_meta
    sha="$(echo "${PJSIP_COMMIT:-}" | cut -c1-9)"

    if [[ -n "$ver" && -n "$sha" ]]; then
        echo "PJSIP.xcframework-${ver}-${sha}.zip"
    elif [[ -n "$ver" ]]; then
        echo "PJSIP.xcframework-${ver}.zip"
    else
        echo "PJSIP.xcframework.zip"
    fi
}

phase_dist() {
    log_info "=== DIST PHASE (zip + checksum) ==="
    [[ -d "${OUTPUT_DIR}/PJSIP.xcframework" ]] \
        || error_exit "${OUTPUT_DIR}/PJSIP.xcframework not found. Run the combine phase first."

    local zip_name zip_path
    zip_name="$(dist_zip_name)"
    zip_path="${OUTPUT_DIR}/${zip_name}"
    rm -f "${zip_path}"
    # ditto preserves bundle symlinks/signatures and matches what Xcode/SPM expect;
    # plain `zip` stores symlink targets unless given -y and can break a signature.
    ( cd "${OUTPUT_DIR}" && ditto -c -k --keepParent "PJSIP.xcframework" "${zip_name}" ) \
        || error_exit "ditto zip failed"

    # `swift package compute-checksum` requires a manifest in CWD, so run it from the
    # package root (which has Package.swift). The value is just the zip's SHA-256, so a
    # plain shasum is an exact fallback when no Swift toolchain is present.
    local checksum
    if command -v swift &>/dev/null; then
        checksum="$(cd "${REPO_ROOT}" && swift package compute-checksum "${zip_path}" 2>/dev/null)" \
            || checksum="$(sha256_of "${zip_path}")"
    else
        checksum="$(sha256_of "${zip_path}")"
    fi

    log_success "Distribution archive: ${zip_path}"
    log_info "SwiftPM checksum: ${checksum}"
    cat <<EOF

To distribute via a GitHub Release instead of committing the binary:

  1. Upload PJSIP.xcframework.zip as a release asset for tag <X.Y.Z>.
  2. Point the manifest at it:

     .binaryTarget(
         name: "PJSIP",
         url: "https://github.com/laconicman/swift-pjsip/releases/download/<X.Y.Z>/${zip_name}",
         checksum: "${checksum}"
     )

EOF
}

# Stage the built artifact into Binaries/ so a LOCAL path-based build can consume
# it — how you test an artifact before publishing it. Binaries/ is gitignored: the
# released package fetches the asset by URL + checksum (docs/Versioning.md), so this
# is a development convenience, not the release path. To consume a staged artifact,
# temporarily point Package.swift at `path: "Binaries/PJSIP.xcframework"`.
phase_install() {
    log_info "=== INSTALL PHASE ==="
    [[ -d "${OUTPUT_DIR}/PJSIP.xcframework" ]] \
        || error_exit "${OUTPUT_DIR}/PJSIP.xcframework not found. Run the combine phase first."

    rm -rf "${REPO_ROOT}/Binaries/PJSIP.xcframework"
    mkdir -p "${REPO_ROOT}/Binaries"
    cp -R "${OUTPUT_DIR}/PJSIP.xcframework" "${REPO_ROOT}/Binaries/PJSIP.xcframework"
    if [[ -f "${OUTPUT_DIR}/RELEASE-NOTES.md" ]]; then
        cp "${OUTPUT_DIR}/RELEASE-NOTES.md" "${REPO_ROOT}/Binaries/RELEASE-NOTES.md"
    else
        log_warn "No RELEASE-NOTES.md in output — run the notes phase to document this build."
    fi

    log_success "Staged into ${REPO_ROOT}/Binaries/ (gitignored — local testing only)"
    log_info "To release instead: build.sh dist notes, then tag + 'gh release create' (docs/Versioning.md)."
}

phase_clean() {
    log_info "=== CLEAN PHASE ==="
    clean_target "device"
    clean_target "simulator"
    rm -rf "${BUILD_ROOT}/pjproject" "${BUILD_ROOT}/combine" "${OUTPUT_DIR}"
    log_success "Clean complete (downloaded archives and meta kept; use distclean to remove everything)"
}

phase_distclean() {
    log_info "=== DISTCLEAN PHASE ==="
    rm -rf "${BUILD_ROOT}"
    log_success "Removed ${BUILD_ROOT}"
}

phase_all() {
    phase_download
    phase_deps
    phase_device
    phase_simulator
    phase_combine
    phase_verify
    phase_notes
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
    cat << EOF
Usage: $0 [options] <phase> [phase ...]

Phases:
  download   Fetch PJSIP + bcg729 + opus sources (interactive source selection on a TTY)
  deps       Build bcg729 and opus for device and simulator
  device     Build PJSIP for iOS device (arm64)
  simulator  Build PJSIP for iOS simulator (arm64)
  combine    Create the single PJSIP.xcframework for Swift Package Manager
  verify     Check that build parameters were really adopted by the binary
  notes      Generate RELEASE-NOTES.md (sources, params, toolchain, checksums)
  package    Create ~20 per-library xcframeworks (manual Xcode integration only)
  dist       Zip the xcframework + compute the SwiftPM checksum (release-asset flow)
  install    Copy PJSIP.xcframework + RELEASE-NOTES.md into Binaries/
  clean      Remove build artifacts (keeps downloaded archives)
  distclean  Remove the entire build root
  all        download deps device simulator combine verify notes

Options:
  --pjsip-source SPEC    PJSIP source: latest | tag=<tag> | branch=<name> | commit=<sha> | archive=<path>
  --bcg729-source SPEC   bcg729 source: latest | tag=<tag> | branch=<name> | archive=<path>
  --opus-source SPEC     opus source: latest | tag=<tag> | branch=<name> | commit=<sha> | archive=<path>
  -y, --non-interactive  Never prompt; unspecified sources default to 'latest'
  --min-ios VER          Minimum iOS version (default: ${MIN_IOS_VERSION})
  --config-site PATH     config_site.h to bake in (default: scripts/config_site-ios.h)
  --patches DIR          Directory of *.patch to apply (default: scripts/patches;
                         point elsewhere, or at an empty dir, to build unpatched)
  --allow-stale-cites    Warn instead of fail when the config_site.h file:line
                         citations do not match the PJSIP tree (scripts/check-cites.sh)
  --build-root DIR       Work directory (default: <repo>/.build-pjsip)
  -h, --help             Show this help

Environment equivalents: PJSIP_SOURCE, BCG729_SOURCE, OPUS_SOURCE, NONINTERACTIVE=1,
MIN_IOS_VERSION, CONFIG_SITE, PATCHES_DIR, ALLOW_STALE_CITES=1, PJSIP_BUILD_ROOT,
EXTRA_CONFIGURE_FLAGS, EXTRA_LDFLAGS.

Examples:
  $0 all                                   # interactive source selection, full build
  $0 -y all                                # CI: latest releases, no prompts
  $0 --pjsip-source tag=2.16 all           # build a specific PJSIP release
  $0 --pjsip-source commit=288de6142 all   # pin an exact upstream tree (releases)
  $0 --pjsip-source archive=~/pjsip.zip \\
     --bcg729-source branch=master all     # mix local archive + branch head
  $0 combine verify notes install          # re-package an existing build
EOF
}

main() {
    local phases=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pjsip-source)    PJSIP_SOURCE_FLAG="${2:?--pjsip-source needs a value}"; shift 2 ;;
            --pjsip-source=*)  PJSIP_SOURCE_FLAG="${1#*=}"; shift ;;
            --bcg729-source)   BCG729_SOURCE_FLAG="${2:?--bcg729-source needs a value}"; shift 2 ;;
            --bcg729-source=*) BCG729_SOURCE_FLAG="${1#*=}"; shift ;;
            --opus-source)     OPUS_SOURCE_FLAG="${2:?--opus-source needs a value}"; shift 2 ;;
            --opus-source=*)   OPUS_SOURCE_FLAG="${1#*=}"; shift ;;
            -y|--non-interactive) NONINTERACTIVE=1; shift ;;
            --min-ios)         MIN_IOS_VERSION="${2:?--min-ios needs a value}"; shift 2 ;;
            --min-ios=*)       MIN_IOS_VERSION="${1#*=}"; shift ;;
            --config-site)     CONFIG_SITE="${2:?--config-site needs a value}"; shift 2 ;;
            --config-site=*)   CONFIG_SITE="${1#*=}"; shift ;;
            --patches)         PATCHES_DIR="${2:?--patches needs a value}"; shift 2 ;;
            --patches=*)       PATCHES_DIR="${1#*=}"; shift ;;
            --allow-stale-cites) ALLOW_STALE_CITES=1; shift ;;
            --build-root)      BUILD_ROOT="${2:?--build-root needs a value}"; shift 2 ;;
            --build-root=*)    BUILD_ROOT="${1#*=}"; shift ;;
            -h|--help)         usage; exit 0 ;;
            download|deps|device|simulator|package|combine|verify|notes|dist|install|clean|distclean|all)
                phases+=("$1"); shift ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    # --build-root may have changed BUILD_ROOT; recompute derived paths.
    META_DIR="${BUILD_ROOT}/meta"
    OUTPUT_DIR="${BUILD_ROOT}/output"

    if [[ ${#phases[@]} -eq 0 ]]; then
        usage
        exit 1
    fi

    local phase
    for phase in ${phases[@]+"${phases[@]}"}; do
        "phase_${phase}"
    done
}

main "$@"
