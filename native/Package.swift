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
            path: "Sources/FlashCat"
        ),
        .testTarget(
            name: "FlashCatKitTests",
            dependencies: ["FlashCatKit"],
            path: "Tests/FlashCatKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
