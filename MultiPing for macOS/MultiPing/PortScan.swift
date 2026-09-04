import SwiftUI
import AppKit
import Network

extension View {
    /// Removes the accent-colored focus/default ring (macOS 14+); no-op below.
    @ViewBuilder func disableFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}

// MARK: - Scan range

enum PortScanRange: String, CaseIterable, Identifiable {
    case common = "Common"
    case system = "1–1024"
    case all = "All"
    case custom = "Custom"

    var id: String { rawValue }

    func ports(customFrom: Int, customTo: Int) -> [Int] {
        switch self {
        case .common: return PortScanModel.commonPorts
        case .system: return Array(1...1024)
        case .all: return Array(1...65535)
        case .custom:
            let low = max(1, min(customFrom, customTo))
            let high = min(65535, max(customFrom, customTo))
            guard low <= high else { return [] }
            return Array(low...high)
        }
    }
}

// MARK: - Model / scanner

@MainActor
final class PortScanModel: ObservableObject {
    nonisolated let host: String

    @Published var isScanning = false
    @Published var scanned = 0
    @Published var total = 0
    @Published var openPorts: [Int] = []
    @Published var statusText = "Choose a range and start the scan."

    private var scanTask: Task<Void, Never>?

    nonisolated init(host: String) {
        self.host = host
    }

    func start(range: PortScanRange, customFrom: Int, customTo: Int, timeout: TimeInterval) {
        guard !isScanning else { return }
        let ports = range.ports(customFrom: customFrom, customTo: customTo)
        guard !ports.isEmpty else {
            statusText = "That range is empty — check the port numbers."
            return
        }
        isScanning = true
        openPorts = []
        scanned = 0
        total = ports.count
        statusText = "Scanning \(ports.count) port\(ports.count == 1 ? "" : "s")…"

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.performScan(ports: ports, timeout: timeout)
            self.isScanning = false
            if Task.isCancelled {
                self.statusText = "Stopped — \(self.openPorts.count) open so far."
            } else {
                self.statusText = "Done — \(self.openPorts.count) open of \(self.total) scanned."
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
    }

    private func performScan(ports: [Int], timeout: TimeInterval) async {
        let host = self.host
        let concurrency = min(256, max(16, ports.count))
        var index = 0

        await withTaskGroup(of: (Int, Bool).self) { group in
            func submitNext() {
                guard index < ports.count else { return }
                let port = ports[index]
                index += 1
                group.addTask { (port, await PortScanModel.probe(host: host, port: port, timeout: timeout)) }
            }
            for _ in 0..<concurrency { submitNext() }

            while let (port, isOpen) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                scanned += 1
                if isOpen {
                    openPorts.append(port)
                    openPorts.sort()
                }
                submitNext()
            }
        }
    }

    /// One TCP connect probe. Resolves `true` if the connection becomes ready
    /// (port open), or `false` on refusal / timeout / cancellation.
    private static let probeQueue = DispatchQueue(label: "com.multiping.portscan", attributes: .concurrent)

    nonisolated static func probe(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard port >= 1, port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let lock = NSLock()
                var finished = false
                func finish(_ open: Bool) {
                    lock.lock()
                    if finished { lock.unlock(); return }
                    finished = true
                    lock.unlock()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: open)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    case .failed, .waiting, .cancelled: finish(false)
                    default: break
                    }
                }
                probeQueue.asyncAfter(deadline: .now() + timeout) { finish(false) }
                connection.start(queue: probeQueue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    // A pragmatic set of frequently-scanned service ports.
    static let commonPorts: [Int] = [
        20, 21, 22, 23, 25, 53, 67, 68, 69, 80, 88, 110, 111, 123, 135, 137, 138, 139,
        143, 161, 162, 179, 389, 443, 445, 465, 500, 514, 515, 587, 631, 636, 873, 902,
        993, 995, 1080, 1194, 1433, 1521, 1723, 1883, 2049, 2082, 2083, 2375, 2376, 3000,
        3128, 3306, 3389, 4444, 5000, 5060, 5432, 5601, 5900, 5901, 6379, 8000, 8080, 8443,
        8883, 8888, 9000, 9090, 9100, 9200, 11211, 27017
    ]

    static let serviceNames: [Int: String] = [
        20: "ftp-data", 21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "dns",
        67: "dhcp", 68: "dhcp", 69: "tftp", 80: "http", 88: "kerberos", 110: "pop3",
        111: "rpcbind", 123: "ntp", 135: "msrpc", 139: "netbios", 143: "imap",
        161: "snmp", 179: "bgp", 389: "ldap", 443: "https", 445: "smb", 465: "smtps",
        500: "isakmp", 514: "syslog", 515: "printer", 587: "submission", 631: "ipp",
        636: "ldaps", 873: "rsync", 902: "vmware", 993: "imaps", 995: "pop3s",
        1080: "socks", 1194: "openvpn", 1433: "mssql", 1521: "oracle", 1723: "pptp",
        1883: "mqtt", 2049: "nfs", 2082: "cpanel", 2083: "cpanel-ssl", 2375: "docker",
        2376: "docker-tls", 3000: "dev/grafana", 3128: "squid", 3306: "mysql",
        3389: "rdp", 4444: "krb/metasploit", 5000: "upnp/dev", 5060: "sip",
        5432: "postgres", 5601: "kibana", 5900: "vnc", 5901: "vnc-1", 6379: "redis",
        8000: "http-alt", 8080: "http-proxy", 8443: "https-alt", 8883: "mqtt-tls",
        8888: "http-alt", 9000: "http-alt", 9090: "http-alt", 9100: "jetdirect",
        9200: "elasticsearch", 11211: "memcached", 27017: "mongodb"
    ]
}

// MARK: - View

struct PortScanView: View {
    @ObservedObject var model: PortScanModel
    @State private var range: PortScanRange = .common
    @State private var customFrom: String = "1"
    @State private var customTo: String = "1024"
    @State private var timeout: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "wifi.router")
                Text("Port scan")
                    .font(.headline)
                Text(model.host)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Picker("Range", selection: $range) {
                ForEach(PortScanRange.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isScanning)

            if range == .custom {
                HStack(spacing: 6) {
                    Text("Ports").foregroundColor(.secondary)
                    TextField("from", text: $customFrom).frame(width: 70).textFieldStyle(.roundedBorder)
                    Text("–")
                    TextField("to", text: $customTo).frame(width: 70).textFieldStyle(.roundedBorder)
                }
                .disabled(model.isScanning)
            }

            if range == .all {
                Label("Scanning all 65,535 ports can take several minutes.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(ResultStatusPalette.orange)
            }

            HStack {
                Stepper("Timeout: \(String(format: "%.2g", timeout)) s per port", value: $timeout, in: 0.25...5, step: 0.25)
                    .disabled(model.isScanning)
                Spacer()
                Button(model.isScanning ? "Stop" : "Start Scan") {
                    if model.isScanning {
                        model.stop()
                    } else {
                        model.start(
                            range: range,
                            customFrom: Int(customFrom) ?? 1,
                            customTo: Int(customTo) ?? 1024,
                            timeout: timeout
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isScanning ? ResultStatusPalette.red : ResultStatusPalette.green)
                .disableFocusRing()
            }

            if model.total > 0 {
                ProgressView(value: Double(model.scanned), total: Double(max(1, model.total)))
            }
            Text(model.statusText)
                .font(.callout)
                .foregroundColor(.secondary)

            Divider()

            Text("Open ports (\(model.openPorts.count))")
                .font(.subheadline).bold()
            resultsList
        }
        .padding(14)
        .frame(minWidth: 400, minHeight: 440)
    }

    private var resultsList: some View {
        ScrollView {
            if model.openPorts.isEmpty {
                Text(model.isScanning ? "Scanning…" : "No open ports found yet.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.openPorts, id: \.self) { port in
                        HStack(spacing: 8) {
                            Text("\(port)")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 60, alignment: .leading)
                                .foregroundColor(ResultStatusPalette.green)
                            Text(PortScanModel.serviceNames[port] ?? "")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Presenter

/// Opens (and reuses) a port-scan window per host.
final class PortScanPresenter: NSObject, NSWindowDelegate {
    static let shared = PortScanPresenter()

    private var windows: [String: NSWindow] = [:]
    private var models: [String: PortScanModel] = [:]
    private var hostByWindow: [ObjectIdentifier: String] = [:]

    func show(host: String) {
        if let existing = windows[host] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = PortScanModel(host: host)
        let hostingView = NSHostingView(rootView: PortScanView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Port Scan — \(host)"
        window.identifier = NSUserInterfaceItemIdentifier("port-scan-\(host)")
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("PortScanWindow-\(host)")

        windows[host] = window
        models[host] = model
        hostByWindow[ObjectIdentifier(window)] = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let host = hostByWindow[ObjectIdentifier(window)] else { return }
        if let model = models[host] {
            Task { @MainActor in model.stop() }
        }
        windows.removeValue(forKey: host)
        models.removeValue(forKey: host)
        hostByWindow.removeValue(forKey: ObjectIdentifier(window))
    }
}
