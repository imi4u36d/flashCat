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
        .target(
            name: "FlashCatCore",
            dependencies: ["FlashCatKit"],
            path: "Sources/FlashCatCore",
            // The String Catalog and its compiled lproj live here now: every
            // L10n lookup from the app shell goes through `FlashCatCore`.
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "FlashCat",
            dependencies: ["FlashCatKit", "FlashCatCore"],
            path: "Sources/FlashCat",
            exclude: ["SPEC.md", "UI-SPEC.md"],
            // `Resources/app-icon.png` is the single master artwork: the build
            // script turns it into AppIcon.icns and the in-app brand mark draws
            // it, so Dock, Finder and window chrome always show the same icon.
            resources: [.process("Resources")],
            // AVKit must be linked explicitly, even though `import AVKit` is in
            // the source. SwiftUI's `VideoPlayer` lives in the `_AVKit_SwiftUI`
            // overlay, so nothing in our code references an AVKit symbol and
            // autolinking pulls in only the overlay — AVKit itself never loads.
            // Its hidden `VideoPlayerView` subclasses `AVPlayerView`, so the
            // first render aborts in the Swift runtime with "failed to demangle
            // superclass of VideoPlayerView" (SIGABRT, i.e. a hard crash right
            // when a generated video appears in the chat).
            linkerSettings: [.linkedFramework("AVKit")]
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
            dependencies: ["FlashCat", "FlashCatCore", "FlashCatKit"],
            path: "Tests/FlashCatTests"
        ),
        .testTarget(
            name: "FlashCatCoreTests",
            dependencies: ["FlashCatCore", "FlashCatKit"],
            path: "Tests/FlashCatCoreTests"
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
