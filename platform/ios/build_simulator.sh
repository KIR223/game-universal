#!/bin/bash
# Build IRON DOMINION for the iOS Simulator (arm64).
# The official Godot 4.7.2 export templates contain only an x86_64 simulator library, which iOS 27 simulators refuse to run,
# so an arm64 simulator library is built once from the Godot source and merged into the exported project:
#   scons platform=ios arch=arm64 ios_simulator=yes target=template_debug vulkan=no
# usage: platform/ios/build_simulator.sh /path/to/libgodot.ios.template_debug.arm64.simulator.a [simulator-udid]
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"   # xcode-select may point at the Command Line Tools after a restart
ARM64_LIB="${1:?path to libgodot.ios.template_debug.arm64.simulator.a}"
UDID="${2:-booted}"
cd "$(dirname "$0")/../.."
rm -rf build/ios && mkdir -p build/ios
godot --headless --path . --export-debug "iOS" build/ios/IronDominion.xcodeproj
LIB=build/ios/IronDominion.xcframework/ios-arm64_x86_64-simulator/libgodot.a
cp "$LIB" build/ios/libgodot_x86_64.a
lipo -create build/ios/libgodot_x86_64.a "$ARM64_LIB" -output "$LIB"
rm build/ios/libgodot_x86_64.a
xcodebuild -project build/ios/IronDominion.xcodeproj -scheme IronDominion -configuration Debug -sdk iphonesimulator \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build/ios/DerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build
APP=build/ios/DerivedData/Build/Products/Debug-iphonesimulator/IronDominion.app
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" com.example.irondominion
