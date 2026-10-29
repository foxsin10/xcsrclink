import CryptoKit
import Foundation

/// Where progress messages go. ``Linker`` is silent by default. Pass ``standard`` to
/// print like the CLI does, or your own closures to collect or forward the messages.
public struct Console: Sendable {
  public init(
    info: @escaping @Sendable (String) -> Void,
    warn: @escaping @Sendable (String) -> Void
  ) {
    self.info = info
    self.warn = warn
  }

  /// Info to stdout, warnings to stderr prefixed with `warning: `.
  public static let standard = Console(
    info: { print($0) },
    warn: { FileHandle.standardError.write(Data("warning: \($0)\n".utf8)) }
  )

  /// Drops every message.
  public static let silent = Console(info: { _ in }, warn: { _ in })

  public var info: @Sendable (String) -> Void
  public var warn: @Sendable (String) -> Void
}

/// What ``Linker/link(_:)`` should do.
public struct LinkOptions: Sendable {
  public init(
    input: String,
    sourceRoot: String? = nil,
    strategies: [Strategy] = [.lldbinit]
  ) {
    self.input = input
    self.sourceRoot = sourceRoot
    self.strategies = strategies
  }

  /// The file Xcode's lldb reads: `~/.lldbinit-Xcode` when it exists, else `~/.lldbinit`.
  public static var defaultLLDBInitPath: String {
    LLDBInit.defaultPath
  }

  /// An `.xcframework`, `.framework`, `.a`, `.dSYM`, or a folder containing them.
  /// Relative paths are resolved against the current directory.
  public var input: String
  /// Local checkout of the library's source. Build paths are matched to files under it.
  public var sourceRoot: String?
  /// Build path → local path rules. When not empty, `sourceRoot` isn't searched. Relative
  /// local paths are resolved against the current directory.
  public var explicitMappings: [PathMapping] = []
  public var strategies: [Strategy] = [.lldbinit]
  /// Name of the link. Defaults to the input's file name without extension. Linking again
  /// under the same name replaces the earlier link.
  public var name: String?
  /// lldbinit file for the `lldbinit` strategy. `nil` means ``defaultLLDBInitPath``.
  public var lldbinitPath: String?
  /// Also write `settings set target.inline-breakpoint-strategy always`, which file:line
  /// breakpoints in whole-module builds and headers need.
  public var inlineBreakpoints = true
  /// With the `patch` strategy, move a signed xcframework's `_CodeSignature` aside
  /// (restored on unlink). Without it, patching a signed xcframework throws.
  public var stripSignature = false
  /// Report what would change through the console, and change nothing.
  public var dryRun = false
  /// With an explicit `lldbinitPath`, point Xcode schemes' LLDB Init File at it.
  public var editSchemes = true
  /// Scheme names or `.xcscheme` paths to edit. Empty: every scheme of the project found
  /// at or above the lldbinit file.
  public var schemes: [String] = []
}

/// A folder that many recorded source files share, e.g. the CI checkout.
public struct BuildRoot: Hashable, Sendable {
  public var path: String
  public var fileCount: Int
}

/// What a prebuilt library's debug info says about its sources. See
/// ``Linker/inspect(_:)``.
public struct Inspection: Sendable {
  /// Files carrying DWARF found in the input.
  public var binaries: [DebugBinary]
  /// Source files recorded in each binary, without Xcode, SDK and compiler paths.
  public var sources: [DebugBinary: [String]]
  /// Things that were skipped, e.g. a dynamic framework without a dSYM.
  public var notes: [String]

  /// Every recorded source file, sorted and without duplicates.
  public var allSources: [String] {
    var seen = Set<String>()
    return sources.values.flatMap(\.self).filter { seen.insert($0).inserted }.sorted()
  }

  /// Groups paths into a few folders that read as build roots.
  public static func buildRoots(of paths: [String]) -> [BuildRoot] {
    SourcePathReader.buildRoots(paths)
      .map { BuildRoot(path: $0.root, fileCount: $0.count) }
  }

  var xcframeworks: [String]
}

/// Maps the build-machine paths in prebuilt libraries' debug info to a local checkout, so
/// lldb (and Xcode) find the sources.
///
/// Links are stored in `registry.json` under ``home``, next to backups of patched files.
/// Don't run two linkers on the same home at the same time.
public struct Linker: Sendable {
  public init(home: URL = Linker.defaultHome, console: Console = .silent) {
    self.home = home
    self.console = console
  }

  /// `$XCSRCLINK_HOME` when set, else `~/.xcsrclink`. The `xcsrclink` CLI uses the same
  /// folder, so links made through the library show up in `xcsrclink list` and vice
  /// versa.
  public static var defaultHome: URL {
    if let h = ProcessInfo.processInfo.environment["XCSRCLINK_HOME"], !h.isEmpty {
      return URL(fileURLWithPath: PathUtil.absolute(h))
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".xcsrclink")
  }

  public var console: Console
  /// Folder holding the registry and backups.
  public var home: URL

  // MARK: - Inspect

  /// Finds the binaries with debug info in `input` and reads the source paths they
  /// record.
  public func inspect(_ input: String) throws -> Inspection {
    try Self.requireExists(input)
    let located = DebugBinaryLocator.locate(input)
    var sources: [DebugBinary: [String]] = [:]
    for b in located.binaries {
      sources[b] = try SourcePathReader.sources(in: b.path)
    }
    return Inspection(
      binaries: located.binaries,
      sources: sources,
      notes: located.notes,
      xcframeworks: located.xcframeworks
    )
  }

  // MARK: - List

  /// The current links, oldest first.
  public func links() throws -> [LinkRecord] {
    try Registry.load(home: home).records
  }

  // MARK: - Link

  /// Links `options.input` to local sources and records the link. With `dryRun`, only
  /// reports through the console and returns the record it would create.
  @discardableResult
  public func link(_ o: LinkOptions) throws -> LinkRecord {
    let input = PathUtil.absolute(o.input)
    let name = o.name ?? ((input as NSString).lastPathComponent as NSString)
      .deletingPathExtension

    // Check paths before touching an existing link, so a typo doesn't undo it.
    try Self.requireExists(input)
    if o.explicitMappings.isEmpty, let source = o.sourceRoot.map(PathUtil.absolute),
       !PathUtil.isDirectory(source) {
      throw XcsrcLinkError.sourceFolderNotFound(path: source)
    }

    // Undo a previous link with this name first: a patched binary must be restored before
    // its paths are read again.
    if !o.dryRun,
       try Registry.load(home: home).records.contains(where: { $0.name == name }) {
      console.info("Replacing previous link '\(name)'")
      try unlink(name: name, force: false)
    }

    let inspection = try inspect(input)
    inspection.notes.forEach(console.warn)
    let debugBinaries = inspection.binaries
      .filter { !(inspection.sources[$0] ?? []).isEmpty }
    guard !debugBinaries.isEmpty else {
      throw XcsrcLinkError.noDebugInfo(input: input)
    }
    let originals = inspection.allSources

    // 1. Work out the mappings.
    var mappings = o.explicitMappings.map { PathMapping(
      from: $0.from,
      to: PathUtil.absolute($0.to)
    ) }
    let sourceRoot = o.sourceRoot.map(PathUtil.absolute)
    if mappings.isEmpty {
      guard let sourceRoot else {
        throw XcsrcLinkError.missingSourceOrMappings
      }
      guard PathUtil.isDirectory(sourceRoot) else {
        throw XcsrcLinkError.sourceFolderNotFound(path: sourceRoot)
      }
      let r = MappingResolver.resolve(originals: originals, sourceRoot: sourceRoot)
      mappings = r.mappings
      if !r.ambiguous.isEmpty {
        console
          .warn(
            "\(r.ambiguous.count) file(s) matched several local files equally well and were skipped, e.g. \(r.ambiguous[0]). Give explicit mappings for them."
          )
      }
      if !r.unmatched.isEmpty {
        console
          .warn(
            "\(r.unmatched.count) of \(originals.count) source file(s) have no match under \(sourceRoot), e.g. \(r.unmatched[0])"
          )
      }
    }
    mappings = MappingResolver.simplify(mappings)
    guard !mappings.isEmpty else {
      throw XcsrcLinkError.noMatchingSources(
        input: input,
        recordedFiles: originals.count,
        sourceRoot: sourceRoot ?? "?"
      )
    }

    let covered = originals.compactMap { PathMapping.apply(mappings, to: $0) }
    let existing = covered.filter { FileManager.default.fileExists(atPath: $0) }
    console
      .info("Mappings (\(existing.count)/\(originals.count) source files found locally):")
    for m in mappings {
      console.info("  \(m.from)\n    -> \(m.to)")
    }

    var record = LinkRecord(
      name: name,
      input: input,
      sourceRoot: sourceRoot,
      strategies: o.strategies,
      mappings: mappings,
      createdAt: Date(),
      lldbinitPath: nil,
      inlineBreakpoints: o.inlineBreakpoints
    )

    if o.strategies
      .contains(.patch) {
      try DWARFPatcher.validate(MappingResolver.widened(mappings))
    }
    if o.dryRun {
      try dryRun(record, binaries: debugBinaries, options: o)
      return record
    }

    // 2. Apply. On failure, undo what was done so far.
    var registry = try Registry.load(home: home)
    do {
      for s in [Strategy.patch, .symlink, .lldbinit] where o.strategies.contains(s) {
        switch s {
        case .patch: try applyPatch(
            &record,
            binaries: debugBinaries,
            xcframeworks: inspection.xcframeworks,
            stripSignature: o.stripSignature
          )
        case .symlink: try applySymlinks(&record)
        case .lldbinit: record.lldbinitPath = PathUtil
          .absolute(o.lldbinitPath ?? LLDBInit.defaultPath)
        }
      }
      if let path = record.lldbinitPath, o.lldbinitPath != nil, o.editSchemes {
        try applySchemes(&record, lldbinit: path, only: o.schemes)
      }
      registry.records.append(record)
      try registry.save(home: home)
      if let path = record.lldbinitPath {
        try refreshLLDBInit(path, registry: registry)
        console
          .info("Updated \(PathUtil.tildeAbbreviated(path)) (source-map for '\(name)')")
      }
    } catch {
      revertSchemes(record.schemes ?? [])
      try? rollback(record)
      if var r = try? Registry.load(home: home),
         r.records.contains(where: { $0.name == name }) {
        r.records.removeAll { $0.name == name }
        try? r.save(home: home)
        if let path = record.lldbinitPath {
          try? refreshLLDBInit(path, registry: r)
        }
      }
      throw error
    }

    console
      .info(
        "\nDone. Restart the debug session in Xcode\(o.strategies.contains(.patch) ? " and rebuild so the patched library is relinked" : "")."
      )
    return record
  }

  // MARK: - Unlink

  /// Removes everything ``link(_:)`` did for this link. A patched file that changed since
  /// (e.g. an updated library) is left alone unless `force` is set.
  public func unlink(name: String, force: Bool = false) throws {
    var registry = try Registry.load(home: home)
    guard let idx = registry.records.firstIndex(where: { $0.name == name }) else {
      throw XcsrcLinkError.noLink(name: name)
    }
    let record = registry.records[idx]
    try restore(record, force: force)
    registry.records.remove(at: idx)
    // Schemes point at the lldbinit file, not at one library: keep them while another
    // link still writes to that file, and hand them to it so its unlink reverts them.
    var schemesToRevert = record.schemes ?? []
    if !schemesToRevert.isEmpty,
       let other = registry.records
         .firstIndex(where: { $0.lldbinitPath == record.lldbinitPath }) {
      registry.records[other]
        .schemes = (registry.records[other].schemes ?? []) + schemesToRevert
      schemesToRevert = []
    }
    try registry.save(home: home)
    revertSchemes(schemesToRevert)
    if let path = record.lldbinitPath {
      try refreshLLDBInit(path, registry: registry)
      console
        .info("Removed source-map for '\(name)' from \(PathUtil.tildeAbbreviated(path))")
    }
    try? FileManager.default
      .removeItem(at: backupRoot.appendingPathComponent(safeName(name)))
    console.info("Unlinked '\(name)'")
  }

  /// Unlinks every link and returns their names.
  @discardableResult
  public func unlinkAll(force: Bool = false) throws -> [String] {
    let names = try links().map(\.name)
    for n in names {
      try unlink(name: n, force: force)
    }
    return names
  }

  // MARK: - Schemes

  struct SchemeTarget { var scheme: String; var value: String }

  static func requireExists(_ input: String) throws {
    let path = PathUtil.absolute(input)
    guard FileManager.default.fileExists(atPath: path) else {
      throw XcsrcLinkError.notFound(path: path)
    }
  }

  func schemeTargets(lldbinit: String, only: [String]) throws -> [SchemeTarget] {
    var targets: [SchemeTarget] = []
    let paths = only.filter { $0.hasSuffix(".xcscheme") }
    let names = only.filter { !$0.hasSuffix(".xcscheme") }
    for p in paths.map(PathUtil.absolute) {
      guard FileManager.default.fileExists(atPath: p) else {
        throw XcsrcLinkError.schemeNotFound(path: p)
      }
      guard let dir = XcodeScheme.projectDir(ofScheme: p) else {
        throw XcsrcLinkError.schemeOutsideProject(path: p)
      }
      targets.append(SchemeTarget(
        scheme: p,
        value: XcodeScheme.value(for: lldbinit, projectDir: dir)
      ))
    }
    guard paths.isEmpty || !names.isEmpty else {
      return targets
    }

    guard let found = XcodeScheme.find(near: lldbinit), !found.schemes.isEmpty else {
      console.warn("""
        no saved Xcode scheme found at or above \(PathUtil.tildeAbbreviated(lldbinit)), so no scheme was changed. \
        Pass the .xcscheme path, or set Edit Scheme › Run › Info › LLDB Init File to this file yourself.
        """)
      return targets
    }
    var schemes = found.schemes
    if !names.isEmpty {
      schemes = schemes.filter { names.contains(XcodeScheme.name(of: $0)) }
      let missing = Set(names).subtracting(schemes.map(XcodeScheme.name(of:)))
      if !missing.isEmpty {
        throw XcsrcLinkError.unknownSchemes(
          names: missing.sorted(),
          projectDir: found.projectDir,
          available: found.schemes.map(XcodeScheme.name(of:))
        )
      }
    }
    let value = XcodeScheme.value(for: lldbinit, projectDir: found.projectDir)
    targets += schemes.map { SchemeTarget(scheme: $0, value: value) }
    return targets
  }

  private var backupRoot: URL {
    home.appendingPathComponent("backups")
  }

  private func dryRun(
    _ record: LinkRecord,
    binaries: [DebugBinary],
    options o: LinkOptions
  ) throws {
    console.info("\nDry run, nothing was changed.")
    if o.strategies.contains(.patch) {
      for b in binaries {
        let counts = try DWARFPatcher.patchFile(
          at: b.path,
          mappings: MappingResolver.widened(record.mappings),
          dryRun: true
        )
        console.info("  would patch \(counts.reduce(0, +)) path string(s) in \(b.path)")
      }
    }
    if o.strategies.contains(.symlink) {
      for m in record.mappings {
        console.info("  would symlink \(m.from) -> \(m.to)")
      }
    }
    if o.strategies.contains(.lldbinit) {
      let path = PathUtil.absolute(o.lldbinitPath ?? LLDBInit.defaultPath)
      var r = record
      r.lldbinitPath = path
      console
        .info("  would write to \(PathUtil.tildeAbbreviated(path)):\n" +
          (LLDBInit.render([r]) ?? ""))
      if o.lldbinitPath != nil, o.editSchemes {
        for t in try schemeTargets(lldbinit: path, only: o.schemes) {
          console
            .info(
              "  would set LLDB Init File of scheme '\(XcodeScheme.name(of: t.scheme))' to \(t.value) (\(PathUtil.tildeAbbreviated(t.scheme)))"
            )
        }
      }
    }
  }

  private func applySchemes(
    _ record: inout LinkRecord,
    lldbinit: String,
    only: [String]
  ) throws {
    var edits: [SchemeEdit] = []
    defer { record.schemes = edits.isEmpty ? nil : edits }
    for t in try schemeTargets(lldbinit: lldbinit, only: only) {
      let name = XcodeScheme.name(of: t.scheme)
      let xml = try String(contentsOfFile: t.scheme, encoding: .utf8)
      switch XcodeScheme.lldbInitFile(in: xml) {
      case nil:
        console.warn("scheme '\(name)' has no Run action, skipping it")
      case .some(t.value)?:
        console.info("Scheme '\(name)' already uses \(t.value)")
      case let .some(other?):
        console.warn("""
          scheme '\(name)' already uses LLDB Init File \(other), leaving it. \
          Add `command source \(PathUtil.tildeAbbreviated(lldbinit))` to that file instead.
          """)
      case .some(nil):
        guard let updated = XcodeScheme.setting(t.value, in: xml) else {
          continue
        }
        try updated.write(toFile: t.scheme, atomically: true, encoding: .utf8)
        edits.append(SchemeEdit(path: t.scheme, value: t.value))
        console.info("Set LLDB Init File of scheme '\(name)' to \(t.value)")
      }
    }
  }

  /// Removes the LLDB Init File from these schemes, unless it was changed since.
  private func revertSchemes(_ edits: [SchemeEdit]) {
    for e in edits {
      let name = XcodeScheme.name(of: e.path)
      guard let xml = try? String(contentsOfFile: e.path, encoding: .utf8) else {
        continue
      }
      guard case .some(e.value)? = XcodeScheme.lldbInitFile(in: xml) else {
        console.warn("scheme '\(name)' no longer uses \(e.value), leaving it")
        continue
      }
      guard let updated = XcodeScheme.setting(nil, in: xml),
            (try? updated.write(toFile: e.path, atomically: true, encoding: .utf8)) !=
            nil else {
        console.warn("couldn't update scheme '\(name)' at \(e.path)")
        continue
      }
      console.info("Removed LLDB Init File from scheme '\(name)'")
    }
  }

  // MARK: - Strategies

  private func applyPatch(
    _ record: inout LinkRecord,
    binaries: [DebugBinary],
    xcframeworks: [String],
    stripSignature: Bool
  ) throws {
    let fm = FileManager.default
    // Patching changes the bytes of a signed xcframework, and Xcode then refuses it.
    for xcf in xcframeworks {
      let sig = (xcf as NSString).appendingPathComponent("_CodeSignature")
      guard fm.fileExists(atPath: sig) else {
        continue
      }
      guard stripSignature else {
        throw XcsrcLinkError.signedXCFramework(path: xcf)
      }
      let backup = try backupDirectory(for: record.name)
        .appendingPathComponent("signature-\(record.movedSignatures.count)").path
      try fm.moveItem(atPath: sig, toPath: backup)
      record.movedSignatures[sig] = backup
      console.info("Moved code signature aside: \(sig)")
    }

    let backups = try backupDirectory(for: record.name)
    for (i, b) in binaries.enumerated() {
      let backup = backups
        .appendingPathComponent("\(i)-\((b.path as NSString).lastPathComponent)").path
      if fm.fileExists(atPath: backup) {
        try fm.removeItem(atPath: backup)
      }
      try fm.copyItem(atPath: b.path, toPath: backup)
      let counts = try DWARFPatcher.patchFile(
        at: b.path,
        mappings: MappingResolver.widened(record.mappings)
      )
      let total = counts.reduce(0, +)
      if total == 0 {
        try? fm.removeItem(atPath: backup)
        continue
      }
      try record.patchedFiles.append(PatchedFile(
        path: b.path,
        backup: backup,
        patchedSHA256: sha256(b.path)
      ))
      console.info("Patched \(total) path string(s) in \(b.path)")
    }
    warnAboutUnpatchedCopies(of: record.patchedFiles)
  }

  /// lldb finds a dSYM by its UUID through Spotlight, so an older copy elsewhere
  /// (DerivedData from an earlier build, another checkout) can be loaded instead of the
  /// patched one, and still shows the build machine's paths.
  private func warnAboutUnpatchedCopies(of patched: [PatchedFile]) {
    let patchedPaths = Set(patched.map { SourcePath($0.path) })
    var stale = Set<String>()
    for p in patched where p.path.contains(".dSYM/Contents/Resources/DWARF/") {
      guard let r = try? Shell.run("/usr/bin/xcrun", ["dwarfdump", "--uuid", p.path]),
            r.status == 0 else {
        continue
      }
      let uuids = r.stdout.split(separator: "\n").compactMap { line -> String? in
        let parts = line.split(separator: " ")
        return parts.count > 1 && parts[0] == "UUID:" ? String(parts[1]) : nil
      }
      let dwarfName = (p.path as NSString).lastPathComponent
      for uuid in uuids {
        guard let found = try? Shell.run(
          "/usr/bin/mdfind",
          ["com_apple_xcode_dsym_uuids == \(uuid)"]
        ) else {
          continue
        }
        for bundle in found.stdout.split(separator: "\n").map(String.init) {
          let file = (bundle as NSString)
            .appendingPathComponent("Contents/Resources/DWARF/\(dwarfName)")
          guard !patchedPaths.contains(SourcePath(file)),
                FileManager.default.fileExists(atPath: file),
                (try? sha256(file)) != p.patchedSHA256 else {
            continue
          }
          stale.insert(bundle)
        }
      }
    }
    guard !stale.isEmpty else {
      return
    }
    console.warn("""
      Other copies of the patched dSYM still have the build machine's paths. lldb finds dSYMs \
      by UUID and may load one of them instead. Rebuild the project each belongs to (Xcode \
      copies the dSYM again), or delete it:
      """ + stale.sorted().map { "\n  \(PathUtil.tildeAbbreviated($0))" }.joined())
  }

  private func applySymlinks(_ record: inout LinkRecord) throws {
    let fm = FileManager.default
    for m in record.mappings {
      guard m.from.hasPrefix("/") else {
        console.warn("skipping symlink for relative build path '\(m.from)'")
        continue
      }
      if let dest = try? fm.destinationOfSymbolicLink(atPath: m.from) {
        if PathUtil.absolute(dest) == m.to {
          continue
        }
        throw XcsrcLinkError.symlinkConflict(path: m.from, destination: dest)
      }
      if fm.fileExists(atPath: m.from) {
        throw XcsrcLinkError.pathExists(path: m.from)
      }
      // Create missing parents one by one so unlink can remove exactly those.
      var missing: [String] = []
      var dir = (m.from as NSString).deletingLastPathComponent
      while !fm.fileExists(atPath: dir), dir != "/" {
        missing.insert(dir, at: 0)
        dir = (dir as NSString).deletingLastPathComponent
      }
      do {
        for d in missing {
          try fm.createDirectory(atPath: d, withIntermediateDirectories: false)
          record.createdDirectories.append(d)
        }
        try fm.createSymbolicLink(atPath: m.from, withDestinationPath: m.to)
        record.symlinks.append(m.from)
        console.info("Symlinked \(m.from) -> \(m.to)")
      } catch {
        let parent = missing.first ?? (m.from as NSString).deletingLastPathComponent
        throw XcsrcLinkError.cannotCreateSymlink(
          path: m.from,
          parent: parent,
          reason: error.localizedDescription
        )
      }
    }
  }

  private func rollback(_ record: LinkRecord) throws {
    try restore(record, force: true)
  }

  private func restore(_ record: LinkRecord, force: Bool) throws {
    let fm = FileManager.default
    for p in record.patchedFiles {
      guard fm.fileExists(atPath: p.backup) else {
        console.warn("backup missing for \(p.path), leaving it patched")
        continue
      }
      if !force, fm.fileExists(atPath: p.path), (try? sha256(p.path)) != p.patchedSHA256 {
        console
          .warn(
            "\(p.path) changed since it was patched (updated library?), not restoring it. Unlink with force to restore it anyway."
          )
        continue
      }
      if fm.fileExists(atPath: p.path) {
        try fm.removeItem(atPath: p.path)
      }
      try fm.copyItem(atPath: p.backup, toPath: p.path)
      console.info("Restored \(p.path)")
    }
    for (original, backup) in record.movedSignatures
      where !fm.fileExists(atPath: original) {
      try fm.moveItem(atPath: backup, toPath: original)
      console.info("Restored code signature: \(original)")
    }
    for link in record.symlinks.reversed() {
      if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
        try fm.removeItem(atPath: link)
        console.info("Removed symlink \(link)")
      }
    }
    for dir in record.createdDirectories.reversed() {
      if (try? fm.contentsOfDirectory(atPath: dir))?
        .isEmpty == true {
        try? fm.removeItem(atPath: dir)
      }
    }
  }

  // MARK: - Helpers

  private func refreshLLDBInit(_ path: String, registry: Registry) throws {
    let records = registry.records.filter { $0.lldbinitPath == path }
    try LLDBInit.write(block: LLDBInit.render(records), to: path)
  }

  private func safeName(_ name: String) -> String {
    name
      .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_"
      }.map(String.init).joined()
  }

  private func backupDirectory(for name: String) throws -> URL {
    let dir = backupRoot.appendingPathComponent(safeName(name))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func sha256(_ path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
