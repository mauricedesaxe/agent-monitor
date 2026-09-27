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
                    "PRIMARY KEY(minute, harness))")
    }

    deinit { sqlite3_close(database) }

    public func upsert(_ records: [MinuteRecord]) throws {
        guard !records.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let sql = "INSERT INTO minutes VALUES(?,?,?,?,?,?,?,?,?) " +
                "ON CONFLICT(minute,harness) DO UPDATE SET samples=excluded.samples, " +
                "active=excluded.active, mean_cpu=excluded.mean_cpu, max_cpu=excluded.max_cpu, " +
                "mean_ram=excluded.mean_ram, max_ram=excluded.max_ram, max_disk_write=excluded.max_disk_write"
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
                guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.query }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func records(since date: Date, harness: Harness) throws -> [MinuteRecord] {
        let sql = "SELECT minute,harness,samples,active,mean_cpu,max_cpu,mean_ram,max_ram,max_disk_write " +
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
        var result: [MinuteRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(MinuteRecord(minute: sqlite3_column_int64(statement, 0), harness: harness,
                                       sampleCount: Int(sqlite3_column_int(statement, 2)),
                                       active: sqlite3_column_int(statement, 3) != 0,
                                       meanCPU: sqlite3_column_double(statement, 4),
                                       maxCPU: sqlite3_column_double(statement, 5),
                                       meanRAM: sqlite3_column_double(statement, 6),
                                       maxRAM: sqlite3_column_double(statement, 7),
                                       maxDiskWriteRate: sqlite3_column_double(statement, 8)))
        }
        return result
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.query }
    }
}

public enum StoreError: Error {
    case open
    case query
}
