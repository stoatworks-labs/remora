import Foundation
import RemoraCore

/// Channel names from the desk over RCP (TCP 49280), read-only: `devinfo` and `get`, never
/// `set`. Names are read at connect and every 30 s, and taken from the desk's NOTIFY lines when
/// someone renames a channel.
///
/// The CL/QL's channels are fixed. A DM's depend on the model, so for a DM the names are asked
/// for once `devinfo productname` has answered, and a cue switched on in a NOTIFY line is
/// reported through `onCue`.
public final class YamahaRCPNames {
    /// RCP paths, each with its channels by RCP index.
    public typealias Table = [String: [Int: ConsoleChannel]]

    public var onNames: (([YamahaChannel: String]) -> Void)?
    public var onModel: ((String) -> Void)?
    public var onState: ((Bool) -> Void)?
    /// The link itself, for a desk where RCP is the only link (the DM).
    var onLink: ((StreamState) -> Void)?
    /// A channel whose cue was switched on.
    public var onCue: ((ConsoleChannel) -> Void)?

    private let queue = DispatchQueue(label: "remora.yamaha.rcp")
    private let tcp: TCPStream
    private var buffer = ""
    private var names: [YamahaChannel: String] = [:]
    private var timer: DispatchSourceTimer?
    private var flush: DispatchWorkItem?
    private var byPath: Table
    private let tableForModel: ((String) -> Table)?
    private let cuePaths: Table

    /// The CL/QL's channels.
    public static let clql: Table = {
        var m: Table = [:]
        for ch in YamahaChannel.named {
            if let (path, i) = ch.rcpName { m[path, default: [:]][i] = ch }
        }
        return m
    }()

    /// `tableForModel`: ask the desk's model first and take the channels from it. `cue`: cue
    /// paths to watch, with their channels by index.
    public init(host: String, port: UInt16 = 49280, platform: Platform, table: Table = YamahaRCPNames.clql,
                tableForModel: ((String) -> Table)? = nil, cue: Table = [:]) {
        tcp = platform.tcp(host: host, port: port, queue: queue)
        byPath = tableForModel == nil ? table : [:]
        self.tableForModel = tableForModel
        cuePaths = cue
        tcp.onState = { [weak self] st in
            guard let self else { return }
            self.onState?(st == .connected)
            self.onLink?(st)
            if st == .connected {
                self.buffer = ""
                self.send("devinfo productname")
                if self.tableForModel == nil { self.requestAll() }
            }
        }
        tcp.onData = { [weak self] bytes in self?.received(bytes) }
    }

    public func start() {
        queue.async {
            self.tcp.start()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 30, repeating: 30)
            t.setEventHandler { [weak self] in
                guard let self, self.tcp.state == .connected else { return }
                self.requestAll()
            }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            tcp.stop()
        }
    }

    private func send(_ command: String) {
        precondition(command.hasPrefix("get ") || command.hasPrefix("devinfo "),
                     "Remora sends only get and devinfo over RCP")
        tcp.send(Array((command + "\n").utf8))
    }

    private func requestAll() {
        for (path, channels) in byPath.sorted(by: { $0.key < $1.key }) {
            for i in channels.keys.sorted() { send("get \(path) \(i) 0") }
        }
    }

    /// For tests: one line as the desk would send it.
    func receiveForTesting(_ line: String) { queue.sync { handle(line) } }

    private func received(_ bytes: [UInt8]) {
        buffer += String(decoding: bytes, as: UTF8.self)
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[buffer.index(after: nl)...])
            handle(line)
        }
        if buffer.count > 1 << 16 { buffer = "" }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("OK devinfo productname") {
            let model = Self.quoted(line) ?? String(line.dropFirst("OK devinfo productname ".count))
            onModel?(model)
            if let tableForModel, byPath.isEmpty {
                byPath = tableForModel(model)
                requestAll()
            }
            return
        }
        if line.hasPrefix("ERROR devinfo"), let tableForModel, byPath.isEmpty {
            byPath = tableForModel("")
            requestAll()
            return
        }
        // OK get MIXER:Current/InCh/Label/Name 16 0 "head1"
        // NOTIFY set MIXER:Current/InCh/Label/Name 16 0 "head1"
        // NOTIFY set MIXER:Current/Cue/InCh/On 4 0 1 "ON"
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        if parts.count >= 5, parts[0] == "NOTIFY", parts[1] == "set",
           let byIndex = cuePaths[String(parts[2])], let i = Int(parts[3]), let ch = byIndex[i] {
            let rest = parts[4].split(separator: " ")
            if rest.count >= 2, Int(rest[1]) == 1 { onCue?(ch) }
            return
        }
        guard parts.count >= 5,
              (parts[0] == "OK" && parts[1] == "get") || (parts[0] == "NOTIFY" && parts[1] == "set"),
              let byIndex = byPath[String(parts[2])], let i = Int(parts[3]),
              let ch = byIndex[i], let name = Self.quoted(line) else { return }
        guard names[ch] != name else { return }
        names[ch] = name
        // Many answers arrive at once at connect; hand them over together.
        flush?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onNames?(self.names)
        }
        flush = w
        queue.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    /// The last double-quoted string on the line.
    static func quoted(_ line: String) -> String? {
        guard let end = line.lastIndex(of: "\"") else { return nil }
        let before = line[..<end]
        guard let start = before.lastIndex(of: "\"") else { return nil }
        return String(line[line.index(after: start)..<end])
    }
}
