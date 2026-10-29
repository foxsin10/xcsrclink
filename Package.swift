// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "xcsrclink",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "xcsrclink", targets: ["xcsrclink"]),
    .library(name: "XcsrcLinkKit", targets: ["XcsrcLinkKit"])
  ],
  targets: [
    .target(name: "XcsrcLinkKit"),
    .executableTarget(name: "xcsrclink", dependencies: ["XcsrcLinkKit"]),
    .testTarget(name: "XcsrcLinkKitTests", dependencies: ["XcsrcLinkKit"])
  ],
  swiftLanguageModes: [.v6]
)
