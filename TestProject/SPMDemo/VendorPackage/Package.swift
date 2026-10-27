// swift-tools-version:5.9
import PackageDescription

// The vendor's SDK as a Swift package, the way SDKs often ship for SwiftPM: prebuilt
// xcframeworks as binary targets. Binaries/ is filled by TestProject/scripts/build-sdk.sh.
let package = Package(
    name: "VendorPackage",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "StaticKit", targets: ["StaticKit"]),
        .library(name: "DynamicKit", targets: ["DynamicKit"]),
        .library(name: "ObjCKit", targets: ["ObjCKit"]),
    ],
    targets: [
        // Zipped: SwiftPM unpacks these into its artifacts folder, like a `url:` binary target.
        .binaryTarget(name: "StaticKit", path: "Binaries/StaticKit.xcframework.zip"),
        .binaryTarget(name: "DynamicKit", path: "Binaries/DynamicKit.xcframework.zip"),
        // A plain folder, used where it is.
        .binaryTarget(name: "ObjCKit", path: "Binaries/ObjCKit.xcframework"),
    ]
)
