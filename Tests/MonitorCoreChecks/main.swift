import Foundation
import Darwin
import MonitorCore

func reading(_ pid: Int32, _ parentPID: Int32, _ name: String, _ path: String) -> ProcessReading {
    ProcessReading(pid: pid, parentPID: parentPID, name: name, path: path,
                   startTicks: 1, cpuTicks: 1, footprintBytes: 1)
}

let percentiles = Percentiles([10, 20, 30, 40, 50])
precondition(percentiles.p50 == 30)
precondition(percentiles.p90 == 46)
precondition(percentiles.p95 == 48)
precondition(abs(percentiles.p99 - 49.6) < 0.0001)

var idleMinute = MinuteAccumulator()
for _ in 0..<119 { idleMinute.add(ResourceUsage(cpuPercent: 1), active: false) }
idleMinute.add(ResourceUsage(cpuPercent: 10), active: true)
let idleRecord = idleMinute.record(minute: 0, harness: .claude)!
precondition(!idleRecord.active)
precondition(idleRecord.maxCPU == 10)
precondition(abs(idleRecord.meanCPU - 1.075) < 0.0001)

let processes = [
    reading(1, 0, "Codex (Renderer)", "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Codex (Renderer)"),
    reading(2, 1, "node", "/usr/local/bin/node"),
    reading(3, 1, "crashpad_handler", "/app/crashpad_handler"),
    reading(4, 0, "2.1.282", "/Users/test/.local/share/claude/versions/2.1.282"),
    reading(5, 0, "AgentMonitor", "/Applications/AgentMonitor.app/Contents/MacOS/AgentMonitor"),
    reading(6, 5, "codex", "/usr/local/bin/codex"),
    reading(7, 6, "codex", "/usr/local/bin/codex"),
]
let owned = ProcessAttribution.classify(processes, excluding: 5)
precondition(owned[1] == .codex)
precondition(owned[2] == .codex)
precondition(owned[3] == nil)
precondition(owned[4] == .claude)
precondition(owned[5] == nil)
precondition(owned[6] == nil)
precondition(owned[7] == nil)

let databaseURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("agent-monitor-checks-\(UUID().uuidString).sqlite3")
let store = try HistoryStore(url: databaseURL)
let record = MinuteRecord(minute: 42, harness: .all, sampleCount: 120, active: true,
                          meanCPU: 25, maxCPU: 90, meanRAM: 2_000_000_000,
                          maxRAM: 3_000_000_000, maxDiskWriteRate: 100_000)
try store.upsert([record])
let loaded = try store.records(since: Date(timeIntervalSince1970: 0), harness: .all)
precondition(loaded.count == 1)
precondition(loaded[0].maxRAM == 3_000_000_000)
precondition(loaded[0].sampleCount == 120)
try? FileManager.default.removeItem(at: databaseURL)

print("Core checks passed")

if let benchmarkIndex = CommandLine.arguments.firstIndex(of: "--benchmark"),
   CommandLine.arguments.indices.contains(benchmarkIndex + 1),
   let interval = Double(CommandLine.arguments[benchmarkIndex + 1]) {
    let sampler = ProcessSampler(discoveryIntervalSeconds: interval)
    var before = rusage()
    var after = rusage()
    getrusage(RUSAGE_SELF, &before)
    let start = Date()
    var lastCount = 0
    while Date().timeIntervalSince(start) < 10 {
        lastCount = sampler.sample().usage[.all]?.processCount ?? 0
        Thread.sleep(forTimeInterval: 0.5)
    }
    getrusage(RUSAGE_SELF, &after)
    func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
    let cpu = seconds(after.ru_utime) + seconds(after.ru_stime)
        - seconds(before.ru_utime) - seconds(before.ru_stime)
    print(String(format: "Discovery %.1f s: %.2f%% of one core, %d tracked processes",
                 interval, cpu / Date().timeIntervalSince(start) * 100, lastCount))
}
