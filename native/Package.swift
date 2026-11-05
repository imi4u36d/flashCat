// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlashCat",
    platforms: [.macOS("26.4")],
    products: [
        .executable(name: "flashCat", targets: ["FlashCat"]),
        .library(name: "FlashCatKit", targets: ["FlashCatKit"]),
        // Renders the WebUI in a real WKWebView and asserts that every page
        // paints. Separate from `swift test` because it needs WebKit, not
        // because it is optional — CI gates on it.
        .executable(name: "webui-render-check", targets: ["WebUIRenderCheck"]),
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
            exclude: ["SPEC.md", "WebUI-SPEC.md"],
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
        // The app shell had no tests at all. These cover the helpers extracted
        // from the live wiring, not `AppState` itself — that split is what makes
        // the shell testable, see CONTRIBUTING.md.
        .testTarget(
            name: "FlashCatTests",
            dependencies: ["FlashCat"],
            path: "Tests/FlashCatTests"
        ),
        // Not a test target: WebKit needs an NSApplication and a run loop, and
        // keeping it out of `swift test` keeps the unit suite fast and free of
        // UI dependencies. See Tools/WebUIRenderCheck.
        .executableTarget(
            name: "WebUIRenderCheck",
            path: "Tools/WebUIRenderCheck",
            exclude: ["README.md"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
