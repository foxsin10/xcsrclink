import Foundation

public enum Strategy: String, Codable, CaseIterable, Sendable {
    /// Add `target.source-map` entries to an lldbinit file. Nothing on disk is modified.
    case lldbinit
    /// Rewrite the paths inside the binaries' DWARF (backups are kept).
    case patch
    /// Create symlinks at the original build paths pointing at the local sources
    /// (the cocoapods-imy-bin approach).
    case symlink
}

public struct PatchedFile: Codable, Sendable {
    public var path: String
    public var backup: String
    /// SHA-256 of the file right after patching, so `unlink` won't clobber a newer copy.
    public var patchedSHA256: String
}

public struct LinkRecord: Codable, Sendable {
    public var name: String
    public var input: String
    public var sourceRoot: String?
    public var strategies: [Strategy]
    public var mappings: [PathMapping]
    public var createdAt: Date
    public var lldbinitPath: String?
    public var inlineBreakpoints: Bool
    public var patchedFiles: [PatchedFile] = []
    public var symlinks: [String] = []
    public var createdDirectories: [String] = []
    /// `_CodeSignature` folders moved aside before patching a signed xcframework: original → backup.
    public var movedSignatures: [String: String] = [:]
}

public struct Registry: Codable {
    public var records: [LinkRecord] = []

    public static var fileURL: URL {
        URL(fileURLWithPath: PathUtil.home).appendingPathComponent("registry.json")
    }

    public static func load() throws -> Registry {
        guard let data = try? Data(contentsOf: fileURL) else { return Registry() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Registry.self, from: data)
    }

    public func save() throws {
        try FileManager.default.createDirectory(atPath: PathUtil.home, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Registry.fileURL, options: .atomic)
    }
}
