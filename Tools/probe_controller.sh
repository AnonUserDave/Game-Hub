#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_developer="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
task_toolchain="$task_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
task_sdk="$task_developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
mkdir -p "$task_root/.build/cache"
"$task_toolchain/clang" -isysroot "$task_sdk" -target arm64-apple-macos14.0 \
    -fmodules-cache-path="$task_root/.build/cache" -fobjc-arc \
    -framework Foundation -framework IOKit -framework IOUSBHost \
    "$task_root/Tools/probe_controller.m" -o "$task_root/.build/probe_controller"
exec "$task_root/.build/probe_controller" "$@"
