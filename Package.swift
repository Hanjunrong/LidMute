// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LidMute",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LidMuteCore", targets: ["LidMuteCore"]),
        .executable(name: "LidMuteApp", targets: ["LidMuteApp"]),
        .executable(name: "LidMuteNativeHost", targets: ["LidMuteNativeHost"]),
    ],
    targets: [
        .target(name: "LidMuteCore"),
        .testTarget(
            name: "LidMuteCoreTests",
            dependencies: ["LidMuteCore", "LidMuteApp"],
            path: "Tests/LidMuteCoreTests"
        ),
        .executableTarget(
            name: "LidMuteApp",
            dependencies: ["LidMuteCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(name: "LidMuteNativeHost", dependencies: ["LidMuteCore"]),
    ]
)
