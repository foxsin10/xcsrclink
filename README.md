# xcsrclink

Debug prebuilt `.a` / `.xcframework` libraries in Xcode as if they were source: set
breakpoints in the library's `.swift` / `.m` files and **step into** its code, instead of
landing in assembly.

This is the "source debugging for binaries" feature of
[cocoapods-imy-bin](https://github.com/MeetYouDevs/cocoapods-imy-bin) (`pod bin code`)
as a standalone CLI. It works with any dependency manager: CocoaPods, SPM binary
targets, Carthage, or a vendored folder.

## Why it's needed

A library compiled with `-g` records the **absolute paths of its source files on the
build machine** in its DWARF debug info, e.g.
`/Users/ci/builds/job-48213/MyLib/Sources/Greeter.swift`. On your machine those files
don't exist, so lldb can't show source or match your breakpoints to code.
`xcsrclink` connects those recorded paths to your local checkout.

## Install

Prebuilt binary (Apple silicon + Intel): download `xcsrclink-<version>-macos-universal.tar.gz`
from [Releases](https://github.com/foxsin10/xcsrclink/releases), then

```sh
tar xzf xcsrclink-*-macos-universal.tar.gz
xattr -d com.apple.quarantine xcsrclink-*-macos-universal/xcsrclink   # if macOS blocks it
install -m 755 xcsrclink-*-macos-universal/xcsrclink ~/.local/bin/
```

From source:

```sh
make install                      # builds release and copies to ~/.local/bin/xcsrclink (no sudo)
make install PREFIX=/opt/homebrew # or another folder you can write to
make uninstall                    # same PREFIX as install
# or
swift build -c release && cp .build/release/xcsrclink /somewhere/on/PATH
```

`/usr/local/bin` is owned by root on most Macs. To install there, run `make build` first,
then `sudo make install PREFIX=/usr/local`. `make install` stops with a hint if the
target folder isn't writable, and warns if it isn't on your `PATH`.

Requires macOS 13+ and Xcode (it uses `xcrun dwarfdump`).

## Usage

```sh
# 1. What paths did the vendor's build record?
xcsrclink info Pods/MyLib/MyLib.xcframework

# 2. Map them to your checkout of the library's source (matched automatically).
xcsrclink link Pods/MyLib/MyLib.xcframework --source ~/src/MyLib

# 3. Restart the debug session in Xcode. Breakpoints and step-into now work.

xcsrclink list            # what's linked
xcsrclink unlink MyLib    # undo everything for that library
```

`<path>` can be an `.xcframework`, `.framework`, `.a`, `.dSYM`, or a folder containing
them (`Pods/`, `Carthage/Build/`, ...). Inside an xcframework every slice is handled,
including dSYMs shipped under `DebugSymbolsPath`.

### Strategies (`--strategy`, comma-separated)

| Strategy | What it does | Breakpoints on your local files | Changes binaries | Notes |
|---|---|---|---|---|
| `lldbinit` (default) | Adds `settings append target.source-map <build> <local>` to `~/.lldbinit-Xcode` (if it exists) or `~/.lldbinit` | ✅ | No | Safest. Applies to every Xcode debug session. |
| `patch` | Rewrites the paths inside the `.a` / dSYM DWARF in place, padding with `/` so no size or offset changes. Originals are backed up to `~/.xcsrclink/backups` | ✅ | Yes (restored on `unlink`) | No lldb config needed, so it also works for teammates if you commit the patched binary. The local path must be no longer than the build path. Rebuild after patching. |
| `symlink` | Creates a symlink at the original build path pointing to your source (the cocoapods-imy-bin approach) | Only in files opened from the build path, e.g. after stepping in | No | May need `sudo` once to create the build path's parent folder. |

Strategies can be combined, e.g. `--strategy patch,lldbinit`.

### Options

```Bash
-s, --source <dir>        local checkout (paths are matched by their longest shared tail)
-m, --map <old>=<new>     explicit mapping, repeatable (skips matching)
-n, --name <name>         link name (default: library name)
    --lldbinit <file>     lldbinit to edit instead of the global one, e.g. a per-project file.
                          Also sets Run › Info › LLDB Init File to $(SRCROOT)/<file> in the
                          schemes of the Xcode project at or above <file>
    --scheme <name|path>  only edit this scheme, repeatable (a .xcscheme path also works)
    --no-scheme           with --lldbinit, leave the schemes alone
    --no-inline-breakpoints  don't add target.inline-breakpoint-strategy=always
    --strip-signature     allow `patch` on a code-signed xcframework (signature restored on unlink)
    --dry-run             print what would change
```

With `--lldbinit`, `unlink` removes the scheme setting again once no other link writes to
that file, and deletes the file if nothing else is left in it. A scheme that already uses
a different LLDB Init File is left alone; add `command source <file>` to that file instead.
The project is searched for only in the lldbinit file's folder and its parents, not in
sibling or child folders. For a file elsewhere, such as next to the library's source, pass
the scheme's path; the value written is then relative, e.g. `$(SRCROOT)/../Vendor/x.lldbinit`:

```Bash
xcsrclink link Frameworks/MyLib.xcframework --source Vendor/MyLib --lldbinit Vendor/x.lldbinit \
  --scheme App/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme
```

The same applies if Xcode never saved the scheme (no `.xcscheme` file yet): pass `--scheme`
with its path, or set the field by hand. The lldbinit file holds your local paths, so
git-ignore it wherever you put it.

### How matching works

For each source file recorded in the binary, `xcsrclink` finds the local file with the
same name that shares the longest trailing path, e.g.

```Bash
/Users/ci/builds/job-48213/MyLib/Sources/Greeter.swift   (recorded)
          /Users/me/src/MyLib/Sources/Greeter.swift      (local)
=> /Users/ci/builds/job-48213  ->  /Users/me/src
```

Each build root gets the local root most of its files agree on. Files that disagree
get their own narrower mapping. Files with several equally good matches are skipped and
reported; use `--map` for those.

A mapping never reaches above the `--source` folder. With `--source ~/proj/VendorSDK`
you get `/ci/job/VendorSDK -> ~/proj/VendorSDK`, not `/ci/job -> ~/proj`. This matters
because lldb also applies source maps in reverse to breakpoints: a mapping that covered
`~/proj` would move breakpoints in your app's own files to the CI path, where they never
bind. (`patch` internally uses the wider `/ci/job -> ~/proj` form, which is safe there
because it only rewrites the vendor's binaries. It's needed when the compiler recorded
file paths relative to a compile folder above the source folder, as clang does.)

## Does it need a dSYM?

It depends on the kind of library:

| Library | Works without a dSYM? | Why |
|---|---|---|
| Static library (`.a`, or an xcframework of `.a` files) | ✅ Yes | The debug info, with its source paths, is stored inside the `.a` itself. |
| Dynamic framework (`.framework`, or an xcframework of frameworks) | ❌ No | When it's built, the debug info is either collected into a dSYM or left in temporary build files on the vendor's machine. Without the dSYM there are no source paths to map. |

Check any library with `xcsrclink info <path>`. If it lists source files, it can be
linked. Otherwise `link` stops with "no debug info with source paths found".

For a dynamic framework without a dSYM:

- Ask the vendor for the dSYM of that exact build. A dSYM matches its binary by UUID,
  so one from a different build won't work.
- If you have the source, build the framework yourself with debug info, or add the
  source to your project directly.

Either way, the library must have been compiled with debug info (`-g`; for Xcode builds
`DEBUG_INFORMATION_FORMAT = dwarf` or `dwarf-with-dsym`). A `.a` built without it, or
with its debug info stripped, has nothing to map either.

## Notes and limits

- The library has to be built **with debug info**. See
  [Does it need a dSYM?](#does-it-need-a-dsym) for which libraries need a dSYM.
- Your checkout should match the commit the binary was built from, or line numbers
  will drift.
- `patch` on an xcframework changes files Xcode copies into DerivedData, so rebuild
  afterwards. If the vendor ships a new binary, `unlink` won't overwrite it (checksums
  are compared; `--force` overrides).
- lldb finds a framework's dSYM by its UUID through Spotlight, so it may load an older
  copy instead of the patched one, e.g. one in DerivedData from an earlier build of
  another project. After `patch`, `xcsrclink` lists any unpatched copies it finds. Rebuild
  the project each belongs to, or delete it. With `lldbinit` every copy works.
- If your app target itself builds with `dwarf-with-dsym`, the app's dSYM holds a copy of
  the library's DWARF. Rebuild after `patch` so it is regenerated. `lldbinit` needs
  nothing extra.
- Evaluating Swift expressions (`po`) in library frames also needs the library's
  `.swiftmodule`. That is separate from source mapping.

## Troubleshooting

Check what lldb loaded in Xcode's debug console (⌘⇧Y) while the app is paused:

```lldb
(lldb) settings show target.source-map   # mappings from your lldbinit
(lldb) breakpoint list                   # "locations = 0 (pending)" means it didn't bind
(lldb) image list MyLib                  # second line shows the dSYM, if one was loaded
```

- **`target.source-map` is empty.** Xcode didn't read the lldbinit file. Check the
  scheme's Edit Scheme › Run › Info › LLDB Init File, or which of `~/.lldbinit-Xcode`
  and `~/.lldbinit` you linked into.
- **Old or duplicate mappings are listed.** Xcode keeps one lldb running between runs,
  and the lldbinit file is read again for every session, so stale mappings stay loaded
  after `unlink` or relinking. Quit and reopen Xcode, or run `settings clear
  target.source-map` in the console and start the app again.
- **A breakpoint's file is a build-machine path.** A mapping is too broad and covers
  your own files. Relink with a current `xcsrclink`, or use a narrower `--source` or
  `--map`.
- **Dynamic framework still shows assembly.** lldb didn't find its dSYM. Load it with
  `add-dsym /path/to/MyLib.framework.dSYM` and step in again.
- **"non-launching port is incompatible with service identifier ..."** and similar
  simulator messages are system log noise, unrelated to debugging.

## Agent skill

[`skills/xcsrclink`](skills/xcsrclink/SKILL.md) teaches your agent the workflow above
(inspect, pick `--source`, dry run, link, verify, troubleshoot), so it can set up source
debugging when you say a vendor library's breakpoints don't bind. Install it for all your
projects with Claude for example:

```sh
mkdir -p ~/.claude/skills
ln -s "$PWD/skills/xcsrclink" ~/.claude/skills/xcsrclink   # from a clone of this repo
```

or via npx:

```sh
npx skills add https://github.com/foxsin10/xcsrclink/skills --skill xcsrclink
```

Keep it in sync with the CLI: when a flag or behavior changes, update the skill too.

## Development

```sh
make install           # rebuild and reinstall after changes
swift test             # unit tests (path matching, Mach-O/archive parsing, patcher, lldbinit)
scripts/e2e.sh         # builds real Swift libraries/xcframeworks and checks every strategy with lldb
TestProject/scripts/verify.sh   # iOS app + simulator check, see below
```

### Test project

[`TestProject/`](TestProject/README.md) holds an iOS SwiftUI app that uses three
prebuilt xcframeworks: a Swift `.a`, a Swift dynamic framework with a dSYM, and an
Objective-C `.a`. They are built from a fake CI path. Open it in Xcode to watch
breakpoints fail, run `xcsrclink link`, and watch them work. `verify.sh` does the same
automatically in the iOS Simulator.

## License

MIT. See [LICENSE](LICENSE).
