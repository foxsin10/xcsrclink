// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "xcsrclink",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "xcsrclink", targets: ["xcsrclink"]),
    .library(name: "XcsrcLinkKit", targets: ["XcsrcLinkKit"]),
    .library(name: "XcsrcLinkCLI", targets: ["XcsrcLinkCLI"])
  ],
  targets: [
    .target(name: "XcsrcLinkKit"),
    .target(name: "XcsrcLinkCLI", dependencies: ["XcsrcLinkKit"]),
    .executableTarget(name: "xcsrclink", dependencies: ["XcsrcLinkCLI"]),
    .testTarget(name: "XcsrcLinkKitTests", dependencies: ["XcsrcLinkKit"]),
    .testTarget(name: "XcsrcLinkCLITests", dependencies: ["XcsrcLinkCLI"])
  ],
  swiftLanguageModes: [.v6]
)
