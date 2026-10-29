import Foundation
import XcsrcLinkKit

/// Commands ``XcsrcLinkCLI/run(_:context:)`` can parse from a command line.
protocol ParsableCommand: XcsrcLinkCommand {
  static var spec: ArgumentSpec { get }
  init(parsed: Arguments) throws
}

// MARK: - info

/// `xcsrclink info <path> [--files] [--copies]`: the binaries with debug info in `path`
/// and the source files they record.
public struct InfoCommand: ParsableCommand {
  public init(path: String, showFiles: Bool = false, showCopies: Bool = false) {
    self.path = path
    self.showFiles = showFiles
    self.showCopies = showCopies
  }

  public init(arguments: [String]) throws {
    try self.init(parsed: Arguments(arguments, spec: Self.spec))
  }

  init(parsed args: Arguments) throws {
    guard let path = args.positionals.first else {
      throw CommandError.missingArgument(command: Self.name)
    }
    self.init(
      path: path,
      showFiles: args.flags.contains("--files"),
      showCopies: args.flags.contains("--copies")
    )
  }

  public static let name = "info"

  /// An `.xcframework`, `.framework`, `.a`, `.dSYM`, or a folder containing them.
  public var path: String
  /// List every recorded source file, marked ✓ when it exists here.
  public var showFiles: Bool
  /// For each dSYM, list every copy with the same UUID (see ``Linker/dSYMCopies(of:)``),
  /// since lldb may load any of them.
  public var showCopies: Bool

  /// Inspects ``path`` (and, with ``showCopies``, finds the dSYM copies) and prints
  /// ``report(for:copies:programName:)``. Throws ``CommandError/nothingFound(path:)``
  /// when there's nothing with debug info.
  @discardableResult
  public func run(in context: CommandContext) throws -> Inspection {
    let inspection = try context.linker.inspect(path)
    guard !inspection.binaries.isEmpty else {
      for note in inspection.notes {
        context.output.print("note: \(note)")
      }
      throw CommandError.nothingFound(path: path)
    }
    var copies: [DebugBinary: [DSYMCopy]] = [:]
    if showCopies {
      for binary in inspection.binaries where binary.kind == .dSYM {
        copies[binary] = try context.linker.dSYMCopies(of: binary)
      }
    }
    let text = report(for: inspection, copies: copies, programName: context.programName)
    context.output.print(text)
    return inspection
  }

  /// The text `info` prints: per binary, how many recorded files exist here and the build
  /// roots they share, plus the dSYM copies in `copies` (with ``showCopies``).
  public func report(
    for inspection: Inspection,
    copies: [DebugBinary: [DSYMCopy]] = [:],
    programName: String = "xcsrclink"
  ) -> String {
    let fm = FileManager.default
    var lines = inspection.notes.map { "note: \($0)" }
    for binary in inspection.binaries.sorted(by: { $0.path < $1.path }) {
      let files = inspection.sources[binary] ?? []
      let slice = binary.slice.map { "[\($0)] " } ?? ""
      lines += ["", "\(slice)\(binary.kind.rawValue): \(binary.path)"]
      guard !files.isEmpty else {
        lines.append("  no source paths in debug info (built without -g?)")
        continue
      }
      let present = files.filter { fm.fileExists(atPath: $0) }.count
      lines
        .append(
          "  \(files.count) source file(s), \(present) found at their recorded path"
        )
      lines.append("  build root(s):")
      for root in Inspection.buildRoots(of: files) {
        lines.append("    \(root.path)  (\(root.fileCount) files)")
      }
      if showFiles {
        lines += files.map { "    \(fm.fileExists(atPath: $0) ? "✓" : "✗") \($0)" }
      }
      if showCopies, let found = copies[binary] {
        lines += copyLines(found)
      }
    }
    if showCopies, !inspection.binaries.contains(where: { $0.kind == .dSYM }) {
      lines += [
        "",
        "--copies: no dSYMs here. Static libraries carry their own debug info."
      ]
    }
    let all = inspection.allSources
    if !all.isEmpty, !all.contains(where: { fm.fileExists(atPath: $0) }) {
      lines += [
        "",
        "None of the recorded files exist here. Map them to your checkout with:",
        "  \(programName) link \(path) --source <your-source-dir>"
      ]
    }
    return lines.joined(separator: "\n")
  }

  static let spec = ArgumentSpec(flags: ["--files", "--copies"], maxPositionals: 1)

  /// `✓` when every recorded file exists here (patched, or mapped needlessly), `✗` when
  /// the copy still points elsewhere and only a source-map can help.
  func copyLines(_ copies: [DSYMCopy]) -> [String] {
    var lines = ["  dSYMs with this UUID (lldb loads whichever it finds first):"]
    for (i, copy) in copies.enumerated() {
      let mark = copy.allFilesFound ? "✓" : "✗"
      let counts = "\(copy.foundFileCount)/\(copy.sourceFileCount) found"
      let this = i == 0 ? "  (this one)" : ""
      lines.append("    \(mark) \(counts)  \(tildeAbbreviated(copy.path))\(this)")
    }
    if copies.count == 1 {
      lines.append("    (no other copies found by Spotlight)")
    }
    return lines
  }
}

// MARK: - link

/// `xcsrclink link <path> --source <dir> [options]`: maps a library's build paths to a
/// local checkout. See ``LinkOptions``.
public struct LinkCommand: ParsableCommand {
  public init(options: LinkOptions) {
    self.options = options
  }

  public init(arguments: [String]) throws {
    try self.init(parsed: Arguments(arguments, spec: Self.spec))
  }

  init(parsed args: Arguments) throws {
    guard let path = args.positionals.first else {
      throw CommandError.missingArgument(command: Self.name)
    }
    var o = LinkOptions(input: path, sourceRoot: args.value(of: "--source"))
    o.name = args.value(of: "--name")
    o.lldbinitPath = args.value(of: "--lldbinit")
    o.inlineBreakpoints = !args.flags.contains("--no-inline-breakpoints")
    o.stripSignature = args.flags.contains("--strip-signature")
    o.dryRun = args.flags.contains("--dry-run")
    o.editSchemes = !args.flags.contains("--no-scheme")
    o.schemes = args.values["--scheme"] ?? []
    o.explicitMappings = try (args.values["--map"] ?? []).map(PathMapping.init(argument:))
    if let list = args.value(of: "--strategy") {
      o.strategies = try Strategy.list(from: list)
    }
    self.init(options: o)
  }

  public static let name = "link"

  public var options: LinkOptions

  /// Links, then prints how to undo it (unless it was a dry run).
  @discardableResult
  public func run(in context: CommandContext) throws -> LinkRecord {
    let record = try context.linker.link(options)
    if !options.dryRun {
      context.output.print("Undo with: \(context.programName) unlink \(record.name)")
    }
    return record
  }

  static let spec = ArgumentSpec(
    valued: ["--source", "--map", "--strategy", "--name", "--lldbinit", "--scheme"],
    flags: ["--no-inline-breakpoints", "--strip-signature", "--dry-run", "--no-scheme"],
    maxPositionals: 1
  )
}

public extension PathMapping {
  /// Parses a `--map` value, `OLD=NEW`.
  init(argument: String) throws {
    guard let eq = argument.firstIndex(of: "="), eq != argument.startIndex,
          argument.index(after: eq) != argument.endIndex else {
      throw CommandError.invalidMapping(argument)
    }
    self.init(
      from: String(argument[..<eq]),
      to: String(argument[argument.index(after: eq)...])
    )
  }
}

public extension Strategy {
  /// Parses a `--strategy` value, a comma-separated list such as `patch,lldbinit`.
  static func list(from argument: String) throws -> [Strategy] {
    try argument.split(separator: ",").map {
      let name = $0.trimmingCharacters(in: .whitespaces)
      guard let strategy = Strategy(rawValue: name) else {
        throw CommandError.unknownStrategy(name)
      }
      return strategy
    }
  }
}

// MARK: - unlink

/// `xcsrclink unlink <name>… [--force]` or `xcsrclink unlink --all`: undoes links.
public struct UnlinkCommand: ParsableCommand {
  public init(_ target: Target, force: Bool = false) {
    self.target = target
    self.force = force
  }

  public init(arguments: [String]) throws {
    try self.init(parsed: Arguments(arguments, spec: Self.spec))
  }

  init(parsed args: Arguments) throws {
    let force = args.flags.contains("--force")
    if args.flags.contains("--all") {
      self.init(.all, force: force)
    } else if !args.positionals.isEmpty {
      self.init(.names(args.positionals), force: force)
    } else {
      throw CommandError.missingArgument(command: Self.name)
    }
  }

  public enum Target: Equatable, Sendable {
    case names([String])
    case all
  }

  public static let name = "unlink"

  public var target: Target
  /// Restore patched files even if they changed since they were patched.
  public var force: Bool

  /// Unlinks and returns the names that were unlinked.
  @discardableResult
  public func run(in context: CommandContext) throws -> [String] {
    let linker = context.linker
    switch target {
    case .all:
      let names = try linker.unlinkAll(force: force)
      if names.isEmpty {
        context.output.print("Nothing linked.")
      }
      return names
    case let .names(names):
      for name in names {
        try linker.unlink(name: name, force: force)
      }
      return names
    }
  }

  static let spec = ArgumentSpec(flags: ["--force", "--all"])
}

// MARK: - list

/// `xcsrclink list`: the current links.
public struct ListCommand: ParsableCommand {
  public init() {}

  public init(arguments: [String]) throws {
    try self.init(parsed: Arguments(arguments, spec: Self.spec))
  }

  init(parsed _: Arguments) throws {
    self.init()
  }

  public static let name = "list"

  /// Prints ``report(for:)`` and returns the links.
  @discardableResult
  public func run(in context: CommandContext) throws -> [LinkRecord] {
    let records = try context.linker.links()
    context.output.print(report(for: records))
    return records
  }

  /// The text `list` prints: each link's name, strategies, input and mappings.
  public func report(for records: [LinkRecord]) -> String {
    guard !records.isEmpty else {
      return "Nothing linked."
    }
    var lines: [String] = []
    for r in records {
      let strategies = r.strategies.map(\.rawValue).joined(separator: ",")
      lines.append("\(r.name)  [\(strategies)]  \(tildeAbbreviated(r.input))")
      lines += r.mappings.map { "    \($0.from) -> \($0.to)" }
      if let path = r.lldbinitPath {
        lines.append("    lldbinit: \(tildeAbbreviated(path))")
      }
      if let schemes = r.schemes, !schemes.isEmpty {
        lines.append("    schemes: \(schemes.map(\.schemeName).joined(separator: ", "))")
      }
      if !r.patchedFiles.isEmpty {
        lines.append("    patched: \(r.patchedFiles.count) file(s)")
      }
      if !r.symlinks.isEmpty {
        lines.append("    symlinks: \(r.symlinks.joined(separator: ", "))")
      }
    }
    return lines.joined(separator: "\n")
  }

  static let spec = ArgumentSpec(maxPositionals: 0)
}
