import Foundation

/// A scheme whose Run action xcsrclink pointed at an lldbinit file.
public struct SchemeEdit: Codable, Hashable, Sendable {
  /// Absolute path of the `.xcscheme` file.
  public internal(set) var path: String
  /// The `customLLDBInitFile` value that was written, e.g.
  /// `$(SRCROOT)/xcsrclink.lldbinit`.
  public internal(set) var value: String

  /// The scheme's name, e.g. `App` for `.../App.xcscheme`.
  public var schemeName: String {
    XcodeScheme.name(of: path)
  }
}

/// Reads and edits the Run action's "LLDB Init File" (`customLLDBInitFile`) in
/// `.xcscheme` files. Edits are textual so the rest of the file keeps Xcode's formatting.
enum XcodeScheme {
  struct Found {
    /// The folder holding the `.xcodeproj` / `.xcworkspace`, which is `$(SRCROOT)`.
    var projectDir: String
    var schemes: [String]
  }

  /// Looks for an Xcode project in the lldbinit file's folder and its parents, and
  /// returns its shared schemes plus the current user's own schemes.
  static func find(near file: String) -> Found? {
    let fm = FileManager.default
    var dir = (PathUtil.absolute(file) as NSString).deletingLastPathComponent
    while true {
      let containers = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        .sorted()
      if !containers.isEmpty {
        let schemes = containers
          .flatMap { schemes(in: (dir as NSString).appendingPathComponent($0)) }
        return Found(projectDir: dir, schemes: schemes)
      }
      if dir == "/" || dir.isEmpty {
        return nil
      }
      dir = (dir as NSString).deletingLastPathComponent
    }
  }

  static func schemes(in container: String) -> [String] {
    let fm = FileManager.default
    let folders = [
      "xcshareddata/xcschemes",
      "xcuserdata/\(NSUserName()).xcuserdatad/xcschemes"
    ]
    return folders.flatMap { sub -> [String] in
      let dir = (container as NSString).appendingPathComponent(sub)
      return ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".xcscheme") }
        .sorted()
        .map { (dir as NSString).appendingPathComponent($0) }
    }
  }

  /// `$(SRCROOT)` for a scheme given by path: the folder holding its `.xcodeproj` /
  /// `.xcworkspace`.
  static func projectDir(ofScheme scheme: String) -> String? {
    var dir = PathUtil.absolute(scheme)
    while dir != "/", !dir.isEmpty {
      dir = (dir as NSString).deletingLastPathComponent
      if dir.hasSuffix(".xcodeproj") || dir.hasSuffix(".xcworkspace") {
        return (dir as NSString).deletingLastPathComponent
      }
    }
    return nil
  }

  static func name(of scheme: String) -> String {
    ((scheme as NSString).lastPathComponent as NSString).deletingPathExtension
  }

  /// The value to store in the scheme:
  /// `$(SRCROOT)/<path relative to the project folder>`, so a shared scheme holds no
  /// personal paths.
  static func value(for lldbinit: String, projectDir: String) -> String {
    let target = SourcePath(PathUtil.absolute(lldbinit)).components
    let base = SourcePath(PathUtil.absolute(projectDir)).components
    var common = 0
    while common < min(target.count, base.count),
          target[common] == base[common] {
      common += 1
    }
    let parts = Array(repeating: "..", count: base.count - common) + target[common...]
    return "$(SRCROOT)/" + parts.joined(separator: "/")
  }

  /// The Run action's LLDB Init File. The outer optional is nil when there is no Run
  /// action.
  static func lldbInitFile(in xml: String) -> String?? {
    guard let tag = launchTagRange(in: xml) else {
      return nil
    }
    let ns = xml as NSString
    guard let m = attribute.firstMatch(in: xml, range: tag) else {
      return .some(nil)
    }
    return .some(unescape(ns.substring(with: m.range(at: 1))))
  }

  /// Returns `xml` with the Run action's LLDB Init File set to `value`, or removed when
  /// `value` is nil. Returns nil when the scheme has no Run action.
  static func setting(_ value: String?, in xml: String) -> String? {
    guard let tag = launchTagRange(in: xml) else {
      return nil
    }
    let ns = xml as NSString
    if let m = attribute.firstMatch(in: xml, range: tag) {
      guard let value else {
        return ns.replacingCharacters(in: m.range, with: "")
      }
      return ns.replacingCharacters(in: m.range(at: 1), with: escape(value))
    }
    guard let value else {
      return xml
    }
    // Xcode writes it right after selectedLauncherIdentifier; match that to keep diffs
    // small.
    if let m = launcher.firstMatch(in: xml, range: tag) {
      let indent = ns.substring(with: m.range(at: 1))
      return ns.replacingCharacters(
        in: NSRange(location: NSMaxRange(m.range), length: 0),
        with: "\n\(indent)customLLDBInitFile = \"\(escape(value))\""
      )
    }
    let lineStart = ns.lineRange(for: NSRange(location: tag.location, length: 0)).location
    let indent = ns.substring(with: NSRange(
      location: lineStart,
      length: tag.location - lineStart
    ))
    let insertAt = tag.location + "<LaunchAction".utf16.count
    return ns.replacingCharacters(
      in: NSRange(location: insertAt, length: 0),
      with: "\n\(indent)   customLLDBInitFile = \"\(escape(value))\""
    )
  }

  // MARK: - XML

  private static let launchTag =
    try! NSRegularExpression(pattern: #"<LaunchAction\b[^>]*>"#)
  private static let attribute =
    try! NSRegularExpression(pattern: #"\n?[ \t]*customLLDBInitFile\s*=\s*"([^"]*)""#)
  private static let launcher =
    try! NSRegularExpression(
      pattern: #"\n([ \t]*)selectedLauncherIdentifier\s*=\s*"[^"]*""#
    )

  private static func launchTagRange(in xml: String) -> NSRange? {
    launchTag.firstMatch(
      in: xml,
      range: NSRange(location: 0, length: (xml as NSString).length)
    )?.range
  }

  private static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
      of: "\"",
      with: "&quot;"
    )
    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(
      of: ">",
      with: "&gt;"
    )
  }

  private static func unescape(_ s: String) -> String {
    s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(
      of: "&lt;",
      with: "<"
    )
    .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(
      of: "&amp;",
      with: "&"
    )
  }
}
