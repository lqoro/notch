// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchDeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates. Pinned; bump deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "NotchDeck",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NotchDeck",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
