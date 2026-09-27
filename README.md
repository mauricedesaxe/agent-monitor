# Agent Monitor

Agent Monitor is a native Swift app for macOS. It shows the combined CPU and memory use of Codex, Claude Code, and OpenCode, with a row for each tool. A History view shows typical active minutes and P50, P90, P95, and P99 of short sample peaks. The app stores history in SQLite on this Mac.

## Run it

Build the app with the macOS Command Line Tools:

```sh
./scripts/build-app.sh
open 'dist/Agent Monitor.app'
```

Keep the app open to collect history. You can close its window and use the menu bar item to open it again. History lives at `~/Library/Application Support/Agent Monitor/history.sqlite3`.

## What the numbers mean

- CPU is a percent of one core. A value above 100% means work ran on multiple cores.
- Memory is the sum of the tracked processes' physical footprints. It is an estimate of the capacity those processes need, not the Mac's free memory.
- The live view also shows SSD read and write rates. Battery power is not measured.
- The collector samples tracked processes every 500 ms. The live view refreshes once a second. SQLite receives minute summaries in batches.
- A working minute has mean CPU use of at least 5% of one core or mean SSD writes of at least 100 KB/s. The typical values are medians of working-minute averages. Peak percentiles use each working minute's highest 500 ms sample.

The app needs to run outside the macOS App Sandbox to inspect other processes. It does not require root and does not send data to a server. Brief processes may start and exit between discovery scans, so their resource use may be missed.

Run the core checks with `CLANG_MODULE_CACHE_PATH=/private/tmp/agent-monitor-clang-cache swift run --disable-sandbox MonitorCoreChecks`. Run `bd ready` for local project tasks.
