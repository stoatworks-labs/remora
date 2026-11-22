import Foundation
import RemoraConsoles
import RemoraCore
import RemoraHosts
#if canImport(RemoraApple)
import RemoraApple
#elseif canImport(RemoraSockets)
import RemoraSockets
#endif

extension ModuleRegistry {
    /// Every module in this build.
    public static let standard = ModuleRegistry(consoles: RemoraConsoles.all, hosts: RemoraHosts.all)
}

extension Bridge {
    /// This system's platform services: RemoraApple's on macOS, RemoraSockets' elsewhere (Windows:
    /// TCP, UDP and OSC so far, no MIDI yet; docs/ARCHITECTURE.md §8).
    public static func defaultPlatform() -> Platform {
        #if canImport(RemoraApple)
        return ApplePlatform()
        #elseif canImport(RemoraSockets)
        return SocketPlatform()
        #else
        fatalError("Remora has no platform services for this system yet (docs/ARCHITECTURE.md)")
        #endif
    }
}
