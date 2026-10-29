import Foundation

/// A normalized file path split into components. Empty and `.` components are dropped, so
/// `/a//b/./c` and `/a/b/c` compare equal (lldb normalizes them the same way).
struct SourcePath: Hashable, Comparable, CustomStringConvertible, Sendable {
  init(_ raw: String) {
    isAbsolute = raw.hasPrefix("/")
    components = raw.split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
      .filter { $0 != "." }
  }

  init(isAbsolute: Bool, components: [String]) {
    self.isAbsolute = isAbsolute
    self.components = components
  }

  let isAbsolute: Bool
  let components: [String]

  var string: String {
    if isAbsolute {
      return "/" + components.joined(separator: "/")
    }
    return components.isEmpty ? "." : components.joined(separator: "/")
  }

  var description: String {
    string
  }

  static func < (lhs: SourcePath, rhs: SourcePath) -> Bool {
    lhs.string < rhs.string
  }

  func dropLast(_ n: Int) -> SourcePath {
    SourcePath(isAbsolute: isAbsolute, components: Array(components.dropLast(n)))
  }

  func appending(_ tail: ArraySlice<String>) -> SourcePath {
    SourcePath(isAbsolute: isAbsolute, components: components + tail)
  }

  func hasPrefix(_ other: SourcePath) -> Bool {
    isAbsolute == other.isAbsolute && components.starts(with: other.components)
  }
}

/// One "build path → local path" rewrite rule.
public struct PathMapping: Codable, Hashable, Sendable, CustomStringConvertible {
  public init(from: String, to: String) {
    self.from = SourcePath(from).string
    self.to = SourcePath(to).string
  }

  public var from: String
  public var to: String

  public var description: String {
    "\(from) -> \(to)"
  }

  /// Applies the first matching mapping. Callers keep mappings ordered most-specific
  /// first.
  public static func apply(_ mappings: [PathMapping], to path: String) -> String? {
    for m in mappings {
      if let r = m.apply(to: path) {
        return r
      }
    }
    return nil
  }

  /// Returns the rewritten path when `path` lives under `from`.
  public func apply(to path: String) -> String? {
    let p = SourcePath(path), f = SourcePath(from)
    guard p.hasPrefix(f) else {
      return nil
    }
    return SourcePath(to).appending(p.components.dropFirst(f.components.count)).string
  }
}

enum PathUtil {
  /// Expands `~` and makes the path absolute against the current directory. Deliberately
  /// avoids `standardizingPath`, which strips `/private` and would stop paths from
  /// matching what the compiler recorded.
  static func absolute(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let url = expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded)
      : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(expanded)
    return canonicalCase(SourcePath(url.standardized.path).string)
  }

  /// The path as the file system spells it, e.g. `~/workspace/App` → `~/Workspace/App` on
  /// a case-insensitive volume. Compilers record the real spelling and lldb compares
  /// paths case-sensitively, so a mapping to a differently cased path never matches. Only
  /// the letter case changes: symlinks (and `/private`) are kept as given.
  static func canonicalCase(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else {
      return path
    }
    defer { free(resolved) }
    let real = String(cString: resolved)
    return real != path && real.caseInsensitiveCompare(path) == .orderedSame ? real : path
  }

  /// Paths that belong to Xcode, SDKs or the compiler rather than the library's own
  /// sources.
  static func isSystemPath(_ p: String) -> Bool {
    if p.hasPrefix("<") || p.hasPrefix("/<") {
      return true
    }
    let markers = [
      ".sdk/",
      "/Xcode.app/",
      "/Xcode-beta.app/",
      ".xctoolchain/",
      "/CommandLineTools/"
    ]
    if markers.contains(where: p.contains) {
      return true
    }
    let prefixes = [
      "/Applications/Xcode",
      "/Library/Developer/",
      "/AppleInternal/",
      "/usr/",
      "/System/"
    ]
    if prefixes.contains(where: p.hasPrefix) {
      return true
    }
    // Swift line tables list module names (e.g. "_SwiftConcurrencyShims"); keep only real
    // files.
    guard let last = SourcePath(p).components.last,
          last.contains(".") else {
      return true
    }
    return false
  }

  static func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir
      .boolValue
  }

  static func tildeAbbreviated(_ path: String) -> String {
    let h = NSHomeDirectory()
    return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
  }
}
