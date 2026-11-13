// swift-tools-version: 6.2
import PackageDescription

// Indexing manifest for editors and SourceKit-LSP. The app itself is built
// from Thaw.xcodeproj by ./build.sh; this mirrors that project's package
// dependencies and Swift settings (as of upstream 2.1.0) so code navigation
// resolves the same modules. Xcode compiles Shared/ into every target, which
// SwiftPM can't do, so it is a separate SharedLib target here.

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "HiddenMenuBar",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0"),
        .package(url: "https://github.com/thaw-app/AXSwift6", .upToNextMinor(from: "0.5.2")),
        .package(url: "https://github.com/buh/CompactSlider", from: "2.1.0"),
        .package(url: "https://github.com/ukushu/Ifrit", from: "4.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.6.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-system", from: "1.4.0"),
    ],
    targets: [
        // Code shared by the app and both XPC services
        .target(
            name: "SharedLib",
            dependencies: [
                .product(name: "AXSwift6", package: "AXSwift6"),
            ],
            path: "Shared",
            swiftSettings: swiftSettings
        ),
        // XPC service that resolves menu bar item ownership (Accessibility)
        .executableTarget(
            name: "MenuBarItemService",
            dependencies: [
                "SharedLib",
                .product(name: "AXSwift6", package: "AXSwift6"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ],
            path: "MenuBarItemService",
            exclude: [
                "Resources",
            ],
            swiftSettings: swiftSettings
        ),
        // XPC service that captures menu bar item images (Screen Recording)
        .executableTarget(
            name: "MenuBarCaptureService",
            dependencies: [
                "SharedLib",
                .product(name: "AXSwift6", package: "AXSwift6"),
            ],
            path: "MenuBarCaptureService",
            exclude: [
                "Resources",
            ],
            swiftSettings: swiftSettings
        ),
        // Main app
        .executableTarget(
            name: "HiddenMenuBar",
            dependencies: [
                "SharedLib",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "AXSwift6", package: "AXSwift6"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "CompactSlider", package: "CompactSlider"),
                .product(name: "IfritStatic", package: "Ifrit"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Thaw",
            exclude: [
                "Resources",
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
