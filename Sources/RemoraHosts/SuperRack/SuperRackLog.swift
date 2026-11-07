import Foundation
import RemoraCore

/// What SuperRack Performer's application log says as it happens (docs/PROTOCOL.md).
public enum SuperRackLogEvent: Equatable {
    /// `Top Bar: select RACK`: the page now shown. OVERVIEW1, RACK and SETUP have been seen.
    case page(String)
    /// `Top Bar: select rack 2`: a rack picked in the top bar, 1-based. Rack steps by MIDI write
    /// nothing.
    case rackPicked(Int)
    /// `head 1 plugin De-Feedback slot 2 select`: a plug-in selected, by mouse or by MIDI.
    case pluginSelected(rack: String, plugin: String, slot: Int)
}

public struct SuperRackLogLine: Equatable {
    /// SuperRack's own timestamp, local time, to the microsecond.
    public var time: Date
    public var event: SuperRackLogEvent
}

public enum SuperRackLogParser {
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MMM-dd HH:mm:ss"
        return f
    }()

    /// One line, as SuperRack writes it:
    /// `2026-Nov-05 21:33:37.971071 @[wl....] [4bd8:-  ] [INF] [general  ] @[MixerChainerCore.cpp:4554] [] head 1 plugin De-Feedback slot 2 select @[WavesLib]`
    public static func parse(_ line: String) -> SuperRackLogLine? {
        guard let open = line.range(of: "] [] ") else { return nil }
        var message = line[open.upperBound...]
        if let tail = message.range(of: " @[", options: .backwards) { message = message[..<tail.lowerBound] }
        guard let event = event(String(message)), let time = time(line) else { return nil }
        return SuperRackLogLine(time: time, event: event)
    }

    static func event(_ m: String) -> SuperRackLogEvent? {
        if m.hasPrefix("Top Bar: select ") {
            let what = m.dropFirst("Top Bar: select ".count)
            if what.hasPrefix("rack "), let n = Int(what.dropFirst(5)) { return .rackPicked(n) }
            let page = String(what)
            guard !page.isEmpty, page.allSatisfy({ $0.isUppercase || $0.isNumber }) else { return nil }
            return .page(page)
        }
        // "<rack> plugin <name> slot <n> select". The shortest rack wins if a name holds " plugin ".
        guard m.hasSuffix(" select"), let p = m.range(of: " plugin "),
              let s = m.range(of: " slot ", options: .backwards), s.lowerBound > p.upperBound else { return nil }
        let rack = String(m[..<p.lowerBound])
        let plugin = String(m[p.upperBound..<s.lowerBound])
        guard !rack.isEmpty, !plugin.isEmpty,
              let slot = Int(m[s.upperBound...].dropLast(" select".count)) else { return nil }
        return .pluginSelected(rack: rack, plugin: plugin, slot: slot)
    }

    static func time(_ line: String) -> Date? {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let clock = parts[1].split(separator: ".", maxSplits: 1)
        guard let day = dayFormat.date(from: "\(parts[0]) \(clock[0])") else { return nil }
        let fraction = clock.count > 1 ? Double("0." + clock[1]) ?? 0 : 0
        return day.addingTimeInterval(fraction)
    }
}

/// Follows SuperRack's application log as it grows, from the end, and hands over each event.
///
/// Read-only: the file is opened for reading and nothing else. Call `check()` now and then: it
/// picks the file up again after SuperRack replaces or truncates it.
public final class SuperRackLogTail {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Waves Audio/SuperRack PerformerApplication.log").path
    }

    public let path: String
    /// Called on `queue` for each event line.
    public var onLine: ((SuperRackLogLine) -> Void)?

    private let queue: DispatchQueue
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var partial = Data()

    public init(path: String = SuperRackLogTail.defaultPath, queue: DispatchQueue = .main) {
        self.path = path
        self.queue = queue
    }

    public var isOpen: Bool { handle != nil }

    /// Opens the log at its end: what was written before is history.
    public func start() {
        queue.async { self.open(fromEnd: true) }
    }

    public func stop() {
        queue.async { self.close() }
    }

    /// Reopens the file if it was replaced, shrank or appeared, and reads anything new.
    public func check() {
        queue.async {
            let a = try? FileManager.default.attributesOfItem(atPath: self.path)
            let ino = (a?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let size = (a?[.size] as? NSNumber)?.uint64Value ?? 0
            if self.handle == nil || ino != self.inode {
                // A file that appears or is replaced while we watch is read from its start.
                self.close()
                if a != nil { self.open(fromEnd: false) }
            } else if size < self.offset {
                self.offset = 0
                self.partial.removeAll()
            }
            self.read()
        }
    }

    private func open(fromEnd: Bool) {
        close()
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        inode = (a?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        offset = fromEnd ? ((try? h.seekToEnd()) ?? 0) : 0
        handle = h
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: h.fileDescriptor,
                                                          eventMask: [.extend, .write, .delete, .rename],
                                                          queue: queue)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            if s.data.contains(.delete) || s.data.contains(.rename) {
                self.read()
                self.close()
            } else {
                self.read()
            }
        }
        s.resume()
        source = s
    }

    private func close() {
        source?.cancel()
        source = nil
        try? handle?.close()
        handle = nil
        partial.removeAll()
    }

    private func read() {
        guard let h = handle else { return }
        do {
            try h.seek(toOffset: offset)
            guard let data = try h.readToEnd(), !data.isEmpty else { return }
            offset += UInt64(data.count)
            partial.append(data)
        } catch {
            return
        }
        while let nl = partial.firstIndex(of: 0x0A) {
            let lineData = partial[partial.startIndex..<nl]
            partial.removeSubrange(partial.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8), let l = SuperRackLogParser.parse(line) {
                onLine?(l)
            }
        }
        // A line without its end yet waits; a runaway one is dropped.
        if partial.count > 64 * 1024 { partial.removeAll() }
    }
}
