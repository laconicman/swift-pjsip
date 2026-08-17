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

### 11. Per-slice by necessity — what Apple forces, and what pjproject forces

Two different constraints get conflated when a macOS slice comes up. Worth separating,
because only one of them is anyone's fault.

**Apple's constraint: a universal iOS+macOS static library cannot exist.** `lipo`
refuses two slices of the same architecture in one fat file, and
`arm64-apple-ios` / `arm64-apple-macos` are both `arm64` — they differ only in the
Mach-O `LC_BUILD_VERSION` platform field. That is precisely why `.xcframework` exists,
and it means decision 2 above (one combined xcframework) plus one slice per platform is
not a compromise we settled for; it is the only shape the tooling permits. Chasing a
single fat `.a` across iOS and macOS is chasing something that cannot be built.

**pjproject's constraint: iOS and macOS are configured by two different mechanisms.**
Verified against pjproject master `b8b988b02`:

- macOS uses plain `./configure`. Autoconf detects the host — our own builds report
  `TARGET_NAME := aarch64-apple-darwin25.5.0`, i.e. macOS **arm64** is a first-class,
  CI-tested configuration.
- iOS goes through `configure-iphone`, which invokes
  `./aconfigure --host=<arch>-apple-darwin_ios`. That triple is **fabricated** —
  `arm64-apple-darwin_ios` is not a real target triple; it exists only so `aconfigure.ac`
  can pattern-match on it, which it does in ~8 places. Clang has accepted real triples
  (`arm64-apple-ios15.0`, `-simulator`, `-macabi`) for years.

The consequence that actually bites: **the same feature is enabled two different ways.**
For the CoreAudio backend, macOS gets `-DPJMEDIA_AUDIO_DEV_HAS_COREAUDIO=1` emitted into
`os-auto.mak` because `aconfigure.ac`'s `*darwin*` branch sets `ac_pjmedia_snd=coreaudio`;
the `*-apple-darwin_ios*` branch deliberately does not, so `config_site_sample.h` has to
hand-`#define` the same macro under `PJ_CONFIG_IPHONE`. Anything upstream ships "for
Apple" via `PJ_CONFIG_IPHONE` therefore reaches **iOS only**, and a macOS slice silently
misses it.

**Rule for `scripts/config_site.h`:** set every feature macro we care about explicitly,
per slice. Do not inherit from upstream defaults and do not assume `PJ_CONFIG_IPHONE`
covers a Mac. Live example — the VPIO other-audio ducking we contributed upstream
([pjproject#5178](https://github.com/pjsip/pjproject/pull/5178), merged 2026-08-17) defaults
to `0` and is switched on by upstream only inside `PJ_CONFIG_IPHONE` — the maintainer confirmed
leaving macOS on the old behaviour is intentional; a macOS slice that wants it must
set `PJMEDIA_AUDIO_DEV_COREAUDIO_ADVANCED_DUCKING 1` itself. Because our `config_site.h`
travels inside the artifact and *is* the ABI (decision 5), that is the right place for it
anyway.

Other sharp edges in `configure-iphone`, for whoever next touches the build scripts: SDK
and toolchain are discovered by globbing `/Applications/XCode.app/…/iPhoneOS.platform`
with a fallback to the pre-2013 `/Developer/…` layout rather than via `xcrun`; the SDK is
chosen by `ls | sort | tail -1`, which is **lexicographic** (`iPhoneOS9.3` sorts after
`iPhoneOS10.0`); `RANLIB` is stubbed to `echo ranlib`; and each run configures exactly one
`-arch`, so multi-arch means multiple configure+make passes.

## Upstream floor — pjproject commits a release must carry

The binary is the only place these land, so the package's real "version" is *which upstream
commits the artifact was built from*. Any release cut from a source tree older than the commits
below reintroduces the corresponding defect in every consumer, silently.

| Since | Upstream | Why a release must not predate it |
|---|---|---|
| 2026-08 | [#5154](https://github.com/pjsip/pjproject/pull/5154) `77ad3feec` + [#5168](https://github.com/pjsip/pjproject/pull/5168) `716ef557d` | **439 (First Hop Lacks Outbound Support) handling.** `use_rfc5626` is on by default, so on TCP/TLS pjsua emits `;reg-id` + `Supported: outbound` — the exact RFC 5626 §6 439 trigger. Before these commits a 439 was unhandled and left the account **permanently unregistered**, with no retry and no fallback. Symptom in the field: registration fails forever with a status code most people have never seen |
| 2025-07 | [#5070](https://github.com/pjsip/pjproject/pull/5070) `54ebfdbec` | `pjsua_acc_add` used `PJ_ASSERT_RETURN` for a capacity condition, so **debug builds abort** where release returns `PJ_ETOOMANY` |
| 2025-08 | [#5076](https://github.com/pjsip/pjproject/pull/5076) | Oversized requests silently fall back to UDP and fragment when the RFC 3261 §18.1.1 TCP upgrade has no TCP transport to acquire — now at least logged |

Record the source commit in `RELEASE-NOTES.md` at build time; a tag alone does not say which
pjproject tree produced it. The running scan of what has changed upstream since the shipped binary,
and the bump checklist, live in `swift-pjsua/Upstream/reference-post-2.16-fixes-impact.md`.

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
