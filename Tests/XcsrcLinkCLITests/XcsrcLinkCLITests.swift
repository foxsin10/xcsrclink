import Foundation
import Testing
import XcsrcLinkCLI
import XcsrcLinkKit

/// Collects what a command prints.
final class Captured: @unchecked Sendable {
  var output: CommandOutput {
    CommandOutput(
      print: { [self] line in lock.withLock { out.append(line) } },
      printError: { [self] line in lock.withLock { err.append(line) } }
    )
  }

  var stdout: String {
    lock.withLock { out.joined(separator: "\n") }
  }

  var stderr: String {
    lock.withLock { err.joined(separator: "\n") }
  }

  private let lock = NSLock()
  private var out: [String] = []
  private var err: [String] = []
}

func scratchHome() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("cli-\(UUID().uuidString)")
}

struct ParsingTests {
  @Test func parsesLinkOptions() throws {
    let command = try LinkCommand(arguments: [
      "Kit.xcframework", "-s", "src", "--map=/ci=/me", "-S", "patch, lldbinit",
      "--name", "K", "--dry-run", "--no-scheme", "--scheme", "A", "--scheme", "B"
    ])
    let o = command.options
    #expect(o.input == "Kit.xcframework")
    #expect(o.sourceRoot == "src")
    #expect(o.explicitMappings == [PathMapping(from: "/ci", to: "/me")])
    #expect(o.strategies == [.patch, .lldbinit])
    #expect(o.name == "K")
    #expect(o.dryRun && !o.editSchemes && o.inlineBreakpoints)
    #expect(o.schemes == ["A", "B"])
  }

  @Test func rejectsBadArguments() {
    #expect(throws: CommandError.unknownOption(
      "----lldbinit",
      suggestion: "--lldbinit"
    )) {
      try LinkCommand(arguments: ["K", "----lldbinit", "x"])
    }
    #expect(throws: CommandError.unexpectedArgument("B")) {
      try InfoCommand(arguments: ["A", "B"])
    }
    #expect(throws: CommandError.missingValue(option: "--source")) {
      try LinkCommand(arguments: ["K", "--source"])
    }
    #expect(throws: CommandError.unexpectedValue(option: "--dry-run")) {
      try LinkCommand(arguments: ["K", "--dry-run=yes"])
    }
    #expect(throws: CommandError.invalidMapping("/ci")) {
      try PathMapping(argument: "/ci")
    }
    #expect(throws: CommandError.unknownStrategy("copy")) {
      try Strategy.list(from: "patch,copy")
    }
    #expect(throws: CommandError.missingArgument(command: "unlink")) {
      try UnlinkCommand(arguments: ["--force"])
    }
  }

  @Test func unlinkTargets() throws {
    #expect(try UnlinkCommand(arguments: ["--all"]).target == .all)
    let byName = try UnlinkCommand(arguments: ["A", "B", "--force"])
    #expect(byName.target == .names(["A", "B"]) && byName.force)
  }
}

struct RunTests {
  @Test func runsCommandsAgainstTheContext() throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let captured = Captured()
    let context = CommandContext(
      home: home,
      output: captured.output,
      programName: "tool xcsrc"
    )

    #expect(try ListCommand().run(in: context).isEmpty)
    #expect(try UnlinkCommand(.all).run(in: context).isEmpty)
    #expect(captured.stdout == "Nothing linked.\nNothing linked.")
    #expect(throws: XcsrcLinkError.noLink(name: "K")) {
      try UnlinkCommand(.names(["K"])).run(in: context)
    }
  }

  @Test func runReturnsExitStatusAndUsesProgramName() {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let captured = Captured()
    let context = CommandContext(
      home: home,
      output: captured.output,
      programName: "tool xcsrc"
    )

    #expect(XcsrcLinkCLI.run(["unlink", "K"], context: context) == 1)
    #expect(XcsrcLinkCLI.run(["frob"], context: context) == 1)
    #expect(XcsrcLinkCLI.run(["info"], context: context) == 1)
    #expect(captured.stderr == """
      error: no link named 'K'. See `tool xcsrc list`.
      error: unknown command 'frob'. Run `tool xcsrc help`.
      error: usage: tool xcsrc info <path> [--files]
      """)
    #expect(XcsrcLinkCLI.run(["link", "--help"], context: context) == 0)
    #expect(captured.stdout.hasPrefix("tool xcsrc \(XcsrcLinkCLI.version): "))
  }

  @Test func listReport() {
    #expect(ListCommand().report(for: []) == "Nothing linked.")
  }
}
