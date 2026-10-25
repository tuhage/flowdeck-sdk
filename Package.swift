// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flowdeck",
    platforms: [
        .iOS(.v16),
        // macOS is supported only so the package compiles and tests on the host
        // toolchain; the SDK targets iOS.
        .macOS(.v13)
    ],
    products: [
        .library(name: "Flowdeck", targets: ["Flowdeck"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(
            name: "Flowdeck",
            dependencies: ["ZIPFoundation"],
            resources: [.copy("Resources/bridge.js")],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "FlowdeckTests",
            dependencies: ["Flowdeck", "ZIPFoundation"],
            resources: [.copy("Fixtures")]
        )
    ]
)
