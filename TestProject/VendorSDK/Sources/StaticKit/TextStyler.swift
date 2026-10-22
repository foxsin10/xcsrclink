import Foundation

enum TextStyler {
    static func decorate(_ text: String) -> String {
        let stars = String(repeating: "*", count: 3)  // BREAKPOINT StaticKit.decorate
        return "\(stars) \(text) \(stars)"
    }
}
