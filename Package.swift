// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Atrium",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Atrium", targets: ["Atrium"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", .upToNextMinor(from: "0.18.0")),
    ],
    targets: [
        // Everything that records, transcribes and writes files. No UI.
        .target(
            name: "AtriumCore",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/AtriumCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app.
        .executableTarget(
            name: "Atrium",
            dependencies: ["AtriumCore"],
            path: "Sources/Atrium",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AtriumCoreTests",
            dependencies: ["AtriumCore"],
            path: "Tests/AtriumCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
