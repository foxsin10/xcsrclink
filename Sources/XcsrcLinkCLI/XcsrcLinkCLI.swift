import Foundation
import XcsrcLinkKit

/// The `xcsrclink` command line as a library. ``run(_:context:)`` runs a whole command
/// line; the command types (``InfoCommand``, ``LinkCommand``, ``UnlinkCommand``,
/// ``ListCommand``) can also be parsed, built and run one by one.
public enum XcsrcLinkCLI {
  public static let version = "0.2.1"

  /// The commands ``run(_:context:)`` knows, by name.
  public static let commands: [any XcsrcLinkCommand.Type] = parsable

  /// Runs one command line without the program name, e.g.
  /// `["link", "MyLib.xcframework", "--source", "src"]`. Errors are printed as `error: …`
  /// to `context.output`. Returns the exit status: 0 on success, 1 on error.
  public static func run(
    _ arguments: [String],
    context: CommandContext = CommandContext()
  ) -> Int32 {
    let output = context.output
    guard let name = arguments.first else {
      output.print(usage(programName: context.programName))
      return 0
    }
    do {
      switch name {
      case "help",
           "-h",
           "--help":
        output.print(usage(programName: context.programName))
      case "version",
           "--version":
        output.print(version)
      default:
        guard let command = parsable.first(where: { $0.name == name }) else {
          throw CommandError.unknownCommand(name)
        }
        let args = try Arguments(Array(arguments.dropFirst()), spec: command.spec)
        if args.wantsHelp {
          output.print(usage(programName: context.programName))
        } else {
          _ = try command.init(parsed: args).run(in: context)
        }
      }
      return 0
    } catch {
      output.printError("error: \(message(for: error, programName: context.programName))")
      return 1
    }
  }

  /// An error's message plus what to type next, e.g. `no link named 'X'. See `xcsrclink
  /// list`.`
  public static func message(
    for error: Error,
    programName p: String = "xcsrclink"
  ) -> String {
    if let e = error as? CommandError {
      switch e {
      case let .unknownOption(_, suggestion):
        // "Did you mean --x?" already ends the sentence.
        return "\(e)\(suggestion == nil ? "." : "") See `\(p) help`."
      case let .missingArgument(command):
        return "usage: \(p) \(usageLine(of: command))"
      case .unknownCommand:
        return "\(e). Run `\(p) help`."
      default:
        return "\(e)"
      }
    }
    guard let e = error as? XcsrcLinkError else {
      return "\(error)"
    }
    switch e {
    case .missingSourceOrMappings:
      return "pass --source <dir> or at least one --map OLD=NEW"
    case let .noMatchingSources(input, _, _):
      return "\(e) Run `\(p) info \(tildeAbbreviated(input))` to see the recorded paths."
    case .signedXCFramework:
      return "\(e) Re-run with --strip-signature (the signature is restored on unlink), "
        + "or use --strategy lldbinit."
    case .pathExists:
      return "\(e) Use --strategy lldbinit instead."
    case let .relativeBuildPath(m):
      return "can't patch relative build path '\(m.from)' in place; use --strategy lldbinit instead"
    case let .replacementTooLong(m, extra):
      return """
        can't patch '\(m.from)' in place: the local path '\(m.to)' is \(extra) bytes longer than the build path.
          Binary patching keeps every string the same length. Either use --strategy lldbinit
          (no binary changes), or put your checkout at a path no longer than the build path.
        """
    case let .cannotCreateSymlink(_, parent, _):
      return """
        \(e)
          The build path's folder isn't writable. Make it yours once, then re-run:
            sudo mkdir -p '\(parent)' && sudo chown "$USER" '\(parent)'
          or use --strategy lldbinit, which needs no special permissions.
        """
    case .noLink:
      return "\(e). See `\(p) list`."
    default:
      return "\(e)"
    }
  }

  /// The help text, with `programName` in every example.
  public static func usage(programName p: String = "xcsrclink") -> String {
    """
    \(p) \(version): debug prebuilt .a / .xcframework libraries against your local source.

    Prebuilt libraries record the absolute paths of the machine that built them. Xcode can't
    find those files on your machine, so breakpoints don't bind and "step into" shows
    assembly. \(p) points those paths at your local checkout.

    USAGE
      \(p) info   <path> [--files] [--copies]
      \(p) link   <path> --source <dir> [options]
      \(p) unlink <name> [--force]  |  \(p) unlink --all
      \(p) list

    <path> may be an .xcframework, .framework, .a, .dSYM, or a folder containing them
    (e.g. Pods/ or Carthage/Build).

    INFO OPTIONS
          --files              List every recorded source file, ✓ if it exists here
          --copies             For each dSYM, list every copy with the same UUID (lldb may
                               load any of them) and whether its files exist here

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
      \(p) info Pods/MyLib/MyLib.xcframework
      \(p) link Pods/MyLib/MyLib.xcframework --source ~/src/MyLib
      \(p) link libFoo.a --map /Users/ci/build/Foo=$HOME/src/Foo --strategy patch
      \(p) unlink MyLib
    """
  }

  /// A warning's message plus the CLI flag that addresses it, e.g.
  /// `Use --force to restore anyway.`
  public static func message(
    for warning: LinkWarning,
    programName p: String = "xcsrclink"
  ) -> String {
    switch warning {
    case let .ambiguousMatches(count, example):
      "\(count) file(s) matched several local files equally well and were skipped, "
        + "e.g. \(example). Use --map to be explicit."
    case let .noSchemeFound(lldbinit):
      "no saved Xcode scheme found at or above \(tildeAbbreviated(lldbinit)), so no "
        + "scheme was changed. Pass --scheme <path/to/Name.xcscheme>, or set Edit Scheme › Run "
        + "› Info › LLDB Init File to this file yourself."
    case let .patchedFileChanged(path):
      "\(path) changed since it was patched (updated library?), not restoring it. "
        + "Use --force to restore anyway."
    case let .unpatchedDSYMCopies(input, _):
      "\(warning)\n  Check which copies lldb could load with: "
        + "\(p) info \(tildeAbbreviated(input)) --copies"
    default:
      "\(warning)"
    }
  }

  static let parsable: [any ParsableCommand.Type] = [
    InfoCommand.self,
    LinkCommand.self,
    UnlinkCommand.self,
    ListCommand.self
  ]

  static func usageLine(of command: String) -> String {
    switch command {
    case InfoCommand.name: "info <path> [--files] [--copies]"
    case LinkCommand.name: "link <path> --source <dir> [options]"
    case UnlinkCommand.name: "unlink <name> | --all"
    default: command
    }
  }
}
