import Foundation
import Darwin
import SQLite3
@_spi(Testing) import MonitorCore

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
for _ in 0..<119 { idleMinute.add(ResourceUsage(cpuPercent: 1)) }
idleMinute.add(ResourceUsage(cpuPercent: 10))
let idleRecord = idleMinute.record(minute: 0, harness: .claude)!
precondition(!idleRecord.active)
precondition(idleRecord.maxCPU == 10)
precondition(abs(idleRecord.meanCPU - 1.075) < 0.0001)

var partialCPU = MinuteAccumulator()
partialCPU.add(ResourceUsage(cpuPercent: 6))
precondition(partialCPU.record(minute: 0, harness: .codex)!.active)
var partialDisk = MinuteAccumulator()
partialDisk.add(ResourceUsage(diskWriteBytesPerSecond: 101 * 1024))
precondition(partialDisk.record(minute: 0, harness: .codex)!.active)

var retryBuffer = MinuteBuffer()
retryBuffer.add(LiveSample(timestamp: Date(timeIntervalSince1970: 60),
                           usage: [.all: ResourceUsage(cpuPercent: 8)], active: true))
do {
    try retryBuffer.persist(currentMinute: 2) { _ in throw StoreError.query }
    preconditionFailure("failed persistence should throw")
} catch StoreError.query {}
precondition(retryBuffer.minutes == [1])
try retryBuffer.persist(currentMinute: 2) { records in
    precondition(records.count == 4)
    precondition(records.first { $0.harness == .all }?.meanCPU == 8)
}
precondition(retryBuffer.minutes.isEmpty)

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

func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-monitor-checks-\(UUID().uuidString).sqlite3")
}

func removeDatabase(at url: URL) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
}

let restartURL = temporaryDatabaseURL()
do {
    defer { removeDatabase(at: restartURL) }
    let firstSample = LiveSample(timestamp: Date(timeIntervalSince1970: 42 * 60 + 1),
                                 usage: [.codex: ResourceUsage(cpuPercent: 10, footprintBytes: 100,
                                                              diskWriteBytesPerSecond: 50)],
                                 active: true)
    let firstCollector = Collector(sampleProvider: { firstSample },
                                   storeFactory: { try HistoryStore(url: restartURL) },
                                   dateProvider: { firstSample.timestamp })
    firstCollector.collectOnce()
    var blocker: OpaquePointer?
    precondition(sqlite3_open(restartURL.path, &blocker) == SQLITE_OK)
    precondition(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    var flushErrors = 0
    var recoveredPersistence = false
    firstCollector.onError = { message in
        if message == nil { recoveredPersistence = true }
        else { flushErrors += 1 }
    }
    firstCollector.flushNow()
    precondition(flushErrors == 1)
    precondition(sqlite3_exec(blocker, "COMMIT", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(blocker)
    firstCollector.flushNow()
    precondition(recoveredPersistence)

    let secondSample = LiveSample(timestamp: Date(timeIntervalSince1970: 42 * 60 + 30),
                                  usage: [.codex: ResourceUsage(cpuPercent: 20, footprintBytes: 300,
                                                               diskWriteBytesPerSecond: 150)],
                                  active: true)
    let secondCollector = Collector(sampleProvider: { secondSample },
                                    storeFactory: { try HistoryStore(url: restartURL) },
                                    dateProvider: { secondSample.timestamp })
    secondCollector.collectOnce()
    secondCollector.flushNow()
    let reopened = try HistoryStore(url: restartURL)
    let loaded = try reopened.records(since: .distantPast, harness: .codex).first!
    precondition(loaded.sampleCount == 2)
    precondition(loaded.meanCPU == 15)
    precondition(loaded.meanRAM == 200)
    precondition(loaded.diskWriteSum == 200)
    precondition(loaded.maxDiskWriteRate == 150)
}

let migrationURL = temporaryDatabaseURL()
do {
    defer { removeDatabase(at: migrationURL) }
    var legacyDatabase: OpaquePointer?
    precondition(sqlite3_open(migrationURL.path, &legacyDatabase) == SQLITE_OK)
    let legacySQL = "CREATE TABLE minutes (minute INTEGER NOT NULL, harness TEXT NOT NULL, " +
        "samples INTEGER NOT NULL, active INTEGER NOT NULL, mean_cpu REAL NOT NULL, " +
        "max_cpu REAL NOT NULL, mean_ram REAL NOT NULL, max_ram REAL NOT NULL, " +
        "max_disk_write REAL NOT NULL, PRIMARY KEY(minute,harness));" +
        "INSERT INTO minutes VALUES(42,'Codex',10,1,1,2,100,200,300000);"
    precondition(sqlite3_exec(legacyDatabase, legacySQL, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(legacyDatabase)
    do {
        let migrated = try HistoryStore(url: migrationURL)
        let checkpoint = try migrated.checkpoints(for: [42]).first!
        precondition(checkpoint.cpuSum == 10)
        precondition(checkpoint.ramSum == 1_000)
        precondition(checkpoint.diskWriteSum == 0)
        precondition(checkpoint.legacyActivityFloor)
        try migrated.upsert([checkpoint])
    }
    let reopened = try HistoryStore(url: migrationURL)
    let checkpoint = try reopened.checkpoints(for: [42]).first!
    var continued = MinuteAccumulator(checkpoint: checkpoint)
    continued.add(ResourceUsage(cpuPercent: 0))
    precondition(continued.record(minute: 42, harness: .codex)!.active)
}

let rolloverURL = temporaryDatabaseURL()
do {
    defer { removeDatabase(at: rolloverURL) }
    let stored = MinuteRecord(minute: 50, harness: .codex, sampleCount: 1, active: true,
                              meanCPU: 10, maxCPU: 10, meanRAM: 100, maxRAM: 100,
                              maxDiskWriteRate: 50, cpuSum: 10, ramSum: 100,
                              diskWriteSum: 50)
    try HistoryStore(url: rolloverURL).upsert([stored])
    let sample = LiveSample(timestamp: Date(timeIntervalSince1970: 50 * 60 + 59),
                            usage: [.codex: ResourceUsage(cpuPercent: 20, footprintBytes: 300,
                                                         diskWriteBytesPerSecond: 150)],
                            active: true)
    let collector = Collector(sampleProvider: { sample },
                              storeFactory: { try HistoryStore(url: rolloverURL) },
                              dateProvider: { Date(timeIntervalSince1970: 51 * 60) })
    collector.collectOnce()
    collector.flushNow()
    let record = try HistoryStore(url: rolloverURL)
        .records(since: .distantPast, harness: .codex).first!
    precondition(record.sampleCount == 2)
    precondition(record.meanCPU == 15)
    precondition(record.meanRAM == 200)
    precondition(record.diskWriteSum == 200)
}

let busyURL = temporaryDatabaseURL()
do {
    defer { removeDatabase(at: busyURL) }
    let busyStore = try HistoryStore(url: busyURL)
    var blocker: OpaquePointer?
    precondition(sqlite3_open(busyURL.path, &blocker) == SQLITE_OK)
    defer { sqlite3_close(blocker) }
    precondition(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    let finished = DispatchSemaphore(value: 0)
    let errorLock = NSLock()
    var writeError: Error?
    DispatchQueue.global().async {
        defer { finished.signal() }
        do {
            let record = MinuteRecord(minute: 7, harness: .all, sampleCount: 1, active: false,
                                      meanCPU: 1, maxCPU: 1, meanRAM: 2, maxRAM: 2,
                                      maxDiskWriteRate: 3, cpuSum: 1, ramSum: 2,
                                      diskWriteSum: 3)
            try busyStore.upsert([record])
        } catch {
            errorLock.lock()
            writeError = error
            errorLock.unlock()
        }
    }
    usleep(200_000)
    precondition(sqlite3_exec(blocker, "COMMIT", nil, nil, nil) == SQLITE_OK)
    precondition(finished.wait(timeout: .now() + 3) == .success)
    errorLock.lock()
    let capturedWriteError = writeError
    errorLock.unlock()
    precondition(capturedWriteError == nil)
    let busyRecords = try busyStore.records(since: .distantPast, harness: .all)
    precondition(busyRecords.count == 1)
}

func sampledProcess(cpuTicks: UInt64) -> ProcessReading {
    ProcessReading(pid: 123, parentPID: 1, name: "codex", path: "/usr/bin/codex",
                   startTicks: 9, cpuTicks: cpuTicks, footprintBytes: 100)
}

var now: UInt64 = 0
var discoveries = 0
let initialProcess = sampledProcess(cpuTicks: 0)
let failureSampler = ProcessSampler(
    discoveryIntervalSeconds: 2,
    clock: { now },
    discoveryReader: {
        discoveries += 1
        return discoveries == 1
            ? ([initialProcess], [initialProcess.pid: .codex], 0, false)
            : ([], [:], 0, true)
    },
    knownProcessReader: { _ in ([sampledProcess(cpuTicks: 2_500_000_000)], 0) }
)
precondition(failureSampler.sample().usage[.codex]?.cpuPercent == 0)
now = 2_000_000_000
precondition(failureSampler.sample().scanFailed)
now = 2_500_000_000
let recoveredSample = failureSampler.sample()
precondition(!recoveredSample.scanFailed)
precondition(abs((recoveredSample.usage[.codex]?.cpuPercent ?? 0) - 100) < 0.001)

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
