import Darwin
import Foundation
import HTTPTypes

/// Works out which network a request came from, so settings can allow or refuse it.
enum Network {
    /// `remote` is the connection's peer address. Requests proxied by `tailscale serve`
    /// arrive from localhost, so for those the forwarded client address decides.
    static func classify(remote: String?, headers: HTTPFields) -> NetworkKind {
        guard let remote, let ip = IP(remote) else { return .internet }
        if ip.isLoopback {
            if let forwarded = headers[HTTPField.Name("X-Forwarded-For")!]?
                .split(separator: ",").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
               let client = IP(forwarded) {
                return classify(client)
            }
            if headers[HTTPField.Name("Tailscale-User-Login")!] != nil { return .tailscale }
            return .thisMac
        }
        return classify(ip)
    }

    private static func classify(_ ip: IP) -> NetworkKind {
        if ip.isLoopback { return .thisMac }
        if ip.isTailscale { return .tailscale }
        let interfaces = localInterfaces()
        if interfaces.contains(where: { $0.address == ip }) { return .thisMac }
        if ip.isPrivate { return .lan }
        if interfaces.contains(where: { !$0.isTunnel && $0.contains(ip) }) { return .lan }
        return .internet
    }

    // MARK: Addresses

    struct IP: Equatable {
        /// 4 bytes for IPv4, 16 for IPv6.
        let bytes: [UInt8]

        init?(_ string: String) {
            var s = string
            if let percent = s.firstIndex(of: "%") { s = String(s[..<percent]) }  // fe80::1%en0
            var v4 = in_addr(), v6 = in6_addr()
            if inet_pton(AF_INET, s, &v4) == 1 {
                bytes = withUnsafeBytes(of: &v4) { Array($0) }
            } else if inet_pton(AF_INET6, s, &v6) == 1 {
                let raw = withUnsafeBytes(of: &v6) { Array($0) }
                // ::ffff:a.b.c.d is just IPv4.
                bytes = raw.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] ? Array(raw.suffix(4)) : raw
            } else {
                return nil
            }
        }

        init(bytes: [UInt8]) { self.bytes = bytes }

        var isV4: Bool { bytes.count == 4 }

        var isLoopback: Bool {
            isV4 ? bytes[0] == 127 : bytes == [UInt8](repeating: 0, count: 15) + [1]
        }

        /// 100.64.0.0/10 (Tailscale's CGNAT range) or fd7a:115c:a1e0::/48.
        var isTailscale: Bool {
            isV4 ? bytes[0] == 100 && bytes[1] & 0xc0 == 64 : Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        }

        /// Private and link-local ranges.
        var isPrivate: Bool {
            if isV4 {
                return bytes[0] == 10
                    || (bytes[0] == 172 && bytes[1] & 0xf0 == 16)
                    || (bytes[0] == 192 && bytes[1] == 168)
                    || (bytes[0] == 169 && bytes[1] == 254)
            }
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
    }

    struct Interface {
        let name: String
        let address: IP
        let mask: IP

        /// utun* covers Tailscale and other VPNs; their subnets aren't "the local network".
        var isTunnel: Bool { name.hasPrefix("utun") || name.hasPrefix("ipsec") }

        func contains(_ ip: IP) -> Bool {
            guard ip.bytes.count == address.bytes.count else { return false }
            return zip(zip(ip.bytes, address.bytes), mask.bytes).allSatisfy { ($0.0 & $1) == ($0.1 & $1) }
        }
    }

    static func localInterfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, let mask = entry.ifa_netmask,
                  // macOS sometimes leaves the netmask's family unset, so read it as the address's.
                  let address = ip(from: addr, family: addr.pointee.sa_family),
                  let netmask = ip(from: mask, family: addr.pointee.sa_family)
            else { continue }
            result.append(Interface(name: String(cString: entry.ifa_name), address: address, mask: netmask))
        }
        return result
    }

    private static func ip(from sockaddr: UnsafeMutablePointer<sockaddr>, family: sa_family_t) -> IP? {
        switch Int32(family) {
        case AF_INET:
            return sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var a = $0.pointee.sin_addr
                return IP(bytes: withUnsafeBytes(of: &a) { Array($0) })
            }
        case AF_INET6:
            return sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var a = $0.pointee.sin6_addr
                return IP(bytes: withUnsafeBytes(of: &a) { Array($0) })
            }
        default:
            return nil
        }
    }
}
