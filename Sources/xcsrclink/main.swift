import Foundation
import XcsrcLinkKit

let version = "0.2.1"

let usage = """
  xcsrclink \(version): debug prebuilt .a / .xcframework libraries against your local source.

  Prebuilt libraries record the absolute paths of the machine that built them. Xcode can't
  find those files on your machine, so breakpoints don't bind and "step into" shows
  assembly. xcsrclink points those paths at your local checkout.

  USAGE
    xcsrclink info   <path> [--files]
    xcsrclink link   <path> --source <dir> [options]
    xcsrclink unlink <name> [--force]  |  xcsrclink unlink --all
    xcsrclink list

  <path> may be an .xcframework, .framework, .a, .dSYM, or a folder containing them
  (e.g. Pods/ or Carthage/Build).

  LINK OPTIONS
    -s, --source <dir>       Local checkout of the library's source. Build paths are matched
                             to it automatically by comparing file paths.
    -m, --map <old>=<new>    Explicit path mapping (repeatable). Skips automatic matching.
    -S, --strategy <list>    Comma-separated, default: lldbinit
                               lldbinit  add target.source-map to your lldbinit (no binary changes)
                               patch     rewrite paths inside the .a/dSYM DWARF in place (backed up)
                               symlink   symlink the build paths to your source (cocoapods-imy-bin style)
    -n, --name <name>        Name for this link (default: library name)
        --lldbinit <file>    lldbinit file to edit (default: ~/.lldbinit-Xcode if present, else ~/.lldbinit).
                             Also sets Run › LLDB Init File in the schemes of the Xcode project
                             at or above <file>; unlink removes it again.
        --scheme <name|path> Only edit this scheme (repeatable). A path to an .xcscheme also works.
        --no-scheme          With --lldbinit, don't edit any scheme
        --no-inline-breakpoints
                             Don't set target.inline-breakpoint-strategy=always
        --strip-signature    Allow patching a signed xcframework (signature restored on unlink)
        --dry-run            Show what would happen without changing anything

  EXAMPLES
    xcsrclink info Pods/MyLib/MyLib.xcframework
    xcsrclink link Pods/MyLib/MyLib.xcframework --source ~/src/MyLib
    xcsrclink link libFoo.a --map /Users/ci/build/Foo=$HOME/src/Foo --strategy patch
    xcsrclink unlink MyLib
  """

/// A usage error from the command line itself.
struct UsageError: Error, CustomStringConvertible {
  init(_ d: String) {
    description = d
  }

  let description: String
}

struct Arguments {
  /// `valued` options take a value, `flags` don't. Anything else is an error, so a typo
  /// like `----lldbinit` stops the command instead of being silently ignored.
  /// `maxPositionals` (nil: any number) catches stray arguments such as a value whose
  /// option was misspelled.
  init(
    _ raw: [String],
    valued: Set<String> = [],
    flags known: Set<String> = [],
    maxPositionals: Int? = nil
  ) throws {
    let known = known.union(["--help"])
    var i = 0
    while i < raw.count {
      var arg = raw[i]
      i += 1
      guard arg.hasPrefix("-"), arg != "-" else {
        positionals.append(arg); continue
      }
      var inline: String?
      if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
        inline = String(arg[arg.index(after: eq)...])
        arg = String(arg[..<eq])
      }
      arg = Arguments.aliases[arg] ?? arg
      if valued.contains(arg) {
        guard let v = inline ?? (i < raw.count ? raw[i] : nil) else {
          throw UsageError("\(arg) needs a value")
        }
        if inline == nil {
          i += 1
        }
        values[arg, default: []].append(v)
      } else if known.contains(arg), inline == nil {
        flags.insert(arg)
      } else if known.contains(arg) {
        throw UsageError("\(arg) takes no value")
      } else {
        let hint = Arguments.closest(to: arg, in: valued.union(known))
          .map { ". Did you mean \($0)?" } ?? ""
        throw UsageError("unknown option '\(arg)'\(hint) See `xcsrclink help`.")
      }
    }
    if let max = maxPositionals, positionals.count > max, !flags.contains("--help") {
      throw UsageError(
        "unexpected argument '\(positionals[max])'. Is the option before it misspelled?"
      )
    }
  }

  static let aliases = [
    "-s": "--source",
    "-m": "--map",
    "-S": "--strategy",
    "-n": "--name",
    "-h": "--help"
  ]

  var positionals: [String] = []
  var values: [String: [String]] = [:]
  var flags: Set<String> = []

  /// The known option nearest to a misspelled one (extra dashes, a typo or two).
  static func closest(to arg: String, in options: Set<String>) -> String? {
    let bare = arg.drop { $0 == "-" }
    if let exact = options
      .first(where: { $0.drop { $0 == "-" } == bare }) {
      return exact
    }
    let scored = options.map { (
      $0,
      editDistance(Array(bare), Array($0.drop { $0 == "-" }))
    ) }
    guard let best = scored.min(by: { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }),
          best.1 <= 2 else {
      return nil
    }
    return best.0
  }

  static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
    var row = Array(0 ... b.count)
    for (i, ca) in a.enumerated() {
      var prev = row[0]
      row[0] = i + 1
      for (j, cb) in b.enumerated() {
        let cur = row[j + 1]
        row[j + 1] = min(row[j + 1] + 1, row[j] + 1, prev + (ca == cb ? 0 : 1))
        prev = cur
      }
    }
    return row[b.count]
  }

  func value(ofKey k: String) -> String? {
    values[k]?.last
  }
}

func tildeAbbreviated(_ path: String) -> String {
  let h = NSHomeDirectory()
  return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
}

/// The library's message plus what to type next.
func message(for error: Error) -> String {
  guard let e = error as? XcsrcLinkError else {
    return "\(error)"
  }
  switch e {
  case .missingSourceOrMappings:
    return "pass --source <dir> or at least one --map OLD=NEW"
  case let .noMatchingSources(input, _, _):
    return "\(e) Run `xcsrclink info \(tildeAbbreviated(input))` to see the recorded paths."
  case .signedXCFramework:
    return "\(e) Re-run with --strip-signature (the signature is restored on unlink), or use --strategy lldbinit."
  case .pathExists:
    return "\(e) Use --strategy lldbinit instead."
  case let .cannotCreateSymlink(_, parent, _):
    return """
      \(e)
        The build path's folder isn't writable. Make it yours once, then re-run:
          sudo mkdir -p '\(parent)' && sudo chown "$USER" '\(parent)'
        or use --strategy lldbinit, which needs no special permissions.
      """
  case .noLink:
    return "\(e). See `xcsrclink list`."
  default:
    return "\(e)"
  }
}

func failWithMessage(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

func runInfo(_ args: Arguments) throws {
  guard let path = args.positionals.first else {
    failWithMessage("usage: xcsrclink info <path> [--files]")
  }
  let ins = try Linker().inspect(path)
  ins.notes.forEach { print("note: \($0)") }
  if ins.binaries
    .isEmpty {
    failWithMessage("no static libraries, dSYMs or DWARF found in \(path)")
  }

  let fm = FileManager.default
  for b in ins.binaries.sorted(by: { $0.path < $1.path }) {
    let files = ins.sources[b] ?? []
    print("\n\(b.slice.map { "[\($0)] " } ?? "")\(b.kind.rawValue): \(b.path)")
    guard !files.isEmpty else {
      print("  no source paths in debug info (built without -g?)")
      continue
    }
    let present = files.filter { fm.fileExists(atPath: $0) }.count
    print("  \(files.count) source file(s), \(present) found at their recorded path")
    print("  build root(s):")
    for g in Inspection
      .buildRoots(of: files) {
      print("    \(g.path)  (\(g.fileCount) files)")
    }
    if args.flags.contains("--files") {
      for f in files {
        print("    \(fm.fileExists(atPath: f) ? "✓" : "✗") \(f)")
      }
    }
  }
  let all = ins.allSources
  if !all.isEmpty, !all.contains(where: { fm.fileExists(atPath: $0) }) {
    print(
      "\nNone of the recorded files exist here. Map them to your checkout with:\n  xcsrclink link \(path) --source <your-source-dir>"
    )
  }
}

func runLink(_ args: Arguments) throws {
  guard let path = args.positionals.first else {
    failWithMessage("usage: xcsrclink link <path> --source <dir> [options]")
  }
  var o = LinkOptions(input: path)
  o.sourceRoot = args.value(ofKey: "--source")
  o.name = args.value(ofKey: "--name")
  o.lldbinitPath = args.value(ofKey: "--lldbinit")
  o.inlineBreakpoints = !args.flags.contains("--no-inline-breakpoints")
  o.stripSignature = args.flags.contains("--strip-signature")
  o.dryRun = args.flags.contains("--dry-run")
  o.editSchemes = !args.flags.contains("--no-scheme")
  o.schemes = args.values["--scheme"] ?? []
  for m in args.values["--map"] ?? [] {
    guard let eq = m.firstIndex(of: "="), eq != m.startIndex,
          m.index(after: eq) != m.endIndex else {
      failWithMessage("--map expects OLD=NEW, got '\(m)'")
    }
    o.explicitMappings.append(PathMapping(
      from: String(m[..<eq]),
      to: String(m[m.index(after: eq)...])
    ))
  }
  if let list = args.value(ofKey: "--strategy") {
    o.strategies = try list.split(separator: ",").map {
      let s = $0.trimmingCharacters(in: .whitespaces)
      guard let v = Strategy(rawValue: s) else {
        throw UsageError(
          "unknown strategy '\(s)'. Use: \(Strategy.allCases.map(\.rawValue).joined(separator: ", "))"
        )
      }
      return v
    }
  }
  let record = try Linker(console: .standard).link(o)
  if !o.dryRun {
    print("Undo with: xcsrclink unlink \(record.name)")
  }
}

func runUnlink(_ args: Arguments) throws {
  let linker = Linker(console: .standard)
  let force = args.flags.contains("--force")
  if args.flags.contains("--all") {
    if try linker.unlinkAll(force: force).isEmpty {
      print("Nothing linked.")
    }
    return
  }
  guard !args.positionals.isEmpty else {
    failWithMessage("usage: xcsrclink unlink <name> | --all")
  }
  for n in args.positionals {
    try linker.unlink(name: n, force: force)
  }
}

func runList() throws {
  let records = try Linker().links()
  if records.isEmpty {
    print("Nothing linked."); return
  }
  for r in records {
    print(
      "\(r.name)  [\(r.strategies.map(\.rawValue).joined(separator: ","))]  \(tildeAbbreviated(r.input))"
    )
    for m in r.mappings {
      print("    \(m.from) -> \(m.to)")
    }
    if let p = r.lldbinitPath {
      print("    lldbinit: \(tildeAbbreviated(p))")
    }
    if let s = r.schemes,
       !s.isEmpty {
      print("    schemes: \(s.map(\.schemeName).joined(separator: ", "))")
    }
    if !r.patchedFiles.isEmpty {
      print("    patched: \(r.patchedFiles.count) file(s)")
    }
    if !r.symlinks
      .isEmpty {
      print("    symlinks: \(r.symlinks.joined(separator: ", "))")
    }
  }
}

let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else {
  print(usage); exit(0)
}

do {
  let rest = Array(raw.dropFirst())
  switch command {
  case "info",
       "link",
       "unlink",
       "list":
    let args: Arguments = switch command {
    case "info": try Arguments(rest, flags: ["--files"], maxPositionals: 1)
    case "link":
      try Arguments(
        rest,
        valued: ["--source", "--map", "--strategy", "--name", "--lldbinit", "--scheme"],
        flags: [
          "--no-inline-breakpoints",
          "--strip-signature",
          "--dry-run",
          "--no-scheme"
        ],
        maxPositionals: 1
      )
    case "unlink": try Arguments(rest, flags: ["--force", "--all"])
    default: try Arguments(rest, maxPositionals: 0)
    }
    if args.flags.contains("--help") {
      print(usage); exit(0)
    }
    switch command {
    case "info": try runInfo(args)
    case "link": try runLink(args)
    case "unlink": try runUnlink(args)
    default: try runList()
    }
  case "help",
       "-h",
       "--help": print(usage)
  case "--version",
       "version": print(version)
  default: failWithMessage("unknown command '\(command)'. Run `xcsrclink help`.")
  }
} catch {
  failWithMessage(message(for: error))
}
