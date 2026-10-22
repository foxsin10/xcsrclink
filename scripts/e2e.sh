#!/bin/bash
# End-to-end check: build a Swift static library as if on CI, wrap it in an xcframework,
# move the sources elsewhere, then verify each xcsrclink strategy makes lldb
# (a) bind a breakpoint set on the local file and (b) step into library source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" -c debug >/dev/null
X="$ROOT/.build/debug/xcsrclink"

W="$(mktemp -d "${TMPDIR:-/tmp}/xcsrclink-e2e.XXXXXX")"
W="$(cd "$W" && pwd -P)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
export XCSRCLINK_HOME="$W/home"
INIT="$W/test.lldbinit"

# --- fixture -----------------------------------------------------------------
CI="$W/ci-agent/workspace/builds/job-48213/MyLib"   # deliberately long "CI" path
mkdir -p "$CI/Sources/MyLib" "$W/out" "$W/app"
cat > "$CI/Sources/MyLib/Greeter.swift" <<'EOF'
public struct Greeter {
    public init() {}
    public func greet(_ name: String) -> String {
        let message = "Hello, \(name)!"
        return Helper.decorate(message)
    }
}
EOF
cat > "$CI/Sources/MyLib/Helper.swift" <<'EOF'
enum Helper {
    static func decorate(_ s: String) -> String {
        let decorated = "** " + s + " **"
        return decorated
    }
}
EOF
cat > "$W/app/main.swift" <<'EOF'
import MyLib
let g = Greeter()
print(g.greet("World"))
EOF
swiftc -parse-as-library -emit-library -static -g -Onone -module-name MyLib \
  -emit-module -emit-module-path "$W/out/MyLib.swiftmodule" \
  "$CI/Sources/MyLib/Greeter.swift" "$CI/Sources/MyLib/Helper.swift" -o "$W/out/libMyLib.a"
xcodebuild -create-xcframework -library "$W/out/libMyLib.a" -output "$W/MyLib.xcframework" >/dev/null
LIB="$(ls "$W"/MyLib.xcframework/*/libMyLib.a)"
cp "$LIB" "$W/pristine.a"

build_app() {
  # Debug builds in Xcode use DWARF-in-.o (no dSYM): lldb reads the library's DWARF from the .a.
  # Keep main.o around like Xcode's DerivedData does, so main.swift has debug info too.
  (cd "$W/app" && swiftc -c -g -Onone -I "$W/out" main.swift -o main.o)
  swiftc -g -Onone "$W/app/main.o" "$LIB" -o "$W/app/App"
  rm -rf "$W/app/App.dSYM"
}
build_app

LOCAL="$W/src/MyLib"                                # the developer's checkout
mkdir -p "$W/src" && mv "$CI" "$LOCAL" && rm -rf "$W/ci-agent"

pass=0; failn=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; failn=$((failn+1)); }

# lldb session: breakpoint by *local* path, then a second run that steps in from main.
check_debug() { # $1 label, $2 file to break in, $3... extra lldb args
  local label="$1" bpfile="$2"; shift 2
  local bp step
  bp="$(cd "$W" && xcrun lldb -b "$@" -o "breakpoint set -f $bpfile -l 3" -o run app/App 2>&1 || true)"
  if grep -q "stop reason = breakpoint 1.1" <<<"$bp" && grep -q -- '-> 3 .*let decorated' <<<"$bp"; then
    ok "$label: breakpoint on ${bpfile#$W/}:3 binds and shows source"
  else bad "$label: breakpoint"; echo "$bp" | tail -8; fi

  step="$(cd "$W" && xcrun lldb -b "$@" -o "breakpoint set -f main.swift -l 3" -o run -o step -o step 2>&1 app/App || true)"
  if grep -q "Greeter.swift" <<<"$step" && grep -q -- '-> .*let message' <<<"$step"; then
    ok "$label: step into Greeter.greet shows library source"
  else bad "$label: step into"; echo "$step" | tail -10; fi
}

expect_broken() {
  local out
  out="$(cd "$W" && xcrun lldb -b "$@" -o "breakpoint set -f $LOCAL/Sources/MyLib/Helper.swift -l 3" -o run app/App 2>&1 || true)"
  if grep -q "no locations (pending)" <<<"$out"; then ok "baseline: breakpoint on local file does NOT bind (problem reproduced)"
  else bad "baseline unexpectedly works"; fi
}

echo "== baseline"
expect_broken -x

echo "== info"
info="$("$X" info "$W/MyLib.xcframework")"
grep -q "2 source file(s), 0 found" <<<"$info" && ok "info lists 2 recorded sources, none present" || { bad "info"; echo "$info"; }

echo "== strategy: lldbinit"
"$X" link "$W/MyLib.xcframework" --source "$W/src" --lldbinit "$INIT" >/dev/null
grep -q "target.source-map" "$INIT" && ok "lldbinit block written" || bad "lldbinit block"
check_debug lldbinit "$LOCAL/Sources/MyLib/Helper.swift" -x -S "$INIT"
"$X" unlink MyLib >/dev/null
grep -q "source-map" "$INIT" && bad "unlink left source-map behind" || ok "unlink removed managed block"

echo "== strategy: patch"
"$X" link "$W/MyLib.xcframework" --source "$W/src" --strategy patch >/dev/null
cmp -s "$LIB" "$W/pristine.a" && bad "library unchanged after patch" || ok "library patched in place"
[ "$(stat -f %z "$LIB")" = "$(stat -f %z "$W/pristine.a")" ] && ok "library size unchanged" || bad "size changed"
build_app   # Xcode relinks after the library changes
check_debug patch "$LOCAL/Sources/MyLib/Helper.swift" -x
"$X" unlink MyLib >/dev/null
cmp -s "$LIB" "$W/pristine.a" && ok "unlink restored the original library byte-for-byte" || bad "restore"
build_app

echo "== strategy: symlink"
"$X" link "$W/MyLib.xcframework" --source "$W/src" --strategy symlink >/dev/null
# Like cocoapods-imy-bin, symlinks make lldb *find* the source at the build path, so
# step-into works and breakpoints bind in files opened from that path (what Xcode
# shows after stepping in). Breakpoints on the real local path need lldbinit/patch.
check_debug symlink "$W/ci-agent/workspace/builds/job-48213/MyLib/Sources/MyLib/Helper.swift" -x
"$X" unlink MyLib >/dev/null
[ -e "$W/ci-agent" ] && bad "symlink/dirs left behind" || ok "unlink removed symlink and created folders"

echo "== signed xcframework"
codesign --force --sign - "$W/MyLib.xcframework" 2>/dev/null
if "$X" link "$W/MyLib.xcframework" --source "$W/src" --strategy patch >/dev/null 2>"$W/err"; then
  bad "patching a signed xcframework should require --strip-signature"
else
  grep -q "strip-signature" "$W/err" && cmp -s "$LIB" "$W/pristine.a" && ok "refuses to patch signed xcframework, nothing changed" || bad "signed refusal"
fi
"$X" link "$W/MyLib.xcframework" --source "$W/src" --strategy patch --strip-signature >/dev/null
[ ! -e "$W/MyLib.xcframework/_CodeSignature" ] && ! cmp -s "$LIB" "$W/pristine.a" && ok "--strip-signature patches and moves signature aside" || bad "strip-signature"
"$X" unlink MyLib >/dev/null
codesign --verify "$W/MyLib.xcframework" 2>/dev/null && ok "unlink restored a valid signature" || bad "signature restore"

echo "== dynamic framework + dSYM inside xcframework"
DCI="$W/ci-agent/workspace/builds/job-99/Dyn"
mkdir -p "$DCI/Sources" "$W/dyn/MyDyn.framework/Versions/A/Modules" "$W/dynapp"
cat > "$DCI/Sources/Calc.swift" <<'EOF'
public enum Calc {
    public static func twice(_ x: Int) -> Int {
        let doubled = x * 2
        return doubled
    }
}
EOF
F="$W/dyn/MyDyn.framework"
swiftc -parse-as-library -emit-library -g -Onone -module-name MyDyn -emit-module \
  -emit-module-path "$F/Versions/A/Modules/MyDyn.swiftmodule/arm64-apple-macos.swiftmodule" \
  -Xlinker -install_name -Xlinker @rpath/MyDyn.framework/Versions/A/MyDyn \
  "$DCI/Sources/Calc.swift" -o "$F/Versions/A/MyDyn"
# swiftc already ran dsymutil (its temp .o files are gone); keep that dSYM.
mv "$F/Versions/A/MyDyn.dSYM" "$W/dyn/MyDyn.framework.dSYM"
ln -s A "$F/Versions/Current"; ln -s Versions/Current/MyDyn "$F/MyDyn"; ln -s Versions/Current/Modules "$F/Modules"
mkdir -p "$F/Versions/A/Resources" && ln -s Versions/Current/Resources "$F/Resources"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.MyDyn" -c "Add :CFBundleExecutable string MyDyn" \
  -c "Add :CFBundlePackageType string FMWK" "$F/Versions/A/Resources/Info.plist" >/dev/null
xcodebuild -create-xcframework -allow-internal-distribution -framework "$F" -debug-symbols "$W/dyn/MyDyn.framework.dSYM" -output "$W/MyDyn.xcframework" >/dev/null
DSYM="$(ls -d "$W"/MyDyn.xcframework/*/dSYMs/MyDyn.framework.dSYM)"
DSLICE="$(dirname "$(dirname "$DSYM")")"
cat > "$W/dynapp/main.swift" <<'EOF'
import MyDyn
print(Calc.twice(21))
EOF
(cd "$W/dynapp" && swiftc -c -g -Onone -F "$DSLICE" main.swift -o main.o)
swiftc -g "$W/dynapp/main.o" -F "$DSLICE" -framework MyDyn -Xlinker -rpath -Xlinker "$DSLICE" -o "$W/dynapp/App"
rm -rf "$W/dynapp/App.dSYM"
mkdir -p "$W/src2" && mv "$DCI" "$W/src2/Dyn"
DLOCAL="$W/src2/Dyn/Sources/Calc.swift"

check_dyn() { # $1 label, $2... extra lldb args
  local label="$1"; shift
  local out
  out="$(cd "$W" && xcrun lldb -b "$@" -o "target symbols add $DSYM" -o "breakpoint set -f $DLOCAL -l 3" -o run dynapp/App 2>&1 || true)"
  if grep -q "stop reason = breakpoint" <<<"$out" && grep -q -- '-> 3 .*let doubled' <<<"$out"; then
    ok "$label: breakpoint in dynamic framework source binds via dSYM"
  else bad "$label: dynamic framework breakpoint"; echo "$out" | tail -8; fi
}

info="$("$X" info "$W/MyDyn.xcframework")"
grep -q "dSYM:" <<<"$info" && ok "info finds the dSYM inside the xcframework" || { bad "dSYM discovery"; echo "$info"; }
"$X" link "$W/MyDyn.xcframework" --source "$W/src2" --lldbinit "$INIT" >/dev/null
check_dyn "dSYM lldbinit" -x -S "$INIT"
"$X" unlink MyDyn >/dev/null
cp -R "$DSYM" "$W/pristine.dSYM"
"$X" link "$W/MyDyn.xcframework" --source "$W/src2" --strategy patch >/dev/null
check_dyn "dSYM patch" -x
"$X" unlink MyDyn >/dev/null
diff -r "$DSYM" "$W/pristine.dSYM" >/dev/null && ok "unlink restored the dSYM" || bad "dSYM restore"

echo "== explicit --map + dry run"
out="$("$X" link "$W/MyLib.xcframework" --map "$W/ci-agent/workspace/builds/job-48213=$W/src" --strategy patch,lldbinit --lldbinit "$INIT" --dry-run)"
grep -qE "would patch [1-9][0-9]* path string" <<<"$out" && ok "dry run reports patch count" || { bad "dry run"; echo "$out"; }
cmp -s "$LIB" "$W/pristine.a" && [ ! -s "$INIT" ] && ok "dry run changed nothing" || bad "dry run changed files"

echo
echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
