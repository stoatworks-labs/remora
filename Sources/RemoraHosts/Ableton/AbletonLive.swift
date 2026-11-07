import Foundation
import RemoraCore

/// Ableton Live through AbletonOSC (ideoforms, MIT, a third-party control surface script), from its
/// README and source (master 0ca6821): Remora reads the track names, selects a track, and listens
/// for the selection. Selecting a track only selects it. Nothing else is sent: no other setter, no
/// method (play, fire, delete, undo), and never an address with a wildcard, which the script turns
/// into calls.
public enum AbletonLive {
    private static let names = "/live/song/get/track_names"
    private static let listen = "/live/view/start_listen/selected_track"
    private static let selected = "/live/view/get/selected_track"
    private static let select = "/live/view/set/selected_track"

    public static let info = ModuleInfo(
        id: "ableton", kind: .host, title: "Ableton Live (AbletonOSC)", product: "Ableton Live",
        maker: "Ableton", status: .experimental,
        about: "Remora selects a track in Live through AbletonOSC, a free control surface script by another author: it reads the track names, selects a track (/live/view/set/selected_track) and listens for the selection, so a click in Live is seen. Return and master tracks aren't racks. Selecting a track only selects it. Built from AbletonOSC's documents and source; not run against Live.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [],
        hostDefaults: HostDefaults(
            port: 11000, replyPort: 11001,
            setUp: """
            1. Copy AbletonOSC's folder (github.com/ideoforms/AbletonOSC) into ~/Music/Ableton/User Library/Remote Scripts, and restart Live (11 or later).
            2. Live › Settings › Link, Tempo & MIDI: choose AbletonOSC as a Control Surface.
            3. AbletonOSC listens on UDP 11000 and answers on 11001, to the address that asked: run nothing else on 11001 on this computer.
            """))

    public static let spec = OSCHostSpec(
        info: info,
        show: { i, _ in i >= 0 ? [OSC.Message(address: select, args: [.int(Int32(clamping: i))])] : [] },
        ask: [OSC.Message(address: names, args: []), OSC.Message(address: listen, args: [])],
        // Track names change without a word, and asking to listen again re-sends the selection.
        poll: 5,
        read: { m in
            switch m.address {
            case names: return [.racks(m.args.map(\.text))]
            case selected: return m.args.first?.number.map { [.position(Int($0))] } ?? []
            case "/live/startup": return [.reask]
            default: return []
            }
        },
        isAllowed: OSCHostSpec.only([names: [""], listen: [""], select: ["i"]]))

    public static let entry = HostModuleEntry(info) { OSCHostModule(spec, $0) }
}
