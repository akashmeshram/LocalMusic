// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalMusic",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalMusicCore", targets: ["LocalMusicCore"]),
        .executable(name: "LocalMusic", targets: ["LocalMusic"]),
    ],
    targets: [
        .target(
            name: "LocalMusicCore",
            path: "Sources/LocalMusicCore"
        ),
        .executableTarget(
            name: "LocalMusic",
            dependencies: ["LocalMusicCore"],
            path: "Sources/LocalMusic",
            exclude: ["Resources/Info.plist", "Resources/LocalMusic.entitlements"]
        ),
        .testTarget(
            name: "LocalMusicTests",
            dependencies: ["LocalMusicCore"],
            path: "Tests/LocalMusicTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
