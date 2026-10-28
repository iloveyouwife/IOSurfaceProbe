import AirliftFFI
import Darwin
import Foundation

enum AirLiftNetwork {
    private static let hostKey = "cacheguard.airlift.host"

    static var targetHost: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "10.7.0.1" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }

    /// Never send a pairing tunnel connection toward a public Internet address.
    static func isLocalIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _): return true
        case (172, 16...31): return true
        case (192, 168), (169, 254): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    @discardableResult
    static func configureTarget() -> Bool {
        let host = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLocalIPv4(host) else { return false }
        _ = host.withCString { al_set_target_host($0) }
        return true
    }

    static var networkSnapshot: String {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return "网络状态无法读取" }
        defer { freeifaddrs(pointer) }

        var hasWifi = false
        var tunnelNames: [String] = []
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let item = node {
            defer { node = item.pointee.ifa_next }
            let name = String(cString: item.pointee.ifa_name)
            let flags = item.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0 && flags & UInt32(IFF_RUNNING) != 0 else { continue }
            if name == "en0" { hasWifi = true }
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("tap") {
                if !tunnelNames.contains(name) { tunnelNames.append(name) }
            }
        }
        let wifi = hasWifi ? "Wi-Fi 已连接" : "Wi-Fi 未检测到"
        let tunnel = tunnelNames.isEmpty ? "未发现 VPN 隧道" : "存在 VPN 隧道（\(tunnelNames.joined(separator: ", "))）"
        return "\(wifi) · \(tunnel)"
    }
}
