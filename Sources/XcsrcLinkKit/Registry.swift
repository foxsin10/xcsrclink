import Foundation

public enum Strategy: String, Codable, CaseIterable, Sendable {
  /// Add `target.source-map` entries to an lldbinit file. Nothing on disk is modified.
  case lldbinit
  /// Rewrite the paths inside the binaries' DWARF (backups are kept).
  case patch
  /// Create symlinks at the original build paths pointing at the local sources (the
  /// cocoapods-imy-bin approach).
  case symlink
}

public struct PatchedFile: Codable, Sendable {
  public internal(set) var path: String
  public internal(set) var backup: String
  /// SHA-256 of the file right after patching, so `unlink` won't clobber a newer copy.
  public internal(set) var patchedSHA256: String
}

public struct LinkRecord: Codable, Sendable {
  public internal(set) var name: String
  public internal(set) var input: String
  public internal(set) var sourceRoot: String?
  public internal(set) var strategies: [Strategy]
  public internal(set) var mappings: [PathMapping]
  public internal(set) var createdAt: Date
  public internal(set) var lldbinitPath: String?
  public internal(set) var inlineBreakpoints: Bool
  public internal(set) var patchedFiles: [PatchedFile] = []
  public internal(set) var symlinks: [String] = []
  public internal(set) var createdDirectories: [String] = []
  /// `_CodeSignature` folders moved aside before patching a signed xcframework: original
  /// → backup.
  public internal(set) var movedSignatures: [String: String] = [:]
  /// Schemes whose LLDB Init File was set to `lldbinitPath`. Optional so older registries
  /// still load.
  public internal(set) var schemes: [SchemeEdit]?
}

/// The list of links, stored as `registry.json` in the linker's home folder.
struct Registry: Codable {
  var records: [LinkRecord] = []

  static func fileURL(home: URL) -> URL {
    home.appendingPathComponent("registry.json")
  }

  static func load(home: URL) throws -> Registry {
    guard let data = try? Data(contentsOf: fileURL(home: home)) else {
      return Registry()
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Registry.self, from: data)
  }

  func save(home: URL) throws {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(self).write(to: Registry.fileURL(home: home), options: .atomic)
  }
}
