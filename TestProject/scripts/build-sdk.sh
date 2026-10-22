#!/bin/bash
# Builds the VendorSDK sources into xcframeworks the way a vendor's CI would:
# the sources are copied to a long "CI agent" path, compiled there with debug info,
# and the copy is deleted. The binaries then reference source paths that don't exist
# on this machine, which is exactly the situation xcsrclink fixes.
#
# Output (in DemoApp/Frameworks):
#   StaticKit.xcframework   Swift static library (.a + .swiftmodule)
#   DynamicKit.xcframework  Swift dynamic framework + dSYM
#   ObjCKit.xcframework     Objective-C static library (.a + headers + modulemap)
#
# Each has an iOS device slice and an iOS simulator slice (arm64 + x86_64).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/DemoApp/Frameworks"
CI_ROOT="${CI_ROOT:-/tmp/xcsrclink-ci/buildkite-agent-07/workspace/ios-sdk-release/builds/job-48213}"
CI_SRC="$CI_ROOT/VendorSDK/Sources"
WORK="$CI_ROOT/build"
MIN_IOS=17.0

echo "Copying sources to the fake CI path: $CI_ROOT"
rm -rf "$CI_ROOT" && mkdir -p "$CI_SRC" "$WORK"
cp -R "$HERE/VendorSDK/Sources/." "$CI_SRC/"

# slice name | sdk | targets
SLICES=(
  "ios|iphoneos|arm64-apple-ios$MIN_IOS"
  "sim|iphonesimulator|arm64-apple-ios$MIN_IOS-simulator x86_64-apple-ios$MIN_IOS-simulator"
)

swift_sources() { find "$CI_SRC/$1" -name '*.swift' | sort; }

build_static_kit() { # slice sdk targets...
  set -e  # these run inside $(...), which does not inherit -e on bash 3.2
  local slice="$1" sdk="$2"; shift 2
  local sdkpath; sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local dir="$WORK/$slice/StaticKit" libs=()
  mkdir -p "$dir/include/StaticKit.swiftmodule"
  for target in "$@"; do
    local arch="${target%%-*}" triple="${target/$MIN_IOS/}"
    mkdir -p "$dir/$arch"
    # -debug-prefix-map is deliberately NOT used: absolute CI paths end up in DWARF.
    (cd "$CI_ROOT" && xcrun swiftc -parse-as-library -emit-library -static -g -Onone \
      -enable-library-evolution -language-mode 6 -module-name StaticKit -target "$target" -sdk "$sdkpath" \
      -emit-module-path "$dir/include/StaticKit.swiftmodule/$triple.swiftmodule" \
      -emit-module-interface-path "$dir/include/StaticKit.swiftmodule/$triple.swiftinterface" \
      $(swift_sources StaticKit) -o "$dir/$arch/libStaticKit.a")
    libs+=("$dir/$arch/libStaticKit.a")
  done
  xcrun lipo -create "${libs[@]}" -output "$dir/libStaticKit.a"
  echo "-library $dir/libStaticKit.a -headers $dir/include"
}

build_dynamic_kit() { # slice sdk targets...
  set -e  # these run inside $(...), which does not inherit -e on bash 3.2
  local slice="$1" sdk="$2"; shift 2
  local sdkpath; sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local dir="$WORK/$slice/DynamicKit"
  local fw="$dir/DynamicKit.framework" bins=()
  mkdir -p "$fw/Modules/DynamicKit.swiftmodule"
  for target in "$@"; do
    local arch="${target%%-*}" triple="${target/$MIN_IOS/}"
    local obj="$dir/obj-$arch"
    mkdir -p "$obj"
    # Compile to object files we keep until dsymutil has read them (like DerivedData).
    (cd "$obj" && xcrun swiftc -parse-as-library -c -g -Onone -enable-library-evolution -language-mode 6 \
      -module-name DynamicKit -target "$target" -sdk "$sdkpath" \
      -emit-module-path "$fw/Modules/DynamicKit.swiftmodule/$triple.swiftmodule" \
      -emit-module-interface-path "$fw/Modules/DynamicKit.swiftmodule/$triple.swiftinterface" \
      $(swift_sources DynamicKit))
    (cd "$obj" && xcrun swiftc -emit-library -target "$target" -sdk "$sdkpath" -module-name DynamicKit \
      -Xlinker -install_name -Xlinker @rpath/DynamicKit.framework/DynamicKit \
      "$obj"/*.o -o "$obj/DynamicKit")
    rm -rf "$obj/DynamicKit.dSYM"
    bins+=("$obj/DynamicKit")
  done
  xcrun lipo -create "${bins[@]}" -output "$fw/DynamicKit"
  local platform; [ "$sdk" = iphoneos ] && platform=iPhoneOS || platform=iPhoneSimulator
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleExecutable string DynamicKit" \
    -c "Add :CFBundleIdentifier string com.example.vendor.DynamicKit" \
    -c "Add :CFBundleName string DynamicKit" \
    -c "Add :CFBundlePackageType string FMWK" \
    -c "Add :CFBundleShortVersionString string 1.0" \
    -c "Add :CFBundleVersion string 1" \
    -c "Add :MinimumOSVersion string $MIN_IOS" \
    -c "Add :CFBundleSupportedPlatforms array" \
    -c "Add :CFBundleSupportedPlatforms:0 string $platform" \
    "$fw/Info.plist" >/dev/null
  xcrun dsymutil "$fw/DynamicKit" -o "$dir/DynamicKit.framework.dSYM"
  echo "-framework $fw -debug-symbols $dir/DynamicKit.framework.dSYM"
}

build_objc_kit() { # slice sdk targets...
  set -e  # these run inside $(...), which does not inherit -e on bash 3.2
  local slice="$1" sdk="$2"; shift 2
  local sdkpath; sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local dir="$WORK/$slice/ObjCKit" libs=()
  mkdir -p "$dir/include"
  cp "$CI_SRC/ObjCKit/OCKCounter.h" "$CI_SRC/ObjCKit/module.modulemap" "$dir/include/"
  for target in "$@"; do
    local arch="${target%%-*}"
    mkdir -p "$dir/$arch"
    (cd "$CI_ROOT" && xcrun --sdk "$sdk" clang -c -g -O0 -fobjc-arc -fmodules -target "$target" -isysroot "$sdkpath" \
      "$CI_SRC/ObjCKit/OCKCounter.m" -o "$dir/$arch/OCKCounter.o")
    xcrun libtool -static -o "$dir/$arch/libObjCKit.a" "$dir/$arch/OCKCounter.o" 2>/dev/null
    libs+=("$dir/$arch/libObjCKit.a")
  done
  xcrun lipo -create "${libs[@]}" -output "$dir/libObjCKit.a"
  echo "-library $dir/libObjCKit.a -headers $dir/include"
}

mkdir -p "$OUT"
for kit in StaticKit DynamicKit ObjCKit; do
  echo "Building $kit"
  args=()
  for s in "${SLICES[@]}"; do
    IFS='|' read -r slice sdk targets <<<"$s"
    case $kit in
      StaticKit)  line="$(build_static_kit "$slice" "$sdk" $targets)" ;;
      DynamicKit) line="$(build_dynamic_kit "$slice" "$sdk" $targets)" ;;
      ObjCKit)    line="$(build_objc_kit "$slice" "$sdk" $targets)" ;;
    esac
    read -r -a parts <<<"$line"
    args+=("${parts[@]}")
  done
  rm -rf "$OUT/$kit.xcframework"
  xcodebuild -create-xcframework "${args[@]}" -output "$OUT/$kit.xcframework" >/dev/null
done

echo "Deleting the CI copy (the binaries now reference missing paths)"
rm -rf "$CI_ROOT"
# Remove the now-empty parent folders too (rmdir only removes empty ones).
d="$(dirname "$CI_ROOT")"; while rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
echo "Done:"
ls -1d "$OUT"/*.xcframework
