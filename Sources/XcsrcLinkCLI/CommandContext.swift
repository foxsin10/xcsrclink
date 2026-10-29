import Foundation
import XcsrcLinkKit

/// A command of the `xcsrclink` CLI. Build one from command-line arguments with
/// ``init(arguments:)`` or from values in code, then call ``run(in:)``.
public protocol XcsrcLinkCommand: Sendable {
  associatedtype Result

  /// The subcommand name, e.g. `link`.
  static var name: String { get }

  /// Parses the arguments that follow the subcommand name, e.g.
  /// `["MyLib.xcframework", "--source", "src"]`.
  init(arguments: [String]) throws

  /// Runs the command, printing to `context.output` like the CLI does.
  @discardableResult
  func run(in context: CommandContext) throws -> Result
}

/// Where a command's text goes. ``standard`` writes to stdout and stderr; pass your own
/// closures to capture or forward it.
public struct CommandOutput: Sendable {
  public init(
    print: @escaping @Sendable (String) -> Void,
    printError: @escaping @Sendable (String) -> Void
  ) {
    self.print = print
    self.printError = printError
  }

  /// Text to stdout, errors and warnings to stderr.
  public static let standard = CommandOutput(
    print: { Swift.print($0) },
    printError: { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
  )

  /// Drops all text.
  public static let silent = CommandOutput(print: { _ in }, printError: { _ in })

  public var print: @Sendable (String) -> Void
  public var printError: @Sendable (String) -> Void

  /// Progress messages to ``print``, warnings to ``printError`` as `warning: …`.
  public var console: Console {
    let printError = printError
    return Console(info: print, warn: { printError("warning: \($0)") })
  }
}

/// What commands run against: the link registry, the output, and the program name used
/// in hints such as `Undo with: xcsrclink unlink MyLib`.
public struct CommandContext: Sendable {
  public init(
    home: URL = Linker.defaultHome,
    output: CommandOutput = .standard,
    programName: String = "xcsrclink"
  ) {
    self.home = home
    self.output = output
    self.programName = programName
  }

  /// Folder holding the registry and backups. See ``Linker/home``.
  public var home: URL
  public var output: CommandOutput
  /// Name to show in hints and usage, e.g. `mytool xcsrc` when embedded in another CLI.
  public var programName: String

  /// A linker on ``home`` that reports to ``output``.
  public var linker: Linker {
    Linker(home: home, console: output.console)
  }
}

/// Errors from parsing or running a command. ``XcsrcLinkCLI/message(for:programName:)``
/// turns them, and ``XcsrcLinkError``, into the CLI's messages.
public enum CommandError: Error, Equatable, Sendable, CustomStringConvertible {
  /// An option the command doesn't know, with the closest known one if any.
  case unknownOption(String, suggestion: String?)
  /// An option that needs a value got none.
  case missingValue(option: String)
  /// An option that takes no value got one (`--flag=value`).
  case unexpectedValue(option: String)
  /// More plain arguments than the command takes.
  case unexpectedArgument(String)
  /// The command's required argument (a path or link name) is missing.
  case missingArgument(command: String)
  /// A `--map` value that isn't `OLD=NEW`.
  case invalidMapping(String)
  /// A `--strategy` value that isn't a ``Strategy``.
  case unknownStrategy(String)
  /// A subcommand that doesn't exist.
  case unknownCommand(String)
  /// `info` found no static library, dSYM or DWARF in the path.
  case nothingFound(path: String)

  public var description: String {
    switch self {
    case let .unknownOption(option, suggestion):
      return "unknown option '\(option)'" +
        (suggestion.map { ". Did you mean \($0)?" } ?? "")
    case let .missingValue(option):
      return "\(option) needs a value"
    case let .unexpectedValue(option):
      return "\(option) takes no value"
    case let .unexpectedArgument(argument):
      return "unexpected argument '\(argument)'. Is the option before it misspelled?"
    case let .missingArgument(command):
      return "\(command) needs more arguments"
    case let .invalidMapping(value):
      return "--map expects OLD=NEW, got '\(value)'"
    case let .unknownStrategy(name):
      let all = Strategy.allCases.map(\.rawValue).joined(separator: ", ")
      return "unknown strategy '\(name)'. Use: \(all)"
    case let .unknownCommand(command):
      return "unknown command '\(command)'"
    case let .nothingFound(path):
      return "no static libraries, dSYMs or DWARF found in \(path)"
    }
  }
}

func tildeAbbreviated(_ path: String) -> String {
  let home = NSHomeDirectory()
  return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
