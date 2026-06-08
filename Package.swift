// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ChromeMultiManagerMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ChromeMultiManagerMac", targets: ["ChromeMultiManagerMac"])
    ],
    targets: [
        .executableTarget(
            name: "ChromeMultiManagerMac",
            path: "Sources/ChromeMultiManagerMac"
        )
    ]
)
