import Foundation

/// The options a command accepts.
struct ArgumentSpec {
  /// Options that take a value, e.g. `--source <dir>`.
  var valued: Set<String> = []
  /// Options that take no value, e.g. `--dry-run`.
  var flags: Set<String> = []
  /// How many plain arguments are allowed; `nil` means any number.
  var maxPositionals: Int?
}

/// A parsed command line. Unknown options are errors, so a typo like `----lldbinit` stops
/// the command instead of being silently ignored, and a limit on plain arguments catches
/// a value whose option was misspelled.
struct Arguments {
  init(_ raw: [String], spec: ArgumentSpec) throws {
    let known = spec.flags.union(["--help"])
    var i = 0
    while i < raw.count {
      var arg = raw[i]
      i += 1
      guard arg.hasPrefix("-"), arg != "-" else {
        positionals.append(arg)
        continue
      }
      var inline: String?
      if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
        inline = String(arg[arg.index(after: eq)...])
        arg = String(arg[..<eq])
      }
      arg = Arguments.aliases[arg] ?? arg
      if spec.valued.contains(arg) {
        guard let value = inline ?? (i < raw.count ? raw[i] : nil) else {
          throw CommandError.missingValue(option: arg)
        }
        if inline == nil {
          i += 1
        }
        values[arg, default: []].append(value)
      } else if known.contains(arg) {
        guard inline == nil else {
          throw CommandError.unexpectedValue(option: arg)
        }
        flags.insert(arg)
      } else {
        let suggestion = Arguments.closest(to: arg, in: spec.valued.union(known))
        throw CommandError.unknownOption(arg, suggestion: suggestion)
      }
    }
    if let max = spec.maxPositionals, positionals.count > max, !wantsHelp {
      throw CommandError.unexpectedArgument(positionals[max])
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

  var wantsHelp: Bool {
    flags.contains("--help")
  }

  /// The known option nearest to a misspelled one (extra dashes, a typo or two).
  static func closest(to arg: String, in options: Set<String>) -> String? {
    let bare = arg.drop { $0 == "-" }
    if let exact = options.first(where: { $0.drop { $0 == "-" } == bare }) {
      return exact
    }
    let scored = options.map { option in
      (option, editDistance(Array(bare), Array(option.drop { $0 == "-" })))
    }
    let best = scored.min { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }
    guard let best, best.1 <= 2 else {
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

  func value(of option: String) -> String? {
    values[option]?.last
  }
}
