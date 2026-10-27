---
name: xcsrclink
description: Source-debug prebuilt iOS/macOS libraries (.a, .framework, .xcframework, dSYM) with the xcsrclink CLI. Use when breakpoints in a vendor/binary library's source never bind, Step Into shows assembly instead of source, or the user wants to map a binary's build-machine paths to a local checkout, or mentions xcsrclink.
---

# xcsrclink

A library built with `-g` records the absolute **build paths** of its sources on the machine that built it. lldb can't find those files locally, so breakpoints stay pending and Step Into lands in assembly. `xcsrclink link` maps the build paths to a local checkout; `xcsrclink unlink` undoes it. `xcsrclink help` is the source of truth for flags.

## Steps

1. **Check the tool.** `xcsrclink --version`. If missing: download the universal tarball from https://github.com/foxsin10/xcsrclink/releases and `install -m 755 .../xcsrclink ~/.local/bin/`, or `make install` from a clone. Requires macOS 13+ and Xcode.

2. **Inspect the library.** `xcsrclink info <path> --files`, where `<path>` is the `.xcframework`, `.framework`, `.a`, `.dSYM`, or a folder of them (`Pods/`, `Carthage/Build/`). Done when it lists source files and their build roots.
   - SwiftPM `binaryTarget`: a `path:` xcframework is at that path; `url:` and zipped ones are unpacked into `.build/artifacts/<package>/<target>/` (Xcode: `DerivedData/<App>-<hash>/SourcePackages/artifacts/`); remote packages' files are in `.build/checkouts/`. The package root works as `<path>` too, and a single target's `.xcframework` links just that one (see Examples). `.zip` files aren't read: use the unpacked copy. Prefer the `lldbinit` strategy: SwiftPM discards a patched copy when it unpacks again.
   - "no source paths" or "dynamic framework with no dSYM": there is nothing to map. A static `.a` carries its own debug info; a dynamic framework needs the dSYM of that exact build (matched by UUID). Tell the user to get the dSYM from the vendor or rebuild with `-g`, and stop.
   - "not found": the path is wrong. Locate the library (`find . -name '*.xcframework'`) before going on.

3. **Find the local source.** A checkout of the library at the commit the binary was built from (otherwise line numbers drift). Pick `--source` as the folder whose name matches the last folder of the build root that `info` printed, e.g. build root `.../job-48213/VendorSDK` → `--source path/to/VendorSDK`. Mappings never reach above `--source`, which keeps them off the app's own files.

4. **Dry run.** `xcsrclink link <path> --source <dir> --dry-run` (add options from step 5). Done when the header reads `N/N source files found locally` and each mapping ends in the same folder name on both sides. Unmatched or ambiguous files: narrow `--source`, or give explicit `--map <build>=<local>` pairs.

5. **Choose where the mapping goes**, then run the same command without `--dry-run`:
   - **Default, `lldbinit` strategy**: writes `target.source-map` to `~/.lldbinit-Xcode` if it exists, else `~/.lldbinit`. Changes no binaries, applies to every Xcode debug session.
   - **Per project, `--lldbinit <file>`**: writes to that file and sets Run › Info › LLDB Init File to `$(SRCROOT)/<relative path>` in the schemes of the Xcode project found in the file's folder or its parents. Put the file next to the `.xcodeproj` so the project is found. A file in a sibling folder needs `--scheme path/to/Name.xcscheme`; an unsaved (auto-created) scheme needs the same. The file holds local paths: make sure `.gitignore` covers it. `--scheme <name>` limits edits, `--no-scheme` skips them. A scheme that already uses another init file is left alone; add `command source <file>` to that file.
   - **`--strategy patch`**: rewrites paths inside the `.a`/dSYM (backed up, restored on unlink). Use when no lldb config is wanted or teammates should share the fix. Local path must be no longer than the build path; signed xcframeworks need `--strip-signature`; rebuild in Xcode afterwards.
   - **`--strategy symlink`**: symlink at the build path. Breakpoints only bind in files opened from the build path; may need `sudo` once for the parent folder. Last resort.

6. **Verify in Xcode.** Quit and reopen Xcode if it was open while linking (it keeps one lldb running, so old mappings stay loaded), then run, break at a call into the library, and press Step Into (F7). Done when the library's source file opens. If not, read [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Examples

Layout (the repo's `TestProject/`, commands run from it):

```
DemoApp/DemoApp.xcodeproj         app project, shared scheme "DemoApp"
DemoApp/Frameworks/               prebuilt xcframeworks
VendorSDK/Sources/DynamicKit/     local source of DynamicKit
```

Per-project lldbinit next to the `.xcodeproj`: the scheme is found on its own and set to `$(SRCROOT)/xcsrclink.lldbinit`.

```sh
xcsrclink link DemoApp/Frameworks/DynamicKit.xcframework --source VendorSDK/Sources/DynamicKit \
  --lldbinit DemoApp/xcsrclink.lldbinit
```

lldbinit in a sibling folder of the project: name the scheme file. It is set to `$(SRCROOT)/../VendorSDK/xcsrclink.lldbinit`.

```sh
xcsrclink link DemoApp/Frameworks/DynamicKit.xcframework --source VendorSDK/Sources/DynamicKit \
  --lldbinit VendorSDK/xcsrclink.lldbinit \
  --scheme DemoApp/DemoApp.xcodeproj/xcshareddata/xcschemes/DemoApp.xcscheme
```

`xcsrclink unlink DynamicKit` reverts either one: mappings, the scheme setting, and the emptied lldbinit file.

SwiftPM, one binary target at a time (the `SPMDemo/` app; `VendorPackage` ships StaticKit and DynamicKit zipped, ObjCKit as a folder). Pass the target's `.xcframework`: a `path:` one where it is, a zipped or `url:` one from Xcode's unpacked copy. Each link is named after its library, and they can share one lldbinit:

```sh
xcsrclink link SPMDemo/VendorPackage/Binaries/ObjCKit.xcframework --source VendorSDK --lldbinit SPMDemo/xcsrclink.lldbinit
A=$(ls -d ~/Library/Developer/Xcode/DerivedData/SPMDemo-*/SourcePackages/artifacts/vendorpackage)
xcsrclink link $A/StaticKit/StaticKit.xcframework --source VendorSDK --lldbinit SPMDemo/xcsrclink.lldbinit
xcsrclink unlink StaticKit   # only that one; the scheme setting stays until the last link using the file is gone
```

A folder (`.../SourcePackages/artifacts`, `.build/artifacts`, the package root) links every binary target in it at once; give it `--name`.

```sh
xcsrclink link SPMDemo/VendorPackage/Binaries --source VendorSDK --name VendorBinaries --lldbinit SPMDemo/xcsrclink.lldbinit
```

## Undo

`xcsrclink list` shows links (name, strategy, mappings, lldbinit, schemes). `xcsrclink unlink <name>` (or `--all`) restores patched binaries, removes symlinks and mappings, and removes the scheme setting once no other link uses that lldbinit file. Relinking the same name replaces the old link.
