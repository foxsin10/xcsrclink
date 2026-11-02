import Foundation

struct ShellResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

enum Shell {
  /// Runs dwarfdump. Its path is looked up through xcrun once, because going through
  /// xcrun for each of thousands of object files is slow.
  static func dwarfdump(_ arguments: [String]) throws -> ShellResult {
    if let path = dwarfdumpPath {
      return try run(path, arguments)
    }
    return try run("/usr/bin/xcrun", ["dwarfdump"] + arguments)
  }

  static func run(_ executable: String, _ arguments: [String]) throws -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    // Send stderr to a temp file so a chatty stderr can't deadlock the stdout pipe.
    let errURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("xcsrclink-\(UUID().uuidString).stderr")
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: errURL) }
    let errHandle = try FileHandle(forWritingTo: errURL)
    defer { try? errHandle.close() }

    let out = Pipe()
    process.standardOutput = out
    process.standardError = errHandle
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errData = (try? Data(contentsOf: errURL)) ?? Data()
    return ShellResult(
      status: process.terminationStatus,
      stdout: String(decoding: outData, as: UTF8.self),
      stderr: String(decoding: errData, as: UTF8.self)
    )
  }

  private static let dwarfdumpPath: String? = {
    guard let r = try? run("/usr/bin/xcrun", ["-f", "dwarfdump"]), r.status == 0 else {
      return nil
    }
    let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }()
}
