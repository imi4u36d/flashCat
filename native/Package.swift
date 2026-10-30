// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlashCat",
    platforms: [.macOS("14.0")],
    products: [
        .executable(name: "flashCat", targets: ["FlashCat"]),
        .library(name: "FlashCatKit", targets: ["FlashCatKit"]),
    ],
    targets: [
        .target(
            name: "FlashCatKit",
            path: "Sources/FlashCatKit"
        ),
        .executableTarget(
            name: "FlashCat",
            dependencies: ["FlashCatKit"],
            path: "Sources/FlashCat",
            // `Resources/app-icon.png` is the single master artwork: the build
            // script turns it into AppIcon.icns and the in-app brand mark draws
            // it, so Dock, Finder and window chrome always show the same icon.
            // `WebUI/` is the「精密仪器」web console (see WebViewShell.swift).
            resources: [.process("Resources"), .copy("WebUI")]
        ),
        .testTarget(
            name: "FlashCatKitTests",
            dependencies: ["FlashCatKit"],
            path: "Tests/FlashCatKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
