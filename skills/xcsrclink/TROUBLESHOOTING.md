# xcsrclink troubleshooting

Check what lldb loaded, in Xcode's debug console (⌘⇧Y) while the app is paused:

```lldb
(lldb) settings show target.source-map   # mappings lldb is using
(lldb) breakpoint list                   # "locations = 0 (pending)" means it didn't bind
(lldb) image list MyLib                  # a second line shows the loaded dSYM
```

Match the symptom:

- **`target.source-map` is empty.** Xcode didn't read the lldbinit file. With the default, check which of `~/.lldbinit-Xcode` and `~/.lldbinit` was written (Xcode reads the first if it exists; `xcsrclink list` shows the file). With `--lldbinit`, check Edit Scheme › Run › Info › LLDB Init File points at it.
- **Old or duplicate mappings listed.** Xcode keeps lldb running between runs. Quit and reopen Xcode, or `settings clear target.source-map` and run again.
- **A breakpoint in the app's own file shows a build-machine path.** A mapping covers the app's sources. Relink with a narrower `--source` or explicit `--map`.
- **Dynamic framework still shows assembly.** lldb didn't find its dSYM (`image list` has no second line). `add-dsym /path/to/MyLib.framework.dSYM`, then step in again.
- **After `patch`, still build-machine paths.** Xcode links from its DerivedData copy: rebuild (⌘B). lldb may also load another dSYM copy with the same UUID found via Spotlight; `link` lists unpatched copies it finds. Rebuild their project or delete them, or use the `lldbinit` strategy, which works for every copy. An app built with `dwarf-with-dsym` holds its own copy of the library's DWARF: rebuild it too.
- **After `patch`, a dynamic framework still shows assembly.** Find out which dSYM lldb loaded: `image list MyLib` shows it on the second line. `xcsrclink info <path> --copies` lists every dSYM with the same UUID: ✓ means its recorded files exist here (patched), ✗ means it still has the build machine's paths. Unpatched copies typically sit in other projects' DerivedData or old build folders (in this repo: `TestProject/build`, `TestProject/build-spm`, SPMDemo's DerivedData). Delete them or rebuild their projects (ask the user first), then quit and reopen Xcode. Or relink with `-S patch,lldbinit`, which covers every copy.
- **Lines are off by a few.** The checkout isn't the commit the binary was built from.
- **`po` fails in library frames.** Expression evaluation needs the library's `.swiftmodule`; source mapping doesn't provide it.
- **"non-launching port is incompatible with service identifier ..."** is simulator log noise.
