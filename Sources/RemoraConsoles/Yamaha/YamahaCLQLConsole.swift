import Foundation
import RemoraCore

/// A Yamaha CL or QL: the editor port (TCP 50000) for the selected channel and anything a
/// control could be learned from, RCP (TCP 49280) for channel names and, while routing is on,
/// input patches. Both read-only.
///
/// One implementation for both, listed twice: the QL's entry has been run on a QL1 and the CL's
/// has not. Each says so when the desk turns out to be the other one.
public final class YamahaCLQLConsole: ConsoleLink {
    /// Which entry made the link.
    public enum Entry: Equatable { case ql, cl }

    public var onState: ((ConsoleState) -> Void)?
    public var onNamesLink: ((Bool) -> Void)?
    public var onModel: ((String) -> Void)?
    public var onSelected: ((ConsoleChannel) -> Void)?
    public var onNames: (([ConsoleChannel: String]) -> Void)?
    public var onControl: ((ControlSource, Int32) -> Void)?
    public var onRoutes: (([ConsoleChannel: [AudioPort]]) -> Void)?

    private let editor: YamahaEditorLink
    private let rcp: YamahaRCPNames

    /// `readPatches`: read each channel's input patch for routing.
    public init(host: String, platform: Platform, readPatches: Bool = false, entry: Entry = .ql) {
        editor = YamahaEditorLink(host: host, platform: platform)
        rcp = YamahaRCPNames(host: host, platform: platform, patches: readPatches ? YamahaRCPNames.clqlPatches : [:])
        editor.onState = { [weak self] st in self?.onState?(st) }
        editor.onChange = { [weak self] c in self?.changed(c) }
        rcp.onState = { [weak self] up in self?.onNamesLink?(up) }
        rcp.onModel = { [weak self] m in self?.onModel?(Self.model(m, entry: entry)) }
        rcp.onNames = { [weak self] n in self?.onNames?(n) }
        rcp.onPatches = { [weak self] r in self?.onRoutes?(r) }
    }

    public func start() {
        editor.start()
        rcp.start()
    }

    public func stop() {
        editor.stop()
        rcp.stop()
    }

    /// The model the desk gave, with a note when it is the other entry's desk: "CL5 (a CL: …)".
    public static func model(_ m: String, entry: Entry) -> String {
        let u = m.uppercased()
        switch entry {
        case .ql where u.hasPrefix("CL"):
            return "\(m) (a CL: Remora has been run on a QL, not a CL; the Yamaha CL entry says so)"
        case .cl where u.hasPrefix("QL"):
            return "\(m) (a QL: the Yamaha QL entry is the one run on a QL)"
        default:
            return m
        }
    }

    private func changed(_ c: YamahaSysEx.Change) {
        switch Self.interpret(c) {
        case .selected(let ch): onSelected?(ch)
        case .control(let source, let value): onControl?(source, value)
        case .none: break
        }
    }

    public enum Event: Equatable {
        case selected(ConsoleChannel)
        case control(ControlSource, Int32)
    }

    /// What an editor-port change means: the selection, something to learn a control from, or
    /// noise that moves with every SEL press and bank change.
    public static func interpret(_ c: YamahaSysEx.Change) -> Event? {
        if c.address == YamahaSysEx.selectedChannel { return .selected(ConsoleChannel(selection: Int(c.value))) }
        if YamahaSysEx.selectionNoise.contains(c.address.element) { return nil }
        return .control(.yamaha(c.address), c.value)
    }
}
