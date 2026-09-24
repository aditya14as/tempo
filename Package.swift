// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tempo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tempo",
            path: "Sources/Tempo",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Optimise release builds for size: a smaller binary, and the
                // optimiser does less work, so rebuilds are faster too.
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ],
            // The Command Line Tools have no XCTest, yet SwiftPM still passes
            // the linker its search paths, and ld warns they don't exist.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-w"])]
        ),
    ]
)
