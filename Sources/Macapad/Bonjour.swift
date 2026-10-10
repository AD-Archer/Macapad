import dnssd
import Foundation

/// Advertises Macapad on the local network as `_macapad._tcp`, so frontends can find
/// this Mac without typing an address. Tailscale has no multicast, so this is LAN only.
@MainActor
final class Bonjour {
    static let serviceType = "_macapad._tcp"

    private var service: DNSServiceRef?
    private var advertised: (name: String, txt: [String: String])?

    /// Starts, updates or stops advertising to match the settings.
    func apply(_ settings: MacapadSettings, port: Int) {
        guard settings.discoverable(.lan) else { return stop() }
        let txt = ["id": settings.id, "v": Health().version, "name": settings.displayName]
        if service != nil, advertised?.name == settings.displayName, advertised?.txt == txt { return }
        stop()

        let record = Self.txtRecord(txt)
        var ref: DNSServiceRef?
        let error = record.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &ref, 0, 0, settings.displayName, Self.serviceType, nil, nil,
                UInt16(port).bigEndian, UInt16(bytes.count), bytes.baseAddress, nil, nil
            )
        }
        guard error == kDNSServiceErr_NoError, let ref else {
            NSLog("Macapad: Bonjour registration failed (\(error))")
            return
        }
        DNSServiceSetDispatchQueue(ref, .main)
        service = ref
        advertised = (settings.displayName, txt)
    }

    func stop() {
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        advertised = nil
    }

    /// DNS TXT format: each entry is a length byte then "key=value".
    private static func txtRecord(_ entries: [String: String]) -> Data {
        var data = Data()
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            let entry = Data("\(key)=\(value)".utf8.prefix(255))
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }
}
