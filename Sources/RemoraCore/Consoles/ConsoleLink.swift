import Foundation

/// A read-only link to a desk. Callbacks arrive on the link's own queue.
///
/// Every link keeps the one rule: it sends the desk only requests to read. Nothing a link sends
/// may change a parameter, recall a scene or press a key.
public protocol ConsoleLink: AnyObject {
    var onState: ((ConsoleState) -> Void)? { get set }
    /// Whether channel names are coming in (a separate connection on some desks).
    var onNamesLink: ((Bool) -> Void)? { get set }
    var onModel: ((String) -> Void)? { get set }
    /// The selected channel, each time it changes (and once when the link opens, if the desk
    /// can say).
    var onSelected: ((ConsoleChannel) -> Void)? { get set }
    /// Every channel name the link knows, each time one changes.
    var onNames: (([ConsoleChannel: String]) -> Void)? { get set }
    /// Anything else the desk reports that a control could be learned from: a key, a fader.
    var onControl: ((ControlSource, Int32) -> Void)? { get set }
    func start()
    func stop()
}

/// A `ConsoleLink` as a console module: its callbacks become events, one for one.
public final class LinkConsoleModule: ConsoleModule {
    public var onEvent: ((ConsoleEvent) -> Void)?
    public let link: ConsoleLink

    public init(_ link: ConsoleLink) {
        self.link = link
        link.onState = { [weak self] st in self?.onEvent?(.link(st)) }
        link.onNamesLink = { [weak self] up in self?.onEvent?(.namesLink(up)) }
        link.onModel = { [weak self] m in self?.onEvent?(.model(m)) }
        link.onSelected = { [weak self] ch in self?.onEvent?(.selected(ch)) }
        link.onNames = { [weak self] n in self?.onEvent?(.names(n)) }
        link.onControl = { [weak self] src, v in self?.onEvent?(.control(src, v)) }
    }

    public func start() { link.start() }
    public func stop() { link.stop() }
}
