#!/bin/bash
# End-to-end check for libraries consumed through SwiftPM `binaryTarget`s.
# Builds the libraries "on CI", ships them as xcframeworks, consumes them from a Swift
# package (local path, zip in a dependency package, dynamic framework + dSYM), then checks
# that xcsrclink makes lldb bind breakpoints on the local source and step into it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" -c debug >/dev/null
X="$ROOT/.build/debug/xcsrclink"

W="$(mktemp -d "${TMPDIR:-/tmp}/xcsrclink-spm.XXXXXX")"
W="$(cd "$W" && pwd -P)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
export XCSRCLINK_HOME="$W/home"
INIT="$W/test.lldbinit"

pass=0; failn=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; failn=$((failn+1)); }

# --- vendor libraries, built at a CI path that won't exist later ---------------------
CI="$W/ci-agent/workspace/builds/job-48213/VendorSDK"
mkdir -p "$CI/MyLib" "$CI/MyDyn" "$W/out" "$W/vendor"
cat > "$CI/MyLib/Greeter.swift" <<'EOF'
public struct Greeter {
    public init() {}
    public func greet(_ name: String) -> String {
        let message = "Hello, \(name)!"
        return Helper.decorate(message)
    }
}
EOF
cat > "$CI/MyLib/Helper.swift" <<'EOF'
enum Helper {
    static func decorate(_ s: String) -> String {
        let decorated = "** " + s + " **"
        return decorated
    }
}
EOF
cat > "$CI/MyDyn/Calc.swift" <<'EOF'
public enum Calc {
    public static func twice(_ x: Int) -> Int {
        let doubled = x * 2
        return doubled
    }
}
EOF

# Both ship as versioned macOS frameworks in xcframeworks, the usual layout for Swift
# binaries in SwiftPM: MyLib as a static framework (DWARF inside the archive), MyDyn as a
# dynamic framework with a dSYM.
TARGET="$(uname -m)-apple-macos13.0"
make_framework() { # $1 name, $2 static|dynamic, $3... sources (relative to $CI)
  local name="$1" kind="$2"; shift 2
  local f="$W/out/$name.framework"
  mkdir -p "$f/Versions/A/Modules/$name.swiftmodule" "$f/Versions/A/Resources"
  local extra=(-Xlinker -install_name -Xlinker "@rpath/$name.framework/Versions/A/$name")
  [ "$kind" = static ] && extra=(-static)
  (cd "$CI" && swiftc -parse-as-library -emit-library -g -Onone -target "$TARGET" -module-name "$name" \
    -emit-module -emit-module-path "$f/Versions/A/Modules/$name.swiftmodule/$(uname -m)-apple-macos.swiftmodule" \
    "${extra[@]}" "$@" -o "$f/Versions/A/$name")
  ln -s A "$f/Versions/Current"; ln -s "Versions/Current/$name" "$f/$name"
  ln -s Versions/Current/Modules "$f/Modules"; ln -s Versions/Current/Resources "$f/Resources"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.$name" -c "Add :CFBundleExecutable string $name" \
    -c "Add :CFBundlePackageType string FMWK" -c "Add :MinimumOSVersion string 13.0" "$f/Versions/A/Resources/Info.plist" >/dev/null
  local args=(-framework "$f")
  if [ "$kind" = dynamic ]; then
    # swiftc already ran dsymutil (its temp .o files are gone); ship that dSYM.
    mv "$f/Versions/A/$name.dSYM" "$W/out/$name.framework.dSYM"
    args+=(-debug-symbols "$W/out/$name.framework.dSYM")
  fi
  xcodebuild -create-xcframework -allow-internal-distribution "${args[@]}" -output "$W/vendor/$name.xcframework" >/dev/null
}
make_framework MyLib static MyLib/Greeter.swift MyLib/Helper.swift
make_framework MyDyn dynamic MyDyn/Calc.swift

# The developer's checkout of the vendor source; the CI path disappears.
mkdir -p "$W/src" && mv "$CI" "$W/src/VendorSDK" && rm -rf "$W/ci-agent"
SRC="$W/src/VendorSDK"

# --- consumers -----------------------------------------------------------------------
# $1 package dir, $2 Package.swift target lines, $3 app dependencies, $4 main.swift
make_app() {
  mkdir -p "$1/Sources/App"
  cat > "$1/Package.swift" <<EOF
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "$(basename "$1")",
    platforms: [.macOS(.v13)],
    $2
)
EOF
  printf '%s\n' "$4" > "$1/Sources/App/main.swift"
}
build() { swift build --package-path "$1" >"$W/build.log" 2>&1 || { cat "$W/build.log"; return 1; }; }

# 1. binaryTarget(path:) to an xcframework in the package.
P1="$W/app-path"
mkdir -p "$P1/Vendor" && cp -R "$W/vendor/MyLib.xcframework" "$P1/Vendor/"
make_app "$P1" 'targets: [
        .binaryTarget(name: "MyLib", path: "Vendor/MyLib.xcframework"),
        .executableTarget(name: "App", dependencies: ["MyLib"]),
    ]' '' 'import MyLib
let g = Greeter()
print(g.greet("World"))'

# 2. A vendor package that ships a zipped xcframework, like a remote `url:` binary target.
#    SwiftPM extracts it into the consumer's .build/artifacts.
V="$W/VendorPkg"
mkdir -p "$V/Sources/VendorKit"
(cd "$W/vendor" && ditto -c -k --keepParent MyLib.xcframework "$V/MyLib.xcframework.zip")
echo '@_exported import MyLib' > "$V/Sources/VendorKit/VendorKit.swift"
cat > "$V/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "VendorPkg",
    platforms: [.macOS(.v13)],
    products: [.library(name: "VendorKit", targets: ["VendorKit"])],
    targets: [
        .binaryTarget(name: "MyLib", path: "MyLib.xcframework.zip"),
        .target(name: "VendorKit", dependencies: ["MyLib"]),
    ]
)
EOF
P2="$W/app-zip"
make_app "$P2" 'dependencies: [.package(path: "../VendorPkg")],
    targets: [
        .executableTarget(name: "App", dependencies: [.product(name: "VendorKit", package: "VendorPkg")]),
    ]' '' 'import VendorKit
let g = Greeter()
print(g.greet("World"))'

# 3. Dynamic framework with its dSYM.
P3="$W/app-dyn"
mkdir -p "$P3/Vendor" && cp -R "$W/vendor/MyDyn.xcframework" "$P3/Vendor/"
make_app "$P3" 'targets: [
        .binaryTarget(name: "MyDyn", path: "Vendor/MyDyn.xcframework"),
        .executableTarget(name: "App", dependencies: ["MyDyn"]),
    ]' '' 'import MyDyn
print(Calc.twice(21))'

for p in "$P1" "$P2" "$P3"; do
  if build "$p"; then ok "swift build: $(basename "$p")"; else bad "swift build: $(basename "$p")"; fi
done

# --- checks ----------------------------------------------------------------------------
HELPER="$SRC/MyLib/Helper.swift"

# $1 label, $2 package, $3... extra lldb args. Breakpoint on the local file, then step in from main.
check_static() {
  local label="$1" pkg="$2"; shift 2
  local out
  out="$(cd "$pkg" && xcrun lldb -b "$@" -o "breakpoint set -f $HELPER -l 3" -o run .build/debug/App </dev/null 2>&1 || true)"
  if grep -q "stop reason = breakpoint 1.1" <<<"$out" && grep -q -- '-> 3 .*let decorated' <<<"$out"; then
    ok "$label: breakpoint on local Helper.swift:3 binds and shows source"
  else bad "$label: breakpoint"; echo "$out" | tail -8; fi
  out="$(cd "$pkg" && xcrun lldb -b "$@" -o "breakpoint set -f main.swift -l 3" -o run -o step -o step .build/debug/App </dev/null 2>&1 || true)"
  if grep -q "Greeter.swift" <<<"$out" && grep -q -- '-> .*let message' <<<"$out"; then
    ok "$label: step into Greeter.greet shows library source"
  else bad "$label: step into"; echo "$out" | tail -10; fi
}

echo "== 1. binaryTarget(path:) xcframework, static library"
out="$(cd "$P1" && xcrun lldb -b -x -o "breakpoint set -f $HELPER -l 3" -o run .build/debug/App </dev/null 2>&1 || true)"
grep -q "no locations (pending)" <<<"$out" && ok "baseline: breakpoint on local file does NOT bind" || bad "baseline unexpectedly works"
info="$("$X" info "$P1/Vendor/MyLib.xcframework")"
grep -q "2 source file(s), 0 found" <<<"$info" && ok "info lists 2 recorded sources" || { bad "info"; echo "$info"; }
"$X" link "$P1/Vendor/MyLib.xcframework" --source "$SRC" --lldbinit "$INIT" --no-scheme >/dev/null
check_static "lldbinit" "$P1" -x -S "$INIT"
"$X" unlink MyLib >/dev/null
"$X" link "$P1/Vendor/MyLib.xcframework" --source "$SRC" --strategy patch >/dev/null
build "$P1"   # relink so the app picks up the patched .a
check_static "patch" "$P1" -x
"$X" unlink MyLib >/dev/null

echo "== 2. zipped xcframework in a dependency package (.build/artifacts)"
ART="$(find "$P2/.build/artifacts" -name MyLib.xcframework -type d | head -1)"
[ -n "$ART" ] && ok "SwiftPM extracted it to ${ART#$P2/}" || bad "no extracted xcframework in .build/artifacts"
info="$("$X" info "$P2/.build/artifacts")"
grep -q "2 source file(s)" <<<"$info" && ok "info on .build/artifacts finds the library" || { bad "info on artifacts"; echo "$info"; }
"$X" link "$P2/.build/artifacts" --source "$SRC" --name VendorPkg --lldbinit "$INIT" --no-scheme >/dev/null
check_static "lldbinit" "$P2" -x -S "$INIT"
"$X" unlink VendorPkg >/dev/null
"$X" link "$P2/.build/artifacts" --source "$SRC" --name VendorPkg --strategy patch >/dev/null
build "$P2"
check_static "patch" "$P2" -x
if build "$P2" && swift package --package-path "$P2" reset >/dev/null 2>&1 && build "$P2"; then
  ART="$(find "$P2/.build/artifacts" -name MyLib.xcframework -type d | head -1)"
  "$X" info "$ART" | grep -q "0 found" && ok "re-extracting the zip (package reset) brings back the original paths" \
    || bad "extracted copy still patched after reset"
fi
"$X" unlink VendorPkg >/dev/null 2>&1 || true

echo "== 3. dynamic framework + dSYM"
CALC="$SRC/MyDyn/Calc.swift"
# `swift build` gives a command-line tool no rpath to the frameworks next to it (`swift run`
# and Xcode set the path themselves), so point dyld there. Spotlight is off, so lldb can only
# use the dSYM that SwiftPM copies next to the framework.
dyn() {
  (cd "$P3" && xcrun lldb -b -x "$@" -o "settings set symbols.enable-external-lookup false" \
    -o "settings set target.env-vars DYLD_FRAMEWORK_PATH=$P3/.build/debug" \
    -o "breakpoint set -f $CALC -l 3" -o run .build/debug/App </dev/null 2>&1 || true)
}
check_dyn() { # $1 label, $2... extra lldb args
  local label="$1"; shift
  local out; out="$(dyn "$@")"
  if grep -q "stop reason = breakpoint 1.1" <<<"$out" && grep -q -- '-> 3 .*let doubled' <<<"$out"; then
    ok "$label: breakpoint on local Calc.swift:3 binds via the dSYM SwiftPM copied"
  else bad "$label: dynamic framework breakpoint"; echo "$out" | tail -8; fi
}
[ -d "$P3/.build/debug/MyDyn.framework.dSYM" ] && ok "SwiftPM copies the dSYM next to the framework" || bad "no dSYM next to the framework"
out="$(dyn)"
grep -q "no locations (pending)" <<<"$out" && grep -q "exited with status = 0" <<<"$out" \
  && ok "baseline: app runs, breakpoint on local file does NOT bind" || { bad "dynamic baseline"; echo "$out" | tail -8; }
"$X" info "$P3/Vendor/MyDyn.xcframework" | grep -q "dSYM:" && ok "info finds the dSYM in the xcframework" || bad "dSYM discovery"
"$X" link "$P3/Vendor/MyDyn.xcframework" --source "$SRC" --lldbinit "$INIT" --no-scheme >/dev/null
check_dyn "lldbinit" -S "$INIT"
"$X" unlink MyDyn >/dev/null
"$X" link "$P3/Vendor/MyDyn.xcframework" --source "$SRC" --strategy patch >/dev/null 2>&1
build "$P3"   # SwiftPM copies the patched dSYM again
check_dyn "patch"
"$X" unlink MyDyn >/dev/null

echo "== folders"
info="$("$X" info "$P2" 2>&1 || true)"
grep -q "2 source file(s)" <<<"$info" && ok "info <package root> finds libraries in .build/artifacts" \
  || { bad "info <package root> misses .build/artifacts"; echo "$info" | tail -3; }

echo
echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
