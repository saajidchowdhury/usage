// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DropboxUsage",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "DropboxUsage", targets: ["DropboxUsage"]),
        .executable(name: "DropboxUsageChecks", targets: ["DropboxUsageChecks"]),
    ],
    targets: [
        .target(name: "DropboxUsageCore"),
        .executableTarget(
            name: "DropboxUsage",
            dependencies: ["DropboxUsageCore"]
        ),
        .executableTarget(
            name: "DropboxUsageChecks",
            dependencies: ["DropboxUsageCore"]
        ),
    ]
)
