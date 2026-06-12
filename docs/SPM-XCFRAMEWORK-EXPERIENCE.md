# Distributing a Combined C/C++ Static Library as a Swift Package — Field Notes

Experience report from building **one** combined `PJSIP.xcframework` (from ~20 PJSIP
static libs) and publishing it as a SwiftPM binary package. Pedantic on purpose: every
branching choice, gotcha, and verification is recorded, so the lessons can transfer to
any prebuilt C/C++ static library shipped via SPM.

> Concrete case: PJSIP/PJSUA + PJSUA2 for iOS (arm64 device + arm64 simulator), with video
> (Metal/VideoToolbox), Darwin TLS, and BCG729. The build automation described here is
> implemented in [`scripts/build.sh`](../scripts/build.sh).

---

## 0. TL;DR decision tree

1. **Multiple interdependent static libs?** → fold into **one** `.a` per slice (`libtool -static`).
   SPM wants exactly one module map per binary target; interdependent public headers want one include path.
2. **Need Swift `import`?** → ship a **module map + umbrella header** inside the xcframework.
   Use `umbrella header "X.h"` (single textual TU, preserves include order), **not** `umbrella "directory"`.
3. **Distribution method (the big fork):**
   - **Git LFS → ✗ DOES NOT WORK with SPM.** Consumers get pointer files. Avoid.
   - **Commit binary directly** → ✓ works (full clone), simplest, repo carries the binary.
   - **GitHub Release + `.binaryTarget(url:checksum:)`** → ✓ works, tiny repo, the "proper" way.
4. **Verify without an app:** `swiftc -typecheck -I Headers` (+ `-cxx-interoperability-mode=default` for C++).

---

## 1. Building the combined xcframework

### 1.1 Fold all static libs into one `.a` per slice
PJSIP ships as ~20 `.a` files (`libpj-*`, `libpjsip-*`, `libpjmedia-*`, `libpjnath-*`,
`libpjsua-*`, `libpjsua2-*`) plus third-party (`srtp`, `yuv`, `webrtc`, `ilbc`, `g7221`,
`resample`) and an externally-built `bcg729`. We merged them per platform with:

```bash
libtool -static -o libpjproject.a <all .a files...> 2> libpjproject.a.libtool.log
```

Nuances:
- **`libtool` is the macOS-supported archive combiner.** `libtool` emits benign
  *"same member name"* warnings (multiple `.o` with identical basenames) — harmless, the linker
  resolves by symbol. Keep them in a log, don't fail on them.
- **Self-contained on purpose:** folding third-party + bcg729 in means consumers link one lib;
  the app-link dead-strips unused objects, so binary size isn't a real concern.
- Collect inputs robustly: `find ... -name '*.a' -print0` + null-delimited read (paths/spaces safe).

### 1.2 Union the public headers (one include path)
PJSIP's public headers cross-include via angle brackets (`<pj/types.h>`, `<pjsua-lib/pjsua.h>`),
so they MUST share one include root. The per-module namespaces are disjoint directories
(`pj/`, `pjlib-util/`, `pjmedia*/`, `pjnath/`, `pjsip*/`, `pjsua-lib/`, `pjsua2/`, `bcg729/`),
so a flat `cp -R` of each `include/` into one `Headers/` never clashes.

> This step also carries the **build-time `pj/config_site.h`** into the artifact. That file's
> constants (e.g. `PJSIP_MAX_PKT_LEN`, video on/off) fix struct layouts == **ABI**. Document
> loudly: consumers must **not** override `config_site.h` — it can't change the prebuilt binary
> and would desync struct layouts → crashes.

### 1.3 Module map + umbrella headers (the crux)
Final artifact `Headers/module.modulemap`:

```modulemap
module PJSIP [system] {
    umbrella header "PJSIP-umbrella.h"
    export *
}

module PJSUA2 [system] {
    requires cplusplus
    header "PJSUA2-umbrella.h"
    export *
}
```

`PJSIP-umbrella.h`:
```c
#define PJ_AUTOCONF 1
#include <pjsua.h>
```
`PJSUA2-umbrella.h`:
```c
#define PJ_AUTOCONF 1
#include <pjsua2.hpp>
```

Why each detail matters:
- **`umbrella header "file.h"` not `umbrella "directory"`.** A *header* umbrella compiles that
  one file as a **single textual translation unit**, preserving PJSIP's required include order.
  A *directory* umbrella compiles each header independently and hits include-ordering errors.
  This is the single most important modular-C insight: it makes a module out of a library that
  officially only supports a **bridging header**.
- **`[system]`** marks the module as a system module: silences the library's many C warnings and
  relaxes modular-include strictness (treats headers leniently). Almost always wanted for vendored C.
- **`requires cplusplus`** keeps `PJSUA2` out of pure-C/ObjC compilations; it only surfaces when
  the consumer compiles as C++ (i.e. C++ interop on).
- **Two modules, one binary target.** The C++ umbrella includes `<pjsua-lib/pjsua.h>` transitively,
  so `PJSUA2` re-exposes the C API; importing both does not double-define symbols.
- **`#define PJ_AUTOCONF 1`** must precede the include so `pj/config.h` pulls the autoconf headers
  (`pj/compat/os_auto.h`, `m_auto.h`) generated at build time → headers match the binary.

### 1.4 Assemble (static-library xcframework form)
```bash
xcodebuild -create-xcframework \
  -library combine/ios-arm64/libpjproject.a            -headers combine/Headers \
  -library combine/ios-arm64-simulator/libpjproject.a  -headers combine/Headers \
  -output  output/PJSIP.xcframework
```
Static libs use `-library <.a> -headers <dir>` (one pair per slice), **not** `-framework`.
Device and simulator slices share the **same** `Headers/` (identical module map/headers; only the
`.a` differs).

---

## 2. ⚠️ THE BUG: case-insensitive header collision (macOS)
My first umbrella was named `PJSIP.h`. macOS APFS is **case-insensitive**, so copying it into
`Headers/` **silently overwrote PJSIP's own `pjsip.h`** — the real core umbrella that pulls in
`sip_multipart.h`, TLS transport, etc. Result: compiles failed with missing types far from the
real cause.

**Fix:** never name generated umbrellas anything that case-folds onto a vendored header. Use a
distinct suffix: `PJSIP-umbrella.h`, `PJSUA2-umbrella.h`.

**Rule:** when generating umbrella/module files into a vendored header tree, check for
case-insensitive name collisions against existing files first.
(`scripts/verify-xcframework.sh` now checks this automatically.)

---

## 3. Verifying WITHOUT building an app
Compile-checking against the xcframework's `Headers/` mirrors exactly what SPM passes the compiler:

```bash
H=output/PJSIP.xcframework/ios-arm64-simulator/Headers

# C module
echo 'import PJSIP
func demo() -> pj_status_t { return pjsua_create() }' > /tmp/c.swift
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios15.0-simulator -I "$H" -typecheck /tmp/c.swift   # exit 0

# C++ module (needs interop flag)
echo 'import PJSUA2' > /tmp/cpp.swift
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios15.0-simulator \
  -cxx-interoperability-mode=default -I "$H" -typecheck /tmp/cpp.swift                                     # exit 0

# textual (bridging-header equivalent) sanity
printf '#define PJ_AUTOCONF 1\n#include <pjsua.h>\nint main(){return 0;}\n' > /tmp/t.m
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -I "$H" -fsyntax-only /tmp/t.m
```
Other checks: `lipo -info` / `file` (arch + platform tag), `nm` (symbol presence:
`pjsua_create`, pjsua2 `libCreate`, bcg729), and `swift package describe` (manifest valid).
All of these are bundled into `scripts/verify-xcframework.sh` (`--typecheck` for the swiftc ones).

Pitfall: don't trust `grep "error:"` + `PIPESTATUS` inside a subshell — capture the compiler's
own exit code explicitly.

---

## 4. Package layout
```
swift-pjsip/
  Package.swift
  Binaries/PJSIP.xcframework/
  Binaries/RELEASE-NOTES.md      # what the committed binary was built from/with
  scripts/                       # reproducible build + verification
  docs/
  README.md
  LICENSE
  .gitignore
  .gitattributes
```
```swift
// swift-tools-version: 5.9
let package = Package(
  name: "PJSIP",
  platforms: [.iOS(.v15)],
  products: [.library(name: "PJSIP", targets: ["PJSIP"])],
  targets: [.binaryTarget(name: "PJSIP", path: "Binaries/PJSIP.xcframework")]
)
```
Notes:
- One `binaryTarget` named `PJSIP` **vends both** modules (`PJSIP`, `PJSUA2`) — the importable
  module names come from the **module map**, not the target name.
- **`binaryTarget` cannot carry `linkerSettings`/`swiftSettings`.** So required system frameworks
  can't be force-linked by the package; document them (app target links them) or add a tiny shim
  `.target` that depends on the binary and holds `linkerSettings` (we documented instead).
- **C++ interop is the *consumer's* setting**, not the package's: `swiftSettings:
  [.interoperabilityMode(.Cxx)]` (SwiftPM) or Xcode Build Setting *C++/Objective-C++*.
- For PJSIP specifically, app must link: `AVFoundation, AudioToolbox, CoreAudio, CoreVideo,
  VideoToolbox, MetalKit, Network, Security, libc++`. (Derive the real list from a working
  integration's project file, not from guessing.)

---

## 5. ⚠️ THE BIG FORK: how to distribute the binary

### 5.1 Git LFS — DOES NOT WORK with SwiftPM (confirmed)
We initially chose LFS and set it up — then discovered SwiftPM's resolver **does not run the LFS
smudge filter**. Consumers receive the ~130-byte **pointer text files** instead of the `.a`, and
the build dies with `xcbutil.BinaryReaderError` / invalid xcframework.
- Apple Dev Forums: *"Xcode will then download the pointer to the lfs file, not the actual file."*
- SwiftPM issue **#8233**; multiple SO threads.
- Works only if a consumer drags the package in as a **local** path with `git-lfs` installed —
  not as a normal remote URL dependency. Unacceptable for "peers paste a URL."

**Rule:** never use Git LFS for SPM-consumed binaries.

### 5.2 Commit binary directly (what we shipped)
SPM does a **full git clone**, so a normally-committed binary arrives intact. Simplest path.
- Size reality: GitHub warns >50 MB, hard-blocks >100 MB per file. Our `.a` is ~13 MB each;
  the 26 MB of binaries compress to ~11 MB in `.git`. Fine.
- `.gitattributes`: mark `*.a binary` (skip text munging). Do **not** use `filter=lfs`.

### 5.3 GitHub Release + checksum (the scalable alternative)
`.binaryTarget(name:url:checksum:)` pointing at a zipped xcframework attached to a Release.
Xcode downloads over HTTPS — no git, no LFS, tiny repo.
- `swift package compute-checksum PJSIP.xcframework.zip` — the checksum must match the **exact**
  uploaded bytes; the release-asset URL is deterministic
  (`.../releases/download/<tag>/<asset>`), so you can set it before uploading.
- Needs a release-upload step (`gh release create` or web UI).
  `scripts/build.sh dist` produces the zip, the checksum, and the manifest snippet.

**Recommendation:** default to **5.3** for versioned/public distribution; **5.2** for
quick internal test-sharing; **never 5.1**.

---

## 6. Converting an LFS repo back to direct-commit
Because the working tree holds the **real** files (LFS smudges on checkout), the cleanest reset
for a fresh, unpushed repo was:
```bash
git lfs uninstall --local
# edit .gitattributes: replace "*.a filter=lfs diff=lfs merge=lfs -text" with "*.a binary"
rm -rf .git && git init && git add . && git commit -m "..."
```
Verify the blob is real, not a pointer:
```bash
git cat-file -s $(git rev-parse HEAD:Binaries/.../libpjproject.a)   # ~13,000,000 bytes, not ~130
git show HEAD:Binaries/.../libpjproject.a | head -c 8 | xxd          # 213c 6172 6368 3e0a == "!<arch>"
git lfs ls-files                                                      # empty
```

---

## 7. Publishing gotchas
- **GitHub MCP could not create the repo** → `403 Resource not accessible by integration`. The
  app backing the MCP lacked repo-creation scope. Fallback: user creates the **empty** repo via
  `github.com/new` (no README/.gitignore/license, so the first push isn't rejected), then push.
- **`gh` CLI not installed**; **SSH key present** → used SSH remote
  `git@github.com:owner/repo.git`.
- **MCP `push_files` is unsuitable for large binaries** (Contents API base64 of 13 MB); use real
  `git push` for binary repos. MCP is fine for *reading*/verifying after push and for text files.
- Tag a version (`git tag 0.1.0 && git push origin 0.1.0`) so consumers can pin
  `from: "0.1.0"`; SPM accepts `0.1.0` or `v0.1.0`.
- Verify post-push via MCP `get_file_contents`: a large file returns metadata
  (*"too large to display (13114472 bytes)"* + raw URL) — that byte count is the proof the real
  binary (not a pointer) is on GitHub.

### zsh footgun
A multi-line `-m "...(C++ ...)..."` commit message triggered `zsh: unknown file attribute: C`
(zsh read `(C` as a glob qualifier). **Avoid parentheses/glob-special chars in shell-passed
commit/tag messages, or use `git commit -F <file>`.**

---

## 8. Official-docs lessons (scope-check requirements!)
From `docs.pjsip.org` (PJSUA2 building) + DeepWiki:
- The doc's **`-fPIC` requirement is SWIG-only** (Python/Java/C# bindings), under a heading scoped
  to SWIG. It does **not** apply to an iOS/Swift static lib, and arm64 is PIC by default anyway.
  We had added `-fPIC` "to be safe" and **reverted it** — surgical-change discipline + don't apply
  a requirement outside its documented scope.
- PJSIP's official iOS-Swift path is a **bridging header**, not a module map → a hint that module
  umbrellas can hit ordering issues (resolved by the single-TU `umbrella header`, §1.3).
- PJSUA2 needs `gnu++14` + `libc++` + **C++ exceptions** (`PJSUA2_THROW`); `pjsua2.hpp` includes
  `<pjsua-lib/pjsua.h>`.

**Rule:** when a vendor doc states a requirement, capture its **scope** (which build path /
target it applies to) before propagating it into the build.

---

## 9. Checklists

**Build a combined static xcframework**
- [ ] Merge `.a` per slice with `libtool -static` (log benign warnings)
- [ ] Union public headers into one `Headers/` (verify disjoint namespaces)
- [ ] Generate umbrella header(s) with required `#define`s before includes
- [ ] Names can't case-fold onto vendored headers (macOS)
- [ ] `module.modulemap`: `[system]`, `umbrella header`, `requires cplusplus` for C++, `export *`
- [ ] `xcodebuild -create-xcframework -library .. -headers ..` per slice
- [ ] Typecheck each module via `swiftc -typecheck -I Headers` (+ C++ interop flag)

**Publish via SPM**
- [ ] Pick distribution: direct-commit (small/internal) or Release+checksum (versioned) — **never LFS**
- [ ] `Package.swift` `binaryTarget`; document required system frameworks + C++ interop
- [ ] `.gitattributes` `*.a binary` (if committing); confirm blob is real, not a pointer
- [ ] Create repo (manually if MCP lacks scope) → push (SSH) → tag a version
- [ ] Verify on the remote (manifest present, binary byte-size sane)
