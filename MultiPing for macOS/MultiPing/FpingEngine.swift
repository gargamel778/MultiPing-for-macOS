import Foundation

struct FpingTarget {
    let id: UUID
    let value: String
    let type: TargetType
}

struct FpingProbeResult {
    let responseTime: String
    let isSuccessful: Bool
    let latencyMilliseconds: Double?
}

enum FpingEngineError: LocalizedError {
    case bundledExecutableMissing
    case bundledExecutableNotExecutable(String)
    case failedToStart(String)
    case fatalOutput(String)

    var errorDescription: String? {
        switch self {
        case .bundledExecutableMissing:
            return "The bundled fping engine is missing. Please reinstall MultiPing from a complete app package."
        case .bundledExecutableNotExecutable(let path):
            return "The bundled fping engine is not executable at \(path). Please reinstall MultiPing from a complete app package."
        case .failedToStart(let message):
            return "The bundled fping engine failed to start: \(message)"
        case .fatalOutput(let output):
            return "The bundled fping engine returned a fatal error: \(output)"
        }
    }
}

/// Continuous, streaming ICMP engine. Rather than one blocking round per interval
/// (where a single slow/down host stalls everyone), it runs a long-lived
/// `fping -l` loop per address family that pings each host every `interval` and
/// emits each host's result independently as it arrives — so the display updates
/// at the set interval regardless of any host's latency or timeouts.
final class FpingEngine {
    private enum AddressFamily { case ipv4, ipv6 }

    private var processes: [Process] = []

    /// Start streaming. `onResult` fires on the main thread per host result;
    /// `onFatal` fires for a fatal engine error (e.g. socket creation failure).
    func start(
        targets: [FpingTarget],
        timeoutMs: Int,
        packetSize: Int,
        dscp: Int,
        intervalMs: Int,
        onResult: @escaping (UUID, FpingProbeResult) -> Void,
        onFatal: @escaping (String) -> Void
    ) throws {
        stop()
        guard !targets.isEmpty else { return }
        let executableURL = try bundledExecutableURL()

        var idsByValue: [String: [UUID]] = [:]
        for target in targets { idsByValue[target.value, default: []].append(target.id) }

        let ipv6 = targets.filter { $0.type == .ipv6 }
        let ipv4 = targets.filter { $0.type != .ipv6 }

        if !ipv4.isEmpty {
            try spawn(executableURL: executableURL, family: .ipv4, targets: ipv4, timeoutMs: timeoutMs,
                      packetSize: packetSize, dscp: dscp, intervalMs: intervalMs,
                      idsByValue: idsByValue, onResult: onResult, onFatal: onFatal)
        }
        if !ipv6.isEmpty {
            try spawn(executableURL: executableURL, family: .ipv6, targets: ipv6, timeoutMs: timeoutMs,
                      packetSize: packetSize, dscp: dscp, intervalMs: intervalMs,
                      idsByValue: idsByValue, onResult: onResult, onFatal: onFatal)
        }
    }

    func stop() {
        for process in processes {
            if let pipe = process.standardOutput as? Pipe {
                pipe.fileHandleForReading.readabilityHandler = nil
            }
            if process.isRunning { process.terminate() }
        }
        processes.removeAll()
    }

    deinit { stop() }

    private func spawn(
        executableURL: URL,
        family: AddressFamily,
        targets: [FpingTarget],
        timeoutMs: Int,
        packetSize: Int,
        dscp: Int,
        intervalMs: Int,
        idsByValue: [String: [UUID]],
        onResult: @escaping (UUID, FpingProbeResult) -> Void,
        onFatal: @escaping (String) -> Void
    ) throws {
        let safeTimeout = max(1, timeoutMs)
        let safePeriod = max(10, intervalMs)      // loop period between pings to a target
        let safeSize = max(0, packetSize)
        let safeDscp = min(63, max(0, dscp))

        var arguments = [
            family == .ipv6 ? "-6" : "-4",
            "-l",                       // loop indefinitely
            "-p", String(safePeriod),   // interval between pings to each target
            "-t", String(safeTimeout),  // per-ping timeout
            "-i", "1",                  // 1 ms between successive targets
            "-b", String(safeSize),
            "-f", "-"
        ]
        if safeDscp > 0 {
            arguments.insert(contentsOf: ["-O", String(safeDscp << 2)], at: arguments.count - 2)
        }

        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe

        // Read streamed output line by line off the main thread, dispatching each
        // parsed result back to the main thread.
        var buffer = Data()
        let readHandle = outputPipe.fileHandleForReading
        readHandle.readabilityHandler = { fileHandle in
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                FpingEngine.dispatch(line: line, idsByValue: idsByValue, onResult: onResult, onFatal: onFatal)
            }
        }

        do {
            try process.run()
            let input = targets.map(\.value).joined(separator: "\n") + "\n"
            if let data = input.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            try? inputPipe.fileHandleForWriting.close()
        } catch {
            readHandle.readabilityHandler = nil
            throw FpingEngineError.failedToStart(error.localizedDescription)
        }

        processes.append(process)
    }

    private static func dispatch(
        line: String,
        idsByValue: [String: [UUID]],
        onResult: @escaping (UUID, FpingProbeResult) -> Void,
        onFatal: @escaping (String) -> Void
    ) {
        if let fatal = fatalMessage(from: line) {
            DispatchQueue.main.async { onFatal(fatal) }
            return
        }
        guard let parsed = parseStreamLine(line),
              let ids = idsByValue[parsed.host], !ids.isEmpty else { return }
        let result = parsed.result
        DispatchQueue.main.async { for id in ids { onResult(id, result) } }
    }

    // MARK: - Parsing

    /// Parses one streamed fping line into (host, result). Handles reply lines
    /// (`host : [n], 64 bytes, 1.23 ms (...)`), timeouts (`host : [n], timed out`),
    /// and name-resolution failures (`host: ... not known`).
    static func parseStreamLine(_ line: String) -> (host: String, result: FpingProbeResult)? {
        if let separator = line.range(of: #"\s+:\s+\["#, options: .regularExpression) {
            let host = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return nil }
            let afterSeq = line[separator.upperBound...]
            guard let closeBracket = afterSeq.range(of: "], ") else { return nil }
            let rest = String(afterSeq[closeBracket.upperBound...])

            if rest.hasPrefix("timed out") || rest.contains("unreachable") {
                return (host, FpingProbeResult(responseTime: "Timeout", isSuccessful: false, latencyMilliseconds: nil))
            }
            if let msRange = rest.range(of: #"[0-9]+(\.[0-9]+)?(?= ms)"#, options: .regularExpression),
               let ms = Double(rest[msRange]) {
                return (host, FpingProbeResult(
                    responseTime: PingResult.formatLatency(milliseconds: ms),
                    isSuccessful: true,
                    latencyMilliseconds: ms
                ))
            }
            return (host, FpingProbeResult(responseTime: "Failed", isSuccessful: false, latencyMilliseconds: nil))
        }

        // Name-resolution failure (printed once at startup for a bad hostname).
        if line.contains("not known") || line.contains("Name or service") || line.contains("resolve") {
            if let colon = line.firstIndex(of: ":") {
                let host = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !host.isEmpty {
                    return (host, FpingProbeResult(responseTime: "Host unknown", isSuccessful: false, latencyMilliseconds: nil))
                }
            }
        }
        return nil
    }

    private static func fatalMessage(from line: String) -> String? {
        let lower = line.lowercased()
        let patterns = ["can't create socket", "cannot create socket", "must run as root", "usage:"]
        guard patterns.contains(where: { lower.contains($0) }) else { return nil }
        return line
    }

    private func bundledExecutableURL() throws -> URL {
        let bundle = Bundle.main
        let candidates = [
            bundle.url(forResource: "fping", withExtension: nil),
            bundle.resourceURL?.appendingPathComponent("fping"),
            bundle.resourceURL?.appendingPathComponent("Resources/fping")
        ].compactMap { $0 }

        guard let executableURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw FpingEngineError.bundledExecutableMissing
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw FpingEngineError.bundledExecutableNotExecutable(executableURL.path)
        }
        return executableURL
    }
}
