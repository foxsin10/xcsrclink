# xcsrclink test project

An iOS app that uses three prebuilt vendor libraries, built so their debug info points at
a CI machine path that doesn't exist on your Mac. Use it to watch the problem happen in
Xcode, then fix it with `xcsrclink`. `SPMDemo` is the same app getting the libraries
through a Swift package; see [SwiftPM version](#swiftpm-version-spmdemo).

```Markdown
TestProject/
├── VendorSDK/Sources/        the libraries' source: your "local checkout"
│   ├── StaticKit/            Swift  → static library (.a) xcframework
│   ├── DynamicKit/           Swift  → dynamic framework + dSYM xcframework
│   └── ObjCKit/              Obj-C  → static library (.a) xcframework
├── DemoApp/
│   ├── DemoApp.xcodeproj     iOS SwiftUI app linking all three
│   ├── DemoApp/              ContentView.swift: one button per library
│   └── Frameworks/           built xcframeworks (generated, git-ignored)
├── SPMDemo/
│   ├── SPMDemo.xcodeproj     the same app (shares DemoApp/DemoApp/*.swift), libraries via SwiftPM
│   └── VendorPackage/        local Swift package: the three libraries as binaryTargets
│       └── Binaries/         StaticKit/DynamicKit zipped, ObjCKit as is (generated, git-ignored)
└── scripts/
    ├── build-sdk.sh          builds the xcframeworks "on CI"
    └── verify.sh             automated simulator + lldb check of every strategy (APP=SPMDemo for SPMDemo)
```

Source lines worth breaking on are marked `// BREAKPOINT ...` in `VendorSDK`, and the
app's call sites are marked `// STEP INTO ...` in `ContentView.swift`.

## 1. Build the vendor libraries

```sh
TestProject/scripts/build-sdk.sh
```

This copies `VendorSDK/Sources` to
`/tmp/xcsrclink-ci/buildkite-agent-07/workspace/ios-sdk-release/builds/job-48213`,
compiles there with `-g` for device and simulator, writes the xcframeworks to
`DemoApp/Frameworks` (and copies them into `SPMDemo/VendorPackage/Binaries`), and deletes
the CI copy. Check what got recorded:

```sh
xcsrclink info TestProject/DemoApp/Frameworks --files
```

## 2. See the problem in Xcode

1. Open `TestProject/DemoApp/DemoApp.xcodeproj` and run the **DemoApp** scheme on an
   iPhone simulator.
2. Add a breakpoint at `VendorSDK/Sources/StaticKit/Greeter.swift` on the
   `BREAKPOINT StaticKit.greeting` line (drag the file into Xcode or open it with ⌘⇧O).
3. Tap **StaticKit**. The breakpoint is never hit.
4. Add a breakpoint on a `STEP INTO` line in `ContentView.swift`, tap its button, and
   press Step Into (F7). You get assembly, not source.

## 3. Fix it

By default `xcsrclink` adds its mappings to `~/.lldbinit-Xcode` (if it exists) or
`~/.lldbinit`, which Xcode reads for every debug session. From `TestProject/`:

```sh
cd TestProject

# All three libraries at once
xcsrclink link DemoApp/Frameworks --source VendorSDK --name VendorSDK

# ...or a single one. The link name defaults to the library name (here "DynamicKit").
xcsrclink link DemoApp/Frameworks/DynamicKit.xcframework --source VendorSDK
```

To keep your global lldbinit untouched, pass `--lldbinit DemoApp/xcsrclink.lldbinit`. It
also sets the DemoApp scheme's Edit Scheme › Run › Info › LLDB Init File to
`$(SRCROOT)/xcsrclink.lldbinit`, and `unlink` puts the scheme back.

The scheme is found only when the Xcode project is in the lldbinit file's folder or a
parent folder. For a file somewhere else, such as `VendorSDK/xcsrclink.lldbinit`, the
project is in a sibling folder and no scheme is changed (you get a warning). Pass the
scheme's path instead:

```sh
xcsrclink link DemoApp/Frameworks/DynamicKit.xcframework --source VendorSDK/Sources/DynamicKit \
  --lldbinit VendorSDK/xcsrclink.lldbinit \
  --scheme DemoApp/DemoApp.xcodeproj/xcshareddata/xcschemes/DemoApp.xcscheme
```

This sets the LLDB Init File to `$(SRCROOT)/../VendorSDK/xcsrclink.lldbinit`. Note that the
repo's `.gitignore` only covers `*.lldbinit` in `TestProject/` and `TestProject/DemoApp/`,
so a file in `VendorSDK/` would show up in `git status`. `DemoApp/xcsrclink.lldbinit`
needs neither `--scheme` nor any `.gitignore` change.
`*.lldbinit` files in the repo are git-ignored, since they contain your local paths.

Add `--dry-run` first to preview. The mapping it prints should end in `VendorSDK` on
both sides:

```sh
/tmp/xcsrclink-ci/.../job-48213/VendorSDK
  -> .../TestProject/VendorSDK
```

`xcsrclink list` shows what's linked. Undo with `xcsrclink unlink VendorSDK` (or
`xcsrclink unlink DynamicKit`).

Other strategies to try (unlink between them; run from the repo root):

```sh
# Rewrite the paths inside the binaries. Rebuild (⌘B) afterwards so Xcode re-copies them.
xcsrclink link TestProject/DemoApp/Frameworks --source TestProject/VendorSDK --name VendorSDK --strategy patch
# Check: every library now reports "N found at their recorded path", with no lldbinit file
xcsrclink info TestProject/DemoApp/Frameworks

# cocoapods-imy-bin style: a symlink at the CI path. Step Into works; breakpoints bind in
# the files Xcode opens from the /tmp/xcsrclink-ci/... path.
xcsrclink link TestProject/DemoApp/Frameworks --source TestProject/VendorSDK --name VendorSDK --strategy symlink
```

## 4. Step into the library in Xcode

1. Quit and reopen Xcode if it was open while you linked or unlinked (see
   [Troubleshooting](#troubleshooting)). Otherwise just stop the app (⌘.).
2. In `ContentView.swift`, put a breakpoint on the line marked
   `// STEP INTO DynamicKit` (`Calculator.average(of:)`).
3. Run (⌘R) on an iPhone simulator and tap **DynamicKit**. Xcode pauses there.
4. Press **F7** (Step Into). Xcode opens `VendorSDK/Sources/DynamicKit/Calculator.swift`
   at `guard !values.isEmpty`.
   - **F6** steps over line by line. **F7** on `Stats.sum(values)` goes into `Stats.swift`.
   - **F8** continues to the next breakpoint.
5. Breakpoints directly in library files also work. Open one with ⌘⇧O (or drag it in
   from Finder) and click the gutter on a `// BREAKPOINT ...` line:

   | Library | File | Marker |
   |---|---|---|
   | StaticKit | `Greeter.swift`, `TextStyler.swift` | `BREAKPOINT StaticKit.greeting`, `.decorate` |
   | DynamicKit | `Calculator.swift`, `Stats.swift` | `BREAKPOINT DynamicKit.average`, `.sum` |
   | ObjCKit | `OCKCounter.m` | `BREAKPOINT ObjCKit.increment` |

   Each works only for libraries you linked.

## SwiftPM version (SPMDemo)

`SPMDemo/SPMDemo.xcodeproj` is the same app (it compiles `DemoApp/DemoApp/*.swift`), but
it gets the three libraries from a local Swift package, `SPMDemo/VendorPackage`, the way
SDKs ship for SwiftPM:

| Library | In `Package.swift` | Where Xcode builds it from |
|---|---|---|
| StaticKit, DynamicKit | `.binaryTarget(path: "Binaries/X.xcframework.zip")` | unpacked into `DerivedData/SPMDemo-<hash>/SourcePackages/artifacts/vendorpackage/X/`, as for a remote `url:` binary target |
| ObjCKit | `.binaryTarget(path: "Binaries/ObjCKit.xcframework")` | used in place, from the package |

`build-sdk.sh` fills `VendorPackage/Binaries`. Open the project, run **SPMDemo**, and set
breakpoints as in [step 4](#4-step-into-the-library-in-xcode). To fix it, link both
places. Find the DerivedData folder under Xcode › Settings › Locations, or with
`ls -d ~/Library/Developer/Xcode/DerivedData/SPMDemo-*`:

```sh
cd TestProject
xcsrclink link SPMDemo/VendorPackage/Binaries --source VendorSDK --name VendorBinaries
xcsrclink link ~/Library/Developer/Xcode/DerivedData/SPMDemo-*/SourcePackages/artifacts \
  --source VendorSDK --name VendorArtifacts
```

Or link one library at a time by passing its `.xcframework`. The link is named after it:

```sh
xcsrclink link SPMDemo/VendorPackage/Binaries/ObjCKit.xcframework --source VendorSDK
A=$(ls -d ~/Library/Developer/Xcode/DerivedData/SPMDemo-*/SourcePackages/artifacts/vendorpackage)
xcsrclink link $A/StaticKit/StaticKit.xcframework --source VendorSDK
xcsrclink link $A/DynamicKit/DynamicKit.xcframework --source VendorSDK
xcsrclink unlink StaticKit   # just that one
```

Linking `VendorPackage/Binaries` as a folder covers only ObjCKit: the `.zip` files there
aren't read, so StaticKit and DynamicKit always come from the unpacked copies.

All links can share one per-project lldbinit: add `--lldbinit SPMDemo/xcsrclink.lldbinit`
to each, and the SPMDemo scheme is pointed at it. `patch` works too and survives normal
rebuilds. When Xcode unpacks the zips again (after Reset Package Caches, or a new
version of the package), the original binaries come back and you need to relink.

## Troubleshooting

In the debug console (⌘⇧Y) while paused:

```lldb
(lldb) settings show target.source-map
(lldb) breakpoint list
(lldb) image list DynamicKit
```

- **Breakpoints stay "pending", or `breakpoint list` shows `/tmp/xcsrclink-ci/...`
  paths for the app's own files.** Xcode keeps one lldb running between runs, so
  mappings from earlier links stay loaded (the same mapping may appear several times).
  Quit and reopen Xcode, or run `settings clear target.source-map` and run again. Links
  made before xcsrclink capped mappings at `--source` covered all of `TestProject/`;
  relink with the current version.
- **`target.source-map` is empty.** Xcode didn't read the file you linked into. Check
  which of `~/.lldbinit-Xcode` and `~/.lldbinit` you used (Xcode prefers the first if it
  exists), or, with `--lldbinit`, that the scheme's LLDB Init File points to it.
- **DynamicKit shows assembly.** Its dSYM wasn't found (`image list DynamicKit` shows no
  second line). Load it with
  `add-dsym TestProject/DemoApp/Frameworks/DynamicKit.xcframework/ios-arm64_x86_64-simulator/dSYMs/DynamicKit.framework.dSYM`.
- **DynamicKit shows assembly after `patch`.** lldb loaded an unpatched copy of the dSYM
  with the same UUID. The second line of `image list DynamicKit` shows which one. Here
  that is usually `build/` or `build-spm/` (left by `verify.sh`) or SPMDemo's
  DerivedData, which still hold the original. They're build output: delete them, then
  quit and reopen Xcode. `xcsrclink info DemoApp/Frameworks/DynamicKit.xcframework
  --copies` lists every copy, ✓ patched or ✗ not.
- **"non-launching port is incompatible with service identifier
  com.apple.PointerUI..."** is simulator log noise; ignore it.

## Automated check

```sh
TestProject/scripts/verify.sh            # SIM_UDID=<udid> to choose a simulator, KEEP=1 to keep lldb logs
APP=SPMDemo TestProject/scripts/verify.sh  # the same checks for the SwiftPM version
```

For the baseline and each strategy, the script builds the app with `xcodebuild` and
launches it in a simulator with `-xcsrclink-autorun`, which makes it call each library
once and exit. It attaches lldb the way Xcode does, then checks that breakpoints in all
three libraries stop with source shown and that stepping into `Calculator.average`
lands in source. The app breakpoint is set by its full path, as Xcode does, so a mapping
that wrongly covers the app's own files fails the check. It also checks that `unlink`
restores everything, and that a rebuild keeps the patched libraries. For SPMDemo it links
`VendorPackage/Binaries` and the `SourcePackages/artifacts` of its own DerivedData
(`TestProject/build-spm`).

## Notes on the setup

- Only DynamicKit ships a dSYM. StaticKit and ObjCKit are static libraries, whose debug
  info lives inside the `.a`, so they need none. See
  [Does it need a dSYM?](../README.md#does-it-need-a-dsym).
- Swift static libraries (`.a`) in an xcframework keep their `.swiftmodule` under
  `Headers/`, which Xcode copies to `$(BUILT_PRODUCTS_DIR)/include`. The app target adds
  that folder to `SWIFT_INCLUDE_PATHS` so `import StaticKit` works. Real vendors that
  ship Swift `.a` xcframeworks need the same setting.
- Debug builds link the libraries from Xcode's copy in DerivedData
  (`build/Build/Products/...` here), not from `DemoApp/Frameworks`. That is why `patch`
  needs a rebuild.
- `verify.sh` turns off lldb's Spotlight dSYM lookup and loads `DynamicKit`'s dSYM from
  its own build (`target symbols add`). Otherwise lldb may pick another copy with the same
  UUID, such as the one in your own Xcode DerivedData, which `patch` doesn't touch, and
  the patch check fails. If Xcode shows assembly for DynamicKit after
  linking, the dSYM wasn't found; see [Troubleshooting](#troubleshooting). In testing,
  Xcode found it inside the xcframework on its own.
