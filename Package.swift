// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "FuzzyPaste",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "FuzzyPasteCore",
            path: "Sources/FuzzyPasteCore"
        ),
        .executableTarget(
            name: "FuzzyPaste",
            dependencies: ["FuzzyPasteCore"],
            path: "Sources/FuzzyPaste"
        ),
        .executableTarget(
            name: "fpaste",
            dependencies: [
                "FuzzyPasteCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/fpaste"
        ),
        .testTarget(
            name: "FuzzyPasteCoreTests",
            dependencies: ["FuzzyPasteCore"],
            path: "Tests/FuzzyPasteCoreTests"
        ),
    ]
)
