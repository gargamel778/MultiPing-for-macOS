import Foundation
import Combine

class PingManager: ObservableObject {
    private let userDefaultsIPKey = "lastIPInput"

    @Published var ipInput: String {
        didSet { UserDefaults.standard.set(ipInput, forKey: userDefaultsIPKey) }
    }
    @Published var results: [PingResult] = [] {
        didSet { Task { @MainActor in self.updateTotalCounts() } }
    }
    @Published var pingStarted = false
    @Published var isPaused = false
    @Published var pingStatus: String = "Stopped"
    @Published var reachableCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var engineErrorMessage: String? = nil

    // Live probe settings — editable from the results window's status bar and
    // applied to the running engine without resetting accumulated data.
    @Published var timeout: String = "2000"
    @Published var interval: String = "1000"
    @Published var packetSize: String = "32"
    @Published var dscp: String = "0"
    private let fpingEngine = FpingEngine()

    /// Background reverse-DNS resolver for bare-IP targets (see resolveReverseDNSNames).
    private let reverseDNSQueue = DispatchQueue(label: "com.multiping.reverseDNS", qos: .utility, attributes: .concurrent)
    private let reverseDNSLimit = DispatchSemaphore(value: 8)

    init() {
        self.ipInput = UserDefaults.standard.string(forKey: userDefaultsIPKey) ?? ""
        Task { @MainActor in self.updateTotalCounts() }
    }

    deinit {
        fpingEngine.stop()
    }

    func startPingTasks(timeout: String, interval: String, size: String, dscp: String) {
        guard !pingStarted else { return }

        let isResuming = (pingStatus == "Paused")
        self.timeout = timeout
        self.interval = interval
        self.packetSize = size
        self.dscp = dscp

        pingStarted = true
        isPaused = false
        pingStatus = "Pinging..."
        engineErrorMessage = nil

        if !isResuming {
            for result in results {
                result.resetStats(initialStatus: "Pinging...")
            }
        } else {
            for result in results where result.responseTime.lowercased() == "paused" {
                result.responseTime = "Pinging..."
            }
        }

        updateTotalCounts()
        startEngine()
        resolveReverseDNSNames()
    }

    /// Resolve a reverse-DNS (PTR) name for every bare-IP target that has no user
    /// note, so hosts outside the local network — which have no MAC/vendor — still
    /// get an identity in the results. Runs off the main thread, concurrency-capped
    /// so many no-PTR hosts can't stall the pool; each name is applied on main once.
    func resolveReverseDNSNames() {
        for result in results {
            guard result.resolvedName == nil,
                  (result.note?.isEmpty ?? true),
                  result.targetType == .ipv4 || result.targetType == .ipv6 else { continue }
            let ip = result.targetValue
            let id = result.id
            reverseDNSQueue.async { [weak self] in
                guard let self else { return }
                self.reverseDNSLimit.wait()
                let name = ReverseDNS.hostname(for: ip)
                self.reverseDNSLimit.signal()
                guard let name else { return }
                DispatchQueue.main.async {
                    self.results.first(where: { $0.id == id })?.resolvedName = name
                }
            }
        }
    }

    /// (Re)start the streaming engine for the currently active (non-paused) hosts.
    private func startEngine() {
        guard pingStarted, !isPaused else { return }

        let timeoutMs = Int(timeout) ?? 2000
        let packetSizeValue = Int(packetSize) ?? 32
        let dscpValue = Int(dscp) ?? 0
        let intervalMs = Int(interval) ?? 1000
        let targets = results
            .filter { !$0.isPaused }
            .map { FpingTarget(id: $0.id, value: $0.targetValue, type: $0.targetType) }

        do {
            try fpingEngine.start(
                targets: targets,
                timeoutMs: timeoutMs,
                packetSize: packetSizeValue,
                dscp: dscpValue,
                intervalMs: intervalMs,
                onResult: { [weak self] id, probe in self?.handleStreamResult(id, probe) },
                onFatal: { [weak self] message in self?.handleFatal(message) }
            )
        } catch {
            handleFatal((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Apply one streamed per-host result. Called on the main thread.
    private func handleStreamResult(_ id: UUID, _ probe: FpingProbeResult) {
        guard pingStarted, !isPaused else { return }
        guard let result = results.first(where: { $0.id == id }), !result.isPaused else { return }

        engineErrorMessage = nil
        result.responseTime = probe.responseTime
        result.isSuccessful = probe.isSuccessful

        let now = Date()
        if probe.isSuccessful {
            result.successCount += 1
            if let latency = probe.latencyMilliseconds {
                result.recordLatency(milliseconds: latency)
                result.appendLatencySample(milliseconds: latency, at: now)
            } else {
                result.clearCurrentLatency()
            }
        } else {
            result.clearCurrentLatency()
            result.failureCount += 1
            result.appendLatencySample(milliseconds: nil, at: now)
        }

        let total = result.successCount + result.failureCount
        result.failureRate = total > 0 ? (Double(result.failureCount) / Double(total)) * 100.0 : 0.0
        updateTotalCounts()
    }

    private func handleFatal(_ message: String) {
        fpingEngine.stop()
        pingStarted = false
        isPaused = false
        pingStatus = "Engine Unavailable"
        engineErrorMessage = (message.hasPrefix("The bundled fping engine"))
            ? message
            : "The bundled fping engine returned a fatal error: \(message)"

        for result in results where ["pinging...", "pending"].contains(result.responseTime.lowercased()) {
            result.responseTime = "Engine unavailable"
            result.isSuccessful = false
        }
        updateTotalCounts()
    }

    /// Pause or resume pinging a single host. The engine is restarted with the
    /// updated host set so a paused host actually stops being pinged.
    func setHostPaused(_ result: PingResult, paused: Bool) {
        result.isPaused = paused
        if paused {
            result.isSuccessful = false
            result.clearCurrentLatency()
            result.responseTime = "Paused"
        } else {
            let active = pingStarted && !isPaused
            result.responseTime = active ? "Pinging..." : "Pending"
        }
        updateTotalCounts()

        if pingStarted && !isPaused {
            startEngine()
        }
    }

    func togglePause() {
        guard (pingStatus == "Pinging..." && !isPaused) || (pingStatus == "Paused" && isPaused) else { return }

        if !isPaused {
            isPaused = true
            pingStarted = false
            pingStatus = "Paused"
            fpingEngine.stop()
            for result in results where result.responseTime.lowercased() == "pinging..." {
                result.responseTime = "Paused"
            }
            updateTotalCounts()
        } else {
            startPingTasks(timeout: timeout, interval: interval, size: packetSize, dscp: dscp)
        }
    }

    /// Validate the (edited) settings and restart the streaming engine with them,
    /// keeping all accumulated stats and history. Used by the status-bar editors.
    func applyLiveSettings() {
        timeout = String(max(1, Int(timeout) ?? 2000))
        interval = String(max(100, Int(interval) ?? 1000))   // interval floor 100 ms
        packetSize = String(max(0, Int(packetSize) ?? 32))
        dscp = String(min(63, max(0, Int(dscp) ?? 0)))
        if pingStarted && !isPaused {
            startEngine()
        }
    }

    func stopPingTasks(clearResults: Bool) {
        let previousStatus = pingStatus
        let wasEffectivelyRunning = pingStarted || previousStatus == "Pinging..." || previousStatus == "Paused"

        fpingEngine.stop()
        pingStarted = false
        isPaused = false

        let newFinalStatus = clearResults ? "Cleared" : "Stopped"
        pingStatus = newFinalStatus
        if clearResults { engineErrorMessage = nil }

        if wasEffectivelyRunning || clearResults {
            for result in results {
                let currentItemStatus = result.responseTime.lowercased()
                if clearResults ||
                    ["pinging...", "paused", "pending"].contains(currentItemStatus) ||
                    (newFinalStatus == "Stopped" && wasEffectivelyRunning) {
                    result.responseTime = newFinalStatus
                    result.isSuccessful = false
                }
                if clearResults {
                    result.resetStats(initialStatus: "Cleared")
                }
            }
        }
        updateTotalCounts()
    }

    func prepareForAppTermination(clearResults: Bool) {
        fpingEngine.stop()
        pingStarted = false
        isPaused = false
        pingStatus = clearResults ? "Cleared" : "Stopped"
        if clearResults {
            engineErrorMessage = nil
            for result in results {
                result.resetStats(initialStatus: "Cleared")
            }
        } else {
            for result in results where ["pinging...", "paused", "pending"].contains(result.responseTime.lowercased()) {
                result.responseTime = "Stopped"
                result.isSuccessful = false
                result.clearCurrentLatency()
            }
        }
        updateTotalCounts()
    }

    private func updateTotalCounts() {
        let inactiveStatuses = ["pinging...", "pending", "paused", "stopped", "cleared", "cancelled", "engine unavailable", "restarting engine..."]
        reachableCount = results.filter { $0.isSuccessful && !inactiveStatuses.contains($0.responseTime.lowercased()) }.count
        failedCount = results.filter { !$0.isSuccessful && !inactiveStatuses.contains($0.responseTime.lowercased()) }.count
    }
}
