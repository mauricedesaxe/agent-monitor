#!/bin/zsh
set -euo pipefail

script_dir="$(dirname "$(realpath "$0")")"
project_root="$(dirname "$script_dir")"
configuration="${1:-release}"
app="$project_root/dist/Agent Monitor.app"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/agent-monitor-clang-cache}"

swift build --package-path "$project_root" --disable-sandbox -c "$configuration" -j 4
binary_dir="$(swift build --package-path "$project_root" --disable-sandbox -c "$configuration" --show-bin-path)"
mkdir -p "$app/Contents/MacOS"
cp "$project_root/Info.plist" "$app/Contents/Info.plist"
cp "$binary_dir/AgentMonitor" "$app/Contents/MacOS/AgentMonitor"
chmod +x "$app/Contents/MacOS/AgentMonitor"
codesign --force --sign - "$app"
print "$app"
