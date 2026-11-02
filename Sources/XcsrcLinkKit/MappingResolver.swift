import Foundation

/// Works out "build root → local root" mappings by matching each recorded source file
/// against files in a local checkout, using the longest shared path tail.
///
/// `/ci/job-7/MyLib/Sources/Foo.swift` + local `~/src/MyLib/Sources/Foo.swift` share
/// `MyLib/Sources/Foo.swift`, which gives `/ci/job-7 -> ~/src`.
enum MappingResolver {
  struct Result {
    /// Ordered most specific first (the order lldb and the patcher should apply them in).
    var mappings: [PathMapping] = []
    var matched: [(original: String, local: String)] = []
    var unmatched: [String] = []
    /// Files with several equally good local candidates.
    var ambiguous: [String] = []
  }

  static let sourceExtensions: Set<String> = [
    "swift", "m", "mm", "c", "cc", "cpp", "cxx", "c++", "h", "hh", "hpp", "hxx", "inc",
    "def",
    "s", "metal"
  ]
  static let skippedDirectories: Set<String> = [
    ".git",
    ".build",
    "DerivedData",
    ".swiftpm",
    "node_modules",
    ".svn",
    ".hg"
  ]
  static let skippedBundles: Set<String> = [
    "xcframework",
    "framework",
    "dsym",
    "xcodeproj",
    "xcworkspace",
    "xcassets"
  ]

  /// basename → local files with that basename.
  static func index(sourceRoot: String) -> [String: [SourcePath]] {
    var idx: [String: [SourcePath]] = [:]
    let root = PathUtil.absolute(sourceRoot)
    guard let e = FileManager.default.enumerator(atPath: root) else {
      return idx
    }
    while let rel = e.nextObject() as? String {
      let name = (rel as NSString).lastPathComponent
      let ext = (name as NSString).pathExtension.lowercased()
      if skippedDirectories.contains(name) || skippedBundles.contains(ext) {
        e.skipDescendants()
        continue
      }
      guard sourceExtensions.contains(ext) else {
        continue
      }
      idx[name, default: []]
        .append(SourcePath((root as NSString).appendingPathComponent(rel)))
    }
    return idx
  }

  static func resolve(originals: [String], sourceRoot: String) -> Result {
    resolve(
      originals: originals,
      index: index(sourceRoot: sourceRoot),
      sourceRoot: SourcePath(PathUtil.absolute(sourceRoot))
    )
  }

  /// `sourceRoot` caps every mapping's local side at that folder, so a mapping never
  /// covers files outside the checkout (e.g. the app's own sources next to it). lldb
  /// applies source maps in reverse to breakpoints, so a too-broad mapping would move
  /// breakpoints in unrelated files to the build path where they can't bind.
  static func resolve(
    originals: [String],
    index: [String: [SourcePath]],
    sourceRoot: SourcePath? = nil
  ) -> Result {
    var result = Result()
    struct Pick {
      let original: SourcePath
      let local: SourcePath
      let shared: Int
      /// Only the file name matched, no parent folder.
      var nameOnly = false
    }
    var picks: [Pick] = []

    for raw in originals {
      let p = SourcePath(raw)
      guard let base = p.components.last, let candidates = index[base] else {
        result.unmatched.append(raw)
        continue
      }
      let scored = candidates.map { ($0, sharedTail(p.components, $0.components)) }
      let best = scored.map(\.1).max() ?? 0
      let top = scored.filter { $0.1 == best }
      if top.count > 1 {
        // A tie on the file name alone means unrelated files, not a real choice.
        if best <= 1 {
          result.unmatched.append(raw)
        } else {
          result.ambiguous.append(raw)
        }
        continue
      }
      var keep = best
      if let root = sourceRoot, top[0].0.hasPrefix(root) {
        keep = min(keep, top[0].0.components.count - root.components.count)
      }
      picks.append(Pick(
        original: p,
        local: top[0].0,
        shared: keep,
        nameOnly: best <= 1
      ))
    }

    // A match on the file name alone is weak: SwiftPM packages are full of files like
    // `Macros.swift` and `Exports.swift`. Trust one only when at least two files, and at
    // least half of those recorded in its folder, land in the same local folder (a
    // renamed folder). Otherwise one shared name would map a whole module to an
    // unrelated folder.
    struct FolderPair: Hashable { let original: SourcePath; let local: SourcePath }
    var recordedPerFolder: [SourcePath: Int] = [:]
    for raw in originals {
      recordedPerFolder[SourcePath(raw).dropLast(1), default: 0] += 1
    }
    var landed: [FolderPair: Int] = [:]
    for pick in picks {
      landed[
        FolderPair(original: pick.original.dropLast(1), local: pick.local.dropLast(1)),
        default: 0
      ] += 1
    }
    picks.removeAll { pick in
      guard pick.nameOnly else {
        return false
      }
      let folder = pick.original.dropLast(1)
      let agreeing = landed[FolderPair(original: folder, local: pick.local.dropLast(1))]
        ?? 0
      let trusted = agreeing >= 2 && agreeing * 2 >= recordedPerFolder[folder, default: 0]
      if !trusted {
        result.unmatched.append(pick.original.string)
      }
      return !trusted
    }

    // Vote for one local root per build root.
    var votes: [PathMapping: Int] = [:]
    for pick in picks {
      let m = mapping(pick.original, pick.local, keep: pick.shared)
      if m.from != m.to {
        votes[m, default: 0] += 1
      }
    }
    var winner: [String: PathMapping] = [:]
    for (m, n) in votes
      .sorted(by: {
        $0.value > $1.value || ($0.value == $1.value && $0.key.to < $1.key.to) }) {
      if winner[m.from] == nil || votes[winner[m.from]!]! < n {
        winner[m.from] = m
      }
    }
    var mappings = Set(winner.values)

    // Files that disagree with their root's winner get a narrower mapping of their own.
    for pick in picks {
      let m = mapping(pick.original, pick.local, keep: pick.shared)
      guard m.from != m.to, winner[m.from] != m else {
        continue
      }
      mappings.insert(mapping(pick.original, pick.local, keep: max(pick.shared - 1, 0)))
    }

    result.mappings = simplify(Array(mappings))
    for pick in picks {
      result.matched.append((
        pick.original.string,
        PathMapping.apply(result.mappings, to: pick.original.string) ?? pick.original
          .string
      ))
    }
    return result
  }

  /// Number of trailing components two paths share.
  static func sharedTail(_ a: [String], _ b: [String]) -> Int {
    zip(a.reversed(), b.reversed()).prefix { $0 == $1 }.count
  }

  /// For `patch`: turns `/ci/job/Lib -> /me/proj/Lib` into `/ci/job -> /me/proj` by
  /// dropping the shared trailing folders. It maps every path the narrow one does to the
  /// same place, and also covers compile folders (DW_AT_comp_dir, line-table dir 0) that
  /// sit above the source folder when the compiler recorded relative file paths. Only
  /// safe for rewriting the vendor binaries, not for lldb source maps.
  static func widened(_ mappings: [PathMapping]) -> [PathMapping] {
    simplify(mappings.map { m in
      var from = SourcePath(m.from).components, to = SourcePath(m.to).components
      while from.count > 1, to.count > 1, from.last == to.last {
        from.removeLast(); to.removeLast()
      }
      return PathMapping(
        from: "/" + from.joined(separator: "/"),
        to: "/" + to.joined(separator: "/")
      )
    })
  }

  /// Drops mappings already implied by a broader one, and orders most specific first.
  static func simplify(_ mappings: [PathMapping]) -> [PathMapping] {
    let sorted = mappings.sorted {
      let a = SourcePath($0.from).components.count,
          b = SourcePath($1.from).components.count
      return a != b ? a > b : $0.from < $1.from
    }
    return sorted.filter { m in
      !sorted.contains { other in
        other != m && SourcePath(m.from).hasPrefix(SourcePath(other.from))
          && SourcePath(other.from).components.count < SourcePath(m.from).components.count
          && other.apply(to: m.from) == m.to
      }
    }
  }

  private static func mapping(
    _ original: SourcePath,
    _ local: SourcePath,
    keep shared: Int
  ) -> PathMapping {
    PathMapping(from: original.dropLast(shared).string, to: local.dropLast(shared).string)
  }
}
