import Foundation
import RemoraCore

/// Every plug-in host module in this build, in the picker's order.
public enum RemoraHosts {
    public static let all: [HostModuleEntry] = [
        SuperRackMIDIModule.entry, SuperRackProLinkModule.entry,
        REAPER.entry, AbletonLive.entry, Logic.entry, MainStage.entry, LiveProfessor.entry,
        GigPerformer.entry, VSTHost.entry, Cantabile.entry, VSTLive.entry,
    ]
}
