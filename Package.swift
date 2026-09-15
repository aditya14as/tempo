// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tempo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tempo",
            path: "Sources/Tempo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
