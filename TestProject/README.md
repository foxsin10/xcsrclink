# xcsrclink test project

An iOS app that uses three prebuilt vendor libraries, built so their debug info points at
a CI machine path that doesn't exist on your Mac. Use it to watch the problem happen in
Xcode, then fix it with `xcsrclink`.

```Markdown
TestProject/
├── VendorSDK/Sources/        the libraries' source: your "local checkout"
│   ├── StaticKit/            Swift  → static library (.a) xcframework
│   ├── DynamicKit/           Swift  → dynamic framework + dSYM xcframework
│   └── ObjCKit/              Obj-C  → static library (.a) xcframework
├── DemoApp/
│   ├── DemoApp.xcodeproj     iOS SwiftUI app linking all three
│   ├── DemoApp/              ContentView.swift: one button per library
│   ├── Frameworks/           built xcframeworks (generated, git-ignored)
│   └── xcsrclink.lldbinit    the scheme's LLDB init file (Edit Scheme › Run › Info)
└── scripts/
    ├── build-sdk.sh          builds the xcframeworks "on CI"
    └── verify.sh             automated simulator + lldb check of every strategy
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
`DemoApp/Frameworks`, and deletes the CI copy. Check what got recorded:

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

The scheme reads `DemoApp/xcsrclink.lldbinit`, so point `xcsrclink` there to keep your
`~/.lldbinit` untouched. From `TestProject/`:

```sh
cd TestProject

# All three libraries at once
xcsrclink link DemoApp/Frameworks --source VendorSDK \
  --name VendorSDK --lldbinit DemoApp/xcsrclink.lldbinit

# ...or a single one. The link name defaults to the library name (here "DynamicKit").
xcsrclink link DemoApp/Frameworks/DynamicKit.xcframework --source VendorSDK \
  --lldbinit DemoApp/xcsrclink.lldbinit
```

Add `--dry-run` first to preview. The mapping it prints should end in `VendorSDK` on
both sides:

```
/tmp/xcsrclink-ci/.../job-48213/VendorSDK
  -> .../TestProject/VendorSDK
```

`xcsrclink list` shows what's linked. Undo with `xcsrclink unlink VendorSDK` (or
`xcsrclink unlink DynamicKit`).

Other strategies to try (unlink between them; run from the repo root):

```sh
# Rewrite the paths inside the binaries. Rebuild (⌘B) afterwards so Xcode re-copies them.
xcsrclink link TestProject/DemoApp/Frameworks --source TestProject/VendorSDK --name VendorSDK --strategy patch

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

## Troubleshooting

In the debug console (⌘⇧Y) while paused:

```
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
- **`target.source-map` is empty.** Check that Edit Scheme › Run › Info › LLDB Init File
  is `$(SRCROOT)/xcsrclink.lldbinit`.
- **DynamicKit shows assembly.** Its dSYM wasn't found (`image list DynamicKit` shows no
  second line). Load it with
  `add-dsym TestProject/DemoApp/Frameworks/DynamicKit.xcframework/ios-arm64_x86_64-simulator/dSYMs/DynamicKit.framework.dSYM`.
- **"non-launching port is incompatible with service identifier
  com.apple.PointerUI..."** is simulator log noise; ignore it.

## Automated check

```sh
TestProject/scripts/verify.sh            # SIM_UDID=<udid> to choose a simulator, KEEP=1 to keep lldb logs
```

For the baseline and each strategy, the script builds the app with `xcodebuild` and
launches it in a simulator with `-xcsrclink-autorun`, which makes it call each library
once and exit. It attaches lldb the way Xcode does, then checks that breakpoints in all
three libraries stop with source shown and that stepping into `Calculator.average`
lands in source. The app breakpoint is set by its full path, as Xcode does, so a mapping
that wrongly covers the app's own files fails the check. It also checks that `unlink`
restores everything.

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
