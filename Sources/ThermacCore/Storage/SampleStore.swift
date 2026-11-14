import Foundation

/// A timestamped event: start/stop of recording, sleep, wake, cold-start anchor, gap.
public struct RecordedEvent: Equatable, Sendable {
    public let time: Double
    public let type: String
    public let detail: String?

    public init(time: Double, type: String, detail: String? = nil) {
        self.time = time
        self.type = type
        self.detail = detail
    }
}

/// Long-format time-series store on SQLite (WAL).
///
/// Schema:
/// - `channels(id, name, kind, category)` — one row per recorded quantity
/// - `samples(channel, t, value)` — `WITHOUT ROWID`, keyed by (channel, t)
/// - `events(t, type, detail)` — sleep/wake/cold_start/start/stop/gap
/// - `meta(key, value)` — schema version, last seen wake time, …
public final class SampleStore {
    public static let schemaVersion = 1

    let db: SQLiteDB
    public let path: String
    private lazy var insertSample = try! db.prepare(
        "INSERT OR REPLACE INTO samples(channel, t, value) VALUES (?, ?, ?)")

    /// Default location: `~/Library/Application Support/thermac/thermac.sqlite`.
    public static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thermac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("thermac.sqlite").path
    }

    /// Opens (creating if needed) a store. Use `":memory:"` for tests.
    public init(path: String) throws {
        self.path = path
        db = try SQLiteDB(path: path)
        if path != ":memory:" { try db.exec("PRAGMA journal_mode=WAL") }
        try db.exec("""
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS channels(
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                category TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS samples(
                channel INTEGER NOT NULL REFERENCES channels(id),
                t REAL NOT NULL,
                value REAL NOT NULL,
                PRIMARY KEY(channel, t)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS events(t REAL NOT NULL, type TEXT NOT NULL, detail TEXT);
            CREATE INDEX IF NOT EXISTS events_t ON events(t);
            """)
        if meta("schema_version") == nil { try setMeta("schema_version", String(Self.schemaVersion)) }
    }

    // MARK: meta

    public func meta(_ key: String) -> String? {
        let s = try? db.prepare("SELECT value FROM meta WHERE key = ?").bind(key)
        return (try? s?.step()) == true ? s?.text(0) : nil
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)").bind(key, value).run()
    }

    // MARK: channels & samples

    /// Registers channels (idempotent) and returns their ids, aligned with the input.
    public func register(_ channels: [Channel]) throws -> [Int64] {
        let upsert = try db.prepare("""
            INSERT INTO channels(name, kind, category) VALUES (?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET kind = excluded.kind, category = excluded.category
            """)
        let lookup = try db.prepare("SELECT id FROM channels WHERE name = ?")
        return try db.transaction {
            try channels.map { ch in
                try upsert.bind(ch.name, ch.kind.rawValue, ch.category.rawValue).run()
                guard try lookup.bind(ch.name).step(), let id = lookup.int(0) else {
                    throw SQLiteError(code: -1, message: "channel \(ch.name) not found after insert")
                }
                return id
            }
        }
    }

    /// Writes one tick: all values share the timestamp `time`. Nil values are skipped.
    public func insert(time: Double, ids: [Int64], values: [Double?]) throws {
        try db.transaction {
            for (id, value) in zip(ids, values) {
                guard let value, value.isFinite else { continue }
                try insertSample.bind(id, time, value).run()
            }
        }
    }

    public func lastSampleTime() -> Double? {
        let s = try? db.prepare("SELECT MAX(t) FROM samples")
        return (try? s?.step()) == true ? s?.double(0) : nil
    }

    /// Samples of one channel in [from, to], ordered by time.
    public func series(_ channel: String, from: Double = 0, to: Double = .infinity) throws -> [(t: Double, value: Double)] {
        let s = try db.prepare("""
            SELECT s.t, s.value FROM samples s JOIN channels c ON c.id = s.channel
            WHERE c.name = ? AND s.t >= ? AND s.t <= ? ORDER BY s.t
            """).bind(channel, from, to.isFinite ? to : Double.greatestFiniteMagnitude)
        var out: [(Double, Double)] = []
        while try s.step() { out.append((s.double(0)!, s.double(1)!)) }
        return out
    }

    public func channelNames() throws -> [(name: String, kind: String, category: String)] {
        let s = try db.prepare("SELECT name, kind, category FROM channels ORDER BY id")
        var out: [(String, String, String)] = []
        while try s.step() { out.append((s.text(0)!, s.text(1)!, s.text(2)!)) }
        return out
    }

    /// Every sample since `from` as rows of (t, channel name, value), ordered by time.
    public func rows(from: Double) throws -> [(t: Double, channel: String, value: Double)] {
        let s = try db.prepare("""
            SELECT s.t, c.name, s.value FROM samples s JOIN channels c ON c.id = s.channel
            WHERE s.t >= ? ORDER BY s.t, c.id
            """).bind(from)
        var out: [(Double, String, Double)] = []
        while try s.step() { out.append((s.double(0)!, s.text(1)!, s.double(2)!)) }
        return out
    }

    // MARK: events

    public func add(_ event: RecordedEvent) throws {
        try db.prepare("INSERT INTO events(t, type, detail) VALUES (?, ?, ?)")
            .bind(event.time, event.type, event.detail).run()
    }

    public func events(from: Double = 0, type: String? = nil) throws -> [RecordedEvent] {
        let s = try db.prepare("""
            SELECT t, type, detail FROM events WHERE t >= ? AND (?2 IS NULL OR type = ?2) ORDER BY t
            """).bind(from, type)
        var out: [RecordedEvent] = []
        while try s.step() { out.append(RecordedEvent(time: s.double(0)!, type: s.text(1)!, detail: s.text(2))) }
        return out
    }

    // MARK: maintenance

    /// Replaces samples older than `cutoff` with per-`bucket` averages (bucket centres).
    /// Idempotent: already-compacted data maps onto itself. Returns rows removed.
    @discardableResult
    public func compact(olderThan cutoff: Double, bucket: Double = 60) throws -> Int {
        let aligned = (cutoff / bucket).rounded(.down) * bucket
        return try db.transaction {
            let before = try count()
            try db.exec("DROP TABLE IF EXISTS temp.agg")
            try db.prepare("""
                CREATE TEMP TABLE agg AS
                SELECT channel, (CAST(t / ?1 AS INTEGER) * ?1) + ?1 / 2.0 AS t, AVG(value) AS value
                FROM samples WHERE t < ?2 GROUP BY channel, CAST(t / ?1 AS INTEGER)
                """).bind(bucket, aligned).run()
            try db.prepare("DELETE FROM samples WHERE t < ?").bind(aligned).run()
            try db.exec("INSERT OR REPLACE INTO samples(channel, t, value) SELECT channel, t, value FROM temp.agg")
            try db.exec("DROP TABLE temp.agg")
            return before - (try count())
        }
    }

    public func count() throws -> Int {
        let s = try db.prepare("SELECT COUNT(*) FROM samples")
        _ = try s.step()
        return Int(s.int(0) ?? 0)
    }

    /// Distinct tick timestamps, ordered — used for gap analysis.
    public func tickTimes(from: Double = 0) throws -> [Double] {
        let s = try db.prepare("""
            SELECT t FROM samples WHERE channel = (SELECT MIN(channel) FROM samples) AND t >= ? ORDER BY t
            """).bind(from)
        var out: [Double] = []
        while try s.step() { out.append(s.double(0)!) }
        return out
    }

    public var fileSize: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let wal = try? FileManager.default.attributesOfItem(atPath: path + "-wal")
        return ((attrs?[.size] as? Int64) ?? 0) + ((wal?[.size] as? Int64) ?? 0)
    }
}

/// Gap analysis for the Phase 2 exit criterion: "no gaps across sleep/wake".
public enum GapAnalysis {
    public struct Gap: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public var duration: Double { end - start }
    }

    /// Intervals between consecutive ticks longer than `threshold` that are NOT explained
    /// by a sleep (a sleep event inside the gap) or a deliberate stop (a stop event inside).
    public static func unexplainedGaps(ticks: [Double], events: [RecordedEvent],
                                       threshold: Double) -> [Gap] {
        let explainers = events.filter { ["sleep", "stop", "wake"].contains($0.type) }.map(\.time)
        return zip(ticks, ticks.dropFirst()).compactMap { a, b in
            guard b - a > threshold else { return nil }
            let explained = explainers.contains { $0 >= a && $0 <= b }
            return explained ? nil : Gap(start: a, end: b)
        }
    }
}
