import Darwin
import Foundation
import SystemConfiguration

/// What this PC is called and which address the phone should connect to.
enum MacNetwork {
    struct Candidate: Equatable, Sendable {
        let interface: String
        let address: String
    }

    static let unavailableAddress = "Kullanılamıyor"

    /// The name shown in Finder and Sharing settings. Looked up once: `Host.current().name` asks
    /// the resolver and can stall the main thread for seconds on a network without working DNS.
    static let computerName: String = {
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? shortHostName
    }()

    static let hostName: String = shortHostName

    private static var shortHostName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "PC" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The address of the interface this PC reaches the network through, falling back to the
    /// lowest-numbered Wi-Fi or Ethernet interface with a private address. VPN, bridge, virtual
    /// machine and link-local interfaces are never picked: a phone on the same Wi-Fi cannot reach
    /// them, and a QR code carrying one of them leaves the phone waiting forever.
    static func preferredAddress(from candidates: [Candidate], primaryInterface: String?) -> String? {
        let usable = candidates
            .filter { isPhysicalInterface($0.interface) && isPrivateAddress($0.address) }
            .sorted { interfaceIndex($0.interface) < interfaceIndex($1.interface) }
        if let primaryInterface, let match = usable.first(where: { $0.interface == primaryInterface }) {
            return match.address
        }
        return usable.first?.address
    }

    static func currentAddress() -> String {
        preferredAddress(from: candidates(), primaryInterface: primaryInterface()) ?? unavailableAddress
    }

    /// Ethernet and Wi-Fi are `en<N>`; everything else (utun, bridge, awdl, vmnet, lo) is not.
    static func isPhysicalInterface(_ name: String) -> Bool {
        name.hasPrefix("en") && name.dropFirst(2).allSatisfy(\.isNumber) && name.count > 2
    }

    /// RFC 1918 plus the carrier-grade range some hotspots hand out. Link-local (169.254.x.x) and
    /// public addresses are excluded.
    static func isPrivateAddress(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    private static func interfaceIndex(_ name: String) -> Int {
        Int(name.dropFirst(2)) ?? Int.max
    }

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Wiqo" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
            return nil
        }
        return global["PrimaryInterface"] as? String
    }

    private static func candidates() -> [Candidate] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var result: [Candidate] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current?.pointee {
            current = interface.ifa_next
            let isUp = interface.ifa_flags & UInt32(IFF_UP) != 0 && interface.ifa_flags & UInt32(IFF_RUNNING) != 0
            guard isUp,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var socketAddress = address.pointee
            guard getnameinfo(&socketAddress, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let bytes = host.map { UInt8(bitPattern: $0) }.prefix(while: { $0 != 0 })
            result.append(Candidate(interface: String(cString: interface.ifa_name), address: String(decoding: bytes, as: UTF8.self)))
        }
        return result
    }
}
