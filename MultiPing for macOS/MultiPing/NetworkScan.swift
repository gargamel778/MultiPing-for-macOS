import SwiftUI
import Foundation
import Darwin

// MARK: - Scan kinds & discovered host model

/// The three ways the Targets Collector can discover live hosts.
enum NetworkScanKind: String, CaseIterable, Identifiable {
    case bonjour = "Bonjour"
    case localSubnet = "Local Subnet"
    case range = "IP Range"
    var id: String { rawValue }
}

/// One host found by a scan. `isSelected` defaults to true so the user opts
/// *out* of hosts they don't want, then hits Start ping.
struct DiscoveredHost: Identifiable, Equatable {
    let id = UUID()
    let ip: String
    var name: String?
    var isSelected: Bool
    let targetType: TargetType
    var mac: String? = nil       // from the ARP cache (same-subnet hosts only)
    var vendor: String? = nil    // resolved from the MAC's OUI
}

/// Locates the bundled universal `fping` binary (shared by the sweeper and the
/// ARP-refresh step).
enum FpingLocator {
    static func url() -> URL? {
        let candidates = [
            Bundle.main.url(forResource: "fping", withExtension: nil),
            Bundle.main.resourceURL?.appendingPathComponent("fping")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - Local network helpers (primary subnet, address math)

enum LocalNetwork {
    /// The IPv4 source address the OS would use to reach the internet, found by
    /// "connecting" a UDP socket to a public IP (no packets are actually sent)
    /// and reading back the chosen local address. Identifies the default-route
    /// interface so we scan the network the user is actually on.
    static func primarySourceIPv4() -> String? {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(53).bigEndian)
        inet_pton(AF_INET, "8.8.8.8", &addr.sin_addr)

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard named == 0 else { return nil }

        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    struct Interface { let name: String; let ipv4: String; let netmask: String; let prefix: Int }

    /// All up, non-loopback IPv4 interfaces with their netmasks.
    static func interfaces() -> [Interface] {
        var out: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var ptr = head
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(cur.pointee.ifa_flags)
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 { continue }
            guard let ip = ipString(sa) else { continue }
            let mask = cur.pointee.ifa_netmask.flatMap { ipString($0) } ?? "255.255.255.0"
            out.append(Interface(name: String(cString: cur.pointee.ifa_name),
                                 ipv4: ip, netmask: mask, prefix: prefixLength(fromMask: mask)))
        }
        return out
    }

    /// The CIDR of the primary (default-route) interface, e.g. "192.168.1.0/24".
    static func primaryNetworkCIDR() -> String? {
        let ifaces = interfaces()
        let chosen: Interface?
        if let primaryIP = primarySourceIPv4(), let match = ifaces.first(where: { $0.ipv4 == primaryIP }) {
            chosen = match
        } else {
            chosen = ifaces.first(where: { $0.name == "en0" }) ?? ifaces.first
        }
        guard let iface = chosen else { return nil }
        return "\(networkAddress(ip: iface.ipv4, prefix: iface.prefix))/\(iface.prefix)"
    }

    /// First and last *host* addresses inside a CIDR (network + 1 .. broadcast - 1).
    static func hostRange(forCIDR cidr: String) -> (start: String, end: String)? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix),
              let ipInt = ipv4ToInt(String(parts[0])) else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << (32 - prefix))
        let network = ipInt & mask
        let broadcast = network | ~mask
        if prefix >= 31 { return (intToIPv4(network), intToIPv4(broadcast)) }
        return (intToIPv4(network + 1), intToIPv4(broadcast - 1))
    }

    // MARK: address math

    static func ipv4ToInt(_ ip: String) -> UInt32? {
        let p = ip.split(separator: ".")
        guard p.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in p { guard let n = UInt32(part), n <= 255 else { return nil }; value = (value << 8) | n }
        return value
    }

    static func intToIPv4(_ v: UInt32) -> String {
        "\((v >> 24) & 0xff).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
    }

    static func networkAddress(ip: String, prefix: Int) -> String {
        guard let ipInt = ipv4ToInt(ip) else { return ip }
        let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << (32 - prefix))
        return intToIPv4(ipInt & mask)
    }

    static func prefixLength(fromMask mask: String) -> Int {
        mask.split(separator: ".").compactMap { UInt8($0) }.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// Numeric string from a sockaddr pointer (IPv4/IPv6).
    static func ipString(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return r == 0 ? String(cString: host) : nil
    }
}

// MARK: - Reverse DNS / mDNS name resolution

enum ReverseDNS {
    /// Blocking PTR lookup for an IP literal. Uses the system resolver, which on
    /// macOS also answers reverse mDNS for `.local` names. Returns nil if there's
    /// no name (so the row just shows the IP).
    static func hostname(for ip: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                            &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
        guard r == 0 else { return nil }
        var name = String(cString: host)
        if name.hasSuffix(".") { name = String(name.dropLast()) }
        return (name.isEmpty || name == ip) ? nil : name
    }
}

// MARK: - ICMP ping sweep (fping generate mode)

/// Runs a one-shot `fping -a -g` sweep and streams the alive hosts as they reply.
final class PingSweeper {
    private var process: Process?
    private var buffer = Data()

    /// Sweep either a CIDR or an explicit start/end range. Callbacks fire on main.
    func sweep(cidr: String?, start: String?, end: String?, ipv6: Bool,
               timeoutMs: Int = 600, retries: Int = 1,
               onHost: @escaping (String) -> Void,
               onFinish: @escaping () -> Void,
               onError: @escaping (String) -> Void) {
        stop()
        guard let exe = FpingLocator.url() else {
            onError("The bundled fping engine is missing."); onFinish(); return
        }

        // -i 3: a small gap between probes so the 254-host burst doesn't overrun
        // buffers and lose ARP/echo replies (ARP-completion below catches any that
        // still slip through). -b/-O etc. not needed for discovery.
        var args = [ipv6 ? "-6" : "-4", "-a", "-q", "-r", String(retries), "-t", String(timeoutMs), "-i", "3", "-g"]
        if let cidr = cidr, !cidr.isEmpty { args.append(cidr) }
        else if let s = start, let e = end { args.append(s); args.append(e) }
        else { onError("Invalid scan range."); onFinish(); return }

        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.executableURL = exe
        proc.arguments = args
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        buffer = Data()

        // Stream alive hosts line-by-line; EOF (empty chunk) marks completion so
        // no trailing host is dropped between the last read and process exit.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                DispatchQueue.main.async { onFinish() }
                return
            }
            guard let self = self else { return }
            self.buffer.append(chunk)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    let ip = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ip.isEmpty { DispatchQueue.main.async { onHost(ip) } }
                }
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            onError("Failed to start scan: \(error.localizedDescription)")
            DispatchQueue.main.async { onFinish() }
        }
    }

    func stop() {
        if let p = process {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil
    }

    deinit { stop() }
}

// MARK: - Bonjour / mDNS service discovery

/// Browses a curated set of common Bonjour service types and resolves each to a
/// host + address. NetServiceBrowser is soft-deprecated but remains the simplest
/// path from a discovered service to (hostName, addresses).
final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browsers: [NetServiceBrowser] = []
    private var resolving: Set<NetService> = []
    private var onHost: ((String, String?) -> Void)?

    private let serviceTypes = [
        "_http._tcp.", "_https._tcp.", "_ssh._tcp.", "_sftp-ssh._tcp.",
        "_smb._tcp.", "_afpovertcp._tcp.", "_nfs._tcp.", "_ftp._tcp.",
        "_device-info._tcp.", "_workstation._tcp.", "_companion-link._tcp.",
        "_rfb._tcp.", "_airplay._tcp.", "_raop._tcp.", "_airport._tcp.",
        "_ipp._tcp.", "_ipps._tcp.", "_printer._tcp.", "_pdl-datastream._tcp.",
        "_googlecast._tcp.", "_spotify-connect._tcp.", "_homekit._tcp.",
        "_hap._tcp.", "_daap._tcp.", "_home-sharing._tcp.", "_apple-mobdev2._tcp."
    ]

    func start(onHost: @escaping (String, String?) -> Void) {
        stop()
        self.onHost = onHost
        for type in serviceTypes {
            let browser = NetServiceBrowser()
            browser.includesPeerToPeer = true
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        onHost = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.insert(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var name = sender.hostName ?? sender.name
        if name.hasSuffix(".") { name = String(name.dropLast()) }
        let finalName = name.isEmpty ? sender.name : name

        var v4: String?, v6: String?
        for data in sender.addresses ?? [] {
            guard let ip = Self.ipString(from: data) else { continue }
            if ip.contains(":") {
                if v6 == nil && !ip.lowercased().hasPrefix("fe80") { v6 = ip }
            } else if v4 == nil {
                v4 = ip
            }
        }
        if let ip = v4 ?? v6 { onHost?(ip, finalName.isEmpty ? nil : finalName) }
        resolving.remove(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(sender)
    }

    private static func ipString(from data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let sa = base.assumingMemoryBound(to: sockaddr.self)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard r == 0 else { return nil }
            // Strip any IPv6 zone id (e.g. "%en0") for display/pinging clarity.
            let s = String(cString: host)
            return s.split(separator: "%").first.map(String.init) ?? s
        }
    }
}

// MARK: - MAC vendor (OUI) lookup

/// Maps a MAC address to its manufacturer using the bundled IEEE OUI database
/// (`oui.txt`, prefix<TAB>vendor). Supports 24/28/36-bit allocations via
/// longest-prefix match, and flags locally-administered (randomized) MACs.
final class OUILookup {
    static let shared = OUILookup()
    private var map: [String: String] = [:]
    private var loaded = false
    private var loading = false
    private var waiters: [() -> Void] = []

    /// Load the database off the main thread once, then run any queued callbacks.
    /// Must be called on the main thread.
    func ensureLoaded(_ completion: @escaping () -> Void) {
        if loaded { completion(); return }
        waiters.append(completion)
        if loading { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            var m: [String: String] = [:]
            if let url = Bundle.main.url(forResource: "oui", withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                m.reserveCapacity(60_000)
                text.split(separator: "\n").forEach { line in
                    if let tab = line.firstIndex(of: "\t") {
                        m[String(line[..<tab])] = String(line[line.index(after: tab)...])
                    }
                }
            }
            DispatchQueue.main.async {
                self.map = m; self.loaded = true; self.loading = false
                let queued = self.waiters; self.waiters = []
                queued.forEach { $0() }
            }
        }
    }

    /// Vendor for a normalized `aa:bb:cc:dd:ee:ff` MAC, or nil if unknown.
    func vendor(forMAC mac: String) -> String? {
        let octets = mac.split(separator: ":")
        guard octets.count == 6 else { return nil }
        var hex = ""
        for o in octets { guard let v = UInt8(o, radix: 16) else { return nil }; hex += String(format: "%02X", v) }
        if let first = UInt8(hex.prefix(2), radix: 16), (first & 0x02) != 0 { return "Locally administered" }
        for len in [9, 7, 6] where hex.count >= len {
            if let v = map[String(hex.prefix(len))] { return v }
        }
        return nil
    }
}

// MARK: - MAC address resolution (ARP cache)

/// Resolves IP → MAC by refreshing the ARP cache (a quick ping of the targets)
/// and reading it back. Only works for hosts on the same L2 segment.
final class MACResolver {
    func resolve(ips: [String], completion: @escaping ([String: String]) -> Void) {
        let v4 = ips.filter { !$0.contains(":") }
        guard !v4.isEmpty else { DispatchQueue.main.async { completion([:]) }; return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.refreshARP(ips: v4)
            let table = self.readARP()
            DispatchQueue.main.async { completion(table) }
        }
    }

    /// Read the whole ARP cache without pinging (a subnet/range sweep has already
    /// pinged every address, so every L2-alive host is resolved). Completion on main.
    func arpTable(completion: @escaping ([String: String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let table = self.readARP()
            DispatchQueue.main.async { completion(table) }
        }
    }

    /// A short ICMP round over the known-alive IPs so every one has a fresh ARP
    /// entry (Bonjour hosts otherwise may never have been pinged).
    private func refreshARP(ips: [String]) {
        guard let exe = FpingLocator.url() else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["-4", "-q", "-r", "0", "-t", "400", "-i", "1"] + ips
        let sink = Pipe(); p.standardOutput = sink; p.standardError = sink
        do {
            try p.run()
            _ = sink.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
        } catch { }
    }

    private func readARP() -> [String: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-an"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: String] = [:]
        // e.g. "? (192.168.1.1) at 3c:37:86:aa:bb:cc on en0 ifscope [ethernet]"
        let regex = try? NSRegularExpression(pattern: #"\(([0-9.]+)\) at ([0-9a-fA-F:]+) "#)
        text.enumerateLines { line, _ in
            guard let regex,
                  let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let ipR = Range(m.range(at: 1), in: line),
                  let macR = Range(m.range(at: 2), in: line) else { return }
            let ip = String(line[ipR])
            if result[ip] == nil, let mac = MACResolver.normalizeMAC(String(line[macR])) { result[ip] = mac }
        }
        return result
    }

    /// Zero-pad each octet and drop broadcast/multicast noise.
    static func normalizeMAC(_ raw: String) -> String? {
        let octs = raw.split(separator: ":")
        guard octs.count == 6 else { return nil }
        var parts: [String] = []
        for o in octs { guard let v = UInt8(o, radix: 16) else { return nil }; parts.append(String(format: "%02x", v)) }
        if let first = UInt8(parts[0], radix: 16), (first & 0x01) != 0 { return nil }   // broadcast/multicast
        return parts.joined(separator: ":")
    }
}

// MARK: - Scan orchestration model

/// Drives a scan and holds its results. Plain ObservableObject (not @MainActor);
/// every mutation is delivered on the main queue by the engines above.
final class NetworkScanModel: ObservableObject {
    @Published var kind: NetworkScanKind = .localSubnet
    @Published var subnetCIDR: String = ""
    @Published var rangeStart: String = ""
    @Published var rangeEnd: String = ""
    @Published var hosts: [DiscoveredHost] = []
    @Published var isScanning: Bool = false
    @Published var statusText: String = "Choose a method and click Scan."

    private let sweeper = PingSweeper()
    private let bonjour = BonjourBrowser()
    private let macResolver = MACResolver()
    private var seenIPs: Set<String> = []
    private var scanGeneration = 0
    /// Numeric IPv4 bounds of the active sweep (subnet/range); nil for Bonjour.
    /// Used after the sweep to pull in hosts that answered ARP but whose ping
    /// reply was lost (or that block ICMP) — the ARP cache is the real host list.
    private var scanBounds: (lo: UInt32, hi: UInt32)?

    /// Guard against runaway sweeps of very large ranges.
    private let maxSweepHosts = 65_536

    init() {
        autofillLocalSubnet()
        OUILookup.shared.ensureLoaded { }   // warm the vendor DB in the background
    }

    // MARK: derived values

    var selectedCount: Int { hosts.lazy.filter { $0.isSelected }.count }

    var subnetHostCount: Int? {
        let parts = subnetCIDR.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix),
              LocalNetwork.ipv4ToInt(String(parts[0])) != nil else { return nil }
        let bits = 32 - prefix
        let total = bits >= 31 ? (UInt64(1) << bits) : (UInt64(1) << bits) - 2
        return Int(min(total, UInt64(Int.max)))
    }

    var rangeHostCount: Int? {
        guard let s = LocalNetwork.ipv4ToInt(rangeStart.trimmingCharacters(in: .whitespaces)),
              let e = LocalNetwork.ipv4ToInt(rangeEnd.trimmingCharacters(in: .whitespaces)), e >= s else { return nil }
        return Int(e - s + 1)
    }

    // MARK: selection

    func toggle(_ id: DiscoveredHost.ID) {
        if let i = hosts.firstIndex(where: { $0.id == id }) { hosts[i].isSelected.toggle() }
    }
    func setAllSelected(_ value: Bool) {
        for i in hosts.indices { hosts[i].isSelected = value }
    }

    // MARK: local subnet autofill

    func autofillLocalSubnet() {
        if let cidr = LocalNetwork.primaryNetworkCIDR() {
            subnetCIDR = cidr
            if let range = LocalNetwork.hostRange(forCIDR: cidr) { rangeStart = range.start; rangeEnd = range.end }
        } else {
            subnetCIDR = "192.168.1.0/24"; rangeStart = "192.168.1.1"; rangeEnd = "192.168.1.254"
        }
    }

    // MARK: scanning

    func startScan() {
        stopScan()
        scanGeneration += 1
        let generation = scanGeneration
        hosts = []
        seenIPs = []
        isScanning = true

        switch kind {
        case .bonjour:
            scanBounds = nil
            statusText = "Browsing for Bonjour / mDNS services…"
            bonjour.start { [weak self] ip, name in self?.addHost(ip: ip, name: name) }
            // Bonjour browsing has no natural end; collect for a fixed window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.scanGeneration == generation, self.isScanning else { return }
                self.finishScan()
            }

        case .localSubnet:
            let cidr = subnetCIDR.trimmingCharacters(in: .whitespaces)
            guard subnetHostCount != nil else { isScanning = false; statusText = "Enter a valid subnet, e.g. 192.168.1.0/24."; return }
            if let n = subnetHostCount, n > maxSweepHosts { isScanning = false; statusText = "Subnet too large (\(n) hosts). Narrow it below \(maxSweepHosts)."; return }
            scanBounds = LocalNetwork.hostRange(forCIDR: cidr).flatMap { r in
                guard let lo = LocalNetwork.ipv4ToInt(r.start), let hi = LocalNetwork.ipv4ToInt(r.end) else { return nil }
                return (lo, hi)
            }
            statusText = "Sweeping \(cidr)…"
            sweeper.sweep(cidr: cidr, start: nil, end: nil, ipv6: cidr.contains(":"),
                          onHost: { [weak self] ip in self?.addHost(ip: ip, name: nil) },
                          onFinish: { [weak self] in guard self?.scanGeneration == generation else { return }; self?.finishScan() },
                          onError: { [weak self] msg in self?.statusText = msg })

        case .range:
            let s = rangeStart.trimmingCharacters(in: .whitespaces)
            let e = rangeEnd.trimmingCharacters(in: .whitespaces)
            guard let count = rangeHostCount else { isScanning = false; statusText = "Enter a valid start and end IP (end ≥ start)."; return }
            if count > maxSweepHosts { isScanning = false; statusText = "Range too large (\(count) hosts). Keep it below \(maxSweepHosts)."; return }
            scanBounds = {
                guard !s.contains(":"), let lo = LocalNetwork.ipv4ToInt(s), let hi = LocalNetwork.ipv4ToInt(e) else { return nil }
                return (lo, hi)
            }()
            statusText = "Sweeping \(s) – \(e)…"
            sweeper.sweep(cidr: nil, start: s, end: e, ipv6: s.contains(":"),
                          onHost: { [weak self] ip in self?.addHost(ip: ip, name: nil) },
                          onFinish: { [weak self] in guard self?.scanGeneration == generation else { return }; self?.finishScan() },
                          onError: { [weak self] msg in self?.statusText = msg })
        }
    }

    func stopScan() {
        sweeper.stop()
        bonjour.stop()
        if isScanning {
            isScanning = false
            statusText = hosts.isEmpty ? "Scan stopped." : "Stopped — \(hosts.count) host(s) found."
        }
    }

    private func finishScan() {
        sweeper.stop()
        bonjour.stop()
        isScanning = false
        if let bounds = scanBounds {
            // The sweep pinged every address, which ARP-resolves each live host
            // even when the ICMP echo reply is lost in the burst (or the host
            // blocks ping). The ARP cache is therefore the authoritative host
            // list — pull in everything it saw within the swept range.
            statusText = "\(hosts.count) replied to ping — checking ARP for the rest…"
            discoverAndFillViaARP(lo: bounds.lo, hi: bounds.hi, generation: scanGeneration)
        } else {
            statusText = hosts.isEmpty ? "No live hosts found." : "\(hosts.count) host(s) found. Deselect any you want to skip."
            resolveMACs(generation: scanGeneration)
        }
    }

    /// Local-sweep completion: read the ARP cache, add every in-range host that
    /// answered ARP but wasn't already found, then fill MAC + vendor for all
    /// hosts from the same snapshot. This is what makes the subnet/range scan
    /// complete rather than "only whatever ICMP replies survived the burst".
    private func discoverAndFillViaARP(lo: UInt32, hi: UInt32, generation: Int) {
        macResolver.arpTable { [weak self] table in
            guard let self, self.scanGeneration == generation else { return }
            var added = false
            for (ip, _) in table {
                guard let v = LocalNetwork.ipv4ToInt(ip), v >= lo, v <= hi, !self.seenIPs.contains(ip) else { continue }
                self.seenIPs.insert(ip)
                self.hosts.append(DiscoveredHost(ip: ip, name: nil, isSelected: true, targetType: .ipv4))
                self.resolveName(for: ip)   // reverse-DNS name for the newly found host
                added = true
            }
            if added { self.sortHosts() }

            OUILookup.shared.ensureLoaded { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                var updated = self.hosts
                for i in updated.indices {
                    if let mac = table[updated[i].ip] {
                        updated[i].mac = mac
                        updated[i].vendor = OUILookup.shared.vendor(forMAC: mac)
                    }
                }
                self.hosts = updated
                self.statusText = self.hosts.isEmpty
                    ? "No live hosts found."
                    : "\(self.hosts.count) host(s) found. Deselect any you want to skip."
            }
        }
    }

    /// After a scan, fill in each host's MAC (from ARP) and OUI vendor in one batch.
    private func resolveMACs(generation: Int) {
        guard !hosts.isEmpty else { return }
        let ips = hosts.map { $0.ip }
        macResolver.resolve(ips: ips) { [weak self] table in
            guard let self, self.scanGeneration == generation, !table.isEmpty else { return }
            OUILookup.shared.ensureLoaded { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                var updated = self.hosts
                for i in updated.indices {
                    if let mac = table[updated[i].ip] {
                        updated[i].mac = mac
                        updated[i].vendor = OUILookup.shared.vendor(forMAC: mac)
                    }
                }
                self.hosts = updated
            }
        }
    }

    private func addHost(ip: String, name: String?) {
        if seenIPs.contains(ip) {
            // A later resolution may carry a name for a host found nameless first.
            if let name, let i = hosts.firstIndex(where: { $0.ip == ip }), hosts[i].name == nil { hosts[i].name = name }
            return
        }
        seenIPs.insert(ip)
        let type: TargetType = ip.contains(":") ? .ipv6 : .ipv4
        hosts.append(DiscoveredHost(ip: ip, name: name, isSelected: true, targetType: type))
        sortHosts()
        if !isScanning { return }
        statusText = "\(hosts.count) host(s) found…"
        if name == nil { resolveName(for: ip) }   // sweep hosts get reverse-DNS names
    }

    private func resolveName(for ip: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let name = ReverseDNS.hostname(for: ip)
            guard let name else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let i = self.hosts.firstIndex(where: { $0.ip == ip }), self.hosts[i].name == nil else { return }
                self.hosts[i].name = name
            }
        }
    }

    private func sortHosts() {
        hosts.sort { a, b in
            switch (LocalNetwork.ipv4ToInt(a.ip), LocalNetwork.ipv4ToInt(b.ip)) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true      // IPv4 before IPv6
            case (nil, _?):    return false
            default:           return a.ip < b.ip
            }
        }
    }
}

// MARK: - Scan UI

struct NetworkScanView: View {
    @ObservedObject var model: NetworkScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $model.kind) {
                ForEach(NetworkScanKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: 340)
            .disabled(model.isScanning)

            inputRow

            HStack(spacing: 12) {
                if model.isScanning {
                    Button("Stop scan") { model.stopScan() }
                    ProgressView().controlSize(.small)
                } else {
                    Button("Scan") { model.startScan() }
                        .buttonStyle(.borderedProminent).disableFocusRing()
                }
                Text(model.statusText).font(.caption).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                if !model.hosts.isEmpty {
                    Button("Select all") { model.setAllSelected(true) }.controlSize(.small)
                    Button("Select none") { model.setAllSelected(false) }.controlSize(.small)
                }
            }

            resultsTable
        }
    }

    @ViewBuilder private var inputRow: some View {
        switch model.kind {
        case .bonjour:
            Text("Discovers hosts advertising Bonjour / mDNS services (AirPlay, SSH, SMB, printers, HomeKit, Chromecast, and more) on your local links.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        case .localSubnet:
            HStack(spacing: 8) {
                Text("Subnet (CIDR):").font(.caption)
                TextField("192.168.1.0/24", text: $model.subnetCIDR)
                    .textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 150).disabled(model.isScanning)
                Button("Auto") { model.autofillLocalSubnet() }.controlSize(.small).disabled(model.isScanning)
                if let n = model.subnetHostCount { Text("~\(n) hosts").font(.caption).foregroundColor(.secondary) }
            }
        case .range:
            HStack(spacing: 8) {
                Text("From:").font(.caption)
                TextField("192.168.1.1", text: $model.rangeStart)
                    .textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 130).disabled(model.isScanning)
                Text("To:").font(.caption)
                TextField("192.168.1.254", text: $model.rangeEnd)
                    .textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 130).disabled(model.isScanning)
                if let n = model.rangeHostCount { Text("~\(n) hosts").font(.caption).foregroundColor(.secondary) }
            }
        }
    }

    @ViewBuilder private var resultsTable: some View {
        if model.hosts.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                Text(model.isScanning ? "Scanning…" : "No hosts yet. Choose a method above and click Scan.")
                    .font(.callout).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("").frame(width: 16)
                    Text("IP Address").frame(width: 120, alignment: .leading)
                    Text("Name (DNS / mDNS)").frame(maxWidth: .infinity, alignment: .leading)
                    Text("MAC Address").frame(width: 135, alignment: .leading)
                    Text("Vendor (OUI)").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.bold()).foregroundColor(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.hosts) { host in
                            DiscoveredHostRow(host: host) { model.toggle(host.id) }
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .border(Color.gray.opacity(0.4), width: 1)
        }
    }
}

private struct DiscoveredHostRow: View {
    let host: DiscoveredHost
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: host.isSelected ? "checkmark.square.fill" : "square")
                .foregroundColor(host.isSelected ? .accentColor : .secondary)
                .frame(width: 16)
            Text(host.ip)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 120, alignment: .leading)
            Text(host.name ?? "—")
                .foregroundColor(host.name == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(host.mac ?? "—")
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(host.mac == nil ? .secondary : .primary)
                .frame(width: 135, alignment: .leading)
            Text(host.vendor ?? "—")
                .foregroundColor(host.vendor == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(host.vendor ?? "")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(host.isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .onTapGesture(perform: toggle)
    }
}
