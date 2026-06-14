# Architecture — PJSIP for Swift, end to end

This document explains how the pieces of the `swift-pjsip` ecosystem fit together
and *why* each non-obvious decision was made. For the war-story-level detail behind
the packaging decisions, see
[SPM-XCFRAMEWORK-EXPERIENCE.md](SPM-XCFRAMEWORK-EXPERIENCE.md).

## The pieces

```
pjsip/pjproject ────────┐
(GitHub, release/tag/   │   scripts/build.sh                this repo (swift-pjsip)
 branch/local archive)  │   download → deps →               ┌──────────────────────────┐
                        ├─► device + simulator →            │ Package.swift            │
BelledonneComm/bcg729 ──┘   combine → verify → notes        │   .binaryTarget(PJSIP)   │
(GitHub or archive)                  │                      │ Binaries/                │
                                     ▼                      │   PJSIP.xcframework      │
                            PJSIP.xcframework  ──install──► │   RELEASE-NOTES.md       │
                            + RELEASE-NOTES.md              └────────────┬─────────────┘
                                                                         │ SPM dependency
                                                                         ▼
                  swift-pjsip-gen                              your app target
                  ┌────────────────────────────┐               ┌─────────────────────┐
                  │ build-tool + command       │  generated    │ import PJSIP        │
                  │ plugins parse the          ├─ Swift ─────► │ import PJSUA2       │
                  │ xcframework's Headers/     │  helpers      │ (+ C++ interop)     │
                  └────────────────────────────┘               └─────────────────────┘
```

| Repo | Role |
|------|------|
| [`swift-pjsip`](https://github.com/laconicman/swift-pjsip) (this one) | Ships the prebuilt `PJSIP.xcframework` as an SPM binary target **and** the scripts that reproduce it. |
| [`swift-pjsip-gen`](https://github.com/laconicman/swift-pjsip-gen) | SwiftPM plugins that parse the headers shipped here and generate Swift conveniences for the imported C types. |
| [`buildPJwVideoPatch`](https://github.com/laconicman/buildPJwVideoPatch) | Origin of the build scripts; now an archive. The canonical, maintained scripts live in [`scripts/`](../scripts/). |

## Design decisions

### 1. Prebuilt binary, not a SwiftPM C-source build

The tempting "pure SPM" route — declaring PJSIP's C/C++ sources as SwiftPM targets —
does not survive contact with reality:

- PJSIP's build runs **autoconf** (`configure-iphone`) which *generates* headers
  (`os_auto.h`, `m_auto.h`) per platform. SwiftPM has no configure step.
- Compile-time options in `config_site.h` change **struct layouts and buffer sizes**.
  A source build would make every consumer's flags part of the ABI — chaos.
- The official docs only support the autoconf path; a hand-maintained SPM target
  list (~20 interdependent libraries plus third-party code) would drift from
  upstream on every release.

So: build PJSIP exactly the official way, then package the *output*.

### 2. One combined xcframework, not ~20

PJSIP produces ~20 static libs whose **public headers cross-include each other**
via angle brackets (`<pj/types.h>`, `<pjsua-lib/pjsua.h>`), so they need one shared
include path. Independently, SwiftPM copies every binary target's `Headers/` into
one include directory and **fails on the second `module.modulemap`** it sees.
Both constraints point at the same answer: merge all static libs into one
`libpjproject.a` per slice (`libtool -static`), union the headers, write **one**
module map.

### 3. Two modules from one binary target

The module map vends `PJSIP` (C) and `PJSUA2` (C++, `requires cplusplus`). The
importable module names come from the **module map**, not the target name — one
`.binaryTarget` is enough for both. `PJSUA2`'s umbrella includes
`<pjsua-lib/pjsua.h>`, so the C API stays reachable from C++ contexts without
duplicate-symbol problems.

### 4. `umbrella header`, not `umbrella "directory"`

PJSIP officially supports a *bridging header*, i.e. one textual translation unit
with a controlled include order. A directory umbrella compiles each header
independently and breaks on PJSIP's include-order assumptions. The single-file
`umbrella header` form reproduces the bridging-header semantics inside a module —
this is the one trick that makes PJSIP importable as a module at all.

Generated umbrella files are suffixed (`PJSIP-umbrella.h`) because macOS
filesystems are case-insensitive: a generated `PJSIP.h` would silently overwrite
PJSIP's own `pjsip.h`.

### 5. `config_site.h` ships inside the artifact — and is the ABI

The binary is compiled against one specific `config_site.h`. Its constants
(`PJSIP_MAX_PKT_LEN`, video toggles, …) fix struct layouts; overriding it
downstream cannot change the compiled code and would desync layouts at runtime.
The exact file therefore travels inside `Headers/pj/`, the umbrella headers pin
`PJ_AUTOCONF=1` so the autoconf headers match the binary, and the README forbids
overrides. Need different options? Rebuild — that's what `scripts/` is for.

### 6. Committed binary, never Git LFS

SwiftPM's resolver does a plain git clone and **does not run the Git LFS smudge
filter** — LFS-backed consumers receive ~130-byte pointer files and a broken
xcframework. The `.a` files (~13 MB each) are committed as normal git blobs
(`.gitattributes: *.a binary`), comfortably under GitHub's limits. For
larger/more frequent releases, `scripts/build.sh dist` produces the zip +
checksum for the `.binaryTarget(url:checksum:)` release-asset alternative.

### 7. The build scripts live with the binary they produce

An auditable binary package needs its provenance next to it: the same repo carries
the scripts (`scripts/build.sh`), the inputs (`scripts/config_site.h`), the output
(`Binaries/PJSIP.xcframework`), a machine-generated build report
(`Binaries/RELEASE-NOTES.md`), and an independent checker
(`scripts/verify-xcframework.sh`) that proves the binary matches the promised
parameters by inspecting its symbol tables and load commands — not the build logs.

### 8. System frameworks: the deliberately pure binary target

PJSIP's static objects reference Apple frameworks (`AVFoundation`, `AudioToolbox`,
`CoreAudio`, `CoreVideo`, `VideoToolbox`, `MetalKit`, `Network`, `Security`,
`libc++`). Because linking happens when the **final executable** is produced, the
**app target** must link them — and a SwiftPM `binaryTarget` cannot carry
`linkerSettings`, so the package can't do it for the consumer. (Linking ≠ importing:
`import PJSIP` only exposes declarations; the linker resolves the framework references
baked into `libpjproject.a` once, at the app link, regardless of which module imported
PJSIP. A missing one is a build-time link error, not a runtime crash.)

The sanctioned way to automate it is the **wrapper-package pattern**: keep the binary
target and add a sibling **source** target — call it `PJSIPSupport` — to the *same*
product, carrying the frameworks via
`linkerSettings: [.linkedFramework("VideoToolbox"), …]`. SwiftPM propagates a linked
target's `linkerSettings` to whatever ultimately links the product, so the app picks
up `-framework VideoToolbox …` automatically. It is **purely additive**:

- it doesn't touch `import PJSIP` / `import PJSUA2` — those module names come from the
  binary's module map, not from any SPM target name;
- it removes nothing and forces nothing on the consumer's *source*;
- it's harmless to consumers who already link those frameworks — the linker dedups
  duplicate `-framework` flags and dead-strips unused code.

`PJSIPSupport` would be a one-file stub (it carries settings, not logic), and is also
where a `PrivacyInfo.xcprivacy` *could* ride if the package ever had to ship one. This
is how Firebase/RevenueCat/Stripe-style binary packages distribute.

We **deliberately keep the pure binary target** anyway: one transparent artifact, with
nothing between the consumer and the xcframework. The app links the frameworks (it does
so regardless), the README documents the list, and the wrapper stays a drop-in upgrade
if that trade-off ever changes.

### 9. Code generation as a separate package

Swift ergonomics for the imported C types (debug descriptions today; richer
wrappers tomorrow) are generated, not handwritten — the PJSIP API surface is huge
and changes per release. That generator lives in
[`swift-pjsip-gen`](https://github.com/laconicman/swift-pjsip-gen), modelled on
`apple/swift-openapi-generator`'s dual-plugin shape, and discovers this package's
headers automatically from the consumer's dependency graph. Its own design notes:
[swift-pjsip-gen/docs/DESIGN.md](https://github.com/laconicman/swift-pjsip-gen/blob/main/docs/DESIGN.md).

### 10. Unsigned, with signing and privacy left to the integrator

The committed artifact is **unsigned**. Xcode 15+ only *warns* on unsigned binary
dependencies (it records the identity on first use and flags later changes), and an
open-source artifact anyone can rebuild can't meaningfully share one signing identity —
so signing is the integrator's call (`codesign --timestamp -s <identity>`;
`scripts/verify-xcframework.sh` reports status). PJSIP isn't on Apple's
privacy-manifest SDK list, and a bare-`.a` xcframework can't bundle a
`PrivacyInfo.xcprivacy` regardless; since PJSIP touches required-reason APIs (system
boot time), the **consuming app** declares those in its own manifest (the README shows
an example). Shipping a manifest *inside* the package would need the static-framework
repackaging or the `PJSIPSupport` target from decision 8.

## Release flow

```bash
./scripts/build.sh all          # build (interactive source pick or -y for latest)
./scripts/build.sh install      # stage Binaries/PJSIP.xcframework + RELEASE-NOTES.md
git diff --stat                 # review
git commit && git tag X.Y.Z && git push origin main X.Y.Z
```

Tags are fully-qualified semantic versions (`0.2.0`, not `0.2`) — required by
SwiftPM ranges and the Swift Package Index. For the GitHub Release +
`.binaryTarget(url:checksum:)` route instead of committing the binary,
`./scripts/build.sh dist` emits the `ditto`-zipped artifact and its SwiftPM checksum;
mirror the released version into the xcframework's `Info.plist` so the artifact
identifies itself.
