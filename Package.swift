// swift-tools-version:6.2
import PackageDescription

// Command Line Tools only (no Xcode): XCTest is unavailable, so assertions live in StrataChecks
// and visual checks in StrataSnapshot. Swift 5 language mode: AppKit callbacks and timers fight
// strict concurrency for no benefit here.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Strata",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "StrataApp", targets: ["StrataApp"]),
        .executable(name: "strata", targets: ["strata"]),
    ],
    targets: [
        .target(name: "StrataCore", swiftSettings: swift5),
        .target(name: "StrataUI", dependencies: ["StrataCore"], swiftSettings: swift5),
        .executableTarget(name: "StrataApp", dependencies: ["StrataCore", "StrataUI"], swiftSettings: swift5),
        .executableTarget(name: "strata", dependencies: ["StrataCore"], swiftSettings: swift5),
        .executableTarget(name: "StrataSnapshot", dependencies: ["StrataCore", "StrataUI"], swiftSettings: swift5),
        .executableTarget(name: "StrataChecks", dependencies: ["StrataCore", "strata"], swiftSettings: swift5),
    ]
)
