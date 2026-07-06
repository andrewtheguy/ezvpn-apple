// swift-tools-version:5.9
import PackageDescription

// Delivers the iOS Rust artifact — libezvpn.xcframework (built by the sibling
// repo's build-ios.sh, released as libezvpn-ios.xcframework.zip) — as a Swift
// package binary target. The app (this repo) references this package by local
// path, so it always uses this manifest; there is no vendored copy.
//
// The binary target has two modes, toggled by the `useLocalXcframework` line
// below. That line is managed by scripts — flip it with:
//
//   scripts/use-local-xcframework.sh          # local dev build (sibling ../ezvpn)
//   scripts/use-release-xcframework.sh [tag]  # pinned release zip (url+checksum)
//
// The mode lives in this file rather than an environment variable so that
// xcodegen, xcodebuild, and the Xcode GUI can never disagree about which
// artifact is linked, and `git diff` shows the current mode at a glance.
// Release mode (reproducible url+checksum) is the committed default.
//
// Local mode links the sibling's build via the committed relative symlink
// local/libezvpn.xcframework -> ../ezvpn/dist/ios/… (SPM forbids binary-target
// paths outside the package root). Build it with `./build-ios.sh release`.

// Managed by scripts/use-{local,release}-xcframework.sh — do not edit by hand.
let useLocalXcframework = true

let binaryTarget: Target = useLocalXcframework
    ? .binaryTarget(name: "libezvpn", path: "local/libezvpn.xcframework")
    : .binaryTarget(
        name: "libezvpn",
        url: "https://github.com/andrewtheguy/ezvpn/releases/download/v0.0.14/libezvpn-ios.xcframework.zip",
        checksum: "b924705f61dcc581fa80ddadd64d9c7a5f60cf601c061e9f3029e6b45bad05c7"
    )

let package = Package(
    name: "Ezvpn",
    products: [
        .library(name: "libezvpn", targets: ["libezvpn"]),
    ],
    targets: [binaryTarget]
)
