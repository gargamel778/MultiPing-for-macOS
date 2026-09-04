import Foundation
import Combine // Needed for ObservableObject

// Define an enum for target types
enum TargetType: String, Codable, CaseIterable { // Added CaseIterable for potential future use
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
    case domain = "Domain"
    case unknown = "Unknown" // For fallback or initial state
}

/// A single timestamped probe outcome used by the latency graph.
/// `latencyMs == nil` marks a failed probe (packet loss) at that instant.
struct LatencySample {
    let time: Date
    let latencyMs: Double?
}

// Converted to a class conforming to ObservableObject
class PingResult: ObservableObject, Identifiable, Equatable { // Added Equatable
    let id = UUID() // Stays the same for Identifiable & Equatable
    let targetValue: String  // Renamed from 'ip' to be more generic
    let targetType: TargetType // New property to store the type
    let note: String? // New property for notes [cite: 1]

    // Properties that change are marked @Published
    @Published var responseTime: String
    @Published var successCount: Int
    @Published var failureCount: Int
    @Published var failureRate: Double
    @Published var isSuccessful: Bool
    @Published var currentLatencyMs: Double?
    @Published var averageLatencyMs: Double?
    @Published var minimumLatencyMs: Double?
    @Published var maximumLatencyMs: Double?
    /// Per-host pause: when true this target is excluded from ping rounds while
    /// the rest of the session keeps running.
    @Published var isPaused: Bool = false

    /// Reverse-DNS (PTR) hostname for a bare-IP target that has no user note.
    /// Resolved once in the background when pinging starts, so hosts outside the
    /// local network (which have no MAC/vendor) still get an identity. nil until
    /// resolved (or if the target already has a note / isn't an IP / has no PTR).
    @Published var resolvedName: String?

    var latencyTotalMs: Double = 0
    var latencySampleCount: Int = 0

    /// Rolling time-series of probe outcomes, consumed by the latency graph.
    /// Pruned to the last 24 hours (the widest graph window) with a hard cap
    /// so long-running sessions stay bounded in memory. Not @Published: it is
    /// always mutated alongside another @Published stat within the same round,
    /// so observers still refresh, and we avoid extra table reloads per sample.
    var latencyHistory: [LatencySample] = []
    private let historyRetention: TimeInterval = 24 * 60 * 60
    private let historyHardCap = 200_000

    // Initializer for the class (UPDATED for note)
    init(targetValue: String, targetType: TargetType, note: String?, responseTime: String, successCount: Int, failureCount: Int, failureRate: Double, isSuccessful: Bool) {
        self.targetValue = targetValue
        self.targetType = targetType
        self.note = note // Initialize the new note property
        self.responseTime = responseTime
        self.successCount = successCount
        self.failureCount = failureCount
        self.failureRate = failureRate
        self.isSuccessful = isSuccessful
        self.currentLatencyMs = nil
        self.averageLatencyMs = nil
        self.minimumLatencyMs = nil
        self.maximumLatencyMs = nil
    }

    // Equatable conformance based on ID
    static func == (lhs: PingResult, rhs: PingResult) -> Bool {
        return lhs.id == rhs.id
    }

    // Helper to reset counts and status (useful for start/clear)
    func resetStats(initialStatus: String = "Pending") {
        // Ensure updates happen on the main thread if called from background
        // However, since @Published handles this, direct assignment is okay here.
        self.responseTime = initialStatus
        self.successCount = 0
        self.failureCount = 0
        self.failureRate = 0.0
        self.isSuccessful = false
        self.currentLatencyMs = nil
        self.averageLatencyMs = nil
        self.minimumLatencyMs = nil
        self.maximumLatencyMs = nil
        self.latencyTotalMs = 0
        self.latencySampleCount = 0
        self.latencyHistory.removeAll(keepingCapacity: true)
        self.isPaused = false
    }

    func recordLatency(milliseconds: Double) {
        currentLatencyMs = milliseconds
        latencyTotalMs += milliseconds
        latencySampleCount += 1
        averageLatencyMs = latencyTotalMs / Double(latencySampleCount)
        minimumLatencyMs = min(minimumLatencyMs ?? milliseconds, milliseconds)
        maximumLatencyMs = max(maximumLatencyMs ?? milliseconds, milliseconds)
    }

    func clearCurrentLatency() {
        currentLatencyMs = nil
    }

    /// Record a probe outcome in the rolling history. `milliseconds == nil`
    /// denotes packet loss (a failed probe) at `time`.
    func appendLatencySample(milliseconds: Double?, at time: Date) {
        latencyHistory.append(LatencySample(time: time, latencyMs: milliseconds))
        pruneLatencyHistory(now: time)
    }

    /// Number of probes, and how many were lost, at or after `cutoff`.
    /// Walks newest-first and stops once older than the cutoff, so it stays cheap
    /// even with a full day of history. Used by the graph's windowed-loss readout.
    func windowStats(since cutoff: Date) -> (lost: Int, total: Int) {
        var lost = 0
        var total = 0
        for sample in latencyHistory.reversed() {
            if sample.time < cutoff { break }
            total += 1
            if sample.latencyMs == nil { lost += 1 }
        }
        return (lost, total)
    }

    private func pruneLatencyHistory(now: Date) {
        let cutoff = now.addingTimeInterval(-historyRetention)
        if let first = latencyHistory.first, first.time < cutoff {
            if let keepFrom = latencyHistory.firstIndex(where: { $0.time >= cutoff }) {
                latencyHistory.removeFirst(keepFrom)
            } else {
                latencyHistory.removeAll(keepingCapacity: true)
            }
        }
        if latencyHistory.count > historyHardCap {
            latencyHistory.removeFirst(latencyHistory.count - historyHardCap)
        }
    }

    static func formatLatency(milliseconds: Double) -> String {
        if milliseconds < 1 {
            return String(format: "%.3f ms", milliseconds)
        }
        if milliseconds < 10 {
            return String(format: "%.2f ms", milliseconds)
        }
        return String(format: "%.1f ms", milliseconds)
    }

    static func latencyDisplay(_ milliseconds: Double?) -> String {
        guard let milliseconds = milliseconds else { return "-" }
        return formatLatency(milliseconds: milliseconds)
    }

    // Convenience accessor for display name, which is always the targetValue
    var displayName: String {
        return targetValue
    }
}
