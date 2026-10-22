import Foundation
import Testing
@testable import Core

@Suite struct PathTests {
    @Test func normalizesPaths() {
        #expect(SourcePath("/a//b/./c/").string == "/a/b/c")
        #expect(SourcePath("./Sources/A.swift").string == "Sources/A.swift")
        #expect(SourcePath("").string == ".")
    }

    @Test func mappingAppliesOnComponentBoundaries() {
        let m = PathMapping(from: "/ci/build", to: "/me/src")
        #expect(m.apply(to: "/ci/build/Foo/A.swift") == "/me/src/Foo/A.swift")
        #expect(m.apply(to: "/ci/build////Foo/A.swift") == "/me/src/Foo/A.swift")
        #expect(m.apply(to: "/ci/builder/A.swift") == nil)
    }

    @Test func filtersSystemPaths() {
        #expect(PathUtil.isSystemPath("/<compiler-generated>"))
        #expect(PathUtil.isSystemPath("/Applications/Xcode.app/Contents/Developer/Platforms/X.sdk/usr/include/a.h"))
        #expect(PathUtil.isSystemPath("_SwiftConcurrencyShims"))
        #expect(!PathUtil.isSystemPath("/Users/ci/MyLib/Sources/A.swift"))
    }
}

@Suite struct ResolverTests {
    func index(_ paths: [String]) -> [String: [SourcePath]] {
        Dictionary(grouping: paths.map(SourcePath.init), by: { $0.components.last! })
    }

    @Test func findsCommonRoot() {
        let r = MappingResolver.resolve(
            originals: ["/ci/job-1/MyLib/Sources/A.swift", "/ci/job-1/MyLib/Sources/Sub/B.swift"],
            index: index(["/Users/me/src/MyLib/Sources/A.swift", "/Users/me/src/MyLib/Sources/Sub/B.swift"])
        )
        #expect(r.mappings == [PathMapping(from: "/ci/job-1", to: "/Users/me/src")])
        #expect(r.unmatched.isEmpty)
    }

    @Test func capsMappingAtSourceRoot() {
        // --source /me/Proj/VendorSDK: the mapping must not cover /me/Proj (the app's own
        // files live there), or lldb would reverse-map the app's breakpoints to the CI path.
        let r = MappingResolver.resolve(
            originals: ["/ci/job/VendorSDK/Sources/Kit/A.swift", "/ci/job/VendorSDK/Sources/Kit/B.swift"],
            index: index(["/me/Proj/VendorSDK/Sources/Kit/A.swift", "/me/Proj/VendorSDK/Sources/Kit/B.swift"]),
            sourceRoot: SourcePath("/me/Proj/VendorSDK")
        )
        #expect(r.mappings == [PathMapping(from: "/ci/job/VendorSDK", to: "/me/Proj/VendorSDK")])
        #expect(r.matched.map(\.local) == ["/me/Proj/VendorSDK/Sources/Kit/A.swift", "/me/Proj/VendorSDK/Sources/Kit/B.swift"])
    }

    @Test func widensMappingsForPatching() {
        #expect(MappingResolver.widened([PathMapping(from: "/ci/job/VendorSDK", to: "/me/Proj/VendorSDK")])
                == [PathMapping(from: "/ci/job", to: "/me/Proj")])
        // Nothing shared: unchanged. Never widens to "/".
        #expect(MappingResolver.widened([PathMapping(from: "/ci/Lib/Sources", to: "/me/LibSrc")])
                == [PathMapping(from: "/ci/Lib/Sources", to: "/me/LibSrc")])
        #expect(MappingResolver.widened([PathMapping(from: "/ci/Lib", to: "/Lib")])
                == [PathMapping(from: "/ci/Lib", to: "/Lib")])
    }

    @Test func handlesRenamedFolder() {
        let r = MappingResolver.resolve(
            originals: ["/ci/MyLib/Sources/A.swift", "/ci/MyLib/Sources/B.swift"],
            index: index(["/me/MyLibSrc/A.swift", "/me/MyLibSrc/B.swift"])
        )
        #expect(r.mappings == [PathMapping(from: "/ci/MyLib/Sources", to: "/me/MyLibSrc")])
    }

    @Test func prefersLongestSharedTailAndReportsAmbiguity() {
        let r = MappingResolver.resolve(
            originals: ["/ci/X/Core/Util.swift", "/ci/X/UI/View.swift", "/ci/X/Other/Dup.swift"],
            index: index(["/me/X/Core/Util.swift", "/me/X/Legacy/Util.swift",
                          "/me/X/UI/View.swift", "/me/a/Dup.swift", "/me/b/Dup.swift"])
        )
        #expect(r.mappings == [PathMapping(from: "/ci", to: "/me")])
        #expect(r.ambiguous == ["/ci/X/Other/Dup.swift"])
    }

    @Test func splitsRootsThatDisagree() {
        // Two modules from one build root, checked out in different places locally.
        let r = MappingResolver.resolve(
            originals: ["/ci/w/Foo/A.swift", "/ci/w/Foo/B.swift", "/ci/w/Bar/C.swift"],
            index: index(["/me/Foo/A.swift", "/me/Foo/B.swift", "/other/Bar/C.swift"])
        )
        for o in ["/ci/w/Foo/A.swift", "/ci/w/Foo/B.swift"] {
            #expect(PathMapping.apply(r.mappings, to: o) == o.replacingOccurrences(of: "/ci/w", with: "/me"))
        }
        #expect(PathMapping.apply(r.mappings, to: "/ci/w/Bar/C.swift") == "/other/Bar/C.swift")
    }

    @Test func simplifyDropsImpliedMappings() {
        let s = MappingResolver.simplify([
            PathMapping(from: "/a", to: "/b"),
            PathMapping(from: "/a/x", to: "/b/x"),
            PathMapping(from: "/a/y", to: "/z"),
        ])
        #expect(s == [PathMapping(from: "/a/y", to: "/z"), PathMapping(from: "/a", to: "/b")])
    }
}

/// Builds a tiny 64-bit Mach-O object with one `__DWARF,__debug_str` section.
func makeMachO(debugStr: [UInt8], cstring: [UInt8] = []) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func name(_ s: String) { var b = Array(s.utf8); b += [UInt8](repeating: 0, count: 16 - b.count); d.append(contentsOf: b) }
    let nsects = 2
    let cmdSize = 72 + 80 * nsects
    let dataStart = 32 + cmdSize
    // mach_header_64
    u32(0xFEED_FACF); u32(0x0100_000C); u32(0); u32(1) /* MH_OBJECT */; u32(1); u32(UInt32(cmdSize)); u32(0); u32(0)
    // LC_SEGMENT_64
    u32(0x19); u32(UInt32(cmdSize)); name(""); u64(0); u64(0); u64(UInt64(dataStart)); u64(0); u32(7); u32(7); u32(UInt32(nsects)); u32(0)
    // sections
    func section(_ sect: String, _ seg: String, offset: Int, size: Int) {
        name(sect); name(seg); u64(0); u64(UInt64(size)); u32(UInt32(offset)); u32(0); u32(0); u32(0); u32(0); u32(0); u32(0); u32(0)
    }
    section("__cstring", "__TEXT", offset: dataStart, size: cstring.count)
    section("__debug_str", "__DWARF", offset: dataStart + cstring.count, size: debugStr.count)
    d.append(contentsOf: cstring)
    d.append(contentsOf: debugStr)
    return d
}

func makeArchive(members: [(String, Data)]) -> Data {
    var d = Data("!<arch>\n".utf8)
    for (n, body) in members {
        func field(_ s: String, _ w: Int) { d.append(contentsOf: Array((s + String(repeating: " ", count: w)).utf8.prefix(w))) }
        var name = Array(n.utf8)
        while (name.count + 60) % 8 != 0 { name.append(0) }
        field("#1/\(name.count)", 16); field("0", 12); field("0", 6); field("0", 6); field("100644", 8)
        field("\(name.count + body.count)", 10); d.append(contentsOf: Array("`\n".utf8))
        d.append(contentsOf: name); d.append(body)
        if d.count % 2 == 1 { d.append(0x0A) }
    }
    return d
}

/// A 32-bit fat header with each slice aligned to 2^14, like `lipo` writes.
func makeFat(slices: [Data]) -> Data {
    var d = Data()
    func be32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
    let align = 1 << 14
    be32(0xCAFE_BABE); be32(UInt32(slices.count))
    var offset = align
    for s in slices {
        be32(0x0100_000C); be32(0); be32(UInt32(offset)); be32(UInt32(s.count)); be32(14)
        offset += (s.count + align - 1) / align * align
    }
    for s in slices {
        d.append(Data(count: (d.count + align - 1) / align * align - d.count))
        d.append(s)
    }
    return d
}

@Suite struct PatcherTests {
    let build = "/ci/agent/build/MyLib"
    var strings: [UInt8] {
        Array("\0\(build)/Sources/A.swift\0\(build)\0/x\(build)/nope.swift\0/ci/agent/build/MyLibOther/B.swift\0".utf8)
    }

    @Test func findsDWARFInArchiveMembersOnly() throws {
        let obj = makeMachO(debugStr: strings, cstring: Array("\(build)/Sources/A.swift\0".utf8))
        let ar = makeArchive(members: [("A.o", obj), ("B.o", obj)])
        let ranges = ar.withUnsafeBytes { MachO.dwarfSectionRanges(in: $0) }
        #expect(ranges.count == 2)
        #expect(ranges.allSatisfy { $0.count == strings.count })
    }

    @Test func rewritesOnlyPathBoundariesAndKeepsSize() throws {
        var data = makeArchive(members: [("A.o", makeMachO(debugStr: strings, cstring: Array("\(build)/Sources/A.swift\0".utf8)))])
        let size = data.count
        let counts = try DWARFPatcher.patch(&data, mappings: [PathMapping(from: build, to: "/me/MyLib")])
        #expect(counts == [2])
        #expect(data.count == size)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("/me/MyLib" + String(repeating: "/", count: build.count - "/me/MyLib".count + 1) + "Sources/A.swift\0"))
        #expect(text.contains("\0/x\(build)/nope.swift"))         // tail of another path: untouched
        #expect(text.contains("/ci/agent/build/MyLibOther/B.swift")) // not a component boundary: untouched
        #expect(text.contains("\(build)/Sources/A.swift\0\0/me/MyLib")) // __cstring (#file literals): untouched
        let patched = data.withUnsafeBytes { buf in
            MachO.dwarfSectionRanges(in: buf).map { String(decoding: buf[$0], as: UTF8.self) }.joined()
        }
        let paths = patched.split(separator: "\0").map(String.init).filter { $0.hasPrefix("/me") }
        #expect(paths.map { SourcePath($0).string } == ["/me/MyLib/Sources/A.swift", "/me/MyLib"])
    }

    /// `lipo -create` of per-arch `.a` files gives a fat file whose slices are archives.
    @Test func recognizesFatArchivesAsStaticLibraries() throws {
        let ar = makeArchive(members: [("A.o", makeMachO(debugStr: strings))])
        let fatOfArchives = makeFat(slices: [ar, ar])
        let fatOfMachO = makeFat(slices: [makeMachO(debugStr: strings)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcsrclink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = [("fat.a", fatOfArchives), ("plain.a", ar), ("fat.dylib", fatOfMachO)]
        for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }

        #expect(MachO.isStaticArchive(fileAt: dir.appendingPathComponent("fat.a").path))
        #expect(MachO.isStaticArchive(fileAt: dir.appendingPathComponent("plain.a").path))
        #expect(!MachO.isStaticArchive(fileAt: dir.appendingPathComponent("fat.dylib").path))
        #expect(fatOfArchives.withUnsafeBytes { MachO.dwarfSectionRanges(in: $0) }.count == 2)
    }

    @Test func refusesLongerReplacement() {
        var data = makeMachO(debugStr: strings)
        #expect(throws: PatchError.self) {
            try DWARFPatcher.patch(&data, mappings: [PathMapping(from: "/ci", to: "/Users/someone/very/long")])
        }
    }
}

@Suite struct LLDBInitTests {
    @Test func writesAndRemovesManagedBlockPreservingUserContent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lldbinit-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        try "command alias pp po\n".write(toFile: file, atomically: true, encoding: .utf8)

        let record = LinkRecord(name: "MyLib", input: "/x/MyLib.xcframework", sourceRoot: nil, strategies: [.lldbinit],
                                mappings: [PathMapping(from: "/ci/a \"b\"", to: "/me/src")], createdAt: Date(),
                                lldbinitPath: file, inlineBreakpoints: true)
        try LLDBInit.write(block: LLDBInit.render([record]), to: file)
        try LLDBInit.write(block: LLDBInit.render([record]), to: file) // idempotent
        let text = try String(contentsOfFile: file, encoding: .utf8)
        #expect(text.hasPrefix("command alias pp po\n"))
        #expect(text.components(separatedBy: LLDBInit.begin).count == 2)
        #expect(text.contains(#"settings append target.source-map "/ci/a \"b\"" "/me/src""#))
        #expect(text.contains("target.inline-breakpoint-strategy always"))

        try LLDBInit.write(block: nil, to: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "command alias pp po\n")
    }
}
