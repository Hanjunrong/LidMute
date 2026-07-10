// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LidMute",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LidMuteCore", targets: ["LidMuteCore"]),
        .executable(name: "LidMuteCoreBehaviorTests", targets: ["LidMuteCoreBehaviorTests"]),
        .executable(name: "LidMuteApp", targets: ["LidMuteApp"]),
        .executable(name: "LidMuteNativeHost", targets: ["LidMuteNativeHost"]),
    ],
    targets: [
        .target(name: "LidMuteCore"),
        .executableTarget(
            name: "LidMuteCoreBehaviorTests",
            dependencies: ["LidMuteCore"],
            path: "Tests/LidMuteCoreBehavior"
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
        .executableTarget(name: "LidMuteNativeHost"),
    ]
)
