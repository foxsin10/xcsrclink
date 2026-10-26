import CryptoKit
import Foundation

public struct LinkError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Where progress messages go. The CLI prints them; tests can collect them.
public struct Console {
    public var info: (String) -> Void
    public var warn: (String) -> Void
    public init(info: @escaping (String) -> Void, warn: @escaping (String) -> Void) {
        self.info = info
        self.warn = warn
    }
    public static let standard = Console(
        info: { print($0) },
        warn: { FileHandle.standardError.write(Data("warning: \($0)\n".utf8)) }
    )
}

public struct LinkOptions {
    public var input: String
    public var sourceRoot: String?
    public var explicitMappings: [PathMapping] = []
    public var strategies: [Strategy] = [.lldbinit]
    public var name: String?
    public var lldbinitPath: String?
    public var inlineBreakpoints = true
    public var stripSignature = false
    public var dryRun = false

    public init(input: String) { self.input = input }
}

public struct Linker {
    public var console: Console

    public init(console: Console = .standard) { self.console = console }

    // MARK: - Inspect

    public struct Inspection {
        public var located: LocateResult
        public var sources: [DebugBinary: [String]]
        public var allSources: [String] {
            var seen = Set<String>()
            return sources.values.flatMap { $0 }.filter { seen.insert($0).inserted }.sorted()
        }
    }

    public func inspect(_ input: String) throws -> Inspection {
        let located = DebugBinaryLocator.locate(input)
        var sources: [DebugBinary: [String]] = [:]
        for b in located.binaries {
            sources[b] = try SourcePathReader.sources(in: b.path)
        }
        return Inspection(located: located, sources: sources)
    }

    // MARK: - Link

    @discardableResult
    public func link(_ o: LinkOptions) throws -> LinkRecord {
        let input = PathUtil.absolute(o.input)
        let name = o.name ?? ((input as NSString).lastPathComponent as NSString).deletingPathExtension

        // Undo a previous link with this name first: a patched binary must be restored
        // before its paths are read again.
        if !o.dryRun, try Registry.load().records.contains(where: { $0.name == name }) {
            console.info("Replacing previous link '\(name)'")
            try unlink(name: name, force: false)
        }

        let inspection = try inspect(input)
        inspection.located.notes.forEach(console.warn)
        let debugBinaries = inspection.located.binaries.filter { !(inspection.sources[$0] ?? []).isEmpty }
        guard !debugBinaries.isEmpty else {
            throw LinkError("no debug info with source paths found in \(input). Build the library with -g (DEBUG_INFORMATION_FORMAT) and ship .a files or dSYMs.")
        }
        let originals = inspection.allSources

        // 1. Work out the mappings.
        var mappings = o.explicitMappings
        let sourceRoot = o.sourceRoot.map(PathUtil.absolute)
        if mappings.isEmpty {
            guard let sourceRoot else { throw LinkError("pass --source <dir> or at least one --map OLD=NEW") }
            guard PathUtil.isDirectory(sourceRoot) else { throw LinkError("source folder not found: \(sourceRoot)") }
            let r = MappingResolver.resolve(originals: originals, sourceRoot: sourceRoot)
            mappings = r.mappings
            if !r.ambiguous.isEmpty {
                console.warn("\(r.ambiguous.count) file(s) matched several local files equally well and were skipped, e.g. \(r.ambiguous[0]). Use --map to be explicit.")
            }
            if !r.unmatched.isEmpty {
                console.warn("\(r.unmatched.count) of \(originals.count) source file(s) have no match under \(sourceRoot), e.g. \(r.unmatched[0])")
            }
        }
        mappings = MappingResolver.simplify(mappings)
        guard !mappings.isEmpty else {
            throw LinkError("couldn't match any of the \(originals.count) recorded source files to files under \(sourceRoot ?? "?"). Is this the right checkout? Run `xcsrclink info` to see the recorded paths.")
        }

        let covered = originals.compactMap { PathMapping.apply(mappings, to: $0) }
        let existing = covered.filter { FileManager.default.fileExists(atPath: $0) }
        console.info("Mappings (\(existing.count)/\(originals.count) source files found locally):")
        for m in mappings { console.info("  \(m.from)\n    -> \(m.to)") }

        var record = LinkRecord(
            name: name,
            input: input,
            sourceRoot: sourceRoot,
            strategies: o.strategies,
            mappings: mappings,
            createdAt: Date(),
            lldbinitPath: nil,
            inlineBreakpoints: o.inlineBreakpoints
        )

        if o.strategies.contains(.patch) { try DWARFPatcher.validate(MappingResolver.widened(mappings)) }
        if o.dryRun {
            try dryRun(record, binaries: debugBinaries, options: o)
            return record
        }

        // 2. Apply. On failure, undo what was done so far.
        var registry = try Registry.load()
        do {
            for s in [Strategy.patch, .symlink, .lldbinit] where o.strategies.contains(s) {
                switch s {
                case .patch: try applyPatch(&record, binaries: debugBinaries, xcframeworks: inspection.located.xcframeworks, stripSignature: o.stripSignature)
                case .symlink: try applySymlinks(&record)
                case .lldbinit: record.lldbinitPath = PathUtil.absolute(o.lldbinitPath ?? LLDBInit.defaultPath)
                }
            }
            registry.records.append(record)
            try registry.save()
            if let path = record.lldbinitPath {
                try refreshLLDBInit(path, registry: registry)
                console.info("Updated \(PathUtil.tildeAbbreviated(path)) (source-map for '\(name)')")
            }
        } catch {
            try? rollback(record)
            if var r = try? Registry.load(), r.records.contains(where: { $0.name == name }) {
                r.records.removeAll { $0.name == name }
                try? r.save()
                if let path = record.lldbinitPath { try? refreshLLDBInit(path, registry: r) }
            }
            throw error
        }

        console.info("\nDone. Restart the debug session in Xcode\(o.strategies.contains(.patch) ? " and rebuild so the patched library is relinked" : ""). Undo with: xcsrclink unlink \(name)")
        return record
    }

    private func dryRun(_ record: LinkRecord, binaries: [DebugBinary], options o: LinkOptions) throws {
        console.info("\nDry run, nothing was changed.")
        if o.strategies.contains(.patch) {
            for b in binaries {
                let counts = try DWARFPatcher.patchFile(at: b.path, mappings: MappingResolver.widened(record.mappings), dryRun: true)
                console.info("  would patch \(counts.reduce(0, +)) path string(s) in \(b.path)")
            }
        }
        if o.strategies.contains(.symlink) {
            for m in record.mappings { console.info("  would symlink \(m.from) -> \(m.to)") }
        }
        if o.strategies.contains(.lldbinit) {
            let path = PathUtil.absolute(o.lldbinitPath ?? LLDBInit.defaultPath)
            var r = record
            r.lldbinitPath = path
            console.info("  would write to \(PathUtil.tildeAbbreviated(path)):\n" + (LLDBInit.render([r]) ?? ""))
        }
    }

    // MARK: - Strategies

    private func applyPatch(_ record: inout LinkRecord, binaries: [DebugBinary], xcframeworks: [String], stripSignature: Bool) throws {
        let fm = FileManager.default
        // Patching changes the bytes of a signed xcframework, and Xcode then refuses it.
        for xcf in xcframeworks {
            let sig = (xcf as NSString).appendingPathComponent("_CodeSignature")
            guard fm.fileExists(atPath: sig) else { continue }
            guard stripSignature else {
                throw LinkError("\(xcf) is code signed and patching would invalidate its signature, so Xcode would reject it. Re-run with --strip-signature (the signature is restored on unlink), or use --strategy lldbinit.")
            }
            let backup = try backupDirectory(for: record.name).appendingPathComponent("signature-\(record.movedSignatures.count)").path
            try fm.moveItem(atPath: sig, toPath: backup)
            record.movedSignatures[sig] = backup
            console.info("Moved code signature aside: \(sig)")
        }

        let backups = try backupDirectory(for: record.name)
        for (i, b) in binaries.enumerated() {
            let backup = backups.appendingPathComponent("\(i)-\((b.path as NSString).lastPathComponent)").path
            if fm.fileExists(atPath: backup) { try fm.removeItem(atPath: backup) }
            try fm.copyItem(atPath: b.path, toPath: backup)
            let counts = try DWARFPatcher.patchFile(at: b.path, mappings: MappingResolver.widened(record.mappings))
            let total = counts.reduce(0, +)
            if total == 0 {
                try? fm.removeItem(atPath: backup)
                continue
            }
            record.patchedFiles.append(PatchedFile(path: b.path, backup: backup, patchedSHA256: try sha256(b.path)))
            console.info("Patched \(total) path string(s) in \(b.path)")
        }
        warnAboutUnpatchedCopies(of: record.patchedFiles)
    }

    /// lldb finds a dSYM by its UUID through Spotlight, so an older copy elsewhere (DerivedData
    /// from an earlier build, another checkout) can be loaded instead of the patched one, and
    /// still shows the build machine's paths.
    private func warnAboutUnpatchedCopies(of patched: [PatchedFile]) {
        let patchedPaths = Set(patched.map { SourcePath($0.path) })
        var stale = Set<String>()
        for p in patched where p.path.contains(".dSYM/Contents/Resources/DWARF/") {
            guard let r = try? Shell.run("/usr/bin/xcrun", ["dwarfdump", "--uuid", p.path]), r.status == 0 else { continue }
            let uuids = r.stdout.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ")
                return parts.count > 1 && parts[0] == "UUID:" ? String(parts[1]) : nil
            }
            let dwarfName = (p.path as NSString).lastPathComponent
            for uuid in uuids {
                guard let found = try? Shell.run("/usr/bin/mdfind", ["com_apple_xcode_dsym_uuids == \(uuid)"]) else { continue }
                for bundle in found.stdout.split(separator: "\n").map(String.init) {
                    let file = (bundle as NSString).appendingPathComponent("Contents/Resources/DWARF/\(dwarfName)")
                    guard !patchedPaths.contains(SourcePath(file)), FileManager.default.fileExists(atPath: file),
                          (try? sha256(file)) != p.patchedSHA256 else { continue }
                    stale.insert(bundle)
                }
            }
        }
        guard !stale.isEmpty else { return }
        console.warn("""
            Other copies of the patched dSYM still have the build machine's paths. lldb finds dSYMs \
            by UUID and may load one of them instead. Rebuild the project each belongs to (Xcode \
            copies the dSYM again), or delete it:
            """ + stale.sorted().map { "\n  \(PathUtil.tildeAbbreviated($0))" }.joined())
    }

    private func applySymlinks(_ record: inout LinkRecord) throws {
        let fm = FileManager.default
        for m in record.mappings {
            guard m.from.hasPrefix("/") else {
                console.warn("skipping symlink for relative build path '\(m.from)'")
                continue
            }
            if let dest = try? fm.destinationOfSymbolicLink(atPath: m.from) {
                if PathUtil.absolute(dest) == m.to { continue }
                throw LinkError("\(m.from) is already a symlink to \(dest). Remove it first.")
            }
            if fm.fileExists(atPath: m.from) {
                throw LinkError("\(m.from) already exists and is not a symlink; refusing to replace it. Use --strategy lldbinit instead.")
            }
            // Create missing parents one by one so unlink can remove exactly those.
            var missing: [String] = []
            var dir = (m.from as NSString).deletingLastPathComponent
            while !fm.fileExists(atPath: dir) && dir != "/" {
                missing.insert(dir, at: 0)
                dir = (dir as NSString).deletingLastPathComponent
            }
            do {
                for d in missing {
                    try fm.createDirectory(atPath: d, withIntermediateDirectories: false)
                    record.createdDirectories.append(d)
                }
                try fm.createSymbolicLink(atPath: m.from, withDestinationPath: m.to)
                record.symlinks.append(m.from)
                console.info("Symlinked \(m.from) -> \(m.to)")
            } catch {
                let parent = missing.first ?? (m.from as NSString).deletingLastPathComponent
                throw LinkError("""
                couldn't create \(m.from): \(error.localizedDescription)
                  The build path's folder isn't writable. Make it yours once, then re-run:
                    sudo mkdir -p '\(parent)' && sudo chown "$USER" '\(parent)'
                  or use --strategy lldbinit, which needs no special permissions.
                """)
            }
        }
    }

    // MARK: - Unlink

    public func unlink(name: String, force: Bool) throws {
        var registry = try Registry.load()
        guard let idx = registry.records.firstIndex(where: { $0.name == name }) else {
            throw LinkError("no link named '\(name)'. See `xcsrclink list`.")
        }
        let record = registry.records[idx]
        try restore(record, force: force)
        registry.records.remove(at: idx)
        try registry.save()
        if let path = record.lldbinitPath {
            try refreshLLDBInit(path, registry: registry)
            console.info("Removed source-map for '\(name)' from \(PathUtil.tildeAbbreviated(path))")
        }
        try? FileManager.default.removeItem(at: backupRoot.appendingPathComponent(safeName(name)))
        console.info("Unlinked '\(name)'")
    }

    private func rollback(_ record: LinkRecord) throws {
        try restore(record, force: true)
    }

    private func restore(_ record: LinkRecord, force: Bool) throws {
        let fm = FileManager.default
        for p in record.patchedFiles {
            guard fm.fileExists(atPath: p.backup) else {
                console.warn("backup missing for \(p.path), leaving it patched")
                continue
            }
            if !force, fm.fileExists(atPath: p.path), (try? sha256(p.path)) != p.patchedSHA256 {
                console.warn("\(p.path) changed since it was patched (updated library?), not restoring it. Use --force to restore anyway.")
                continue
            }
            if fm.fileExists(atPath: p.path) { try fm.removeItem(atPath: p.path) }
            try fm.copyItem(atPath: p.backup, toPath: p.path)
            console.info("Restored \(p.path)")
        }
        for (original, backup) in record.movedSignatures where !fm.fileExists(atPath: original) {
            try fm.moveItem(atPath: backup, toPath: original)
            console.info("Restored code signature: \(original)")
        }
        for link in record.symlinks.reversed() {
            if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
                try fm.removeItem(atPath: link)
                console.info("Removed symlink \(link)")
            }
        }
        for dir in record.createdDirectories.reversed() {
            if (try? fm.contentsOfDirectory(atPath: dir))?.isEmpty == true { try? fm.removeItem(atPath: dir) }
        }
    }

    // MARK: - Helpers

    private func refreshLLDBInit(_ path: String, registry: Registry) throws {
        let records = registry.records.filter { $0.lldbinitPath == path }
        try LLDBInit.write(block: LLDBInit.render(records), to: path)
    }

    private var backupRoot: URL { URL(fileURLWithPath: PathUtil.home).appendingPathComponent("backups") }

    private func safeName(_ name: String) -> String {
        name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }.map(String.init).joined()
    }

    private func backupDirectory(for name: String) throws -> URL {
        let dir = backupRoot.appendingPathComponent(safeName(name))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
