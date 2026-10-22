import Foundation

enum Stats {
    static func sum(_ values: [Double]) -> Double {
        var result = 0.0
        for value in values {
            result += value                         // BREAKPOINT DynamicKit.sum
        }
        return result
    }
}
