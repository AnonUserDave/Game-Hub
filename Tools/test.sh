#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_developer="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
task_toolchain="$task_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
task_platform="$task_developer/Platforms/MacOSX.platform/Developer"
task_sdk="$task_platform/SDKs/MacOSX.sdk"
cd "$task_root"
mkdir -p "$task_root/.build/cache"
export SDKROOT="$task_sdk"
export SWIFT_EXEC="$task_toolchain/swiftc"
export CLANG_MODULE_CACHE_PATH="$task_root/.build/cache"
# Build the XCTest bundle without SwiftPM's xcrun-based runner discovery. The
# installed native xctest binary can execute it directly even when xcrun is
# blocked by an unaccepted Xcode license.
"$task_toolchain/swift" build --build-tests --sdk "$task_sdk" \
    --cache-path "$task_root/.build/swiftpm-cache" \
    --config-path "$task_root/.build/swiftpm-config" \
    --security-path "$task_root/.build/swiftpm-security" --disable-sandbox \
    -Xswiftc -F -Xswiftc "$task_platform/Library/Frameworks" \
    -Xswiftc -I -Xswiftc "$task_platform/usr/lib" \
    -Xlinker -rpath -Xlinker "$task_platform/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$task_platform/usr/lib" \
    -Xlinker -rpath -Xlinker "$task_developer/../SharedFrameworks" \
    -Xlinker -L -Xlinker "$task_platform/usr/lib"
exec "$task_developer/usr/bin/xctest" "$@" "$task_root/.build/arm64-apple-macosx/debug/GameHubPackageTests.xctest"
