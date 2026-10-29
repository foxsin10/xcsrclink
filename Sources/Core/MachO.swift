import Foundation

/// Minimal reader that finds where DWARF sections live inside a file. Understands thin
/// Mach-O (32/64-bit), fat/universal binaries and `ar` static archives, including
/// archives inside fat files. Only file offsets are returned; nothing is decoded.
public enum MachO {
  public enum FileKind: String, Codable, Sendable {
    case archive
    case fat
    case machO
    case unknown
  }

  public static func kind(of bytes: UnsafeRawBufferPointer) -> FileKind {
    if bytes.count >= 8,
       Array(bytes[0 ..< 8]) == Array("!<arch>\n".utf8) {
      return .archive
    }
    guard bytes.count >= 8 else {
      return .unknown
    }
    let le = bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
    if le == 0xFEED_FACF || le == 0xFEED_FACE {
      return .machO
    }
    let be = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
    if be == 0xCAFE_BABE || be == 0xCAFE_BABF {
      // Java class files share 0xCAFEBABE; real fat headers have few architectures.
      let n = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
      if n > 0, n < 64 {
        return .fat
      }
    }
    return .unknown
  }

  public static func kind(ofFileAt path: String) -> FileKind {
    guard let handle = FileHandle(forReadingAtPath: path) else {
      return .unknown
    }
    defer { try? handle.close() }
    let head = handle.readData(ofLength: 8)
    return head.withUnsafeBytes { kind(of: $0) }
  }

  /// True for an `ar` archive, or a fat file whose slices are archives (what
  /// `lipo -create` makes from per-arch `.a` files, the usual vendor shape).
  public static func isStaticArchive(fileAt path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else {
      return false
    }
    defer { try? handle.close() }
    let head = handle.readData(ofLength: 32)
    let firstSliceOffset: UInt64? = head.withUnsafeBytes { b in
      switch kind(of: b) {
      case .archive: return 0
      case .fat where b.count >= 32:
        // The first fat_arch / fat_arch_64 entry starts at byte 8; its offset field at
        // byte 16.
        let is64 = UInt32(
          bigEndian: b.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        ) ==
          0xCAFE_BABF
        return is64
          ? UInt64(bigEndian: b.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
          : UInt64(UInt32(bigEndian: b.loadUnaligned(
            fromByteOffset: 16,
            as: UInt32.self
          )))
      default: return nil
      }
    }
    guard let offset = firstSliceOffset else {
      return false
    }
    if offset == 0 {
      return true
    }
    guard (try? handle.seek(toOffset: offset)) != nil else {
      return false
    }
    return handle.readData(ofLength: 8).withUnsafeBytes { kind(of: $0) } == .archive
  }

  /// File-offset ranges of every section in the `__DWARF` segment.
  public static func dwarfSectionRanges(in bytes: UnsafeRawBufferPointer)
    -> [Range<Int>] {
    var result: [Range<Int>] = []
    collect(bytes, start: 0, end: bytes.count, depth: 0, into: &result)
    return result
  }

  public static func hasDWARF(fileAt path: String) -> Bool {
    guard let data = FileManager.default.contents(atPath: path) else {
      return false
    }
    return data.withUnsafeBytes { !dwarfSectionRanges(in: $0).isEmpty }
  }

  // MARK: - Parsing

  private static func collect(
    _ b: UnsafeRawBufferPointer,
    start: Int,
    end: Int,
    depth: Int,
    into out: inout [Range<Int>]
  ) {
    guard depth < 3, start >= 0, end <= b.count, end - start >= 8 else {
      return
    }
    let slice = UnsafeRawBufferPointer(rebasing: b[start ..< end])
    switch kind(of: slice) {
    case .archive: archive(b, start: start, end: end, depth: depth, into: &out)
    case .fat: fat(b, start: start, end: end, depth: depth, into: &out)
    case .machO: thin(b, start: start, end: end, into: &out)
    case .unknown: break
    }
  }

  private static func archive(
    _ b: UnsafeRawBufferPointer,
    start: Int,
    end: Int,
    depth: Int,
    into out: inout [Range<Int>]
  ) {
    var off = start + 8
    while off + 60 <= end {
      let name = ascii(b, off, 16)
      guard let size = Int(ascii(b, off + 48, 10)), size >= 0,
            off + 60 + size <= end else {
        return
      }
      var dataStart = off + 60
      if name.hasPrefix("#1/"), let n = Int(name.dropFirst(3)), n <= size {
        dataStart += n // BSD long member name stored in front of the data
      }
      if !name.hasPrefix("__.SYMDEF"), name != "/", name != "//" {
        collect(b, start: dataStart, end: off + 60 + size, depth: depth + 1, into: &out)
      }
      off += 60 + size
      if off % 2 == 1 {
        off += 1
      }
    }
  }

  private static func fat(
    _ b: UnsafeRawBufferPointer,
    start: Int,
    end: Int,
    depth: Int,
    into out: inout [Range<Int>]
  ) {
    let magic = be32(b, start)
    let is64 = magic == 0xCAFE_BABF
    let count = Int(be32(b, start + 4))
    let entrySize = is64 ? 32 : 20
    for i in 0 ..< count {
      let e = start + 8 + i * entrySize
      guard e + entrySize <= end else {
        return
      }
      let offset = is64 ? Int(be64(b, e + 8)) : Int(be32(b, e + 8))
      let size = is64 ? Int(be64(b, e + 16)) : Int(be32(b, e + 12))
      collect(
        b,
        start: start + offset,
        end: min(end, start + offset + size),
        depth: depth + 1,
        into: &out
      )
    }
  }

  private static func thin(
    _ b: UnsafeRawBufferPointer,
    start: Int,
    end: Int,
    into out: inout [Range<Int>]
  ) {
    let magic = le32(b, start)
    let is64 = magic == 0xFEED_FACF
    let ncmds = Int(le32(b, start + 16))
    var cmd = start + (is64 ? 32 : 28)
    for _ in 0 ..< ncmds {
      guard cmd + 8 <= end else {
        return
      }
      let type = le32(b, cmd)
      let size = Int(le32(b, cmd + 4))
      guard size >= 8, cmd + size <= end else {
        return
      }
      if type == 0x19 || type == 0x1 { // LC_SEGMENT_64 / LC_SEGMENT
        let nsects = Int(le32(b, cmd + (is64 ? 64 : 48)))
        let sectSize = is64 ? 80 : 68
        var s = cmd + (is64 ? 72 : 56)
        for _ in 0 ..< nsects {
          guard s + sectSize <= cmd + size else {
            break
          }
          if ascii(b, s + 16, 16) == "__DWARF" {
            let length = is64 ? Int(le64(b, s + 40)) : Int(le32(b, s + 36))
            let offset = Int(le32(b, s + (is64 ? 48 : 40)))
            let lo = start + offset
            if offset > 0, length > 0,
               lo + length <= end {
              out.append(lo ..< (lo + length))
            }
          }
          s += sectSize
        }
      }
      cmd += size
    }
  }

  // MARK: - Byte helpers

  private static func ascii(
    _ b: UnsafeRawBufferPointer,
    _ off: Int,
    _ len: Int
  ) -> String {
    let raw = b[off ..< (off + len)].prefix { $0 != 0 }
    return String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespaces)
  }

  private static func le32(
    _ b: UnsafeRawBufferPointer,
    _ o: Int
  ) -> UInt32 {
    b.loadUnaligned(
      fromByteOffset: o,
      as: UInt32.self
    ).littleEndian }

  private static func le64(
    _ b: UnsafeRawBufferPointer,
    _ o: Int
  ) -> UInt64 {
    b.loadUnaligned(
      fromByteOffset: o,
      as: UInt64.self
    ).littleEndian }

  private static func be32(
    _ b: UnsafeRawBufferPointer,
    _ o: Int
  ) -> UInt32 {
    UInt32(bigEndian: b.loadUnaligned(
      fromByteOffset: o,
      as: UInt32.self
    )) }

  private static func be64(
    _ b: UnsafeRawBufferPointer,
    _ o: Int
  ) -> UInt64 {
    UInt64(bigEndian: b.loadUnaligned(
      fromByteOffset: o,
      as: UInt64.self
    )) }
}
