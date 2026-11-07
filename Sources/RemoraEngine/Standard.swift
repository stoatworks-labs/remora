import Foundation
import RemoraConsoles
import RemoraCore
import RemoraHosts
#if canImport(RemoraApple)
import RemoraApple
#endif

extension ModuleRegistry {
    /// Every module in this build.
    public static let standard = ModuleRegistry(consoles: RemoraConsoles.all, hosts: RemoraHosts.all)
}

extension Bridge {
    /// This system's platform services.
    public static func defaultPlatform() -> Platform {
        #if canImport(RemoraApple)
        return ApplePlatform()
        #else
        fatalError("Remora has no platform services for this system yet (docs/ARCHITECTURE.md)")
        #endif
    }
}
