import Foundation
import Core

let version = "0.1.0"

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
      --lldbinit <file>    lldbinit file to edit (default: ~/.lldbinit-Xcode if present, else ~/.lldbinit)
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

struct Arguments {
    var positionals: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    static let aliases = ["-s": "--source", "-m": "--map", "-S": "--strategy", "-n": "--name", "-h": "--help"]

    init(_ raw: [String], valued: Set<String>) throws {
        var i = 0
        while i < raw.count {
            var arg = raw[i]
            i += 1
            guard arg.hasPrefix("-"), arg != "-" else { positionals.append(arg); continue }
            var inline: String?
            if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
                inline = String(arg[arg.index(after: eq)...])
                arg = String(arg[..<eq])
            }
            arg = Arguments.aliases[arg] ?? arg
            if valued.contains(arg) {
                guard let v = inline ?? (i < raw.count ? raw[i] : nil) else { throw LinkError("\(arg) needs a value") }
                if inline == nil { i += 1 }
                values[arg, default: []].append(v)
            } else {
                flags.insert(arg)
            }
        }
    }

    func value(_ k: String) -> String? { values[k]?.last }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func runInfo(_ args: Arguments) throws {
    guard let path = args.positionals.first else { fail("usage: xcsrclink info <path> [--files]") }
    let linker = Linker()
    let ins = try linker.inspect(path)
    ins.located.notes.forEach { print("note: \($0)") }
    if ins.located.binaries.isEmpty { fail("no static libraries, dSYMs or DWARF found in \(path)") }

    let fm = FileManager.default
    for b in ins.located.binaries.sorted(by: { $0.path < $1.path }) {
        let files = ins.sources[b] ?? []
        print("\n\(b.slice.map { "[\($0)] " } ?? "")\(b.kind.rawValue): \(b.path)")
        guard !files.isEmpty else {
            print("  no source paths in debug info (built without -g?)")
            continue
        }
        let present = files.filter { fm.fileExists(atPath: $0) }.count
        print("  \(files.count) source file(s), \(present) found at their recorded path")
        print("  build root(s):")
        for g in SourcePathReader.buildRoots(files) { print("    \(g.root)  (\(g.count) files)") }
        if args.flags.contains("--files") {
            for f in files { print("    \(fm.fileExists(atPath: f) ? "✓" : "✗") \(f)") }
        }
    }
    let all = ins.allSources
    if !all.isEmpty, !all.contains(where: { fm.fileExists(atPath: $0) }) {
        print("\nNone of the recorded files exist here. Map them to your checkout with:\n  xcsrclink link \(path) --source <your-source-dir>")
    }
}

func runLink(_ args: Arguments) throws {
    guard let path = args.positionals.first else { fail("usage: xcsrclink link <path> --source <dir> [options]") }
    var o = LinkOptions(input: path)
    o.sourceRoot = args.value("--source")
    o.name = args.value("--name")
    o.lldbinitPath = args.value("--lldbinit")
    o.inlineBreakpoints = !args.flags.contains("--no-inline-breakpoints")
    o.stripSignature = args.flags.contains("--strip-signature")
    o.dryRun = args.flags.contains("--dry-run")
    for m in args.values["--map"] ?? [] {
        guard let eq = m.firstIndex(of: "="), eq != m.startIndex, m.index(after: eq) != m.endIndex else {
            fail("--map expects OLD=NEW, got '\(m)'")
        }
        o.explicitMappings.append(PathMapping(from: String(m[..<eq]), to: PathUtil.absolute(String(m[m.index(after: eq)...]))))
    }
    if let list = args.value("--strategy") {
        o.strategies = try list.split(separator: ",").map {
            let s = $0.trimmingCharacters(in: .whitespaces)
            guard let v = Strategy(rawValue: s) else {
                throw LinkError("unknown strategy '\(s)'. Use: \(Strategy.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return v
        }
    }
    try Linker().link(o)
}

func runUnlink(_ args: Arguments) throws {
    let linker = Linker()
    let force = args.flags.contains("--force")
    if args.flags.contains("--all") {
        let names = try Registry.load().records.map(\.name)
        if names.isEmpty { print("Nothing linked.") }
        for n in names { try linker.unlink(name: n, force: force) }
        return
    }
    guard !args.positionals.isEmpty else { fail("usage: xcsrclink unlink <name> | --all") }
    for n in args.positionals { try linker.unlink(name: n, force: force) }
}

func runList() throws {
    let records = try Registry.load().records
    if records.isEmpty { print("Nothing linked."); return }
    for r in records {
        print("\(r.name)  [\(r.strategies.map(\.rawValue).joined(separator: ","))]  \(PathUtil.tildeAbbreviated(r.input))")
        for m in r.mappings { print("    \(m.from) -> \(m.to)") }
        if let p = r.lldbinitPath { print("    lldbinit: \(PathUtil.tildeAbbreviated(p))") }
        if !r.patchedFiles.isEmpty { print("    patched: \(r.patchedFiles.count) file(s)") }
        if !r.symlinks.isEmpty { print("    symlinks: \(r.symlinks.joined(separator: ", "))") }
    }
}

let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else { print(usage); exit(0) }
do {
    let rest = Array(raw.dropFirst())
    switch command {
    case "info": try runInfo(Arguments(rest, valued: []))
    case "link": try runLink(Arguments(rest, valued: ["--source", "--map", "--strategy", "--name", "--lldbinit"]))
    case "unlink": try runUnlink(Arguments(rest, valued: []))
    case "list": try runList()
    case "help", "-h", "--help": print(usage)
    case "--version", "version": print(version)
    default: fail("unknown command '\(command)'. Run `xcsrclink help`.")
    }
} catch {
    fail("\(error)")
}
