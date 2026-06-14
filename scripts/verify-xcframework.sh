#!/bin/bash
#
# verify-xcframework.sh — prove that a PJSIP.xcframework was really built with
# the parameters this distribution promises, by inspecting the binary itself
# (not the build logs).
#
# Checks, per slice:
#   - architecture (arm64) and platform tag (device vs simulator, via
#     LC_BUILD_VERSION) and minimum iOS version
#   - native Darwin SSL: Security/Network framework symbol references present,
#     OpenSSL symbols absent
#   - TLS transport, video subsystem, VideoToolbox codec, bcg729 (G.729),
#     SRTP — all present as defined symbols
#   - disabled codecs (GSM, Speex) absent
# Plus header checks: module map shape, config_site.h constants, and
# case-insensitive filename collisions (the macOS umbrella-clobbering bug).
#
# Usage:
#   verify-xcframework.sh [--expect-min-ios 15.0] [--quiet] [--typecheck] <PJSIP.xcframework>
#
#   --typecheck additionally compiles `import PJSIP` / `import PJSUA2` against
#   the xcframework headers with swiftc — the closest no-app approximation of
#   what SwiftPM does in a consumer build.
#
# Standalone on purpose: it can verify the committed Binaries/PJSIP.xcframework
# without any build state. Requires macOS (xcrun, nm, otool, lipo).

set -euo pipefail

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi

EXPECT_MIN_IOS="15.0"
QUIET=0
TYPECHECK=0
XCF=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expect-min-ios)   EXPECT_MIN_IOS="${2:?--expect-min-ios needs a value}"; shift 2 ;;
        --expect-min-ios=*) EXPECT_MIN_IOS="${1#*=}"; shift ;;
        --quiet)            QUIET=1; shift ;;
        --typecheck)        TYPECHECK=1; shift ;;
        -h|--help)          grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -28; exit 0 ;;
        *)                  XCF="$1"; shift ;;
    esac
done

[[ -n "$XCF" ]] || { echo "Usage: $0 [--expect-min-ios VER] [--quiet] [--typecheck] <PJSIP.xcframework>" >&2; exit 2; }
[[ -d "$XCF" ]] || { echo "Not found: $XCF" >&2; exit 2; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "This verifier needs macOS binary tools (nm/otool/lipo)." >&2; exit 2; }

PASS=0; FAIL=0; WARN=0

pass() { PASS=$((PASS + 1)); [[ $QUIET -eq 1 ]] || printf "  ${GREEN}PASS${NC}  %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "  ${RED}FAIL${NC}  %s\n" "$*"; }
warn() { WARN=$((WARN + 1)); [[ $QUIET -eq 1 ]] || printf "  ${YELLOW}WARN${NC}  %s\n" "$*"; }
section() { [[ $QUIET -eq 1 ]] || printf "\n%s\n" "$*"; }

TMP="$(mktemp -d /tmp/pjsip-verify.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Symbol-table helpers (nm output cached per slice)
# ---------------------------------------------------------------------------

prepare_symbols() {
    # prepare_symbols LIB PREFIX -> writes $TMP/PREFIX.{defined,undefined}
    local lib="$1" prefix="$2"
    xcrun nm -gUj "$lib" 2>/dev/null | sort -u > "$TMP/${prefix}.defined" || true
    xcrun nm -guj "$lib" 2>/dev/null | sort -u > "$TMP/${prefix}.undefined" || true
}

has_defined()    { grep -qx "_$2" "$TMP/$1.defined"; }
has_undefined()  { grep -qx "_$2" "$TMP/$1.undefined"; }
count_prefix_u() { grep -c "^_$2" "$TMP/$1.undefined" 2>/dev/null || true; }

check_defined() {
    # check_defined PREFIX SYMBOL DESCRIPTION
    if has_defined "$1" "$2"; then
        pass "$3 (symbol _$2 present)"
    else
        fail "$3 — symbol _$2 NOT found"
    fi
}

check_absent() {
    # check_absent PREFIX SYMBOL DESCRIPTION — neither defined nor referenced
    if has_defined "$1" "$2" || has_undefined "$1" "$2"; then
        fail "$3 — symbol _$2 unexpectedly present"
    else
        pass "$3 (no _$2)"
    fi
}

# ---------------------------------------------------------------------------
# Per-slice binary checks
# ---------------------------------------------------------------------------

verify_slice() {
    local slice="$1" expected_platform="$2"   # expected_platform: IOS | IOSSIMULATOR
    local lib="$XCF/$slice/libpjproject.a"

    section "── Slice: $slice"

    if [[ ! -f "$lib" ]]; then
        fail "libpjproject.a missing in $slice"
        return
    fi

    # Architecture
    local archs
    archs="$(xcrun lipo -archs "$lib" 2>/dev/null || echo '?')"
    if [[ "$archs" == "arm64" ]]; then
        pass "architecture: $archs"
    else
        fail "architecture: expected arm64, got '$archs'"
    fi

    # Platform + minimum OS from the first object's LC_BUILD_VERSION.
    # otool prints 'platform 2' (IOS) / 'platform 7' (IOSSIMULATOR) on older
    # toolchains and symbolic names on newer ones — accept both.
    local bv platform minos
    bv="$(xcrun otool -l "$lib" 2>/dev/null | grep -m1 -A4 'LC_BUILD_VERSION' || true)"
    platform="$(echo "$bv" | awk '/platform/ {print $2; exit}')"
    minos="$(echo "$bv" | awk '/minos/ {print $2; exit}')"

    case "$expected_platform" in
        IOS)
            if [[ "$platform" == "2" || "$platform" == "IOS" || "$platform" == "PLATFORM_IOS" ]]; then
                pass "platform tag: iOS device ($platform)"
            else
                fail "platform tag: expected iOS device (2), got '$platform'"
            fi
            ;;
        IOSSIMULATOR)
            if [[ "$platform" == "7" || "$platform" == "IOSSIMULATOR" || "$platform" == "PLATFORM_IOSSIMULATOR" ]]; then
                pass "platform tag: iOS simulator ($platform)"
            else
                fail "platform tag: expected iOS simulator (7), got '$platform'"
            fi
            ;;
    esac

    if [[ "$minos" == "$EXPECT_MIN_IOS" ]]; then
        pass "minimum iOS: $minos"
    elif [[ -z "$minos" ]]; then
        warn "minimum iOS: could not read LC_BUILD_VERSION minos"
    else
        fail "minimum iOS: expected $EXPECT_MIN_IOS, got $minos"
    fi

    prepare_symbols "$lib" "$slice"

    # Core stack
    check_defined "$slice" "pj_init"      "pjlib core built"
    check_defined "$slice" "pjsua_create" "pjsua (high-level C API) built"

    # TLS transport + native Darwin SSL (--enable-darwin-ssl):
    # the Darwin backend talks to Apple's Network/Security frameworks, so the
    # archive must REFERENCE their symbols; OpenSSL symbols must be absent.
    check_defined "$slice" "pjsip_tls_transport_start" "TLS transport compiled in (PJSIP_HAS_TLS_TRANSPORT)"
    local sec_refs nw_refs
    sec_refs="$(count_prefix_u "$slice" "Sec")"
    nw_refs="$(count_prefix_u "$slice" "nw_")"
    if [[ "${sec_refs:-0}" -gt 0 || "${nw_refs:-0}" -gt 0 ]]; then
        pass "native Darwin SSL: references Security (${sec_refs:-0}) / Network (${nw_refs:-0}) framework symbols"
    else
        fail "native Darwin SSL: no Security/Network framework symbol references found"
    fi
    check_absent "$slice" "SSL_CTX_new"     "no OpenSSL (SSL_CTX_new)"
    check_absent "$slice" "OPENSSL_init_ssl" "no OpenSSL (OPENSSL_init_ssl)"

    # Video (--enable-video + config_site PJMEDIA_VIDEO_DEV_HAS_IOS / VID_TOOLBOX)
    check_defined "$slice" "pjmedia_vid_dev_subsys_init"     "video device subsystem built (PJMEDIA_HAS_VIDEO)"
    check_defined "$slice" "pjmedia_codec_vid_toolbox_init"  "VideoToolbox codec built (PJMEDIA_HAS_VID_TOOLBOX_CODEC)"
    if has_undefined "$slice" 'VTCompressionSessionCreate'; then
        pass "VideoToolbox framework referenced (VTCompressionSessionCreate)"
    else
        warn "VideoToolbox framework reference not found (VTCompressionSessionCreate)"
    fi
    if grep -qxF '_OBJC_CLASS_$_AVCaptureSession' "$TMP/$slice.undefined"; then
        pass "iOS camera backend referenced (AVCaptureSession)"
    else
        warn "AVCaptureSession reference not found — iOS video device backend may be off"
    fi

    # G.729 via bcg729 (--with-bcg729 + PJMEDIA_HAS_BCG729)
    check_defined "$slice" "pjmedia_codec_bcg729_init"  "PJSIP bcg729 codec wrapper built (PJMEDIA_HAS_BCG729)"
    check_defined "$slice" "initBcg729EncoderChannel"   "bcg729 implementation folded into archive"

    # SRTP (bundled third-party, on by default)
    check_defined "$slice" "pjmedia_transport_srtp_create" "SRTP transport built"

    # Codecs that were explicitly disabled at configure time
    check_absent "$slice" "pjmedia_codec_gsm_init"   "GSM codec disabled (--disable-gsm-codec)"
    check_absent "$slice" "pjmedia_codec_speex_init" "Speex codec disabled (--disable-speex-codec)"

    # PJSUA2 C++ API (mangled C++ symbols, e.g. pj::Endpoint)
    if grep -q 'N2pj8Endpoint' "$TMP/$slice.defined"; then
        pass "PJSUA2 C++ API present (pj::Endpoint symbols)"
    else
        warn "PJSUA2 C++ symbols not found — PJSUA2 module would be empty"
    fi
}

# ---------------------------------------------------------------------------
# Header / bundle checks
# ---------------------------------------------------------------------------

verify_headers() {
    local headers="$XCF/ios-arm64/Headers"
    section "── Headers & bundle"

    if [[ -f "$XCF/Info.plist" ]]; then
        if plutil -lint "$XCF/Info.plist" >/dev/null 2>&1; then
            pass "Info.plist is valid (plutil -lint)"
        else
            fail "Info.plist does not lint"
        fi
        local slices
        slices="$(grep -c '<key>LibraryIdentifier</key>' "$XCF/Info.plist")"
        if [[ "$slices" -eq 2 ]]; then
            pass "Info.plist declares 2 library slices"
        else
            fail "Info.plist declares $slices slices (expected 2)"
        fi
    else
        fail "Info.plist missing"
    fi

    [[ -d "$headers" ]] || { fail "Headers/ missing in ios-arm64 slice"; return; }

    local mm="$headers/module.modulemap"
    if [[ -f "$mm" ]]; then
        grep -q 'module PJSIP'  "$mm" && pass "module map vends PJSIP"  || fail "module map: PJSIP module missing"
        grep -q 'module PJSUA2' "$mm" && pass "module map vends PJSUA2" || fail "module map: PJSUA2 module missing"
        grep -q 'umbrella header' "$mm" && pass "PJSIP uses an umbrella *header* (single-TU, include-order safe)" \
            || fail "module map: expected 'umbrella header' form"
        grep -q 'requires cplusplus' "$mm" && pass "PJSUA2 gated behind 'requires cplusplus'" \
            || warn "PJSUA2 not gated behind 'requires cplusplus'"
    else
        fail "module.modulemap missing"
    fi

    [[ -f "$headers/PJSIP-umbrella.h" ]]  && pass "PJSIP-umbrella.h present"  || fail "PJSIP-umbrella.h missing"
    [[ -f "$headers/PJSUA2-umbrella.h" ]] && pass "PJSUA2-umbrella.h present" || fail "PJSUA2-umbrella.h missing"

    # The macOS case-insensitivity trap: a generated header whose name
    # case-folds onto a vendored one (PJSIP.h vs pjsip.h) silently clobbers it.
    local dupes
    dupes="$( (cd "$headers" && find . -type f | tr '[:upper:]' '[:lower:]' | sort | uniq -d) )"
    if [[ -z "$dupes" ]]; then
        pass "no case-insensitive filename collisions in Headers/"
    else
        fail "case-insensitive filename collisions: $dupes"
    fi

    # config_site.h — the ABI contract. Verify the promised constants.
    local cs="$headers/pj/config_site.h"
    if [[ -f "$cs" ]]; then
        grep -Eq 'define[[:space:]]+PJ_SSL_SOCK_IMP[[:space:]]+PJ_SSL_SOCK_IMP_APPLE' "$cs" \
            && pass "config_site.h: PJ_SSL_SOCK_IMP_APPLE (native Darwin SSL)" \
            || fail "config_site.h: PJ_SSL_SOCK_IMP_APPLE not set"
        grep -Eq 'define[[:space:]]+PJMEDIA_HAS_VIDEO[[:space:]]+1' "$cs" \
            && pass "config_site.h: PJMEDIA_HAS_VIDEO 1" \
            || fail "config_site.h: PJMEDIA_HAS_VIDEO not 1"
        grep -Eq 'define[[:space:]]+PJMEDIA_HAS_BCG729[[:space:]]+1' "$cs" \
            && pass "config_site.h: PJMEDIA_HAS_BCG729 1" \
            || fail "config_site.h: PJMEDIA_HAS_BCG729 not 1"
        grep -Eq 'define[[:space:]]+PJSIP_HAS_TLS_TRANSPORT[[:space:]]+1' "$cs" \
            && pass "config_site.h: PJSIP_HAS_TLS_TRANSPORT 1" \
            || fail "config_site.h: PJSIP_HAS_TLS_TRANSPORT not 1"
        if grep -Eq 'define[[:space:]]+PJSIP_MAX_PKT_LEN' "$cs"; then
            pass "config_site.h: PJSIP_MAX_PKT_LEN = $(grep -E 'define[[:space:]]+PJSIP_MAX_PKT_LEN' "$cs" | awk '{print $3}')"
        else
            warn "config_site.h: PJSIP_MAX_PKT_LEN not overridden (default ~4000)"
        fi
    else
        fail "pj/config_site.h missing from Headers (ABI contract undocumented)"
    fi
}

# ---------------------------------------------------------------------------
# Code signature (Xcode 15+ records the identity on first use and fails the build
# if a later copy is unsigned / altered / signed by someone else). Unsigned is a
# warning, not a failure: it is allowed, but consumers see a notice and SDKs on
# Apple's required-reason list must be signed.
# ---------------------------------------------------------------------------

verify_signature() {
    section "── Code signature"
    if codesign -dv "$XCF" 2>/dev/null; then
        codesign -dvvv "$XCF" 2>&1 \
            | grep -E 'Authority|TeamIdentifier|Timestamp' \
            | sed 's/^/        /' || true
        if codesign --verify --verbose=2 "$XCF" >/dev/null 2>&1; then
            pass "code signature verifies"
        else
            fail "code signature present but does NOT verify"
        fi
    else
        warn "unsigned — Xcode 15+ warns consumers; sign with: codesign --timestamp -s <identity> $XCF"
    fi
}

# ---------------------------------------------------------------------------
# Optional: typecheck the modules like a SwiftPM consumer would
# ---------------------------------------------------------------------------

verify_typecheck() {
    section "── Swift typecheck (consumer simulation)"
    local headers="$XCF/ios-arm64-simulator/Headers"
    local target="arm64-apple-ios${EXPECT_MIN_IOS}-simulator"

    printf 'import PJSIP\nfunc _verify() -> pj_status_t { return pjsua_create() }\n' > "$TMP/c.swift"
    if xcrun --sdk iphonesimulator swiftc -target "$target" -I "$headers" -typecheck "$TMP/c.swift" 2> "$TMP/c.err"; then
        pass "import PJSIP + pjsua_create() typechecks"
    else
        fail "import PJSIP failed to typecheck: $(head -3 "$TMP/c.err" | tr '\n' ' ')"
    fi

    printf 'import PJSUA2\n' > "$TMP/cpp.swift"
    if xcrun --sdk iphonesimulator swiftc -target "$target" -cxx-interoperability-mode=default \
        -I "$headers" -typecheck "$TMP/cpp.swift" 2> "$TMP/cpp.err"; then
        pass "import PJSUA2 typechecks (C++ interop)"
    else
        fail "import PJSUA2 failed to typecheck: $(head -3 "$TMP/cpp.err" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------

[[ $QUIET -eq 1 ]] || echo "Verifying: $XCF (expected min iOS: $EXPECT_MIN_IOS)"

verify_slice "ios-arm64" "IOS"
verify_slice "ios-arm64-simulator" "IOSSIMULATOR"
verify_headers
verify_signature
if [[ $TYPECHECK -eq 1 ]]; then
    verify_typecheck
fi

echo
if [[ $FAIL -eq 0 ]]; then
    printf "${GREEN}VERIFIED${NC}: %d checks passed" "$PASS"
    [[ $WARN -gt 0 ]] && printf ", ${YELLOW}%d warnings${NC}" "$WARN"
    printf "\n"
    exit 0
else
    printf "${RED}VERIFICATION FAILED${NC}: %d failed, %d passed, %d warnings\n" "$FAIL" "$PASS" "$WARN"
    exit 1
fi
