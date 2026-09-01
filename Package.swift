// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SmoothScreen",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SmoothScreen", targets: ["SmoothScreen"])
    ],
    targets: [
        .executableTarget(
            name: "SmoothScreen",
            path: "Sources/SmoothScreen",
            linkerSettings: [
                .linkedFramework("AVKit")
            ]
        ),
        .testTarget(
            name: "SmoothScreenTests",
            dependencies: ["SmoothScreen"]
        )
    ],
    swiftLanguageModes: [.v5]
)
