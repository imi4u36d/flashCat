// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlashCat",
    platforms: [.macOS("14.0")],
    products: [
        .executable(name: "flashCat", targets: ["FlashCat"]),
    ],
    targets: [
        .executableTarget(
            name: "FlashCat",
            path: "Sources/FlashCat"
        ),
    ]
)
