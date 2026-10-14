#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_developer="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
task_toolchain="$task_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
task_sdk="$task_developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
task_app="$task_root/Game Hub.app"
if [[ ! -x "$task_toolchain/swiftc" || ! -d "$task_sdk" ]]; then
    print -u2 "Xcode's Swift compiler and macOS SDK are required. Set DEVELOPER_DIR if Xcode is installed elsewhere."
    exit 1
fi
mkdir -p "$task_root/.build/cache" "$task_app/Contents/MacOS" "$task_app/Contents/Resources/Manifests"
rm -f "$task_app"/Contents/Resources/Manifests/*.json(N)
print "Building native arm64 Game Hub…"
"$task_toolchain/clang" -isysroot "$task_sdk" -target arm64-apple-macos14.0 \
    -fmodules-cache-path="$task_root/.build/cache" -fobjc-arc \
    -I "$task_root/Sources/FusionUSB/include" -c "$task_root/Sources/FusionUSB/FusionUSB.m" -o "$task_root/.build/FusionUSB.o"
"$task_toolchain/swiftc" -sdk "$task_sdk" -target arm64-apple-macosx14.0 \
    -module-cache-path "$task_root/.build/cache" -swift-version 5 -O \
    -I "$task_root/Sources/FusionUSB/include" "$task_root/.build/FusionUSB.o" -framework IOUSBHost \
    -module-name GameHub "$task_root"/Sources/GameHub/*.swift \
    -o "$task_app/Contents/MacOS/GameHub"
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root"/Library/Manifests/*.json "$task_app/Contents/Resources/Manifests/"
cp "$task_root/docs/INTEGRATION.md" "$task_app/Contents/Resources/INTEGRATION.md"
cp "$task_root/docs/CONTROLLER.md" "$task_app/Contents/Resources/CONTROLLER.md"
print "Built $task_app"
