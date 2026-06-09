# swift-pjsip

A Swift Package that ships a single, self-contained **PJSIP** build for iOS as one
binary `xcframework`. It replaces the ~20 separate per-library `xcframework`s that a
manual PJSIP integration normally requires with **one** artifact you can `import`.

The build is produced by the `combine` phase of the companion build script
(`buildPJwVideoPatch/build.sh`) and follows the official PJSIP guidance:
- PJSUA2 building: <https://docs.pjsip.org/en/latest/pjsua2/building.html>
- iOS build / Swift usage: <https://docs.pjsip.org/en/latest/get-started/ios/build_instructions.html>

## What's inside

- **One static library per platform slice** — `libpjproject.a` — that already contains
  every PJSIP sublibrary (`pjlib`, `pjlib-util`, `pjnath`, `pjmedia*`, `pjsip*`, `pjsua`,
  `pjsua2`), all bundled third-party deps (`srtp`, `yuv`, `webrtc`, `ilbc`, `g7221`,
  `resample`), **and** `bcg729` (G.729). Unused objects are dead-stripped when your app links.
- **Slices:** `ios-arm64` (device) and `ios-arm64-simulator`.
- **A unified `Headers/` tree** with a single `module.modulemap` exposing two modules.

## Modules

| Module    | API                              | Language | Consumer requirement                         |
|-----------|----------------------------------|----------|----------------------------------------------|
| `PJSIP`   | pjsua1 + pjsip/pjmedia/pjnath/pjlib | C       | none — plain `import PJSIP`                   |
| `PJSUA2`  | PJSUA2 high-level API            | C++      | C++ interop (`.interoperabilityMode(.Cxx)`)  |

`PJSUA2` transitively imports `PJSIP`, so the full C API is reachable from C++ contexts too.

## Installation (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…**, paste the repo URL, and add the `PJSIP`
product to your app target:

```
https://github.com/laconicman/swift-pjsip
```

Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/laconicman/swift-pjsip", from: "0.1.0")
]
```

(In Xcode choose "Up to Next Major Version" from `0.1.0`, or track `branch: "main"` for the latest.)

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

In an Xcode app target (not SPM manifest), set **Build Settings → C++ and Objective-C
Interoperability → C++ / Objective-C++** instead.

## Required system frameworks / libraries

This is a **static** library, so your **app target** must link the frameworks PJSIP
depends on (the package cannot force-link them through a binary target). Based on the
working integration this build was extracted from:

- `AVFoundation`, `AudioToolbox`, `CoreAudio`, `CoreVideo`, `VideoToolbox` — audio/video
- `MetalKit` — video rendering
- `Network`, `Security` — transport and Darwin SSL (this build uses `--enable-darwin-ssl`)
- `Foundation`
- **C++ standard library (`libc++`)** — required by PJSUA2 (built with `gnu++14` / `libc++`)

VoIP apps typically also add `CallKit` and `PushKit`, but those are app features, not PJSIP
requirements. If the linker reports a missing symbol, add the framework it points to.

## ABI / configuration note — do **not** override `config_site.h`

The binary was compiled against a **specific** `pj/config_site.h` (video + VideoToolbox,
BCG729, `PJSIP_MAX_PKT_LEN=16000`, Apple SSL, …). Those constants fix struct layouts and
buffer sizes — i.e. the **ABI**. The exact `config_site.h` ships inside the xcframework's
`Headers/`. Overriding it in a consumer has **no effect on the prebuilt binary** and would
desync struct layouts at runtime, so leave it as-is.

`PJ_AUTOCONF=1` is baked into the umbrella headers so the public headers pull the autoconf
headers (`os_auto.h` / `m_auto.h`) generated at build time and stay matched to the binary.

## Regenerating the binary

From the build project (`buildPJwVideoPatch/`):

```bash
./build.sh all        # download → deps → device → simulator → package → combine
# or, if device/ and simulator/ are already built:
./build.sh combine
```

Then copy the result into this package:

```bash
cp -R buildPJwVideoPatch/output/PJSIP.xcframework swift-pjsip/Binaries/
```

The `PJSIP.xcframework` (including the `*.a` binaries) is **committed directly** to this repo
as normal Git files, so SwiftPM resolves it with no extra setup — peers just add the package
URL in Xcode. Git LFS is intentionally **not** used: SwiftPM's package resolution does not run
the LFS filter, so LFS-backed binaries would arrive as broken pointer files.
