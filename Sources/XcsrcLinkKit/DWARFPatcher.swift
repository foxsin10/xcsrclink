import Foundation

/// Rewrites source paths inside DWARF sections without changing any sizes or offsets.
///
/// Each occurrence of `from` that sits on a path boundary is overwritten with `to`, and
/// the leftover bytes are filled with `/`. lldb normalizes `a////b` to `a/b`, so the
/// padded path resolves to the local file.
enum DWARFPatcher {
  static let padByte = UInt8(ascii: "/")

  static func validate(_ mappings: [PathMapping]) throws {
    for m in mappings {
      guard m.from.hasPrefix("/"),
            m.to.hasPrefix("/") else {
        throw XcsrcLinkError.relativeBuildPath(m)
      }
      let extra = m.to.utf8.count - m.from.utf8.count
      if extra > 0 {
        throw XcsrcLinkError.replacementTooLong(m, extraBytes: extra)
      }
    }
  }

  /// Patches `data` in place. Returns how many strings each mapping rewrote (same order
  /// as `mappings`).
  @discardableResult
  static func patch(_ data: inout Data, mappings: [PathMapping]) throws -> [Int] {
    try validate(mappings)
    // Most specific first, so `/a/b/c` wins over `/a`.
    let order = mappings.indices
      .sorted { mappings[$0].from.utf8.count > mappings[$1].from.utf8.count }
    let froms = mappings.map { Array($0.from.utf8) }
    let tos = mappings.map { m -> [UInt8] in
      var t = Array(m.to.utf8)
      t += [UInt8](repeating: padByte, count: m.from.utf8.count - t.count)
      return t
    }
    var counts = [Int](repeating: 0, count: mappings.count)

    data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
      let ranges = MachO.dwarfSectionRanges(in: UnsafeRawBufferPointer(buf))
      for range in ranges {
        var i = range.lowerBound
        while i < range.upperBound {
          // Jump to the next '/', where every absolute path starts.
          guard let hit = memchr(
            buf.baseAddress! + i,
            Int32(padByte),
            range.upperBound - i
          ) else {
            break
          }
          i = buf.baseAddress!.distance(to: UnsafeMutableRawPointer(hit))
          var advanced = false
          if i == range.lowerBound || !isPathByte(buf[i - 1]) {
            for k in order {
              let f = froms[k]
              let endIdx = i + f.count
              guard endIdx <= range.upperBound,
                    endIdx == range
                      .upperBound || buf[endIdx] == 0 || buf[endIdx] == padByte else {
                continue
              }
              if memcmp(buf.baseAddress! + i, f, f.count) == 0 {
                tos[k].withUnsafeBytes { src in
                  (buf.baseAddress! + i).copyMemory(
                    from: src.baseAddress!,
                    byteCount: f.count
                  )
                }
                counts[k] += 1
                i = endIdx
                advanced = true
                break
              }
            }
          }
          if !advanced {
            i += 1
          }
        }
      }
    }
    return counts
  }

  /// Reads, patches and atomically rewrites a file. With `dryRun`, only counts.
  static func patchFile(
    at path: String,
    mappings: [PathMapping],
    dryRun: Bool = false
  ) throws -> [Int] {
    guard var data = FileManager.default.contents(atPath: path) else {
      throw XcsrcLinkError.unreadable(path: path)
    }
    let counts = try patch(&data, mappings: mappings)
    if !dryRun, counts.contains(where: { $0 > 0 }) {
      let attrs = try? FileManager.default.attributesOfItem(atPath: path)
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      if let perms = attrs?[.posixPermissions] {
        try? FileManager.default.setAttributes(
          [.posixPermissions: perms],
          ofItemAtPath: path
        )
      }
    }
    return counts
  }

  /// A byte that can appear inside a path. A match preceded by one of these is the tail
  /// of a longer path (e.g. `/x/foo` when looking for `/foo`) and must not be rewritten.
  private static func isPathByte(_ c: UInt8) -> Bool {
    switch c {
    case UInt8(ascii: "a") ... UInt8(ascii: "z"),
         UInt8(ascii: "A") ... UInt8(ascii: "Z"),
         UInt8(ascii: "0") ... UInt8(ascii: "9"):
      true
    default:
      "/._-~+@ ".utf8.contains(c)
    }
  }
}
