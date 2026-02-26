// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "FuzzyPaste",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "FuzzyPaste",
            path: "Sources/FuzzyPaste"
        )
    ]
)
