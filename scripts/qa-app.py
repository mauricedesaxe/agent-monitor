#!/usr/bin/env python3
"""Isolated packaged-app end-to-end check and resource profiler."""

import argparse
import csv
import json
import math
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "dist/Agent Monitor.app/Contents/MacOS/AgentMonitor"
FIXTURE_SOURCE = ROOT / "Tests/fixtures/opencode.c"
MIN_FIXTURE_RAM_BYTES = 8 * 1024 * 1024


class CheckFailed(Exception):
    pass


class RunSession:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="agent-monitor-qa-")
        self.root = Path(self.temporary.name)
        self.data_directory = self.root / "data"
        if not self.data_directory.is_absolute():
            raise CheckFailed("Isolated data directory must be an absolute path")
        self.environment = os.environ.copy()
        self.environment.pop("CFFIXED_USER_HOME", None)
        self.environment["AGENT_MONITOR_DATA_DIR"] = str(self.data_directory)
        self.children = []

    def __enter__(self):
        return self

    def __exit__(self, _type, _value, _traceback):
        failures = []
        for child in reversed(self.children):
            try:
                self.stop(child)
            except (OSError, subprocess.TimeoutExpired, CheckFailed) as error:
                failures.append(f"PID {child.pid}: {error}")
        self.temporary.cleanup()
        if failures:
            message = "Could not stop isolated child processes: " + "; ".join(failures)
            if _type is not None:
                sys.stderr.write(f"qa-app cleanup: {message}\n")
            else:
                raise CheckFailed(message)

    @property
    def database(self):
        return self.data_directory / "history.sqlite3"

    def start(self, argv):
        child = subprocess.Popen(argv, env=self.environment, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        self.children.append(child)
        return child

    def stop(self, child):
        if child.poll() is not None:
            return
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired as error:
                raise CheckFailed(f"PID {child.pid} did not exit after SIGKILL") from error

    def snapshot(self):
        result = subprocess.run([str(APP), "--snapshot"], env=self.environment,
                                capture_output=True, text=True, timeout=10, check=True)
        sample = json.loads(result.stdout)
        if sample["scanFailed"]:
            raise CheckFailed("Process scan failed in packaged --snapshot")
        return sample


def require_app():
    if not APP.is_file() or not os.access(APP, os.X_OK):
        raise CheckFailed("Packaged app missing. Run ./scripts/build-app.sh first.")


def compile_fixture(destination):
    command = ["/usr/bin/clang", "-O2", "-std=c11", "-Wall", "-Wextra", "-Werror",
               str(FIXTURE_SOURCE), "-o", str(destination)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
    if result.returncode != 0:
        raise CheckFailed(f"Could not compile OpenCode fixture: {result.stderr.strip() or result.stdout.strip()}")


def wait_for(predicate, seconds, description, child=None):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if child is not None and child.poll() is not None:
            raise CheckFailed(f"Packaged app exited before {description} (status {child.returncode})")
        result = predicate()
        if result is not None:
            return result
        time.sleep(0.5)
    raise CheckFailed(f"Timed out after {seconds:g}s waiting for {description}")


def history_rows(database):
    if not database.exists():
        return {}
    try:
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=1) as connection:
            rows = connection.execute("SELECT harness, samples, active, mean_cpu, max_cpu, "
                                      "mean_ram, max_ram FROM minutes ORDER BY minute DESC").fetchall()
    except sqlite3.OperationalError as error:
        if "no such table" in str(error):
            return {}
        raise CheckFailed(f"Cannot read isolated history database: {error}") from error
    latest = {}
    for row in rows:
        latest.setdefault(row[0], row[1:])
    return latest


def e2e():
    require_app()
    with RunSession() as session:
        baseline = session.snapshot()["harnesses"]["OpenCode"]
        fixture_path = session.root / "opencode"
        compile_fixture(fixture_path)
        fixture = session.start([str(fixture_path)])
        time.sleep(1)
        def fixture_seen():
            usage = session.snapshot()["harnesses"]["OpenCode"]
            if (usage["processCount"] > baseline["processCount"]
                    and usage["cpuPercent"] - baseline["cpuPercent"] > 5
                    and usage["ramBytes"] - baseline["ramBytes"] >= MIN_FIXTURE_RAM_BYTES):
                return usage
            return None
        live = wait_for(fixture_seen, 15, "OpenCode fixture in packaged snapshot", fixture)
        app = session.start([str(APP)])
        def persisted():
            rows = history_rows(session.database)
            open_row, all_row = rows.get("OpenCode"), rows.get("All agents")
            if not open_row or not all_row:
                return None
            if (open_row[0] > 0 and all_row[0] > 0 and open_row[1] == 1
                    and all_row[1] == 1 and open_row[2] > 5 and all_row[2] > 5
                    and open_row[3] > 0 and all_row[3] > 0
                    and open_row[4] - baseline["ramBytes"] >= MIN_FIXTURE_RAM_BYTES
                    and all_row[4] >= open_row[4]):
                return rows
            return None
        rows = wait_for(persisted, 55, "active OpenCode and All agents history rows", app)
        session.stop(fixture)
        def fixture_gone():
            usage = session.snapshot()["harnesses"]["OpenCode"]
            return usage if usage["processCount"] <= baseline["processCount"] else None
        gone = wait_for(fixture_gone, 15, "fixture removal from packaged snapshot", app)
        sys.stdout.write(json.dumps({"result": "pass", "app_pid": app.pid, "fixture_pid": fixture.pid,
                                     "fixture_live": live, "fixture_after_stop": gone,
                                     "history_harnesses": sorted(rows),
                                     "opencode_max_cpu": rows["OpenCode"][3]}, indent=2) + "\n")


def cpu_seconds(value):
    days = 0
    if "-" in value:
        day, value = value.split("-", 1)
        days = int(day)
    parts = [float(part) for part in value.split(":")]
    total = 0.0
    for part in parts:
        total = total * 60 + part
    return days * 86400 + total


def percentile(values, fraction):
    values = sorted(values)
    position = (len(values) - 1) * fraction
    low = int(position)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (position - low)


def process_usage(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "time=", "-o", "rss="],
                            capture_output=True, text=True, timeout=5, check=False)
    if result.returncode != 0 or not result.stdout.strip():
        raise CheckFailed(f"Cannot read CPU time and RSS for app PID {pid}: {result.stderr.strip()}")
    cpu, rss = result.stdout.split()
    return cpu_seconds(cpu), int(rss) * 1024


def database_file_bytes(database):
    return sum(path.stat().st_size for path in
               (database, Path(str(database) + "-wal"), Path(str(database) + "-shm"))
               if path.exists())


def profile(duration, interval, output, stacks):
    require_app()
    with RunSession() as session:
        app = session.start([str(APP)])
        start = time.monotonic()
        samples = []
        previous = None
        while time.monotonic() - start < duration:
            if app.poll() is not None:
                raise CheckFailed(f"Packaged app exited while profiling (status {app.returncode})")
            cpu, rss = process_usage(app.pid)
            now = time.monotonic()
            cpu_percent = 0.0 if previous is None else 100 * max(0, cpu - previous[0]) / (now - previous[1])
            samples.append({"elapsed_seconds": round(now - start, 3), "cpu_one_core_percent": round(cpu_percent, 3),
                            "rss_bytes": rss, "database_file_bytes": database_file_bytes(session.database)})
            previous = cpu, now
            time.sleep(min(interval, max(0, duration - (now - start))))
        if len(samples) < 2:
            raise CheckFailed("Profile needs at least two samples. Increase --duration or reduce --interval.")
        rss_values = [sample["rss_bytes"] for sample in samples]
        cpu_values = [sample["cpu_one_core_percent"] for sample in samples[1:]]
        result = {"app_pid": app.pid, "duration_seconds": round(samples[-1]["elapsed_seconds"], 3),
                  "interval_seconds": interval, "sample_count": len(samples),
                  "cpu_one_core_percent_mean": round(sum(cpu_values) / len(cpu_values), 3),
                  "cpu_one_core_percent": {name: round(percentile(cpu_values, value), 3) for name, value in
                                           (("p50", .5), ("p90", .9), ("p95", .95), ("p99", .99))},
                  "cpu_one_core_percent_max": max(cpu_values),
                  "rss_bytes": {name: round(percentile(rss_values, value)) for name, value in
                                (("p50", .5), ("p90", .9), ("p95", .95), ("p99", .99))},
                  "rss_bytes_max": max(rss_values),
                  "database_file_bytes_final": samples[-1]["database_file_bytes"]}
        if stacks:
            stacks.parent.mkdir(parents=True, exist_ok=True)
            stack_run = subprocess.run(["/usr/bin/sample", str(app.pid), "5", "-file", str(stacks)],
                                       capture_output=True, text=True, timeout=15, check=False)
            if stack_run.returncode != 0:
                raise CheckFailed(f"Stack sampling failed: {stack_run.stderr.strip() or stack_run.stdout.strip()}")
            result["stacks_path"] = str(stacks)
        if output:
            output.parent.mkdir(parents=True, exist_ok=True)
            if output.suffix.lower() == ".csv":
                with output.open("w", newline="") as file:
                    writer = csv.DictWriter(file, fieldnames=samples[0].keys())
                    writer.writeheader()
                    writer.writerows(samples)
            else:
                output.write_text(json.dumps({"summary": result, "samples": samples}, indent=2) + "\n")
        sys.stdout.write(json.dumps(result, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("e2e", help="Check packaged process discovery and SQLite history")
    profile_parser = subcommands.add_parser("profile", help="Measure packaged app CPU and RSS")
    profile_parser.add_argument("--duration", type=float, default=60)
    profile_parser.add_argument("--interval", type=float, default=0.5)
    profile_parser.add_argument("--output", type=Path, help="Write samples to .json or .csv")
    profile_parser.add_argument("--stacks", type=Path, help="Capture a 5-second macOS CPU stack sample after metrics")
    arguments = parser.parse_args()
    if arguments.command == "profile":
        if not math.isfinite(arguments.duration) or arguments.duration <= 0:
            parser.error("--duration must be positive and finite")
        if not math.isfinite(arguments.interval) or arguments.interval <= 0:
            parser.error("--interval must be positive and finite")
    try:
        if arguments.command == "e2e":
            e2e()
        else:
            profile(arguments.duration, arguments.interval, arguments.output, arguments.stacks)
    except (CheckFailed, OSError, subprocess.SubprocessError, sqlite3.Error, ValueError, KeyError) as error:
        sys.stderr.write(f"qa-app: {error}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
