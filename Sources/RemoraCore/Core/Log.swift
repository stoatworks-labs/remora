import Foundation

/// One line per event, to stdout and ~/Library/Logs/Remora.log, and the last few kept for
/// the settings window.
public enum Log {
    private static let lock = NSLock()
    private static var recentLines: [String] = []
    private static let file: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Remora.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Set false in tests.
    public static var enabled = true

    public static func line(_ s: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let l = "\(stamp.string(from: Date())) \(s)"
        print(l)
        fflush(stdout)
        file?.write((l + "\n").data(using: .utf8)!)
        recentLines.append(l)
        if recentLines.count > 200 { recentLines.removeFirst(recentLines.count - 200) }
    }

    public static var recent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recentLines
    }
}
