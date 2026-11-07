import Foundation

extension Settings {
    /// SuperRack MIDI's driver, from its flat keys in settings.json.
    public var driverConfig: SuperRackDriver.Config {
        var c = SuperRackDriver.Config()
        c.channel = min(max(midiChannel, 1), 16)
        c.ccBase = min(max(ccBase, 0), 127 - NavCommand.allCases.count + 1)
        c.spacing = Double(min(max(stepMilliseconds, 0), 500)) / 1000
        c.mode = mode
        c.openRackAfterMove = openRackAfterMove
        return c
    }
}
