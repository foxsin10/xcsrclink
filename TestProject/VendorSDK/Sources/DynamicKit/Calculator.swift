import Foundation

/// Shipped as a dynamic framework with a dSYM inside `DynamicKit.xcframework`.
public enum Calculator {
    public static func average(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let total = Stats.sum(values)               // BREAKPOINT DynamicKit.average
        return total / Double(values.count)
    }
}
