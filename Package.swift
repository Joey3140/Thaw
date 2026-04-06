// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HiddenMenuBar",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.0.0"),
        .package(url: "https://github.com/tmandry/AXSwift", from: "0.3.2"),
        .package(url: "https://github.com/buh/CompactSlider", exact: "1.1.6"),
        .package(url: "https://github.com/ukushu/Ifrit", from: "2.0.3"),
    ],
    targets: [
        // Shared library used by both the app and the XPC service
        .target(
            name: "SharedLib",
            dependencies: [
                .product(name: "AXSwift", package: "AXSwift"),
            ],
            path: "Shared",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // XPC service for resolving menu bar item ownership on macOS 26
        .executableTarget(
            name: "MenuBarItemService",
            dependencies: [
                "SharedLib",
                .product(name: "AXSwift", package: "AXSwift"),
            ],
            path: "MenuBarItemService",
            exclude: [
                "Resources",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Main app
        .executableTarget(
            name: "HiddenMenuBar",
            dependencies: [
                "SharedLib",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "AXSwift", package: "AXSwift"),
                .product(name: "CompactSlider", package: "CompactSlider"),
                .product(name: "IfritStatic", package: "Ifrit"),
            ],
            path: "Thaw",
            exclude: [
                "Resources/Info.plist",
                "Resources/Assets.xcassets",
                "Resources/Acknowledgements.rtf",
            ],
            resources: [
                .copy("Resources/Acknowledgements.pdf"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
