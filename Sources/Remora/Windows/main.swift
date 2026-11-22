// Remora.exe: Windows' Remora (docs/ARCHITECTURE.md §8). The engine runs headless, with the same
// command line as the Mac's, its MIDI on a loopback port the user makes. There is no settings
// window yet: settings.json is edited by hand (`Remora --settings` says where it is), and a local
// web page is the plan.
import Foundation
import RemoraCLI
import RemoraCore
import RemoraEngine

let cli = CLI(version: appVersion)

if cli.has("--version") {
    print(appVersion)
    exit(0)
}

if cli.has("--help") {
    print("""
    \(cli.helpTitle)

      Remora                       run the bridge, logging to the console and to
                                   \(Places.logFile.path); settings from
                                   \(Settings.fileURL.path)
    \(CLI.readCommandsHelp)
      Remora --headless [--host HOST] [--for SECS] [--dry-run]
                                   the same as Remora alone; --host overrides the desk's address,
                                   --dry-run logs the MIDI instead of sending it

    MIDI goes out on a loopback port you make once, named as settings.json's "midiPortName"
    ("Remora"): in loopMIDI, or with Windows MIDI Services' Tools as a loopback pair,
    midi loopback create --root-name "Remora". Remora sends on "Remora (A)", and SuperRack's MIDI
    module or VST Live listens to "Remora (B)"; both are experimental here. Learned MIDI controls
    are heard only with Windows MIDI Services, which shares each input between programs. Windows
    has no settings window or plug-in window guard yet; for SuperRack, SuperRack (ProLink) needs
    no port ("superrack.prolink" in "pluginHost").
    """)
    exit(0)
}

// --racks, --mapping, --settings, --probe and --auto-build: each exits.
cli.runReadCommands()

for flag in ["--screenshots", "--film", "--plugin-windows", "--through-app"] where cli.has(flag) {
    cli.fail("\(flag) is not on Windows yet: it needs the Mac's menu-bar app", 2)
}

// Remora alone is --headless here.
Log.line("Remora \(appVersion) on Windows; settings from \(Settings.fileURL.path)")
cli.headless()
