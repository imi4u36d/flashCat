// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlashCat",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "flashCat", targets: ["FlashCat"]),
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
            dependencies: ["FlashCat"],
            path: "Tests/FlashCatTests"
        ),
    ]
)
