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
    targets: [
        .target(
            name: "Flowdeck",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "FlowdeckTests",
            dependencies: ["Flowdeck"]
        )
    ]
)
