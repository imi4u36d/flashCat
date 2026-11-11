// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlashCat",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "flashCat", targets: ["FlashCat"]),
        // Not `flashcat`: APFS is case-insensitive, and a product name that
        // differs from `flashCat` only by case collides with the app's build
        // directory. The shipped binary is still renamed to `flashcat` when
        // the bundle is assembled.
        .executable(name: "flashcat-cli", targets: ["FlashCatCLI"]),
        .library(name: "FlashCatKit", targets: ["FlashCatKit"]),
    ],
    targets: [
        .target(
            name: "FlashCatKit",
            path: "Sources/FlashCatKit",
            // Design notes live next to the code they describe; they are not
            // build inputs, but SwiftPM warns about undeclared files unless
            // they are excluded explicitly.
            exclude: ["SPEC.md", "Gateway/SPEC.md"]
        ),
        .target(
            name: "FlashCatCLICore",
            dependencies: ["FlashCatKit"],
            path: "Sources/FlashCatCLICore",
            exclude: ["SPEC.md"]
        ),
        .executableTarget(
            name: "FlashCatCLI",
            dependencies: ["FlashCatCLICore"],
            path: "Sources/flashcat-cli"
        ),
        .executableTarget(
            name: "FlashCat",
            dependencies: ["FlashCatKit"],
            path: "Sources/FlashCat",
            exclude: ["SPEC.md", "UI-SPEC.md"],
            // `Resources/app-icon.png` is the single master artwork: the build
            // script turns it into AppIcon.icns and the in-app brand mark draws
            // it, so Dock, Finder and window chrome always show the same icon.
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "FlashCatKitTests",
            dependencies: ["FlashCatKit"],
            path: "Tests/FlashCatKitTests",
            resources: [.copy("Fixtures")]
        ),
        // The app shell had no tests at all. These cover the helpers extracted
        // from the live wiring, not `AppState` itself — that split is what makes
        // the shell testable, see CONTRIBUTING.md.
        .testTarget(
            name: "FlashCatTests",
            dependencies: ["FlashCat", "FlashCatKit"],
            path: "Tests/FlashCatTests"
        ),
        // The CLI's parser, SSE decoder and output formatting are pure; they
        // get the same no-window test harness as the kit.
        .testTarget(
            name: "FlashCatCLICoreTests",
            dependencies: ["FlashCatCLICore", "FlashCatKit"],
            path: "Tests/FlashCatCLICoreTests"
        ),
    ]
)
