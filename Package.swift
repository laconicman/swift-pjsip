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
// so there is exactly one library to link per platform slice.
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
            path: "Binaries/PJSIP.xcframework"
        )
    ]
)
