import Foundation

/// A file that carries DWARF for some prebuilt code: a static library, an object file, a
/// dSYM's DWARF file, or (rarely) a Mach-O with embedded DWARF.
public struct DebugBinary: Hashable, Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case staticLibrary = "static library"
    case dSYM
    case machO = "Mach-O"
  }

  public let path: String
  public let kind: Kind
  /// xcframework library identifier, e.g. `ios-arm64_x86_64-simulator`.
  public let slice: String?
}

public struct LocateResult {
  public var binaries: [DebugBinary] = []
  /// Human-readable notes about things that were skipped (dynamic frameworks without
  /// dSYMs, ...).
  public var notes: [String] = []
  /// xcframework bundles found (they may be code signed).
  public var xcframeworks: [String] = []
}

public enum DebugBinaryLocator {
  public static func locate(_ input: String) -> LocateResult {
    var result = LocateResult()
    visit(PathUtil.absolute(input), slice: nil, into: &result)
    var seen = Set<String>()
    result.binaries = result.binaries.filter { seen.insert($0.path).inserted }
    return result
  }

  private static func visit(_ path: String, slice: String?, into r: inout LocateResult) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else {
      r.notes.append("not found: \(path)")
      return
    }
    switch (path as NSString).pathExtension.lowercased() {
    case "xcframework": xcframework(path, into: &r)
    case "framework": framework(path, slice: slice, into: &r)
    case "dsym": dSYM(path, slice: slice, into: &r)
    default:
      if PathUtil.isDirectory(path) {
        directory(path, into: &r)
      } else {
        file(path, slice: slice, into: &r)
      }
    }
  }

  private static func xcframework(_ path: String, into r: inout LocateResult) {
    r.xcframeworks.append(path)
    let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
          ) as? [String: Any],
          let libs = plist["AvailableLibraries"] as? [[String: Any]] else {
      r.notes.append("\(path): no readable Info.plist, scanning folder instead")
      directory(path, into: &r)
      return
    }
    for lib in libs {
      guard let id = lib["LibraryIdentifier"] as? String,
            let libPath = lib["LibraryPath"] as? String else {
        continue
      }
      let base = (path as NSString).appendingPathComponent(id)
      let full = (base as NSString).appendingPathComponent(libPath)
      if let dsyms = lib["DebugSymbolsPath"] as? String {
        let dir = (base as NSString).appendingPathComponent(dsyms)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
          where name.hasSuffix(".dSYM") {
          dSYM((dir as NSString).appendingPathComponent(name), slice: id, into: &r)
        }
      }
      if let binaryPath = lib["BinaryPath"] as? String, libPath.hasSuffix(".framework") {
        frameworkBinary(
          (base as NSString).appendingPathComponent(binaryPath),
          framework: full,
          slice: id,
          into: &r
        )
      } else {
        visit(full, slice: id, into: &r)
      }
    }
  }

  private static func framework(
    _ path: String,
    slice: String?,
    into r: inout LocateResult
  ) {
    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    frameworkBinary(
      (path as NSString).appendingPathComponent(name),
      framework: path,
      slice: slice,
      into: &r
    )
  }

  private static func frameworkBinary(
    _ binary: String,
    framework: String,
    slice: String?,
    into r: inout LocateResult
  ) {
    let resolved = (binary as NSString).resolvingSymlinksInPath
    if MachO.isStaticArchive(fileAt: resolved) {
      r.binaries.append(DebugBinary(path: resolved, kind: .staticLibrary, slice: slice))
      return
    }
    switch MachO.kind(ofFileAt: resolved) {
    case .archive,
         .machO,
         .fat:
      if MachO.hasDWARF(fileAt: resolved) {
        r.binaries.append(DebugBinary(path: resolved, kind: .machO, slice: slice))
      } else {
        // Dynamic framework: DWARF lives in a dSYM next to it, if one shipped.
        let sibling = framework + ".dSYM"
        if FileManager.default.fileExists(atPath: sibling) {
          dSYM(sibling, slice: slice, into: &r)
        } else if !r.binaries
          .contains(where: { $0.kind == .dSYM && $0.slice == slice && slice != nil }) {
          r.notes
            .append(
              "\((framework as NSString).lastPathComponent)\(slice.map { " [\($0)]" } ?? ""): dynamic framework with no dSYM, so there is no debug info to map"
            )
        }
      }
    case .unknown:
      r.notes.append("\(binary): not a Mach-O or static archive")
    }
  }

  private static func dSYM(_ path: String, slice: String?, into r: inout LocateResult) {
    let dwarfDir = (path as NSString).appendingPathComponent("Contents/Resources/DWARF")
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dwarfDir)) ?? [] {
      let file = (dwarfDir as NSString).appendingPathComponent(name)
      r.binaries.append(DebugBinary(path: file, kind: .dSYM, slice: slice))
    }
  }

  private static func file(_ path: String, slice: String?, into r: inout LocateResult) {
    if MachO.isStaticArchive(fileAt: path) {
      r.binaries.append(DebugBinary(path: path, kind: .staticLibrary, slice: slice))
      return
    }
    switch MachO.kind(ofFileAt: path) {
    case .archive,
         .machO,
         .fat:
      if MachO.hasDWARF(fileAt: path) {
        r.binaries.append(DebugBinary(path: path, kind: .machO, slice: slice))
      } else {
        r.notes.append("\(path): Mach-O without DWARF (look for its .dSYM)")
      }
    case .unknown:
      r.notes.append("\(path): not a Mach-O or static archive")
    }
  }

  /// Any folder, e.g. `Pods/`, `Carthage/Build` or a vendor directory: find bundles and
  /// libraries in it.
  private static func directory(_ path: String, into r: inout LocateResult) {
    let fm = FileManager.default
    guard let e = fm.enumerator(atPath: path) else {
      return
    }
    while let rel = e.nextObject() as? String {
      let full = (path as NSString).appendingPathComponent(rel)
      let ext = (rel as NSString).pathExtension.lowercased()
      let name = (rel as NSString).lastPathComponent
      let parent = ((full as NSString).deletingLastPathComponent as NSString)
        .lastPathComponent
      if ["xcframework", "framework", "dsym"].contains(ext) {
        e.skipDescendants()
        // A .framework that has a sibling .xcframework parent is handled by the
        // xcframework.
        visit(full, slice: nil, into: &r)
      } else if [".git", "DerivedData", "node_modules"].contains(name) {
        e.skipDescendants()
      } else if parent == ".build", !["artifacts", "checkouts"].contains(name),
                PathUtil.isDirectory(full) {
        // SwiftPM: binary targets are unpacked into .build/artifacts and dependency
        // packages are cloned into .build/checkouts. The rest is build output. (Only for
        // folders: skipDescendants() on a file skips its remaining siblings.)
        e.skipDescendants()
      } else if ext == "a" || ext == "o" {
        file(full, slice: nil, into: &r)
      }
    }
  }
}

public enum SourcePathReader {
  /// Source files recorded in the binary's DWARF, minus Xcode/SDK/compiler paths.
  public static func sources(in binary: String) throws -> [String] {
    let r = try Shell.run("/usr/bin/xcrun", ["dwarfdump", "--show-sources", binary])
    guard r.status == 0 else {
      throw NSError(domain: "xcsrclink", code: Int(r.status), userInfo: [
        NSLocalizedDescriptionKey: "dwarfdump failed for \(binary): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      ])
    }
    var seen = Set<String>()
    return r.stdout.split(separator: "\n").map(String.init)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !PathUtil.isSystemPath($0) }
      .map { SourcePath($0).string }
      .filter { seen.insert($0).inserted }
      .sorted()
  }

  /// Groups paths into a few directories that read as "build roots".
  public static func buildRoots(_ paths: [String]) -> [(root: String, count: Int)] {
    var groups: [(prefix: [String], abs: Bool, count: Int)] = []
    for p in paths.map(SourcePath.init).sorted() {
      let dir = Array(p.components.dropLast())
      if let last = groups.indices.last, groups[last].abs == p.isAbsolute {
        let common = zip(groups[last].prefix, dir).prefix { $0 == $1 }.count
        if common >= min(3, groups[last].prefix.count, dir.count), common > 0 {
          groups[last].prefix = Array(dir.prefix(common))
          groups[last].count += 1
          continue
        }
      }
      groups.append((dir, p.isAbsolute, 1))
    }
    return groups.map { (
      SourcePath(isAbsolute: $0.abs, components: $0.prefix).string,
      $0.count
    ) }
  }
}
