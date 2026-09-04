import SwiftUI
import AppKit
import Foundation

// Enum for View Modes (Unchanged)
enum ResultsViewMode: String, CaseIterable, Identifiable {
    case list = "≡ List Layout"
    case grid = "# Grid Layout"
    var id: String { self.rawValue }
}

/// How the Targets Collector sources its hosts: the saved manual list, or a
/// live network scan.
enum TargetInputMode: String, CaseIterable, Identifiable {
    case myHosts = "My Hosts"
    case networkScan = "Network Scan"
    var id: String { self.rawValue }
}

struct IPInputView: View {
    @ObservedObject var manager: PingManager
    @State var timeout: String = "2000"
    @State var size: String = "32"
    // Ping interval in milliseconds, remembered between sessions (min 100 ms).
    @AppStorage("PingIntervalMsV1") var interval: String = "1000"
    @State var dscp: String = "0"
    @State private var selectedViewMode: ResultsViewMode = .list
    @State private var inputMode: TargetInputMode = .myHosts
    @StateObject private var scanModel = NetworkScanModel()

    private var placeholderText: String = """
e.g.,
8.8.8.8
2001:db8::1
example.com
192.168.1.1, Home Router
10.0.0.2    Office Server
ff00::1\tLab IPv6 Gateway

Notes are optional. Use comma, space, or tab to separate target from note.
"""
    
    init(manager: PingManager) {
        self.manager = manager
    }

    var validTargetCount: Int {
        return parseTargets(from: manager.ipInput).count
    }

    /// Targets that "Start ping" will act on, depending on the active mode.
    var activeTargetCount: Int {
        inputMode == .myHosts ? validTargetCount : scanModel.selectedCount
    }

    var dscpMarkDescription: String {
        guard let value = Int(dscp.trimmingCharacters(in: .whitespacesAndNewlines)), (0...63).contains(value) else {
            return "Invalid"
        }
        return DSCPMark.name(for: value)
    }
    

    var body: some View {
        VStack(spacing: 15) {
            // Settings Row
            HStack(alignment: .bottom, spacing: 15) {
                VStack(alignment: .leading) { Text("Timeout (ms)").font(.caption); TextField("2000", text: $timeout).textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 80) }
                VStack(alignment: .leading) { Text("Size (bytes)").font(.caption); TextField("32", text: $size).textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 80) }
                VStack(alignment: .leading) { Text("Interval (ms)").font(.caption); TextField("1000", text: $interval).textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 80) }
                VStack(alignment: .leading) {
                    Text("DSCP (0-63)").font(.caption)
                    HStack(spacing: 6) {
                        TextField("0", text: $dscp)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 80)
                        Text(dscpMarkDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                    }
                }
                Spacer()
            }.padding(.top).padding(.horizontal)

            // Source Mode Switcher: saved manual list vs. live network scan.
            Picker("", selection: $inputMode) {
                ForEach(TargetInputMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).padding(.horizontal)

            if inputMode == .myHosts {
                // Engine Notice Text
                Text("Notice:\nMultiPing now uses a bundled fping engine for bulk ICMP probing. If the engine is unavailable, the test will stop and show repair guidance instead of falling back to legacy ping.")
                    .font(.footnote).fontWeight(.bold).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal).padding(.bottom, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Target Input Area Label
                Text("Enter Targets (Each target on a separate line; notes optional)").font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $manager.ipInput).frame(maxWidth: .infinity, maxHeight: .infinity).border(Color.gray.opacity(0.5), width: 1)
                    if manager.ipInput.isEmpty { Text(placeholderText).foregroundColor(.secondary).padding(.leading, 5).padding(.top, 8).allowsHitTesting(false) }
                }.padding(.horizontal).layoutPriority(1)
            } else {
                NetworkScanView(model: scanModel)
                    .padding(.horizontal).layoutPriority(1)
            }

            // Bottom Row (Controls)
            HStack {
                Text(inputMode == .myHosts ? "Count of Targets: \(validTargetCount)" : "Selected hosts: \(scanModel.selectedCount)")
                    .font(.callout).foregroundColor(.secondary).padding(.trailing, 20)
                Text("Monitoring layout:").font(.callout).padding(.trailing, 10)
                Picker("", selection: $selectedViewMode) {
                    ForEach(ResultsViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented).frame(maxWidth: 200)
                    .help("Choose the monitoring layout for the results window")
                Spacer()
                if inputMode == .networkScan {
                    Button("Add to My Hosts") { addSelectedScanHostsToMyHosts() }
                        .disabled(scanModel.selectedCount == 0)
                        .help("Append the selected discovered hosts to your saved My Hosts list")
                }
                Button("Start ping") { startPing() }
                    .buttonStyle(.borderedProminent).disabled(activeTargetCount == 0)
                    .help(inputMode == .myHosts ? "Begin pinging all targets" : "Begin pinging the selected discovered hosts")
            }.padding(.horizontal).padding(.bottom)

        }
        .padding(.top)
        .frame(minWidth: inputMode == .networkScan ? 680 : 480,
               minHeight: inputMode == .networkScan ? 460 : 380)
        .onChange(of: inputMode) { newMode in
            if newMode == .networkScan { growCollectorWindowForScan() }
        }
    }

    /// Switching to Network Scan grows the collector to a size that comfortably
    /// shows the IP/Name/MAC/Vendor table. Never shrinks an already-larger window,
    /// and leaves My Hosts alone.
    private func growCollectorWindowForScan() {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "ip-input" || $0.title == "Targets Collector"
        }) else { return }
        let target = NSSize(width: 880, height: 660)
        let frame = window.frame
        let newWidth = max(frame.width, target.width)
        let newHeight = max(frame.height, target.height)
        guard newWidth > frame.width || newHeight > frame.height else { return }
        let topLeftY = frame.origin.y + frame.height        // keep the top edge anchored
        let newFrame = NSRect(x: frame.origin.x, y: topLeftY - newHeight, width: newWidth, height: newHeight)
        window.setFrame(newFrame, display: true, animate: true)
    }

    /// Append the hosts selected in a scan to the persistent My Hosts list
    /// (`ip, name`), skipping any target already present. Does not touch the scan.
    func addSelectedScanHostsToMyHosts() {
        let selected = scanModel.hosts.filter { $0.isSelected }
        guard !selected.isEmpty else { return }
        let existing = Set(parseTargets(from: manager.ipInput).map { $0.value.lowercased() })
        var newLines: [String] = []
        for host in selected where !existing.contains(host.ip.lowercased()) {
            if let name = host.name, !name.isEmpty { newLines.append("\(host.ip), \(name)") }
            else { newLines.append(host.ip) }
        }
        guard !newLines.isEmpty else {
            scanModel.statusText = "All selected hosts are already in My Hosts."
            return
        }
        var text = manager.ipInput
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += newLines.joined(separator: "\n") + "\n"
        manager.ipInput = text   // didSet persists to UserDefaults
        scanModel.statusText = "Added \(newLines.count) host(s) to My Hosts."
    }

    /// Route "Start ping" to the manual list or the scan selection.
    func startPing() {
        if inputMode == .myHosts {
            prepareAndStartPing()
        } else {
            startPingForScanHosts()
        }
    }

    /// Build the results session from the hosts selected in a network scan and
    /// begin pinging them (using their resolved name as the note).
    func startPingForScanHosts() {
        let selected = scanModel.hosts.filter { $0.isSelected }
        guard !selected.isEmpty else { return }
        validateSettings()
        let inputWindow = NSApp.keyWindow
        manager.results.removeAll()
        manager.pingStarted = false
        for host in selected {
            manager.results.append(PingResult(targetValue: host.ip,
                                              targetType: host.targetType,
                                              note: host.name,
                                              responseTime: "Pending",
                                              successCount: 0, failureCount: 0,
                                              failureRate: 0.0, isSuccessful: false))
        }
        manager.startPingTasks(timeout: self.timeout, interval: self.interval, size: self.size, dscp: self.dscp)
        openResultsWindow(mode: selectedViewMode)
        inputWindow?.close()
    }

    func validateSettings() {
        let timeoutValue = max(1, Int(timeout) ?? 2000)
        let sizeValue = max(0, Int(size) ?? 32)
        let intervalValue = max(100, Int(interval) ?? 1000)   // interval in ms, floor 100 ms
        let dscpValue = min(63, max(0, Int(dscp) ?? 0))

        timeout = String(timeoutValue)
        size = String(sizeValue)
        interval = String(intervalValue)
        dscp = String(dscpValue)
    }

    func dscpDescription() -> String {
        guard let dscpValue = Int(dscp), dscpValue > 0 else {
            return "Off"
        }
        return "\(dscpValue)"
    }
    
    private func identifyTargetType(_ targetString: String) -> TargetType {
        let trimmedTarget = targetString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTarget.isEmpty { return .unknown }
        let ipv4Parts = trimmedTarget.split(separator: ".")
        if ipv4Parts.count == 4 && ipv4Parts.allSatisfy({ part in
            if let n = Int(part), String(n) == part, n >= 0 && n <= 255 { return true }
            return false
        }) {
            if ipv4Parts.joined(separator: ".").count == trimmedTarget.count {
                 return .ipv4
            }
        }
        if trimmedTarget.contains(":") {
            if !trimmedTarget.lowercased().hasPrefix("http://") &&
               !trimmedTarget.lowercased().hasPrefix("https://") &&
               trimmedTarget.components(separatedBy: "/").count == 1 &&
               trimmedTarget.components(separatedBy: "?").count == 1 &&
               trimmedTarget.components(separatedBy: "#").count == 1 {
                 let colonCount = trimmedTarget.filter { $0 == ":" }.count
                 if colonCount >= 1 && colonCount <= 7 {
                     if colonCount == 1 {
                         let parts = trimmedTarget.split(separator: ":")
                         if parts.count == 2, let lastPart = parts.last, Int(lastPart) != nil {
                             if parts.first?.contains(".") ?? false {
                             } else {
                                return .ipv6
                             }
                         } else {
                            return .ipv6
                         }
                     } else {
                        return .ipv6
                     }
                 }
            }
        }
        if !trimmedTarget.contains(" ") {
            return .domain
        }
        return .unknown
    }

    private func parseTargets(from input: String) -> [(value: String, note: String?, type: TargetType)] {
        return input.split { $0.isNewline }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line -> (value: String, note: String?, type: TargetType) in
                var targetValue = line
                var noteValue: String? = nil
                if let commaRange = line.range(of: ",") {
                    targetValue = String(line[..<commaRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    noteValue = String(line[commaRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let tabRange = line.range(of: "\t") {
                    targetValue = String(line[..<tabRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    noteValue = String(line[tabRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    if let firstSpaceRange = line.range(of: " ") {
                        let potentialTarget = String(line[..<firstSpaceRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let potentialNote = String(line[firstSpaceRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !potentialTarget.isEmpty && !potentialNote.isEmpty {
                            targetValue = potentialTarget
                            noteValue = potentialNote
                        }
                    }
                }
                if noteValue?.isEmpty ?? true { noteValue = nil }
                if targetValue.isEmpty {
                    return (value: line, note: nil, type: identifyTargetType(line))
                }
                return (value: targetValue, note: noteValue, type: identifyTargetType(targetValue))
            }
    }

    func prepareAndStartPing() {
        validateSettings()
        let inputWindow = NSApp.keyWindow // Get a reference to the current input window
        manager.results.removeAll()
        manager.pingStarted = false // Reset pingStarted state
        let targetsWithNotes = parseTargets(from: manager.ipInput)
        guard !targetsWithNotes.isEmpty else { return }

        for targetInfo in targetsWithNotes {
            manager.results.append(PingResult(targetValue: targetInfo.value,
                                              targetType: targetInfo.type,
                                              note: targetInfo.note,
                                              responseTime: "Pending",
                                              successCount: 0, failureCount: 0,
                                              failureRate: 0.0, isSuccessful: false))
        }
        manager.startPingTasks(timeout: self.timeout, interval: self.interval, size: self.size, dscp: self.dscp)
        openResultsWindow(mode: selectedViewMode)
        inputWindow?.close() // Close the input window after starting pings
    }

    func openResultsWindow(mode: ResultsViewMode) {
        // Single shared opener (configures the window to survive close without
        // crashing the close animation, and attaches no ping-stopping onDisappear).
        openMultiPingResultsWindow(manager: manager, mode: mode)
    }
}
