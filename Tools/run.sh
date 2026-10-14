#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
if [[ ! -x "$task_root/Game Hub.app/Contents/MacOS/GameHub" ]]; then
    "$task_root/Tools/build.sh"
fi
export GAMEHUB_LIBRARY_ROOT="$task_root"
exec "$task_root/Game Hub.app/Contents/MacOS/GameHub" "$@"
