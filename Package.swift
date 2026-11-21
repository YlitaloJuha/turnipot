// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Turnipot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Turnipot", targets: ["Turnipot"]),
        .executable(name: "turnipot-hook", targets: ["turnipot-hook"]),
        .library(name: "NotchCore", targets: ["NotchCore"]),
    ],
    targets: [
        .target(name: "NotchCore", path: "Sources/NotchCore"),
        .executableTarget(
            name: "Turnipot",
            dependencies: ["NotchCore"],
            path: "Sources/Turnipot"
        ),
        // Standalone hook binary: Foundation only, does NOT depend on NotchCore
        // so it stays tiny and starts fast.
        .executableTarget(name: "turnipot-hook", dependencies: ["HookOutput"], path: "Sources/turnipot-hook"),
        // Hook stdout mapping (Foundation only), shared by turnipot-hook and the self-tests.
        .target(name: "HookOutput", path: "Sources/HookOutput"),
        // XCTest and swift-testing macros are NOT available with Command Line Tools only,
        // so tests are a plain executable: `swift run turnipot-selftest` (exit code != 0 on failure).
        .executableTarget(
            name: "turnipot-selftest",
            dependencies: ["NotchCore", "HookOutput"],
            path: "Sources/turnipot-selftest"
        ),
    ],
    swiftLanguageModes: [.v5]
)
