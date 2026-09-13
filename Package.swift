// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Showcase",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Showcase", targets: ["Showcase"])
    ],
    targets: [
        .executableTarget(
            name: "Showcase",
            path: "Sources/Showcase",
            resources: [.copy("Resources/Bibata")],
            linkerSettings: [
                .linkedFramework("AVKit")
            ]
        ),
        .testTarget(
            name: "ShowcaseTests",
            dependencies: ["Showcase"]
        )
    ],
    swiftLanguageModes: [.v5]
)
