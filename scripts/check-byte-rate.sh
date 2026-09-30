#!/bin/zsh
set -euo pipefail

project_root="$(dirname "$(dirname "$(realpath "$0")")")"
scratch="$(mktemp -d /private/tmp/agent-monitor-byte-rate.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/agent-monitor-clang-cache}"

{
    print 'import Foundation'
    sed -n '/^private func bytes(_ value: UInt64) -> String {/,/^}/p' "$project_root/Sources/AgentMonitor/AgentMonitorApp.swift"
    sed -n '/^private func bytesPerSecond(_ value: Double) -> String {/,/^}/p' "$project_root/Sources/AgentMonitor/AgentMonitorApp.swift"
    cat <<'SWIFT'
let cases: [(String, Double, String)] = [
    ("ordinary", 1024, bytes(1024) + "/s"),
    ("negative", -1, bytes(0) + "/s"),
    ("nan", .nan, bytes(0) + "/s"),
    ("uint64 ceiling", Double(UInt64.max), bytes(UInt64(Int64.max)) + "/s"),
    ("infinity", .infinity, bytes(UInt64(Int64.max)) + "/s"),
]

for (name, input, expected) in cases {
    let actual = bytesPerSecond(input)
    precondition(actual == expected, "\(name): \(actual) != \(expected)")
    print("PASS \(name)")
}
SWIFT
} > "$scratch/main.swift"

swiftc "$scratch/main.swift" -o "$scratch/check-byte-rate"
python3 -c 'import subprocess, sys; subprocess.run([sys.argv[1]], check=True, timeout=10)' "$scratch/check-byte-rate"
