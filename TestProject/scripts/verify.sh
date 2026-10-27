#!/bin/bash
# Automated check that xcsrclink makes the DemoApp debuggable in the iOS Simulator.
# APP=SPMDemo runs the same checks on SPMDemo, which gets the libraries through a Swift
# package (VendorPackage) instead of linking the xcframeworks directly.
#
# For the baseline and each strategy it builds DemoApp with xcodebuild (like Xcode's
# Run), launches it in a simulator waiting for the debugger, attaches lldb (what Xcode
# does), and checks that:
#   - breakpoints set on files in VendorSDK/ bind and stop with source shown, for the
#     Swift static library, the Swift dynamic framework (via its dSYM) and the ObjC library
#   - "step into" from the app lands in library source
# The app is launched with -xcsrclink-autorun so it calls each library and exits by itself.
#
# Uses a temporary xcsrclink state folder and lldbinit, so your ~/.lldbinit is not touched. Set SIM_UDID to pick a simulator.
set -euo pipefail

# /bin/pwd -P gives the path as the file system spells it (bash's built-in pwd keeps the
# case you typed). lldb compares paths case-sensitively,
# so ~/workspace/... would not match the ~/Workspace/... the compiler recorded.
HERE="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"
REPO="$(cd "$HERE/.." && /bin/pwd -P)"
SRC="$HERE/VendorSDK/Sources"
APP="${APP:-DemoApp}"
case "$APP" in
  DemoApp)
    PROJECT="$HERE/DemoApp/DemoApp.xcodeproj"; DD="$HERE/build"
    BUNDLE_ID=com.example.xcsrclink.DemoApp ;;
  SPMDemo)
    PROJECT="$HERE/SPMDemo/SPMDemo.xcodeproj"; DD="$HERE/build-spm"
    BUNDLE_ID=com.example.xcsrclink.SPMDemo ;;
  *) echo "error: APP must be DemoApp or SPMDemo" >&2; exit 1 ;;
esac
PRODUCTS="$DD/Build/Products/Debug-iphonesimulator"
# What to link, as name=path. DemoApp links the xcframeworks it references. SPMDemo's
# zipped binary targets are unpacked by Xcode into SourcePackages/artifacts (where a remote
# package's would be too); ObjCKit is used in place from the package.
if [ "$APP" = DemoApp ]; then
  LINKS=("VendorSDK=$HERE/DemoApp/Frameworks")
else
  LINKS=("VendorBinaries=$HERE/SPMDemo/VendorPackage/Binaries" "VendorArtifacts=$DD/SourcePackages/artifacts")
fi
CI_ROOT="${CI_ROOT:-/tmp/xcsrclink-ci/buildkite-agent-07/workspace/ios-sdk-release/builds/job-48213}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/xcsrclink-verify.XXXXXX")"
trap '[ -n "${KEEP:-}" ] && echo "Logs kept in $TMP" || rm -rf "$TMP"' EXIT
export XCSRCLINK_HOME="$TMP/home"
INIT="$TMP/test.lldbinit"
: > "$INIT"

echo "Building xcsrclink"
swift build --package-path "$REPO" -c release >/dev/null
X="$REPO/.build/release/xcsrclink"

if [ ! -d "$HERE/DemoApp/Frameworks/StaticKit.xcframework" ] || [ ! -d "$HERE/SPMDemo/VendorPackage/Binaries" ]; then
  "$HERE/scripts/build-sdk.sh"
fi
if [ -e "$CI_ROOT" ]; then
  echo "error: $CI_ROOT exists, so sources would be found without xcsrclink. Remove it first." >&2
  exit 1
fi

# Pick and boot a simulator.
UDID="${SIM_UDID:-$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
devs = json.load(sys.stdin)["devices"]
ios = sorted((k for k in devs if ".iOS-" in k), key=lambda k: [int(x) for x in k.split(".iOS-")[1].split("-")], reverse=True)
for k in ios:
    for d in devs[k]:
        if d["name"].startswith("iPhone"):
            print(d["udid"]); sys.exit()
')}"
[ -n "$UDID" ] || { echo "error: no iPhone simulator found" >&2; exit 1; }
echo "Simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

line_of() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }
L_GREET=$(line_of "$SRC/StaticKit/Greeter.swift" "BREAKPOINT StaticKit.greeting")
L_AVG=$(line_of "$SRC/DynamicKit/Calculator.swift" "BREAKPOINT DynamicKit.average")
L_INC=$(line_of "$SRC/ObjCKit/OCKCounter.m" "BREAKPOINT ObjCKit.increment")
L_STEP=$(line_of "$HERE/DemoApp/DemoApp/ContentView.swift" "STEP INTO DynamicKit")

build_app() {
  xcodebuild build -project "$PROJECT" -scheme "$APP" -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" >"$TMP/build.log" 2>&1 \
    || { tail -30 "$TMP/build.log"; echo "error: $APP build failed" >&2; exit 1; }
  xcrun simctl install "$UDID" "$PRODUCTS/$APP.app"
}

# Runs one debug session. $1 = folder to set breakpoints in, $2... = extra lldb args.
debug_session() {
  local bpsrc="$1"; shift
  local launch pid
  touch "$INIT"   # unlink deletes the lldbinit file once it is empty
  launch="$(xcrun simctl launch --wait-for-debugger --terminate-running-process "$UDID" "$BUNDLE_ID" -xcsrclink-autorun)"
  pid="${launch##*: }"
  # Watchdog: if something hangs, end the app so lldb returns.
  ( sleep 120; xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 ) &
  local watchdog=$!
  # lldb normally finds DynamicKit's dSYM through Spotlight, which can return any copy with
  # the same UUID, e.g. one in your own Xcode DerivedData that `patch` didn't touch. So turn
  # that off and load the dSYM from this build once DynamicKit is loaded (first stop).
  xcrun lldb -x -b "$@" \
    -o "settings set symbols.enable-external-lookup false" \
    -o "platform select ios-simulator" \
    -o "process attach -p $pid" \
    -o "breakpoint set -f $bpsrc/StaticKit/Greeter.swift -l $L_GREET" \
    -o "breakpoint set -f $bpsrc/DynamicKit/Calculator.swift -l $L_AVG" \
    -o "breakpoint set -f $bpsrc/ObjCKit/OCKCounter.m -l $L_INC" \
    -o "breakpoint set -f $HERE/DemoApp/DemoApp/ContentView.swift -l $L_STEP" \
    -o continue -o "target symbols add $PRODUCTS/DynamicKit.framework.dSYM" \
    -o continue -o "thread step-in" -o continue -o continue -o continue \
    2>&1 || true
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}

pass=0; failn=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; failn=$((failn+1)); }

# A stop shows source when lldb prints a "-> <line>" listing (not "->  0x..." disassembly).
shows_source() { grep -qE -- "^-> +[0-9]+ .*$2" <<<"$1"; }

check_all() { # $1 label, $2 session output
  local label="$1" out="$2"
  echo "$out" > "$TMP/session-$label.log"
  shows_source "$out" "BREAKPOINT StaticKit.greeting" && ok "$label: StaticKit (.a, Swift) breakpoint stops with source" || bad "$label: StaticKit breakpoint"
  shows_source "$out" "BREAKPOINT DynamicKit.average" && ok "$label: DynamicKit (dynamic + dSYM) breakpoint stops with source" || bad "$label: DynamicKit breakpoint"
  shows_source "$out" "BREAKPOINT ObjCKit.increment" && ok "$label: ObjCKit (.a, Obj-C) breakpoint stops with source" || bad "$label: ObjCKit breakpoint"
  shows_source "$out" "guard !values.isEmpty" && ok "$label: step into Calculator.average shows library source" || bad "$label: step into"
}

link_all() { # extra link args
  for l in "${LINKS[@]}"; do "$X" link "${l#*=}" --source "$HERE/VendorSDK" --name "${l%%=*}" "$@" >/dev/null; done
}
unlink_all() { for l in "${LINKS[@]}"; do "$X" unlink "${l%%=*}" >/dev/null; done; }
checksum() {
  for l in "${LINKS[@]}"; do find "${l#*=}" -type f -print0; done | sort -z | xargs -0 shasum -a 256 | shasum -a 256
}

echo "== $APP: baseline (no xcsrclink)"
build_app
PRISTINE="$(checksum)"   # after the build: Xcode unpacks SPMDemo's artifacts on its first build
out="$(debug_session "$SRC" -S "$INIT")"
if grep -q "no locations (pending)" <<<"$out" && ! shows_source "$out" "BREAKPOINT StaticKit.greeting"; then
  ok "baseline: breakpoints in VendorSDK don't bind (problem reproduced)"
else
  bad "baseline unexpectedly works, so the test proves nothing"
fi

echo "== $APP: strategy lldbinit"
link_all --lldbinit "$INIT" --no-scheme
check_all lldbinit "$(debug_session "$SRC" -S "$INIT")"
unlink_all

echo "== $APP: strategy patch"
link_all --strategy patch
PATCHED="$(checksum)"
build_app   # Xcode re-copies the patched libraries into DerivedData and relinks
[ "$(checksum)" = "$PATCHED" ] && ok "patched libraries survive a rebuild" || bad "the build replaced the patched libraries"
check_all patch "$(debug_session "$SRC" -S "$INIT")"
unlink_all
[ "$(checksum)" = "$PRISTINE" ] && ok "unlink restored the xcframeworks byte-for-byte" || bad "xcframeworks differ after unlink"
build_app

echo "== $APP: strategy symlink (cocoapods-imy-bin style)"
link_all --strategy symlink
# Breakpoints go on the build path, which is where Xcode opens files after stepping in.
check_all symlink "$(debug_session "$CI_ROOT/VendorSDK/Sources" -S "$INIT")"
unlink_all
[ ! -e "$CI_ROOT" ] && ok "unlink removed the symlink" || bad "symlink left at $CI_ROOT"

echo
echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
