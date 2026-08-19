// swift-tools-version: 5.9
import PackageDescription

// swift-pjsip
// ===========
// Distributes a single, self-contained PJSIP build as one binary xcframework.
//
// The xcframework vends TWO Clang modules (see its module.modulemap):
//   - `PJSIP`  : the C API (pjsua1 + pjsip / pjmedia / pjnath / pjlib). Pure C, no interop needed.
//   - `PJSUA2` : the C++ API. Consumers MUST enable C++ interop in their own target
//                (swiftSettings: [.interoperabilityMode(.Cxx)]).
//
// libpjproject.a already contains all PJSIP sublibraries + third-party deps + bcg729,
// so there is exactly one library to link per platform slice. What that means for the
// consuming app — which system frameworks it must link, and what it must NOT link
// itself — is in docs/ARCHITECTURE.md.
//
// The artifact is fetched from a GitHub Release rather than committed. Committing it
// cost ~15-19 MB of incompressible blobs in every clone, permanently, per rebuild —
// and the release cadence is now per-PJSIP-release. Never Git LFS: SwiftPM's resolver
// does a plain clone and does not run the LFS smudge filter, so consumers would get
// pointer files (docs/SPM-XCFRAMEWORK-EXPERIENCE.md).
//
// The checksum is published in each release's notes so a downstream author can pin it
// without downloading the asset first. Regenerate both with `scripts/build.sh dist`.
let package = Package(
    name: "PJSIP",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "PJSIP", targets: ["PJSIP"])
    ],
    targets: [
        .binaryTarget(
            name: "PJSIP",
            url: "https://github.com/laconicman/swift-pjsip/releases/download/0.2.0/PJSIP.xcframework-2.17.0-288de6142.zip",
            checksum: "00214082e4b246bf224f6a2dd3ca8a064e755bb8205962194518377a7349526b"
        )
    ]
)
