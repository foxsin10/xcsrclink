import Foundation

/// Maintains one managed block inside an lldbinit file. Everything outside the block is left alone.
public enum LLDBInit {
    static let begin = "# >>> xcsrclink (managed block, edit with `xcsrclink link/unlink`) >>>"
    static let end = "# <<< xcsrclink <<<"

    /// Xcode reads `~/.lldbinit-Xcode` when it exists and `~/.lldbinit` otherwise.
    /// Writing to whichever Xcode reads avoids hiding the other file.
    public static var defaultPath: String {
        let home = NSHomeDirectory()
        let xcode = (home as NSString).appendingPathComponent(".lldbinit-Xcode")
        if FileManager.default.fileExists(atPath: xcode) { return xcode }
        return (home as NSString).appendingPathComponent(".lldbinit")
    }

    public static func render(_ records: [LinkRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        var lines = [begin]
        if records.contains(where: \.inlineBreakpoints) {
            // Needed for file:line breakpoints in files that are not their own compile unit
            // (whole-module builds, headers). Without it Xcode breakpoints in those files never bind.
            lines.append("settings set target.inline-breakpoint-strategy always")
        }
        for r in records.sorted(by: { $0.name < $1.name }) {
            lines.append("# \(r.name): \(PathUtil.tildeAbbreviated(r.input))")
            for m in r.mappings {
                lines.append("settings append target.source-map \(quote(m.from)) \(quote(m.to))")
            }
        }
        lines.append(end)
        return lines.joined(separator: "\n")
    }

    /// Replaces (or removes, when `block` is nil) the managed block in `path`.
    public static func write(block: String?, to path: String) throws {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var kept: [Substring] = []
        var inside = false
        for line in existing.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == begin { inside = true; continue }
            if line == end { inside = false; continue }
            if !inside { kept.append(line) }
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        var text = kept.joined(separator: "\n")
        if let block {
            if !text.isEmpty { text += "\n\n" }
            text += block
        }
        if !text.isEmpty { text += "\n" }
        if text.isEmpty {
            guard FileManager.default.fileExists(atPath: path) else { return }
            // An emptied project lldbinit is just clutter. Keep the home ones: whether
            // ~/.lldbinit-Xcode exists decides which file Xcode reads.
            let home = NSHomeDirectory() as NSString
            let homeFiles = [".lldbinit", ".lldbinit-Xcode"].map { SourcePath(home.appendingPathComponent($0)) }
            if !homeFiles.contains(SourcePath(PathUtil.absolute(path))) {
                try FileManager.default.removeItem(atPath: path)
                return
            }
        }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
