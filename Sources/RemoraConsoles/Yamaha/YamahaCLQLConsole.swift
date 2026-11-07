import Foundation
import RemoraCore

/// A Yamaha CL or QL: the editor port (TCP 50000) for the selected channel and anything a
/// control could be learned from, RCP (TCP 49280) for channel names and, while routing is on,
/// input patches. Both read-only.
public final class YamahaCLQLConsole: ConsoleLink {
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
    public init(host: String, platform: Platform, readPatches: Bool = false) {
        editor = YamahaEditorLink(host: host, platform: platform)
        rcp = YamahaRCPNames(host: host, platform: platform, patches: readPatches ? YamahaRCPNames.clqlPatches : [:])
        editor.onState = { [weak self] st in self?.onState?(st) }
        editor.onChange = { [weak self] c in self?.changed(c) }
        rcp.onState = { [weak self] up in self?.onNamesLink?(up) }
        rcp.onModel = { [weak self] m in self?.onModel?(m) }
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
