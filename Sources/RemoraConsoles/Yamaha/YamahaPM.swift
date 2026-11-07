import Foundation
import RemoraCore

/// A Yamaha RIVAGE PM over RCP (TCP 49280), read-only: names, and cue as the selection.
///
/// The PM has no selected-channel parameter, and its screens can show up to three selected
/// channels, so there is no one channel to follow. What RCP carries is cue, A and B, so the
/// channel last put on either cue is followed, as on a DM. RCP on a PM is evidenced only by
/// Companion's yamaha-rcp module (v4.0.1), which drives a PM over TCP 49280 with its own PM
/// parameter list ("Rivage Parameters-4"); Yamaha documents OSC on UDP 49900 instead. What a PM
/// answers to `devinfo productname` has not been seen. Not yet run against a desk.
public final class YamahaPMConsole: ConsoleLink {
    public var onState: ((ConsoleState) -> Void)?
    public var onNamesLink: ((Bool) -> Void)?
    public var onModel: ((String) -> Void)?
    public var onSelected: ((ConsoleChannel) -> Void)?
    public var onNames: (([ConsoleChannel: String]) -> Void)?
    public var onControl: ((ControlSource, Int32) -> Void)?

    let rcp: YamahaRCPNames

    public init(host: String, port: UInt16 = 49280, platform: Platform) {
        rcp = YamahaRCPNames(host: host, port: port, platform: platform, table: YamahaPM.names, cue: YamahaPM.cue)
        rcp.onLink = { [weak self] st in
            switch st {
            case .stopped: self?.onState?(.stopped)
            case .connecting: self?.onState?(.connecting)
            case .connected: self?.onState?(.live)
            case .failed(let why): self?.onState?(.failed(why))
            }
        }
        rcp.onState = { [weak self] up in self?.onNamesLink?(up) }
        rcp.onModel = { [weak self] m in self?.onModel?(m) }
        rcp.onNames = { [weak self] n in self?.onNames?(n) }
        rcp.onCue = { [weak self] ch in self?.onSelected?(ch) }
    }

    public func start() { rcp.start() }
    public func stop() { rcp.stop() }

    /// For tests: one line as the desk would send it.
    public func receiveForTesting(_ line: String) { rcp.receiveForTesting(line) }
}

/// The PM's channels as RCP numbers them (from 0), from Companion's PM parameter list. The list
/// is one size for the whole family, so a smaller engine answers the channels it lacks with
/// errors, as a QL1 does.
public enum YamahaPM {
    private static func run(_ n: Int, _ make: (Int) -> ConsoleChannel) -> [Int: ConsoleChannel] {
        Dictionary(uniqueKeysWithValues: (0..<n).map { ($0, make($0 + 1)) })
    }

    /// 288 inputs, 72 mixes, 36 matrices.
    public static let names: YamahaRCPNames.Table = [
        "MIXER:Current/InCh/Label/Name": run(288, ConsoleChannel.input),
        "MIXER:Current/Mix/Label/Name": run(72, ConsoleChannel.mix),
        "MIXER:Current/Mtrx/Label/Name": run(36, ConsoleChannel.matrix),
    ]

    /// Cue switches to follow. The second index is Cue A or B; either counts.
    public static let cue: YamahaRCPNames.Table = [
        "MIXER:Current/Cue/InCh/On": run(288, ConsoleChannel.input),
        "MIXER:Current/Cue/Mix/On": run(72, ConsoleChannel.mix),
        "MIXER:Current/Cue/Mtrx/On": run(36, ConsoleChannel.matrix),
    ]
}
