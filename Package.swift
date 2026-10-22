// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xcsrclink",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "xcsrclink", targets: ["xcsrclink"]),
    ],
    targets: [
        .target(name: "Core"),
        .executableTarget(name: "xcsrclink", dependencies: ["Core"]),
        .testTarget(name: "XCSrcLinkCoreTests", dependencies: ["Core"]),
    ],
    swiftLanguageModes: [.v5]
)
