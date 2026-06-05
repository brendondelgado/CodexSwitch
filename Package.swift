// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexSwitch",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CodexSwitch",
            path: "Sources/CodexSwitch",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CodexSwitchTests",
            dependencies: ["CodexSwitch"],
            path: "Tests/CodexSwitchTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
