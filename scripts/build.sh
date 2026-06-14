#!/bin/bash
#
# build.sh — build PJSIP (+ bcg729) for iOS and package it as the single
# combined PJSIP.xcframework that this Swift package ships in Binaries/.
#
# Follows the official PJSIP build guidance:
#   - https://docs.pjsip.org/en/latest/get-started/ios/build_instructions.html
#   - https://docs.pjsip.org/en/latest/pjsua2/building.html
#
# Usage: ./scripts/build.sh [options] <phase> [phase ...]
# Run with --help for the full phase/option reference.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Defaults (every one overridable via flag or environment)
# ---------------------------------------------------------------------------

MIN_IOS_VERSION="${MIN_IOS_VERSION:-15.0}"   # keep in sync with Package.swift `.iOS(.v15)`
CONFIG_SITE="${CONFIG_SITE:-${SCRIPTS_DIR}/config_site.h}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
PJSIP_SOURCE_FLAG=""
BCG729_SOURCE_FLAG=""

# The configure flags that define this distribution: native Darwin SSL (TLS
# via Security/Network frameworks, no OpenSSL), video, G.729 via bcg729,
# and no GSM/Speex. Changing these changes the ABI story documented in the
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
        release|tag|branch)
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
        cd "${build_dir}"
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

build_pjsip() {
    local target="$1"
    local arch bcg729_path output_dir
    arch="$(get_target_arch "$target")"
    bcg729_path="${BUILD_ROOT}/bcg729-${target}"
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
        cd "${BUILD_ROOT}/pjproject"
        find . -name "*.depend" -exec rm {} \; 2>/dev/null || true

        log_info "Configuring PJSIP (log: ${configure_log})..."
        # shellcheck disable=SC2086
        ./configure-iphone \
            "${CONFIGURE_FLAGS[@]}" \
            --with-bcg729="${bcg729_path}" \
            ${EXTRA_CONFIGURE_FLAGS:-} \
            2>&1 | tee "${configure_log}" \
            || error_exit "PJSIP configure failed"

        # Fail fast if configure silently dropped a critical option — the
        # binary checks in verify-xcframework.sh would catch it later, but
        # catching it here saves a long build.
        if ! grep -q "bcg729 usability... ok" "${configure_log}"; then
            error_exit "configure did not confirm bcg729 ('bcg729 usability... ok' missing). Check ${configure_log}."
        fi
        if grep -qi "darwin ssl.*no\|ssl.*disabled" "${configure_log}"; then
            log_warn "configure output suggests Darwin SSL may be disabled — check ${configure_log}"
        fi

        log_info "Building PJSIP (this may take a while)..."
        make dep && make clean && make || error_exit "PJSIP build failed"
    )

    record_build_env "$target"

    mkdir -p "${output_dir}"
    mv "${BUILD_ROOT}/pjproject" "${output_dir}/pjproject"
    mkdir -p "${output_dir}/bcg729"
    cp -R "${bcg729_path}/." "${output_dir}/bcg729/" 2>/dev/null || true

    log_success "PJSIP ${target} build complete"
}

# Merge every static lib in a build tree (all pjproject libs + third_party +
# bcg729) into ONE libpjproject.a. libtool is the supported macOS tool for
# combining archives; benign "same member name" warnings are kept in a log
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

    local pjsip_spec bcg729_spec
    pjsip_spec="$(resolve_source_spec "PJSIP" "${PJSIP_SOURCE_FLAG}" "PJSIP_SOURCE" "Latest GitHub release")"
    bcg729_spec="$(resolve_source_spec "bcg729" "${BCG729_SOURCE_FLAG}" "BCG729_SOURCE" "Latest tagged release")"

    log_info "PJSIP source:  ${pjsip_spec}"
    log_info "bcg729 source: ${bcg729_spec}"

    fetch_pjsip_source "$pjsip_spec"
    fetch_bcg729_source "$bcg729_spec"
    apply_config_site

    log_success "Download phase complete"
}

phase_deps() {
    log_info "=== DEPENDENCIES PHASE ==="
    check_build_prerequisites
    [[ -d "${BUILD_ROOT}/bcg729-source" ]] \
        || error_exit "bcg729 source not found. Run the download phase first."
    build_bcg729 "device"
    build_bcg729 "simulator"
    log_success "Dependencies phase complete"
}

phase_device() {
    log_info "=== DEVICE BUILD PHASE ==="
    check_build_prerequisites
    [[ -d "${BUILD_ROOT}/bcg729-device" ]] \
        || error_exit "bcg729 device build not found. Run the deps phase first."
    build_pjsip "device"
    log_success "Device build phase complete"
}

phase_simulator() {
    log_info "=== SIMULATOR BUILD PHASE ==="
    check_build_prerequisites
    [[ -d "${BUILD_ROOT}/bcg729-simulator" ]] \
        || error_exit "bcg729 simulator build not found. Run the deps phase first."
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
# bcg729 + all third_party static libs are FOLDED into libpjproject.a so the
# artifact is self-contained; the linker dead-strips unused objects at the
# consuming app's link step.
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
    cat > "${work}/Headers/module.modulemap" <<'EOF'
module PJSIP [system] {
    umbrella header "PJSIP-umbrella.h"
    export *
}

module PJSUA2 [system] {
    requires cplusplus
    header "PJSUA2-umbrella.h"
    export *
}
EOF

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
    log_info "Folded into libpjproject.a: all pjproject libs + third_party + bcg729 (self-contained; dead-stripped at app link)."
}

phase_verify() {
    log_info "=== VERIFY PHASE ==="
    [[ -d "${OUTPUT_DIR}/PJSIP.xcframework" ]] \
        || error_exit "${OUTPUT_DIR}/PJSIP.xcframework not found. Run the combine phase first."
    "${SCRIPTS_DIR}/verify-xcframework.sh" \
        --expect-min-ios "${MIN_IOS_VERSION}" \
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
        echo
        echo "## Build parameters"
        echo
        echo "- Slices: \`ios-arm64\` (device), \`ios-arm64-simulator\`"
        echo "- Minimum iOS: \`${MIN_IOS_VERSION:-unknown}\`"
        echo "- configure flags: \`${CONFIGURE_FLAGS[*]} --with-bcg729=<bcg729 install>\`"
        echo "- Extra configure flags: \`${EXTRA_CONFIGURE_FLAGS:-none}\`"
        echo "- LDFLAGS: \`${BASE_LDFLAGS}${EXTRA_LDFLAGS:+ ${EXTRA_LDFLAGS}}\`"
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
        echo "| CMake (bcg729) | ${CMAKE_VERSION:-unknown} |"
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
        echo
        echo "## Verification"
        echo
        echo "Build-parameter adoption checks (\`scripts/verify-xcframework.sh\`): **${verify_result}**"
        echo
        echo "The checks confirm, against the binary itself: arm64 slices, device/simulator"
        echo "platform tags, minimum iOS version, native Darwin SSL (Network/Security symbol"
        echo "references, no OpenSSL), TLS transport, video + VideoToolbox codec, bcg729"
        echo "G.729, SRTP, and that disabled codecs (GSM/Speex) are absent."
    } > "${notes}"

    log_success "Release notes written -> ${notes}"
}

# Zip the xcframework and compute the SwiftPM checksum, for distributing via
# `.binaryTarget(url:checksum:)` from a GitHub Release instead of committing
# the binary. (Never use Git LFS for SPM binaries — consumers receive pointer
# files; see docs/SPM-XCFRAMEWORK-EXPERIENCE.md.)
phase_dist() {
    log_info "=== DIST PHASE (zip + checksum) ==="
    [[ -d "${OUTPUT_DIR}/PJSIP.xcframework" ]] \
        || error_exit "${OUTPUT_DIR}/PJSIP.xcframework not found. Run the combine phase first."

    local zip_path="${OUTPUT_DIR}/PJSIP.xcframework.zip"
    rm -f "${zip_path}"
    # ditto preserves bundle symlinks/signatures and matches what Xcode/SPM expect;
    # plain `zip` stores symlink targets unless given -y and can break a signature.
    ( cd "${OUTPUT_DIR}" && ditto -c -k --keepParent "PJSIP.xcframework" "PJSIP.xcframework.zip" ) \
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
         url: "https://github.com/laconicman/swift-pjsip/releases/download/<X.Y.Z>/PJSIP.xcframework.zip",
         checksum: "${checksum}"
     )

EOF
}

# Copy the built artifact (and release notes) into the package's Binaries/,
# replacing the committed xcframework. Review `git diff` and commit manually.
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

    log_success "Installed into ${REPO_ROOT}/Binaries/"
    log_info "Next: review 'git status', commit, tag a semantic version, push."
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
  download   Fetch PJSIP + bcg729 sources (interactive source selection on a TTY)
  deps       Build bcg729 for device and simulator
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
  --pjsip-source SPEC    PJSIP source: latest | tag=<tag> | branch=<name> | archive=<path>
  --bcg729-source SPEC   bcg729 source: latest | tag=<tag> | branch=<name> | archive=<path>
  -y, --non-interactive  Never prompt; unspecified sources default to 'latest'
  --min-ios VER          Minimum iOS version (default: ${MIN_IOS_VERSION})
  --config-site PATH     config_site.h to bake in (default: scripts/config_site.h)
  --build-root DIR       Work directory (default: <repo>/.build-pjsip)
  -h, --help             Show this help

Environment equivalents: PJSIP_SOURCE, BCG729_SOURCE, NONINTERACTIVE=1,
MIN_IOS_VERSION, CONFIG_SITE, PJSIP_BUILD_ROOT, EXTRA_CONFIGURE_FLAGS, EXTRA_LDFLAGS.

Examples:
  $0 all                                   # interactive source selection, full build
  $0 -y all                                # CI: latest releases, no prompts
  $0 --pjsip-source tag=2.16 all           # build a specific PJSIP release
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
            -y|--non-interactive) NONINTERACTIVE=1; shift ;;
            --min-ios)         MIN_IOS_VERSION="${2:?--min-ios needs a value}"; shift 2 ;;
            --min-ios=*)       MIN_IOS_VERSION="${1#*=}"; shift ;;
            --config-site)     CONFIG_SITE="${2:?--config-site needs a value}"; shift 2 ;;
            --config-site=*)   CONFIG_SITE="${1#*=}"; shift ;;
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
