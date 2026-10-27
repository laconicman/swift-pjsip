# Versioning and release policy

`swift-pjsip` ships a **prebuilt binary**. That makes versioning less obvious than for a source
package, because the thing that changes most often — the PJSIP tree the artifact was built from —
is invisible to SwiftPM's resolver. This file fixes the policy and carries the history table.

> **Where things live.** `Binaries/RELEASE-NOTES.md` is **machine-generated** by
> `scripts/build.sh notes` and is overwritten by every build; it describes *one* artifact in full
> (sources, patches, config_site, toolchain, checksums). The table below is **curated** and
> describes *every* release. Do not hand-edit the generated file; do not automate this one.

## Policy

**The package version is independent semver. It does not mirror PJSIP's version.**

The temptation is to tag `2.17.0` and be done. Resist it, for two concrete reasons:

1. **SPM resolves on the package's own version.** If the tag *is* the PJSIP version, a
   packaging-only fix — a wrong module map, a missing framework in the link list, a bad
   `Info.plist` — has nowhere to go. `2.17.1` would claim a PJSIP patch release that does not
   exist, and `2.17.0+1` is not a thing SwiftPM ranges understand.
2. **It would collide with itself.** Two artifacts can share a PJSIP version and differ in
   `config_site.h`, which *is* the ABI. There would be no way to express that.

Upstream provenance goes in the **artifact name** and the **release notes** instead, where it can
be as specific as it needs to be without constraining the resolver.

### The bump rule

> **A changed binary is a version bump. Always. Even when no Swift source line changed.**

This is the rule the package needed and did not have: `0.1.2` sat here through five merged
upstream PRs of our own, because nothing *forced* a bump when only the binary moved. Concretely,
bump when any of these change:

| Change | Bump |
|---|---|
| `config_site-*.h` — any value | **minor** (it is the ABI) |
| PJSIP source commit | **minor** — even a "no user-visible change" upstream bump |
| Local patch set | **minor** |
| Added or removed slice | **minor** |
| Manifest, module map, docs, scripts — binary untouched | **patch** |
| Removing a product, or a floor raise consumers must react to | **major** (post-1.0) |

Pre-1.0 the leading `0.` absorbs what would otherwise be major bumps; that is the only reason the
distribution move below is a minor and not a major.

### Tags

Fully-qualified three-component tags (`0.2.0`, never `0.2`) — required by SwiftPM ranges and the
Swift Package Index.

### Artifact naming

Release assets are named `PJSIP.xcframework-<pjsip-version>-<short-sha>.zip`, e.g.
`PJSIP.xcframework-2.17.0-288de6142.zip`. The package version is already in the release tag; the
asset name carries the upstream identity, so a downloaded file is self-identifying and two
artifacts built from different upstream trees can never be confused for one another.

`scripts/build.sh dist` derives both halves from the build itself — the version from the built
headers' `PJ_VERSION_NUM_*`, the SHA from the recorded source metadata — so the name cannot drift
from the contents.

**The zip is not byte-reproducible.** `ditto -c -k` records timestamps, so re-zipping the same
xcframework yields a different SHA-256. Zip **once** per release, publish *that* file, and record
*that* checksum here — never recompute it from a fresh zip after the asset is uploaded, or the
manifest will reject the download.

Neither is the merged `libpjproject.a`, measured while cutting `0.2.1`: `xcrun libtool -static`
stamps fresh archive metadata, so re-running `combine` over untouched object files produces a
different `.a` SHA-256. What *is* reproducible is one level down — the archive **members**. To
prove a respin did not change the code, extract both archives and compare member checksums
(`0.2.1` vs the withdrawn `0.2.0`: 428/428 identical per slice), not the `.a` digest.

Two refinements, from cutting `0.3.1`. Compare members **by position**: the archive holds 586
members under 566 names (448 / 428 before `0.4.0`), and `ar -x` keeps one file per name, so
extraction silently skips 20.
And a respin that has lost its build tree can still be proven, by rebuilding from the same
sources with the same Xcode **under the same build-root path**: the objects embed that absolute
path in about 40 strings, and with it unchanged the rebuild reproduces every member byte for
byte.

### Checksums are published, not just computed

The SwiftPM checksum of the release asset goes **in the release notes**, so a downstream author can
pin `.binaryTarget(checksum:)` without downloading the asset first. `phase_notes` emits it, ready
to paste.

## Release history

One row per release. `Patches` lists what `scripts/patches/` applied at build time.

| Package | PJSIP | Upstream SHA | Patches | Artifact SHA-256 (SwiftPM checksum) | Notes |
|---|---|---|---|---|---|
| `0.5.0` | 2.17.0 (master, post-2.17) | [`1f0ebf2eb`](https://github.com/pjsip/pjproject/commit/1f0ebf2ebe43efdedc61bbef48df02a3f89dec1c) | none | `d82d4847bf6acdfdc31e972093660a5f35fac7e914ac3a27a40fb81a0792bec5` | **VP8+VP9 added** — libvpx `v1.17.0` (BSD-3-Clause + the libvpx `PATENTS` grant) built per slice with its own `./configure` + make and folded into `libpjproject.a`: 817 archive members vs 586, ~2.3 MB per slice, no vpx headers shipped. Device slice is `arm64-darwin-gcc` with `-miphoneos-version-min` overridden via `--extra-cflags`; the simulator has no arm64 libvpx target, so `arm64-darwin20-gcc` is retargeted with `-target arm64-apple-ios15.0-simulator` + an `LD` probe wrapper (see `build_vpx`). Same upstream tree as `0.4.0`, same bcg729 `1.1.2` / opus `v1.6.1`. `config_site-ios.h`: `PJMEDIA_HAS_VPX_CODEC`/`_VP8`/`_VP9` `1` (VP9 is an upstream-off default — this is the ABI-changing bit, hence MINOR). Docs corrected per [#20](https://github.com/laconicman/swift-pjsip/issues/20): G.722.1 and L16 were never shipped. |
| `0.4.0` | 2.17.0 (master, post-2.17) | [`1f0ebf2eb`](https://github.com/pjsip/pjproject/commit/1f0ebf2ebe43efdedc61bbef48df02a3f89dec1c) | none | `d0f35d4a5da1a3ab5e4201ed36925e02b94b7512c67718d253b29a6aa8d33e4e` | **Opus added** — libopus `v1.6.1` ([`22244de5a`](https://github.com/xiph/opus/commit/22244de5a79bd1d6d623c32e72bf1954b56235be), BSD-3-Clause + the Opus patent licence) built per slice with CMake and folded into `libpjproject.a`: 586 archive members vs 448, no opus headers shipped. [#8](https://github.com/laconicman/swift-pjsip/issues/8) asked for Opus as a one-change release; `0.4.0` deliberately pairs it with the master bump (maintainer's call, 2026-10-27). 36 upstream commits on `0.3.1`, among them `contact_rewritten` set before the rewrite's REGISTER is sent ([#5331](https://github.com/pjsip/pjproject/pull/5331), ours), the Darwin SSL backend defaulting to TLS 1.2 + 1.3 ([#5335](https://github.com/pjsip/pjproject/pull/5335)), a late ACK reading a destroyed dialog ([#5341](https://github.com/pjsip/pjproject/pull/5341)), a deleted `Call`/`Account` affecting a new one with its id ([#5340](https://github.com/pjsip/pjproject/pull/5340)), `contact_rewrite_method` normalised when the account is added ([#5342](https://github.com/pjsip/pjproject/pull/5342)), bounded `Event`/`Subscription-State`/`Replaces` header printers ([#5352](https://github.com/pjsip/pjproject/pull/5352)), a negative-sequence-number jitter-buffer fix ([#5358](https://github.com/pjsip/pjproject/pull/5358)), the stream decode buffer bounded by its allocated size ([#5361](https://github.com/pjsip/pjproject/pull/5361)), and several security advisories merged from forks. `config_site-ios.h`: `PJMEDIA_HAS_OPUS_CODEC 1` + line-reference refresh. bcg729 `1.1.2` |
| `0.3.1` | 2.17.0 (master, post-2.17) | [`bd69054a6`](https://github.com/pjsip/pjproject/commit/bd69054a696054db8fb4e62b759a3ecaf26c0189) | none | `89884473132571c75956d0cd2727c9bb0b9d09b2c614e09071599dbd0af14422` | Headers-only respin of `0.3.0`. `PJSIP-errno-swift.h` now exports every status code Swift's importer drops from the eight errno headers: 206 in all, `0.3.0`'s 78 `sip_errno.h` names plus 128 from pjlib-util, pjnath, the audio and video device headers, and pjsip-simple. All 341 codes the headers define are nameable from Swift, and `verify-xcframework.sh --typecheck` checks them independently of the export (ARCHITECTURE.md decision 4). Rebuilt from the same sources with the same Xcode 27.0 under `0.3.0`'s build path: all 448 archive members and the symbol table identical to `0.3.0` by position, per slice; headers differ only in `PJSIP-errno-swift.h`. bcg729 `1.1.2` |
| `0.3.0` | 2.17.0 (master, post-2.17) | [`bd69054a6`](https://github.com/pjsip/pjproject/commit/bd69054a696054db8fb4e62b759a3ecaf26c0189) | none | `3e7e3a5c5993ef4e5dd4e0d8ce28fa3b09872662fc942ddb6f351051bf090c5b` | 105 upstream commits on `0.2.1`, among them a configured `+sip.instance` sent without SIP outbound ([#5313](https://github.com/pjsip/pjproject/pull/5313)), the regc Contact update when outbound is unconfirmed (#5281), the Apple TLS series (#5222 whole-file read, #5230, #5233, #5234, #5282) and three security advisories that touch a SIP client. **First artifact with no local patch**: `iphone17-darwin-dev-stride` retired, upstream carries it as #5249. The module exports the `sip_errno.h` status codes to Swift (`PJSIP-errno-swift.h`, ARCHITECTURE.md decision 4). Conference bridge is now `conf_thread.c` (upstream's new default, #5297). `config_site-ios.h`: comments only. bcg729 `1.1.2` |
| `0.2.1` | 2.17.0 (master, post-2.17) | [`288de6142`](https://github.com/pjsip/pjproject/commit/288de6142044483944a60015c17afd32b6166bb6) | `iphone17-darwin-dev-stride` | `36f49d1abc62010184439e8d56a45c292307ed5321bff47a983cd1390c282dda` | **Replaces the withdrawn `0.2.0`.** Module map gains `textual header` for the two config headers — without it the clang module dropped `config_site.h`'s overrides and Swift imported the `PJ_CONFIG_IPHONE` preset's values instead of the binary's (ARCHITECTURE.md decision 4). Capacity block now hands `PJSUA_MAX_ACC` / `PJSUA_MAX_CONF_PORTS` back to upstream's defaults with a bare `#undef`. Headers-only respin: 428/428 archive members identical to `0.2.0` per slice |
| ~~`0.2.0`~~ **withdrawn** | 2.17.0 (master, post-2.17) | [`288de6142`](https://github.com/pjsip/pjproject/commit/288de6142044483944a60015c17afd32b6166bb6) | `iphone17-darwin-dev-stride` | `00214082e4b246bf224f6a2dd3ca8a064e755bb8205962194518377a7349526b` | **Deleted 2026-08-22** — shipped a module map that made every Swift consumer compile `PJSUA_MAX_ACC` 4 / `PJSUA_MAX_CALLS` 4 / `PJSUA_MAX_CONF_PORTS` 12 against a binary built with 8 / 8 / 254, and with them a `pjsua_conf_port_info` 968 bytes shorter than the library writes. Superseded by `0.2.1`; asset and tag removed so nothing can resolve it |
| `0.1.2` | 2.16.0 | *not recorded* | "iPhone 17 device patch" (unversioned; recovered 2026-08-19 as `historical/2.16-…`) | *not recorded* | Built by the older `buildPJwVideoPatch` scripts, not by `scripts/build.sh` |
| `0.1.1` | 2.16.0 | *not recorded* | as above | *not recorded* | |
| `0.1.0` | 2.16.0 | *not recorded* | as above | *not recorded* | Initial |

**The three "not recorded" rows are the reason this file exists.** Everything about the shipped
2.16 artifact beyond its PJSIP version had to be reconstructed by archaeology — diffing the source
archive that build consumed against a clean upstream export — because no build recorded it. From
`0.2.0` on, `scripts/build.sh notes` records sources, commit, patches, `config_site.h`, toolchain
and checksums automatically, and this table carries the same facts forward for comparison.

## Upstream floor

Independent of version *numbers*, a release must not be cut from a PJSIP tree older than the
commits listed in [ARCHITECTURE.md](./ARCHITECTURE.md#upstream-floor--pjproject-commits-a-release-must-carry).
That table is the reason `0.2.0` is built from master rather than the `2.17` tag: `2.17` predates
the 439 / RFC 5626 handling ([#5154](https://github.com/pjsip/pjproject/pull/5154),
[#5168](https://github.com/pjsip/pjproject/pull/5168)) and the CoreAudio ducking work
([#5178](https://github.com/pjsip/pjproject/pull/5178)), so shipping it would reintroduce a defect
that leaves an account permanently unregistered.

## See also

- [ARCHITECTURE.md](./ARCHITECTURE.md) — what is inside the artifact, and the distribution shape
- [Build-Time-Feature-Gates.md](./Build-Time-Feature-Gates.md) — what `config_site` decides for everyone
- [`scripts/patches/README.md`](../scripts/patches/README.md) — the patch set and its retirement criteria
