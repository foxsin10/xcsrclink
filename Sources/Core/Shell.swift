import Foundation

public struct ShellResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum Shell {
    public static func run(_ executable: String, _ arguments: [String]) throws -> ShellResult {
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
}
