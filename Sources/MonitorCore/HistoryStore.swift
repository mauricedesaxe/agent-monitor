import Foundation
import SQLite3

public final class HistoryStore {
    private var database: OpaquePointer?

    public static var defaultURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Monitor", isDirectory: true)
        return directory.appendingPathComponent("history.sqlite3")
    }

    public init(url: URL = HistoryStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            throw StoreError.open
        }
        sqlite3_busy_timeout(database, 2_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS minutes (" +
                    "minute INTEGER NOT NULL, harness TEXT NOT NULL, samples INTEGER NOT NULL, " +
                    "active INTEGER NOT NULL, mean_cpu REAL NOT NULL, max_cpu REAL NOT NULL, " +
                    "mean_ram REAL NOT NULL, max_ram REAL NOT NULL, max_disk_write REAL NOT NULL, " +
                    "cpu_sum REAL NOT NULL DEFAULT 0, ram_sum REAL NOT NULL DEFAULT 0, " +
                    "disk_write_sum REAL NOT NULL DEFAULT 0, " +
                    "legacy_activity_floor INTEGER NOT NULL DEFAULT 0, " +
                    "PRIMARY KEY(minute, harness))")
        try migrateCheckpoints()
    }

    deinit { sqlite3_close(database) }

    public func upsert(_ records: [MinuteRecord]) throws {
        guard !records.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let sql = "INSERT INTO minutes (minute,harness,samples,active,mean_cpu,max_cpu," +
                "mean_ram,max_ram,max_disk_write,cpu_sum,ram_sum,disk_write_sum,legacy_activity_floor) " +
                "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) " +
                "ON CONFLICT(minute,harness) DO UPDATE SET samples=excluded.samples, " +
                "active=excluded.active, mean_cpu=excluded.mean_cpu, max_cpu=excluded.max_cpu, " +
                "mean_ram=excluded.mean_ram, max_ram=excluded.max_ram, max_disk_write=excluded.max_disk_write, " +
                "cpu_sum=excluded.cpu_sum, ram_sum=excluded.ram_sum, disk_write_sum=excluded.disk_write_sum, " +
                "legacy_activity_floor=excluded.legacy_activity_floor"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw StoreError.query
            }
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, record.minute)
                _ = record.harness.rawValue.withCString { text in
                    sqlite3_bind_text(statement, 2, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                sqlite3_bind_int(statement, 3, Int32(record.sampleCount))
                sqlite3_bind_int(statement, 4, record.active ? 1 : 0)
                sqlite3_bind_double(statement, 5, record.meanCPU)
                sqlite3_bind_double(statement, 6, record.maxCPU)
                sqlite3_bind_double(statement, 7, record.meanRAM)
                sqlite3_bind_double(statement, 8, record.maxRAM)
                sqlite3_bind_double(statement, 9, record.maxDiskWriteRate)
                sqlite3_bind_double(statement, 10, record.cpuSum)
                sqlite3_bind_double(statement, 11, record.ramSum)
                sqlite3_bind_double(statement, 12, record.diskWriteSum)
                sqlite3_bind_int(statement, 13, record.legacyActivityFloor ? 1 : 0)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.query }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func records(since date: Date, harness: Harness) throws -> [MinuteRecord] {
        let sql = "SELECT minute,harness,samples,active,mean_cpu,max_cpu,mean_ram,max_ram,max_disk_write," +
                  "cpu_sum,ram_sum,disk_write_sum,legacy_activity_floor " +
                  "FROM minutes WHERE minute >= ? AND harness = ? ORDER BY minute"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970 / 60))
        _ = harness.rawValue.withCString { text in
            sqlite3_bind_text(statement, 2, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        let result = try readRecords(statement, expectedHarness: harness)
        return result
    }

    public func checkpoints(for minutes: Set<Int64>) throws -> [MinuteRecord] {
        guard !minutes.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: minutes.count).joined(separator: ",")
        let sql = "SELECT minute,harness,samples,active,mean_cpu,max_cpu,mean_ram,max_ram,max_disk_write," +
            "cpu_sum,ram_sum,disk_write_sum,legacy_activity_floor FROM minutes " +
            "WHERE minute IN (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(statement) }
        for (index, minute) in minutes.sorted().enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), minute)
        }
        return try readRecords(statement, expectedHarness: nil)
    }

    private func readRecords(_ statement: OpaquePointer?, expectedHarness: Harness?) throws -> [MinuteRecord] {
        var result: [MinuteRecord] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let harnessText = sqlite3_column_text(statement, 1),
                  let storedHarness = Harness(rawValue: String(cString: harnessText)),
                  expectedHarness == nil || storedHarness == expectedHarness else {
                throw StoreError.query
            }
            result.append(MinuteRecord(minute: sqlite3_column_int64(statement, 0), harness: storedHarness,
                                       sampleCount: Int(sqlite3_column_int(statement, 2)),
                                       active: sqlite3_column_int(statement, 3) != 0,
                                       meanCPU: sqlite3_column_double(statement, 4),
                                       maxCPU: sqlite3_column_double(statement, 5),
                                       meanRAM: sqlite3_column_double(statement, 6),
                                       maxRAM: sqlite3_column_double(statement, 7),
                                       maxDiskWriteRate: sqlite3_column_double(statement, 8),
                                       cpuSum: sqlite3_column_double(statement, 9),
                                       ramSum: sqlite3_column_double(statement, 10),
                                       diskWriteSum: sqlite3_column_double(statement, 11),
                                       legacyActivityFloor: sqlite3_column_int(statement, 12) != 0))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw StoreError.query }
        return result
    }

    private func migrateCheckpoints() throws {
        let additions = [
            ("cpu_sum", "REAL NOT NULL DEFAULT 0"),
            ("ram_sum", "REAL NOT NULL DEFAULT 0"),
            ("disk_write_sum", "REAL NOT NULL DEFAULT 0"),
            ("legacy_activity_floor", "INTEGER NOT NULL DEFAULT 0"),
        ]
        let existing = try columnNames(table: "minutes")
        let needsBackfill = additions.contains { !existing.contains($0.0) }
        guard needsBackfill else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for (name, declaration) in additions where !existing.contains(name) {
                try execute("ALTER TABLE minutes ADD COLUMN \(name) \(declaration)")
            }
            try execute("UPDATE minutes SET cpu_sum=mean_cpu*samples, ram_sum=mean_ram*samples, " +
                        "legacy_activity_floor=active")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func columnNames(table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let columnText = sqlite3_column_text(statement, 1) else { throw StoreError.query }
            names.insert(String(cString: columnText))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw StoreError.query }
        return names
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.query }
    }
}

public enum StoreError: Error {
    case open
    case query
}
