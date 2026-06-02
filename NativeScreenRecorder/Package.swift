// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NativeScreenRecorder",
    defaultLocalization: "zh",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "NativeScreenRecorder", targets: ["NativeScreenRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "NativeScreenRecorder",
            path: "Sources/NativeScreenRecorder",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
