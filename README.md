# swift-pjsip

[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flaconicman%2Fswift-pjsip%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/laconicman/swift-pjsip)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flaconicman%2Fswift-pjsip%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/laconicman/swift-pjsip)
[![Latest tag](https://img.shields.io/github/v/tag/laconicman/swift-pjsip?label=release&sort=semver)](https://github.com/laconicman/swift-pjsip/tags)
[![License](https://img.shields.io/badge/license-MIT%20(package)%20·%20GPL%20(binary)-blue)](#licensing)

**[PJSIP](https://www.pjsip.org) for iOS as a single Swift Package.** Add one URL in
Xcode, `import PJSIP`, and you have a full SIP/VoIP stack with video
(Metal/VideoToolbox), native Darwin TLS, G.729, and SRTP — no bridging header, no
manual library juggling, no build-from-source ritual.

```swift
dependencies: [
    .package(url: "https://github.com/laconicman/swift-pjsip", from: "0.1.0")
]
```

## Why this exists

PJSIP is the de-facto open-source SIP stack, but consuming it from a Swift app is
famously painful:

- The [official iOS instructions](https://docs.pjsip.org/en/latest/get-started/ios/build_instructions.html)
  have you run an autoconf build yourself, embed **~20 separate static libraries**,
  and expose the C API through a **bridging header**. There is no official SPM,
  CocoaPods, or binary artifact.
- Swift Package Manager cannot replace that build: PJSIP's configure step generates
  per-platform headers and bakes compile-time options (`config_site.h`) into the
  binary, which a SwiftPM C-source target cannot reproduce. Building from C/C++
  sources inside SPM is explicitly *not* the supported path — so this package ships
  a **prebuilt** `xcframework` instead.
- Existing alternatives are either stale CocoaPods wrappers, Homebrew-built
  frameworks that need extra tooling on every developer machine, or commercial VoIP
  SDKs that hide PJSIP behind their own API.

`swift-pjsip` packages the *official* PJSIP build output — built by the
[reproducible scripts in this repo](#rebuilding-the-binary) — as **one** combined
binary `xcframework` with a proper Clang module map, so it behaves like any other
Swift package. Modules instead of a bridging header. One artifact instead of twenty.

## What's inside

- **One static library per platform slice** — `libpjproject.a` — containing every
  PJSIP sublibrary (`pjlib`, `pjlib-util`, `pjnath`, `pjmedia*`, `pjsip*`, `pjsua`,
  `pjsua2`), all bundled third-party deps (`srtp`, `yuv`, `webrtc`, `ilbc`, `g7221`,
  `resample`), **and** `bcg729` (G.729). Unused objects are dead-stripped when your
  app links, so "everything included" does not mean "everything shipped".
- **Slices:** `ios-arm64` (device) and `ios-arm64-simulator`.
- **A unified `Headers/` tree** with a single `module.modulemap` exposing two modules.
- **Capabilities baked in:** video (iOS camera backend + VideoToolbox hardware codec),
  TLS via native Darwin SSL (Security/Network frameworks — no OpenSSL), G.729 (bcg729),
  SRTP, UDP/TCP/TLS transports. GSM and Speex are compiled out.
- **[`Binaries/RELEASE-NOTES.md`](Binaries/RELEASE-NOTES.md)** documenting what the
  committed binary was built from and with.

## Modules

| Module    | API                                 | Language | Consumer requirement                        |
|-----------|-------------------------------------|----------|---------------------------------------------|
| `PJSIP`   | pjsua1 + pjsip/pjmedia/pjnath/pjlib | C        | none — plain `import PJSIP`                 |
| `PJSUA2`  | PJSUA2 high-level API               | C++      | C++ interop (`.interoperabilityMode(.Cxx)`) |

`PJSUA2` transitively imports `PJSIP`, so the full C API is reachable from C++
contexts too.

## Installation

In Xcode: **File → Add Package Dependencies…**, paste the repo URL, and add the
`PJSIP` product to your app target:

```
https://github.com/laconicman/swift-pjsip
```

Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/laconicman/swift-pjsip", from: "0.1.0")
]
```

For the **C API**:

```swift
import PJSIP

var status = pjsua_create()
```

For the **PJSUA2 C++ API**, enable C++ interop on the consuming target:

```swift
// Package.swift of the consumer
.target(
    name: "MySipFeature",
    dependencies: [.product(name: "PJSIP", package: "swift-pjsip")],
    swiftSettings: [.interoperabilityMode(.Cxx)]
)
```

```swift
import PJSUA2   // namespace `pj` (e.g. pj.Endpoint)
```

In an Xcode app target (not an SPM manifest), set **Build Settings → C++ and
Objective-C Interoperability → C++ / Objective-C++** instead.

### Swift helpers

[`swift-pjsip-gen`](https://github.com/laconicman/swift-pjsip-gen) is a companion
package whose SwiftPM plugins parse this package's headers and generate Swift
conveniences (e.g. `CustomStringConvertible` conformances) for the imported C types.

## Required system frameworks / libraries

This is a **static** library, so your **app target** must link the frameworks PJSIP
depends on (a SwiftPM binary target cannot carry `linkerSettings`, so the package
cannot force-link them):

- `AVFoundation`, `AudioToolbox`, `CoreAudio`, `CoreVideo`, `VideoToolbox` — audio/video
- `MetalKit` — video rendering
- `Network`, `Security` — transport and Darwin SSL (this build uses `--enable-darwin-ssl`)
- `Foundation`
- **C++ standard library (`libc++`)** — required by PJSUA2 (built with `gnu++14` / `libc++`)

VoIP apps typically also add `CallKit` and `PushKit`, but those are app features, not
PJSIP requirements. If the linker reports a missing symbol, add the framework it
points to.

## ABI / configuration note — do **not** override `config_site.h`

The binary is compiled against a **specific** `pj/config_site.h` (video +
VideoToolbox, BCG729, `PJSIP_MAX_PKT_LEN=16000`, Apple SSL, …). Those constants fix
struct layouts and buffer sizes — i.e. the **ABI**. The exact `config_site.h` ships
inside the xcframework's `Headers/`. Overriding it in a consumer has **no effect on
the prebuilt binary** and would desync struct layouts at runtime, so leave it as-is.
If you need different compile-time options, [rebuild](#rebuilding-the-binary) with
your own `config_site.h` instead.

`PJ_AUTOCONF=1` is baked into the umbrella headers so the public headers pull the
autoconf headers (`os_auto.h` / `m_auto.h`) generated at build time and stay matched
to the binary.

## Rebuilding the binary

The canonical build scripts live in [`scripts/`](scripts/) and follow the official
PJSIP guidance ([iOS build instructions](https://docs.pjsip.org/en/latest/get-started/ios/build_instructions.html),
[PJSUA2 building](https://docs.pjsip.org/en/latest/pjsua2/building.html)). On a Mac
with Xcode and CMake (`brew install cmake`):

```bash
./scripts/build.sh all        # interactive: pick PJSIP/bcg729 source (release, tag, branch, archive)
./scripts/build.sh -y all     # non-interactive: latest releases, no prompts
./scripts/build.sh install    # copy the result + RELEASE-NOTES.md into Binaries/
```

Pin sources or customize without prompts:

```bash
./scripts/build.sh --pjsip-source tag=2.16 --bcg729-source tag=1.1.1 all
./scripts/build.sh --pjsip-source archive=~/Downloads/pjproject-patched.zip \
                   --config-site my/config_site.h --min-ios 16.0 all
```

The pipeline is phase-based (`download → deps → device → simulator → combine →
verify → notes`), each phase re-runnable in isolation. Toolchain locations (Xcode,
SDKs, simulator platform) are detected via `xcode-select`/`xcrun` — nothing is
hardcoded. See `./scripts/build.sh --help`.

### Trust, but verify

Every build is checked against the parameters it was *supposed* to be built with —
by inspecting the binary, not the logs:

```bash
./scripts/verify-xcframework.sh Binaries/PJSIP.xcframework              # the committed binary
./scripts/verify-xcframework.sh --typecheck .build-pjsip/output/PJSIP.xcframework
```

This proves: arm64 slices with correct device/simulator platform tags and minimum
iOS; native Darwin SSL (Security/Network symbols present, OpenSSL absent); TLS
transport; video + VideoToolbox; bcg729 G.729; SRTP; GSM/Speex absent; sane module
map and headers. `--typecheck` additionally compiles `import PJSIP` / `import PJSUA2`
against the artifact the way SwiftPM would.

`./scripts/build.sh notes` generates `RELEASE-NOTES.md` for the build — sources and
commits, configure flags, the full `config_site.h`, Xcode/SDK/clang/CMake versions,
artifact checksums, and the verification result.

## Architecture & design decisions

The non-obvious choices (one combined xcframework instead of twenty; umbrella
*header* instead of umbrella directory; committed binary instead of Git LFS; two
modules from one binary target; …) are documented in:

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the pieces fit together and why
- [`docs/SPM-XCFRAMEWORK-EXPERIENCE.md`](docs/SPM-XCFRAMEWORK-EXPERIENCE.md) — field
  notes from building and distributing a combined C/C++ static library via SwiftPM,
  including the failure modes (Git LFS pointer files, case-insensitive header
  collisions, include-order traps)

## Licensing

Three layers, three licenses — please read this before shipping:

- **This package** (manifest, scripts, docs): [MIT](LICENSE).
- **PJSIP** (the compiled binary): [GPL v2 or later](https://www.pjsip.org/licensing.htm),
  with commercial licensing available from Teluu.
- **bcg729** (G.729 codec, folded into the binary):
  [GPL v3](https://github.com/BelledonneCommunications/bcg729), with commercial
  licensing available from Belledonne Communications.

Shipping the combined binary in a closed-source app requires either GPL compliance
(effectively GPLv3 for the combination) or commercial licenses from the respective
vendors. G.729 patents have expired worldwide, but codec licensing ≠ patent licensing —
verify your obligations for your jurisdiction and distribution model.
