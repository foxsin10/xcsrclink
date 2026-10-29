import Foundation

/// A dSYM on this Mac for the same build (same UUID) as another one. lldb finds dSYMs by
/// UUID through Spotlight and loads whichever copy it finds, so a stale copy elsewhere
/// can hide a patched one.
public struct DSYMCopy: Hashable, Sendable {
  public init(
    path: String,
    dwarfFile: String,
    sourceFileCount: Int,
    foundFileCount: Int
  ) {
    self.path = path
    self.dwarfFile = dwarfFile
    self.sourceFileCount = sourceFileCount
    self.foundFileCount = foundFileCount
  }

  /// The `.dSYM` bundle.
  public var path: String
  /// The DWARF file inside it.
  public var dwarfFile: String
  /// Source files the copy records.
  public var sourceFileCount: Int
  /// How many of them exist on this machine. Equal to `sourceFileCount` when the copy is
  /// patched (or was built here); 0 when it still has the build machine's paths.
  public var foundFileCount: Int

  /// Every recorded file exists here, so lldb can show source without a source-map.
  public var allFilesFound: Bool {
    sourceFileCount > 0 && foundFileCount == sourceFileCount
  }
}

public extension Linker {
  /// Every dSYM with the same UUID as `binary`, found through Spotlight, including
  /// `binary`'s own bundle. Empty when `binary` isn't a dSYM.
  func dSYMCopies(of binary: DebugBinary) throws -> [DSYMCopy] {
    guard binary.kind == .dSYM else {
      return []
    }
    let fm = FileManager.default
    return try DSYMLocator.copies(ofDWARFFile: binary.path).map { file in
      let sources = try SourcePathReader.sources(in: file)
      return DSYMCopy(
        path: DSYMLocator.bundle(ofDWARFFile: file),
        dwarfFile: file,
        sourceFileCount: sources.count,
        foundFileCount: sources.filter { fm.fileExists(atPath: $0) }.count
      )
    }
  }
}

enum DSYMLocator {
  /// The UUIDs (one per architecture) of a Mach-O or DWARF file.
  static func uuids(of file: String) -> [String] {
    guard let r = try? Shell.run("/usr/bin/xcrun", ["dwarfdump", "--uuid", file]),
          r.status == 0 else {
      return []
    }
    return r.stdout.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: " ")
      return parts.count > 1 && parts[0] == "UUID:" ? String(parts[1]) : nil
    }
  }

  /// DWARF files of every dSYM sharing a UUID with `dwarfFile`, `dwarfFile` first.
  static func copies(ofDWARFFile dwarfFile: String) -> [String] {
    let name = (dwarfFile as NSString).lastPathComponent
    var seen: Set<SourcePath> = [SourcePath(dwarfFile)]
    var result = [dwarfFile]
    for uuid in uuids(of: dwarfFile) {
      let query = "com_apple_xcode_dsym_uuids == \(uuid)"
      guard let found = try? Shell.run("/usr/bin/mdfind", [query]) else {
        continue
      }
      for bundle in found.stdout.split(separator: "\n").map(String.init).sorted() {
        let file = (bundle as NSString)
          .appendingPathComponent("Contents/Resources/DWARF/\(name)")
        guard FileManager.default.fileExists(atPath: file),
              seen.insert(SourcePath(file)).inserted else {
          continue
        }
        result.append(file)
      }
    }
    return result
  }

  /// `X.dSYM` for `X.dSYM/Contents/Resources/DWARF/X`.
  static func bundle(ofDWARFFile file: String) -> String {
    var url = URL(fileURLWithPath: file)
    for _ in 0 ..< 4 {
      url.deleteLastPathComponent()
    }
    return url.path
  }
}
