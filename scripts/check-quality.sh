#!/bin/sh
set -eu

usage() {
	printf '%s\n' 'Usage: scripts/check-quality.sh [quick|full] [--seed UInt64] [--iterations 1..100000]' >&2
	exit 2
}

mode=quick
seed=12648430
iterations=
if [ "$#" -gt 0 ]; then
	case "$1" in
		quick|full) mode=$1; shift ;;
		--*) ;;
		*) usage ;;
	esac
fi
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || usage
	case "$1" in
		--seed) seed=$2 ;;
		--iterations) iterations=$2 ;;
		*) usage ;;
	esac
	shift 2
done
case "$seed" in ''|*[!0-9]*) usage ;; esac
if [ -z "$iterations" ]; then
	if [ "$mode" = full ]; then iterations=40; else iterations=10; fi
fi
case "$iterations" in ''|*[!0-9]*) usage ;; esac
[ "$iterations" -ge 1 ] && [ "$iterations" -le 100000 ] || usage

script_dir=$(dirname -- "$(realpath "$0")")
repo_dir=$(dirname -- "$script_dir")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/agent-monitor-quality.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
export CLANG_MODULE_CACHE_PATH="$scratch/clang-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

printf '%s\n' 'Checking full-package strict concurrency and warnings'
swift build --disable-sandbox --package-path "$repo_dir" --scratch-path "$scratch/strict" \
	-Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift run --disable-sandbox --package-path "$repo_dir" --scratch-path "$scratch/strict" MonitorCoreChecks
"$script_dir/check-byte-rate.sh"
swift run --disable-sandbox --package-path "$repo_dir" --scratch-path "$scratch/strict" MonitorCoreFuzz \
	--seed "$seed" --iterations "$iterations"

if [ "$mode" = full ]; then
	for sanitizer in address thread; do
		printf 'Checking %s sanitizer\n' "$sanitizer"
		case "$sanitizer" in
			address) target="$scratch/address" ;;
			thread) target="$scratch/thread" ;;
		esac
		swift run --disable-sandbox --package-path "$repo_dir" --scratch-path "$target" --sanitize "$sanitizer" MonitorCoreChecks
		swift run --disable-sandbox --package-path "$repo_dir" --scratch-path "$target" --sanitize "$sanitizer" \
			MonitorCoreFuzz --seed "$seed" --iterations "$iterations"
	done
fi
