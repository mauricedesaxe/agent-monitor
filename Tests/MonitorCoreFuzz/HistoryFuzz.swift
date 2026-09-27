import Foundation
import SQLite3
@_spi(Testing) import MonitorCore

private struct RecordKey: Hashable {
    let minute: Int64
    let harness: Harness
}

private struct LedgerEntry {
    var count = 0
    var cpuSum = 0.0
    var ramSum = 0.0
    var diskWriteSum = 0.0
    var maxCPU = 0.0
    var maxRAM = 0.0
    var maxDiskWrite = 0.0
    var legacyActivityFloor = false

    mutating func add(_ usage: ResourceUsage) {
        count += 1
        cpuSum += usage.cpuPercent
        ramSum += Double(usage.footprintBytes)
        diskWriteSum += usage.diskWriteBytesPerSecond
        maxCPU = max(maxCPU, usage.cpuPercent)
        maxRAM = max(maxRAM, Double(usage.footprintBytes))
        maxDiskWrite = max(maxDiskWrite, usage.diskWriteBytesPerSecond)
    }
}

private struct Ledger {
    var entries: [RecordKey: LedgerEntry] = [:]

    mutating func add(_ sample: LiveSample) {
        let minute = Int64(sample.timestamp.timeIntervalSince1970 / 60)
        for harness in Harness.allCases {
            let key = RecordKey(minute: minute, harness: harness)
            var entry = entries[key] ?? LedgerEntry()
            entry.add(sample.usage[harness] ?? ResourceUsage())
            entries[key] = entry
        }
    }

    mutating func addLegacy(minute: Int64, count: Int, meanCPU: Double, meanRAM: Double,
                            maxCPU: Double, maxRAM: Double, maxDiskWrite: Double) {
        entries[RecordKey(minute: minute, harness: .codex)] = LedgerEntry(
            count: count, cpuSum: meanCPU * Double(count), ramSum: meanRAM * Double(count),
            diskWriteSum: 0, maxCPU: maxCPU, maxRAM: maxRAM,
            maxDiskWrite: maxDiskWrite, legacyActivityFloor: true)
    }

    func check(_ records: [MinuteRecord], label: String) throws {
        var actual: [RecordKey: MinuteRecord] = [:]
        for record in records {
            let key = RecordKey(minute: record.minute, harness: record.harness)
            guard actual.updateValue(record, forKey: key) == nil else {
                throw FuzzFailure("\(label): duplicate row minute=\(key.minute) harness=\(key.harness.rawValue)")
            }
        }
        guard actual.count == entries.count, Set(actual.keys) == Set(entries.keys) else {
            throw FuzzFailure("\(label): row keys differ; expected \(describeKeys(entries.keys)), got \(describeKeys(actual.keys))")
        }
        for (key, expected) in entries {
            guard let row = actual[key] else { throw FuzzFailure("\(label): missing row") }
            let meanCPU = expected.cpuSum / Double(expected.count)
            let meanRAM = expected.ramSum / Double(expected.count)
            let active = expected.legacyActivityFloor || meanCPU >= 5
                || expected.diskWriteSum / Double(expected.count) >= 100 * 1024
            let values: [(String, Double, Double)] = [
                ("cpuSum", row.cpuSum, expected.cpuSum),
                ("ramSum", row.ramSum, expected.ramSum),
                ("diskWriteSum", row.diskWriteSum, expected.diskWriteSum),
                ("meanCPU", row.meanCPU, meanCPU),
                ("meanRAM", row.meanRAM, meanRAM),
                ("maxCPU", row.maxCPU, expected.maxCPU),
                ("maxRAM", row.maxRAM, expected.maxRAM),
                ("maxDiskWriteRate", row.maxDiskWriteRate, expected.maxDiskWrite),
            ]
            guard row.sampleCount == expected.count, row.active == active,
                  row.legacyActivityFloor == expected.legacyActivityFloor else {
                throw FuzzFailure("\(label): flags/count differ at \(key.minute)/\(key.harness.rawValue); expected count=\(expected.count) active=\(active) floor=\(expected.legacyActivityFloor), got count=\(row.sampleCount) active=\(row.active) floor=\(row.legacyActivityFloor)")
            }
            for (field, got, want) in values where abs(got - want) > 0.000_001 {
                throw FuzzFailure("\(label): \(field) differs at \(key.minute)/\(key.harness.rawValue); expected \(want), got \(got)")
            }
        }
    }

    private func describeKeys<S: Sequence>(_ keys: S) -> String where S.Element == RecordKey {
        keys.map { "\($0.minute)/\($0.harness.rawValue)" }.sorted().joined(separator: ",")
    }
}

struct HistoryCase {
    let minute: Int64
    let legacy: Bool
    let legacyCount: Int
    let initialSamples: [LiveSample]
    let restartedSamples: [LiveSample]

    static func make(random: inout CaseRandom) -> Self {
        let minute = Int64(10_000 + random.integer(1_000_000))
        func sample(at second: Int64, random: inout CaseRandom) -> LiveSample {
            var usage: [Harness: ResourceUsage] = [:]
            var total = ResourceUsage()
            for harness in Harness.individual where random.integer(4) != 0 {
                let measurement = ResourceUsage(
                    cpuPercent: Double(random.integer(20)),
                    footprintBytes: UInt64(random.integer(10_000)),
                    diskWriteBytesPerSecond: Double(random.integer(220_000)),
                    processCount: 1)
                usage[harness] = measurement
                total.add(measurement)
            }
            usage[.all] = total
            return LiveSample(timestamp: Date(timeIntervalSince1970: TimeInterval(second)),
                              usage: usage, active: true)
        }
        let initial = (0..<(1 + random.integer(4))).map { _ in
            sample(at: minute * 60 + Int64(random.integer(30)), random: &random)
        }
        var restarted: [LiveSample] = []
        for index in 0..<(2 + random.integer(5)) {
            let sampleMinute = minute + (index < 2 ? 0 : 1)
            restarted.append(sample(at: sampleMinute * 60 + Int64(30 + random.integer(30)),
                                    random: &random))
        }
        return Self(minute: minute, legacy: random.integer(3) == 0,
                    legacyCount: 1 + random.integer(5), initialSamples: initial,
                    restartedSamples: restarted)
    }

    func check() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-monitor-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        var ledger = Ledger()
        if legacy {
            try createLegacyDatabase(at: databaseURL)
            ledger.addLegacy(minute: minute, count: legacyCount, meanCPU: 1, meanRAM: 100,
                             maxCPU: 2, maxRAM: 200, maxDiskWrite: 300_000)
        }

        do {
            let store = try HistoryStore(url: databaseURL)
            try ledger.check(readAll(store), label: "migration")
            var buffer = MinuteBuffer()
            for checkpoint in try store.checkpoints(for: [minute]) {
                buffer.merge(checkpoint)
            }
            for sample in initialSamples {
                buffer.add(sample)
                ledger.add(sample)
            }
            let before = buffer.records()
            do {
                try buffer.persist(currentMinute: minute) { _ in throw StoreError.query }
                throw FuzzFailure("failed writer did not throw")
            } catch StoreError.query {}
            guard buffer.minutes == [minute] else {
                throw FuzzFailure("failed writer changed pending minutes")
            }
            try ledger.check(before, label: "pending buffer before retry")
            try ledger.check(buffer.records(), label: "pending buffer after retry")
            try buffer.persist(currentMinute: minute, using: store.upsert)
            try ledger.check(readAll(store), label: "first persistence")
            try buffer.persist(currentMinute: minute, using: store.upsert)
            try ledger.check(readAll(store), label: "repeated upsert")
        }

        for (index, sample) in restartedSamples.enumerated() {
            do {
                let collector = Collector(sampleProvider: { sample },
                                          storeFactory: { try HistoryStore(url: databaseURL) },
                                          dateProvider: { sample.timestamp })
                collector.collectOnce()
                collector.flushNow()
            }
            ledger.add(sample)
            let store = try HistoryStore(url: databaseURL)
            try ledger.check(readAll(store), label: "restart \(index)")
        }
    }

    func describe() -> String {
        func describe(_ sample: LiveSample) -> String {
            let usage = Harness.allCases.map { harness in
                let value = sample.usage[harness] ?? ResourceUsage()
                return "\(harness.rawValue):\(Int(value.cpuPercent))/\(value.footprintBytes)/\(Int(value.diskWriteBytesPerSecond))"
            }.joined(separator: ",")
            return "\(Int64(sample.timestamp.timeIntervalSince1970)){\(usage)}"
        }
        return "minute=\(minute) legacy=\(legacy) legacyCount=\(legacyCount) initial=[\(initialSamples.map(describe).joined(separator: ";"))] restart=[\(restartedSamples.map(describe).joined(separator: ";"))]"
    }

    private func createLegacyDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw FuzzFailure("legacy SQLite open failed") }
        defer { sqlite3_close(database) }
        let sql = "CREATE TABLE minutes (minute INTEGER NOT NULL, harness TEXT NOT NULL, " +
            "samples INTEGER NOT NULL, active INTEGER NOT NULL, mean_cpu REAL NOT NULL, " +
            "max_cpu REAL NOT NULL, mean_ram REAL NOT NULL, max_ram REAL NOT NULL, " +
            "max_disk_write REAL NOT NULL, PRIMARY KEY(minute,harness));" +
            "INSERT INTO minutes VALUES(\(minute),'Codex',\(legacyCount),1,1,2,100,200,300000);"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FuzzFailure("legacy SQLite fixture failed")
        }
    }

    private func readAll(_ store: HistoryStore) throws -> [MinuteRecord] {
        try Harness.allCases.flatMap { try store.records(since: .distantPast, harness: $0) }
    }
}
