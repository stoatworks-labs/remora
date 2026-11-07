import Foundation

/// A Yamaha DM7 or DM3, over RCP (TCP 49280) alone, read-only.
///
/// Yamaha documents no way to read the selected channel on the DM series: its OSC is set-only,
/// its MIDI is Control and Program Change, and its editor protocol is not published. What RCP
/// does carry is cue, and the desk can tie SEL to cue (Preferences, "[CUE] > [SEL] Link"), so
/// the channel last put on cue is the one to follow, as the Qu's PAFL is. Built from Yamaha's
/// manuals and the RCP parameter lists; not yet run against a desk.
public final class YamahaDMConsole: ConsoleLink {
    public var onState: ((ConsoleState) -> Void)?
    public var onNamesLink: ((Bool) -> Void)?
    public var onModel: ((String) -> Void)?
    public var onSelected: ((ConsoleChannel) -> Void)?
    public var onNames: (([ConsoleChannel: String]) -> Void)?
    public var onControl: ((ControlSource, Int32) -> Void)?

    let rcp: YamahaRCPNames

    public init(host: String, port: UInt16 = 49280, platform: Platform) {
        rcp = YamahaRCPNames(host: host, port: port, platform: platform, tableForModel: YamahaDM.channels(model:),
                             cue: YamahaDM.cue)
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

/// The DM series' channels as RCP numbers them (from 0), from Yamaha's RCP parameter lists.
public enum YamahaDM {
    private static func run(_ n: Int, _ make: (Int) -> ConsoleChannel) -> [Int: ConsoleChannel] {
        Dictionary(uniqueKeysWithValues: (0..<n).map { ($0, make($0 + 1)) })
    }

    /// Names to read. A DM3 has 16 inputs, 2 stereo inputs, 4 FX returns, 6 mixes and 2
    /// matrices; a DM7 120 inputs (72 on the Compact, which answers the rest with errors),
    /// 48 mixes and 12 matrices. Anything that is not a DM3 is read as a DM7.
    public static func channels(model: String) -> YamahaRCPNames.Table {
        if model.uppercased().hasPrefix("DM3") {
            return [
                "MIXER:Current/InCh/Label/Name": run(16, ConsoleChannel.input),
                "MIXER:Current/StInCh/Label/Name": run(2, ConsoleChannel.stereo),
                "MIXER:Current/FxRtnCh/Label/Name": run(4, ConsoleChannel.fxReturn),
                "MIXER:Current/Mix/Label/Name": run(6, ConsoleChannel.mix),
                "MIXER:Current/Mtrx/Label/Name": run(2, ConsoleChannel.matrix),
            ]
        }
        return [
            "MIXER:Current/InCh/Label/Name": run(120, ConsoleChannel.input),
            "MIXER:Current/Mix/Label/Name": run(48, ConsoleChannel.mix),
            "MIXER:Current/Mtrx/Label/Name": run(12, ConsoleChannel.matrix),
        ]
    }

    /// Cue switches to follow. The DM7's second index is Cue A or B; either counts.
    public static let cue: YamahaRCPNames.Table = [
        "MIXER:Current/Cue/InCh/On": run(120, ConsoleChannel.input),
        "MIXER:Current/Cue/StInCh/On": run(2, ConsoleChannel.stereo),
        "MIXER:Current/Cue/FxRtnCh/On": run(4, ConsoleChannel.fxReturn),
        "MIXER:Current/Cue/Mix/On": run(48, ConsoleChannel.mix),
        "MIXER:Current/Cue/Mtrx/On": run(12, ConsoleChannel.matrix),
    ]
}
