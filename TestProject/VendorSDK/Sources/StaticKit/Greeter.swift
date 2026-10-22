import Foundation

/// Shipped as a static library (`libStaticKit.a`) inside `StaticKit.xcframework`.
public struct Greeter {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public func greeting() -> String {
        let base = "Hello, \(name)!"            // BREAKPOINT StaticKit.greeting
        return TextStyler.decorate(base)
    }
}
