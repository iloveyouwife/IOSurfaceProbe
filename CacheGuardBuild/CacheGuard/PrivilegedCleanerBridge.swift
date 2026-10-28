import Foundation

/// An intentionally inactive extension boundary.
///
/// A future implementation must prove access on the EXACT OS build,
/// enumerate only allowlisted cache roots, offer backup/preview, and fail closed.
/// Signing an IPA or enabling Developer Mode does NOT grant this privilege.
protocol PrivilegedCleanerBridge {
    func probe() -> PrivilegeProbe
    func enumerateAllowlistedCaches() throws -> [URL]
}

struct PrivilegeProbe {
    let supported: Bool
    let reason: String
}

struct UnavailablePrivilegedBridge: PrivilegedCleanerBridge {
    func probe() -> PrivilegeProbe {
        PrivilegeProbe(
            supported: false,
            reason: "AirLift 已接入配对与容器查询，但尚未实现或真机验证安全的跨 App 缓存枚举/删除。"
        )
    }

    func enumerateAllowlistedCaches() throws -> [URL] {
        return []
    }
}
