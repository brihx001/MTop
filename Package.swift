// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MTop",
            path: "Sources/MTop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
