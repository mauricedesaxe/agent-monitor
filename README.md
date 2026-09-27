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

## Check changes

Run `./scripts/check-quality.sh quick` to build the whole package with complete concurrency checks and warnings treated as errors. It also runs the existing core checks and 10 generated cases in each domain. Run `./scripts/check-quality.sh full` to check 40 cases per domain under AddressSanitizer and ThreadSanitizer as well. Pass `--iterations 500` for a longer run or `--seed 173` to use a chosen seed.

The generator checks process ownership graphs and minute history across failed writes, SQLite migration, and collector restarts. Each history case uses a new temporary SQLite directory. The checks never open the app's database or scan live processes. They run only when invoked and add no work to the app. The installed Apple Swift toolchain has no usable macOS libFuzzer runtime, so these are seeded cases without coverage feedback.

Run one reported failure directly with `CLANG_MODULE_CACHE_PATH=/private/tmp/agent-monitor-clang-cache swift run --disable-sandbox MonitorCoreFuzz --domain history --seed 173 --case 284`. Use `--domain attribution` for a process case. The failure prints its seed, case number, invariant, and fixture. Run `bd ready` for local project tasks.

## Packaged app QA

Build the bundle first with `./scripts/build-app.sh`. Then run:

```sh
python3 scripts/qa-app.py e2e
python3 scripts/qa-app.py profile --duration 60 --interval 0.5 --output /private/tmp/agent-monitor-profile.json
```

The E2E check compiles a small `opencode` workload with the system clang, then starts it and the packaged app with `AGENT_MONITOR_DATA_DIR` set to a temporary absolute directory. The variable moves both the SQLite database and the app's single-instance lock; when it is unset or not an absolute path, the app uses its normal Application Support directory. The workload uses CPU and touches 16 MiB of memory. The check verifies that the packaged `--snapshot` command detects the process, more than 5% CPU use, and at least 8 MiB of added memory. It then waits for active OpenCode and All agents rows with CPU and memory use in SQLite, and checks that attribution clears after the workload stops. It can take about a minute because the app persists history every 30 seconds. The test never opens your normal history database or stops processes it did not start.

The profiler measures the packaged app's own PID, with CPU as a percent of one core and CPU and RSS percentiles. It also reports the combined size of the SQLite database, WAL, and shared-memory files. `--output` saves per-sample JSON, or CSV when the path ends in `.csv`. Add `--stacks /private/tmp/agent-monitor-stacks.txt` to capture a separate five-second macOS CPU stack sample after the metrics run. Its numbers are observations, not pass/fail budgets. Run it on an otherwise quiet Mac for comparisons. The E2E check exercises process discovery and persistence; inspect the visible Live and History views manually when changing UI behavior.
