// swift-tools-version: 6.0
// washtower-relay: the always-on half of the WashTower Live Activity. It runs on the
// iMac behind the Cloudflare tunnel, polls LG ThinQ Connect, and starts, updates and
// ends the iPhone's Live Activity with APNs pushes. No third-party dependencies.
//
// RelayCore compiles four files from ../Shared through the symlinks in
// Sources/RelayCore/Shared, so the relay and the apps share one ThinQ client, one
// parser and one Live Activity wire format (LaundryActivityState). Those files use
// internal access, so they have to live in the same module as the relay logic;
// the executable is a thin wrapper around RelayCore's public entry point, and the
// tests reach the rest with @testable import.
import PackageDescription

let package = Package(
    name: "WashTowerRelay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "washtower-relay", targets: ["WashTowerRelay"]),
    ],
    targets: [
        .target(name: "RelayCore"),
        .executableTarget(name: "WashTowerRelay", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
    ]
)
