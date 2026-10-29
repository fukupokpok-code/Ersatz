// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Ersatz",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ErsatzCore", targets: ["ErsatzCore"]),
        .executable(name: "Ersatz", targets: ["Ersatz"])
    ],
    targets: [
        .target(
            name: "CSQLite",
            path: "Sources/CSQLite",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "ErsatzCore",
            dependencies: ["CSQLite"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "Ersatz",
            dependencies: ["ErsatzCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI", .when(platforms: [.macOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
                .linkedFramework("AVKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreImage", .when(platforms: [.macOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.macOS])),
                .linkedFramework("ImageIO", .when(platforms: [.macOS])),
                .linkedFramework("QuickLookThumbnailing", .when(platforms: [.macOS])),
                .linkedFramework("CoreServices", .when(platforms: [.macOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "ErsatzCoreTests",
            dependencies: ["ErsatzCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
