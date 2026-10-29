# AGENTS.md

## Release

The version bump comes last: make it only once every check in step 1 is green on the
commit being released. A release in progress keeps the old version everywhere until then.

1. **Verify.** Run each and read its result:
   - `swift test`
   - `scripts/e2e.sh`
   - `scripts/e2e-spm.sh` (takes several minutes)
   - `TestProject/scripts/verify.sh` and `APP=SPMDemo TestProject/scripts/verify.sh`
     (iOS Simulator)
   - `swiftformat --lint --config .claude/skills/swiftformat/swiftformat.config Package.swift Sources Tests`

   Done when every suite reports 0 failed and the lint prints `0/N files require
   formatting`. A failure means fix, commit, and start step 1 again.
2. **Bump.** Set `XcsrcLinkCLI.version` in `Sources/XcsrcLinkCLI/XcsrcLinkCLI.swift`
   and every doc that names the new version (e.g. the README's `from: "x.y.z"`), in its
   own commit: `chore: bump version to x.y.z`.
3. **Publish**, after the user merges (they use "rebase and merge", so rebase local
   `main` onto `origin/main` first):
   - annotated tag `x.y.z`, no `v` prefix
   - `swift build -c release --arch arm64 --arch x86_64` (output in
     `.build/out/Products/Release`)
   - tarball `xcsrclink-x.y.z-macos-universal.tar.gz` holding `xcsrclink`, `LICENSE` and
     `README.md` in a `xcsrclink-x.y.z-macos-universal/` folder, with a `.sha256` file
     beside it, attached to the GitHub release
