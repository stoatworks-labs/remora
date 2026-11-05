import Foundation
import SQLite3

public struct Rack: Hashable, Codable {
    /// 0-based: the order SuperRack's Next/Previous Rack steps through.
    public var index: Int
    public var name: String
    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
    public var label: String { "\(index + 1) \(name)" }
}

/// The racks in SuperRack Performer's current session, read from its session database.
///
/// The database is never opened in place: the file and its WAL are copied to a temporary
/// folder and the copy is read, so SuperRack's own files are never locked or written.
public enum SuperRackSession {
    public static let defaultPath = "/Users/Shared/Waves/SuperRack Performer/Sessions/CurrentSPRKP.dat"

    public enum ReadError: Error, CustomStringConvertible {
        case missing(String)
        case sqlite(String)
        public var description: String {
            switch self {
            case .missing(let p): return "no SuperRack session at \(p)"
            case .sqlite(let s): return "could not read the session: \(s)"
            }
        }
    }

    /// Changes whenever SuperRack writes the session (file or WAL).
    public static func stamp(_ path: String) -> String {
        [path, path + "-wal"].map { p -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            let d = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let s = (a?[.size] as? NSNumber)?.intValue ?? -1
            return "\(d):\(s)"
        }.joined(separator: "|")
    }

    public static func racks(at path: String) throws -> [Rack] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw ReadError.missing(path) }
        let dir = fm.temporaryDirectory.appendingPathComponent("remora-session-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("session.dat").path
        try fm.copyItem(atPath: path, toPath: copy)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.copyItem(atPath: path + suffix, toPath: copy + suffix)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw ReadError.sqlite(String(cString: sqlite3_errstr(sqlite3_errcode(db))))
        }
        defer { sqlite3_close(db) }

        // The session's rack count: the database holds 64 rack slots whatever the session uses.
        let count = try query(db, "select num_tracks from config_info where track_type = 0").first
            .flatMap { Int($0[0]) } ?? 64
        let rows = try query(db, """
            select o.obj_index, sc.name from snapshot_chainer sc
            join object o on o.id = sc.chainer_id
            where sc.snapshot_id = -1 and o.obj_type = 0
            order by o.obj_index
            """)
        return rows.compactMap { r -> Rack? in
            guard let i = Int(r[0]), i < count else { return nil }
            return Rack(index: i, name: r[1])
        }
    }

    private static func query(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw ReadError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        var out: [[String]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(st)).map { c in
                sqlite3_column_text(st, c).map { String(cString: $0) } ?? ""
            })
        }
        return out
    }
}
