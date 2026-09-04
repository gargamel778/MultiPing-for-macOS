import SwiftUI
import AppKit

// MARK: - Palette

/// Colors for the latency graph. The plotted latency trace is dark green and
/// the grid / axis lines are light green, drawn on a dark "scope" background.
enum LatencyGraphPalette {
    static let plotBackground = Color(red: 0.04, green: 0.06, blue: 0.04)
    static let trace = Color(red: 0.16, green: 0.55, blue: 0.24)          // dark green line
    static let traceFillTop = Color(red: 0.16, green: 0.55, blue: 0.24).opacity(0.38)
    static let traceFillBottom = Color(red: 0.16, green: 0.55, blue: 0.24).opacity(0.03)
    static let grid = Color(red: 0.56, green: 0.85, blue: 0.55).opacity(0.28)   // light green
    static let axisText = Color(red: 0.62, green: 0.85, blue: 0.62)
    static let loss = Color(red: 0.86, green: 0.24, blue: 0.20)           // packet-loss bars

    /// A more neutral grid used by the multi-host graph, where colored series
    /// carry the meaning and a green grid would clash.
    static let neutralGrid = Color.gray.opacity(0.22)
    static let neutralAxisText = Color.gray

    /// Distinct series colors for the multi-host graph, assigned by index.
    static let series: [Color] = [
        Color(red: 0.36, green: 0.72, blue: 0.36),
        Color(red: 0.30, green: 0.60, blue: 0.98),
        Color(red: 0.95, green: 0.61, blue: 0.16),
        Color(red: 0.85, green: 0.34, blue: 0.86),
        Color(red: 0.93, green: 0.36, blue: 0.32),
        Color(red: 0.20, green: 0.78, blue: 0.76),
        Color(red: 0.95, green: 0.79, blue: 0.20),
        Color(red: 0.60, green: 0.47, blue: 0.90),
        Color(red: 0.62, green: 0.78, blue: 0.30),
        Color(red: 0.95, green: 0.52, blue: 0.70)
    ]

    static func seriesColor(_ index: Int) -> Color { series[index % series.count] }
}

// MARK: - Time window

/// Selectable time window for the latency graph. Each window defines its total
/// span, the spacing of vertical (time) grid lines, how their labels are
/// formatted, and how often the live view redraws its moving right edge.
enum LatencyGraphWindow: String, CaseIterable, Identifiable {
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case sixtyMinutes = "60m"
    case oneDay = "1d"

    var id: String { rawValue }

    /// Total span shown along the x-axis.
    var duration: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .sixtyMinutes: return 60 * 60
        case .oneDay: return 24 * 60 * 60
        }
    }

    /// Spacing between vertical time grid lines.
    /// 1m→15s, 5m→1m, 15m→3m, 60m→5m, 1d→1h.
    var tickInterval: TimeInterval {
        switch self {
        case .oneMinute: return 15
        case .fiveMinutes: return 60
        case .fifteenMinutes: return 3 * 60
        case .sixtyMinutes: return 5 * 60
        case .oneDay: return 60 * 60
        }
    }

    /// How often the live graph re-renders to advance the "now" edge. Chosen so
    /// the time axis moves roughly one pixel per redraw — smooth scrolling rather
    /// than a visible jump each tick. (New samples also force a redraw as they
    /// arrive, at the ping interval.) Assumes an ~800px-wide plot; clamped.
    var redrawInterval: TimeInterval {
        min(max(duration / 800.0, 0.05), 5.0)
    }

    private var tickDateFormat: String {
        switch self {
        case .oneMinute, .fiveMinutes, .fifteenMinutes: return "HH:mm:ss"
        case .sixtyMinutes, .oneDay: return "HH:mm"
        }
    }

    func tickLabel(for date: Date, formatter: DateFormatter) -> String {
        formatter.dateFormat = tickDateFormat
        return formatter.string(from: date)
    }
}

// MARK: - Per-window time-window state

/// Time-window persistence for the graphs. Each context (single / embedded /
/// multi) has its own key so they never move together, and each open window
/// keeps its selection in its own @State so two windows of the same context are
/// independent — the key is only used to seed a new window and remember the last
/// choice for the next one.
enum LatencyGraphWindowKey {
    static let single = "LatencyGraphWindowSingleV1"
    static let embedded = "LatencyGraphWindowEmbeddedV1"
    static let multi = "LatencyGraphWindowMultiV1"

    /// Per-host key so each host's single-graph window remembers its own window
    /// across close/reopen.
    static func host(_ target: String) -> String { "LatencyGraphWindow-host-\(target)" }

    /// Seed value for a new window's @State: the last-used window for that key.
    static func stored(_ key: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? LatencyGraphWindow.fiveMinutes.rawValue
    }

    /// A binding that updates the window's own @State and also saves the choice
    /// as the per-type default (without touching other open windows).
    static func binding(_ source: Binding<String>, key: String) -> Binding<String> {
        Binding(get: { source.wrappedValue }, set: { newValue in
            source.wrappedValue = newValue
            UserDefaults.standard.set(newValue, forKey: key)
        })
    }
}

// MARK: - Renderer

/// Draws one target's latency history into a Canvas for a given time window.
/// Samples are bucketed per horizontal pixel column so even a full day of
/// data renders cheaply, while packet-loss columns are painted as red bars.
struct LatencyGraphRenderer {
    let samples: [LatencySample]
    let window: LatencyGraphWindow

    private let leftInset: CGFloat = 54
    private let rightInset: CGFloat = 12
    private let topInset: CGFloat = 12
    private let bottomInset: CGFloat = 26
    private let axisFontSize: CGFloat = 12

    private struct Column {
        var sum: Double = 0
        var count: Int = 0
        var maxLatency: Double = 0
        var hasSuccess = false
        var hasLoss = false
        var average: Double { count > 0 ? sum / Double(count) : 0 }
    }

    func render(into context: inout GraphicsContext, size: CGSize, now: Date, formatter: DateFormatter) {
        let plot = CGRect(
            x: leftInset,
            y: topInset,
            width: max(1, size.width - leftInset - rightInset),
            height: max(1, size.height - topInset - bottomInset)
        )

        // Scope background + frame.
        context.fill(Path(plot), with: .color(LatencyGraphPalette.plotBackground))

        let duration = window.duration
        let tEnd = now.timeIntervalSince1970
        let tStart = tEnd - duration

        // Bucket samples into pixel columns.
        let columnCount = max(1, Int(plot.width.rounded()))
        var columns = [Column](repeating: Column(), count: columnCount)
        var windowMax = 0.0
        var windowSamples: [LatencySample] = []
        for sample in samples {
            let t = sample.time.timeIntervalSince1970
            guard t >= tStart, t <= tEnd else { continue }
            windowSamples.append(sample)
            var index = Int(((t - tStart) / duration) * Double(columnCount))
            if index < 0 { index = 0 }
            if index >= columnCount { index = columnCount - 1 }
            if let latency = sample.latencyMs {
                columns[index].sum += latency
                columns[index].count += 1
                columns[index].maxLatency = max(columns[index].maxLatency, latency)
                columns[index].hasSuccess = true
                windowMax = max(windowMax, latency)
            } else {
                columns[index].hasLoss = true
            }
        }

        // Auto-scale the y-axis to the largest latency in the window, snapped to
        // a "nice" 1/2/5 step so grid labels stay round.
        let (yMax, yStep) = LatencyGraphRenderer.niceAxis(forMax: windowMax)

        func xFor(column index: Int) -> CGFloat {
            plot.minX + (CGFloat(index) + 0.5) / CGFloat(columnCount) * plot.width
        }
        func xFor(epoch t: Double) -> CGFloat {
            plot.minX + CGFloat((t - tStart) / duration) * plot.width
        }
        func yFor(_ latency: Double) -> CGFloat {
            plot.maxY - CGFloat(min(latency, yMax) / yMax) * plot.height
        }

        // Horizontal grid lines + y-axis labels (latency in ms).
        var value = 0.0
        while value <= yMax + 0.0001 {
            let y = yFor(value)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(LatencyGraphPalette.grid), lineWidth: 0.5)
            context.draw(
                Text(LatencyGraphRenderer.formatLatencyAxis(value)).font(.system(size: axisFontSize, design: .monospaced))
                    .foregroundColor(LatencyGraphPalette.axisText),
                at: CGPoint(x: plot.minX - 6, y: y),
                anchor: .trailing
            )
            value += yStep
        }

        // Vertical grid lines + x-axis time labels, aligned to clock boundaries.
        let tick = window.tickInterval
        var tickTime = (floor(tStart / tick) + 1) * tick
        while tickTime <= tEnd + 0.001 {
            let x = xFor(epoch: tickTime)
            if x >= plot.minX - 0.5 {
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(LatencyGraphPalette.grid), lineWidth: 0.5)
                context.draw(
                    Text(window.tickLabel(for: Date(timeIntervalSince1970: tickTime), formatter: formatter))
                        .font(.system(size: axisFontSize, design: .monospaced))
                        .foregroundColor(LatencyGraphPalette.axisText),
                    at: CGPoint(x: x, y: plot.maxY + 5),
                    anchor: .top
                )
            }
            tickTime += tick
        }

        // Packet-loss bars: paint a red band spanning the duration of each run
        // of consecutive failed probes. The width comes from the probe spacing,
        // so an isolated loss still shows a visible bar and consecutive losses
        // merge into one continuous band.
        let spacing = medianSpacing(of: windowSamples)
        var sampleIndex = 0
        while sampleIndex < windowSamples.count {
            guard windowSamples[sampleIndex].latencyMs == nil else {
                sampleIndex += 1
                continue
            }
            let runStart = windowSamples[sampleIndex].time.timeIntervalSince1970
            var runEnd = runStart
            while sampleIndex < windowSamples.count && windowSamples[sampleIndex].latencyMs == nil {
                runEnd = windowSamples[sampleIndex].time.timeIntervalSince1970
                sampleIndex += 1
            }
            // If this loss run includes the newest sample, the outage is ongoing:
            // extend the band all the way to the right edge ("now").
            let ongoing = (sampleIndex >= windowSamples.count)
            let left = max(plot.minX, xFor(epoch: runStart - spacing / 2))
            let right = ongoing ? plot.maxX : min(plot.maxX, xFor(epoch: runEnd + spacing / 2))
            guard right > left else { continue }
            let rect = CGRect(x: left, y: plot.minY, width: max(1, right - left), height: plot.height)
            context.fill(Path(rect), with: .color(LatencyGraphPalette.loss.opacity(0.5)))
        }

        let gapThresholdSeconds = 4 * spacing

        // Build the drawable vertices (success columns) in order, noting whether
        // an outage (loss column) fell between a vertex and the previous one.
        struct Vertex { let column: Int; let point: CGPoint; let lossBefore: Bool }
        var vertices: [Vertex] = []
        var lossPending = false
        for index in 0..<columnCount {
            if columns[index].hasSuccess {
                vertices.append(Vertex(column: index,
                                       point: CGPoint(x: xFor(column: index), y: yFor(columns[index].average)),
                                       lossBefore: lossPending))
                lossPending = false
            } else if columns[index].hasLoss {
                lossPending = true
            }
        }

        func gapSeconds(_ from: Int, _ to: Int) -> Double { Double(to - from) / Double(columnCount) * duration }

        // Split into segments. Break before a vertex on an outage, or on a gap
        // that is a local *spike* — much larger than the gaps on BOTH sides. That
        // distinguishes a genuine pause/interruption (an isolated large gap) from
        // a change in the ping interval (a sustained change in spacing, which
        // should stay connected as one line).
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        for k in vertices.indices {
            if k > 0 {
                let gap = gapSeconds(vertices[k - 1].column, vertices[k].column)
                let gapBefore = k >= 2 ? gapSeconds(vertices[k - 2].column, vertices[k - 1].column) : gap
                let gapAfter = k + 1 < vertices.count ? gapSeconds(vertices[k].column, vertices[k + 1].column) : gap
                let isSpike = gap > 4 * gapBefore && gap > 4 * gapAfter
                if vertices[k].lossBefore || isSpike {
                    if !current.isEmpty { segments.append(current); current = [] }
                }
            }
            current.append(vertices[k].point)
        }
        // Hold the most recent value out to "now" (the right edge) — but only if
        // the newest sample is recent. A paused (or otherwise stalled) host stops
        // producing samples, so after a beat the line stops extending and a gap
        // opens up to "now" instead of a misleading flat held line. The historical
        // trace stays drawn.
        if let lastPoint = current.last {
            let newestSampleTime = windowSamples.last?.time.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
            if tEnd - newestSampleTime <= 2.5 * trailingSpacing(of: windowSamples), lastPoint.x < plot.maxX {
                current.append(CGPoint(x: plot.maxX, y: lastPoint.y))
            }
            segments.append(current)
        }

        // Enter from the left edge at the value interpolated between the last
        // sample before the window and the first one inside it, so the trace
        // reaches the edge smoothly as data scrolls out — rather than snapping to a
        // flat connector. Skipped across a real gap (e.g. a pause boundary).
        if let priorSample = samples.last(where: { $0.time.timeIntervalSince1970 < tStart && $0.latencyMs != nil }),
           let priorLatency = priorSample.latencyMs,
           let firstInWindow = windowSamples.first(where: { $0.latencyMs != nil }),
           let firstLatency = firstInWindow.latencyMs,
           var firstSegment = segments.first,
           let firstPoint = firstSegment.first,
           firstPoint.x > plot.minX {
            let t0 = priorSample.time.timeIntervalSince1970
            let t1 = firstInWindow.time.timeIntervalSince1970
            if t1 - t0 <= gapThresholdSeconds {
                let fraction = t1 > t0 ? (tStart - t0) / (t1 - t0) : 0
                let valueAtStart = priorLatency + (firstLatency - priorLatency) * fraction
                firstSegment.insert(CGPoint(x: plot.minX, y: yFor(valueAtStart)), at: 0)
                segments[0] = firstSegment
            }
        }

        for points in segments {
            guard let first = points.first, let last = points.last else { continue }

            // Soft area fill under the trace.
            var area = Path()
            area.move(to: CGPoint(x: first.x, y: plot.maxY))
            for point in points { area.addLine(to: point) }
            area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [LatencyGraphPalette.traceFillTop, LatencyGraphPalette.traceFillBottom]),
                    startPoint: CGPoint(x: 0, y: plot.minY),
                    endPoint: CGPoint(x: 0, y: plot.maxY)
                )
            )

            // The trace itself.
            var line = Path()
            line.addLines(points)
            context.stroke(
                line,
                with: .color(LatencyGraphPalette.trace),
                style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
            )

            // Mark isolated single points so they don't vanish.
            if points.count == 1 {
                let dot = CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)
                context.fill(Path(ellipseIn: dot), with: .color(LatencyGraphPalette.trace))
            }
        }

        // Plot frame on top.
        context.stroke(Path(plot), with: .color(LatencyGraphPalette.grid.opacity(1.4)), lineWidth: 0.75)

        // "ms" axis caption.
        context.draw(
            Text("ms").font(.system(size: axisFontSize, design: .monospaced)).foregroundColor(LatencyGraphPalette.axisText),
            at: CGPoint(x: plot.minX - 6, y: plot.minY - 3),
            anchor: .bottomTrailing
        )

        // Empty-state hint.
        if windowMax == 0 && !samples.contains(where: { $0.time.timeIntervalSince1970 >= tStart }) {
            context.draw(
                Text("Waiting for data…").font(.system(size: 11)).foregroundColor(LatencyGraphPalette.axisText.opacity(0.7)),
                at: CGPoint(x: plot.midX, y: plot.midY),
                anchor: .center
            )
        }
    }

    /// Snap an axis maximum up to a round 1/2/5 × 10ⁿ value and pick a matching
    /// grid step that yields ~4–6 lines. Shared with the multi-host graph.
    static func niceAxis(forMax rawMax: Double) -> (max: Double, step: Double) {
        guard rawMax > 0 else { return (10, 2) }
        let step = niceNumber(rawMax / 5)
        let maxValue = max(step, (rawMax / step).rounded(.up) * step)
        return (maxValue, step)
    }

    /// Spacing of the most recent samples (current ping rate), used to decide
    /// whether the trace is still "live" at the right edge — robust to a changed
    /// ping interval, unlike the whole-window median.
    private func trailingSpacing(of samples: [LatencySample]) -> Double {
        guard samples.count >= 2 else { return window.duration / 120 }
        var diffs: [Double] = []
        var index = samples.count - 1
        while index > 0 && diffs.count < 6 {
            let delta = samples[index].time.timeIntervalSince1970 - samples[index - 1].time.timeIntervalSince1970
            if delta > 0 { diffs.append(delta) }
            index -= 1
        }
        guard !diffs.isEmpty else { return window.duration / 120 }
        diffs.sort()
        return diffs[diffs.count / 2]
    }

    /// Typical spacing between consecutive probes in the window, used to size
    /// packet-loss bars. Falls back to a small fraction of the window when there
    /// are too few samples to measure.
    private func medianSpacing(of samples: [LatencySample]) -> Double {
        guard samples.count >= 2 else { return window.duration / 120 }
        var diffs: [Double] = []
        diffs.reserveCapacity(samples.count - 1)
        for index in 1..<samples.count {
            let delta = samples[index].time.timeIntervalSince1970 - samples[index - 1].time.timeIntervalSince1970
            if delta > 0 { diffs.append(delta) }
        }
        guard !diffs.isEmpty else { return window.duration / 120 }
        diffs.sort()
        return diffs[diffs.count / 2]
    }

    static func niceNumber(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let fraction = value / pow(10, exponent)
        let niceFraction: Double
        if fraction <= 1 { niceFraction = 1 }
        else if fraction <= 2 { niceFraction = 2 }
        else if fraction <= 5 { niceFraction = 5 }
        else { niceFraction = 10 }
        return niceFraction * pow(10, exponent)
    }

    static func formatLatencyAxis(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value < 1 { return String(format: "%.2f", value) }
        if value < 10 { return String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }
}

// MARK: - Shared graph views

/// The live graph body shared by the floating window and the embedded pane: a
/// compact stats bar (including the windowed packet-loss count) above the Canvas.
/// One `TimelineView` clock drives both the moving right edge and the
/// windowed-loss readout so they stay in sync.
struct LatencyGraphView: View {
    @ObservedObject var result: PingResult
    let window: LatencyGraphWindow
    var compact: Bool = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: Date(), by: window.redrawInterval)) { timeline in
            VStack(spacing: 0) {
                statsBar(now: timeline.date)
                Canvas { context, size in
                    var mutableContext = context
                    LatencyGraphRenderer(samples: result.latencyHistory, window: window)
                        .render(into: &mutableContext, size: size, now: timeline.date, formatter: Self.dateFormatter)
                }
                .background(LatencyGraphPalette.plotBackground)
            }
        }
    }

    private func statsBar(now: Date) -> some View {
        let windowed = result.windowStats(since: now.addingTimeInterval(-window.duration))
        let lossPercent = windowed.total > 0 ? Double(windowed.lost) / Double(windowed.total) * 100 : 0
        return HStack(spacing: compact ? 10 : 16) {
            stat("Current", result.currentLatencyMs)
            stat("Avg", result.averageLatencyMs)
            stat("Min", result.minimumLatencyMs)
            stat("Max", result.maximumLatencyMs)
            Spacer()
            // Packets lost within the currently shown time window (request #2).
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 9)).foregroundColor(.secondary)
                Text("Lost \(window.rawValue):").font(.system(size: 11)).foregroundColor(.secondary)
                Text("\(windowed.lost)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(windowed.lost > 0 ? ResultStatusPalette.red : ResultStatusPalette.green)
                Text("/ \(windowed.total)")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                if windowed.lost > 0 {
                    Text(String(format: "(%.0f%%)", lossPercent))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ResultStatusPalette.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 3 : 5)
        .background(.bar)
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Text(PingResult.latencyDisplay(value))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}

/// Title bar with the target name/note and the time-window picker. The embedded
/// pane also gets a collapse chevron and a "pop out to a window" button.
struct LatencyGraphTitleBar: View {
    @ObservedObject var result: PingResult
    @Binding var windowRaw: String
    var compact: Bool = false
    var collapsed: Binding<Bool>? = nil
    var onPopOut: (() -> Void)? = nil

    private var window: LatencyGraphWindow {
        LatencyGraphWindow(rawValue: windowRaw) ?? .fiveMinutes
    }

    var body: some View {
        HStack(spacing: 8) {
            if let collapsed {
                Button {
                    collapsed.wrappedValue.toggle()
                } label: {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(collapsed.wrappedValue ? "Show graph" : "Hide graph")
            }

            Text(result.displayName)
                .font(.system(size: compact ? 12 : 14, weight: .semibold, design: .monospaced))
                .foregroundColor(ResultStatusPalette.swiftColor(for: result))
                .lineLimit(1)
            if let note = result.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: compact ? 10 : 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Picker("", selection: Binding(get: { window }, set: { windowRaw = $0.rawValue })) {
                ForEach(LatencyGraphWindow.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: compact ? 210 : 230)
            .labelsHidden()
            .help("Time window shown on the graph")

            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Open this graph in a separate window")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 5 : 8)
        .background(.bar)
    }
}

/// Content of the free-floating per-target graph window (opened by double-click
/// in List view or clicking a card's chart glyph in Grid view).
struct LatencyGraphContainerView: View {
    @ObservedObject var result: PingResult
    // This window's own live selection, keyed per host so each host remembers
    // its last window across close/reopen.
    @State private var windowRaw: String
    private let windowKey: String

    init(result: PingResult) {
        _result = ObservedObject(wrappedValue: result)
        let key = LatencyGraphWindowKey.host(result.targetValue)
        self.windowKey = key
        _windowRaw = State(initialValue: LatencyGraphWindowKey.stored(key))
    }

    private var window: LatencyGraphWindow {
        LatencyGraphWindow(rawValue: windowRaw) ?? .fiveMinutes
    }

    var body: some View {
        VStack(spacing: 0) {
            LatencyGraphTitleBar(result: result, windowRaw: LatencyGraphWindowKey.binding($windowRaw, key: windowKey))
            LatencyGraphView(result: result, window: window)
        }
        .frame(minWidth: 480, minHeight: 300)
    }
}

/// Compact latency graph embedded at the bottom of the results window, showing
/// the currently selected target. Collapsible, with its own independent
/// time-window selection.
struct EmbeddedLatencyGraphView: View {
    @ObservedObject var result: PingResult
    /// Height of the graph body (below the title/stats bars). The container
    /// owns and persists this so the pane can be drag-resized.
    var graphBodyHeight: CGFloat = 250
    // This pane's own live selection (per results window). Seeded from / saved
    // to the per-type default.
    @State private var windowRaw: String = LatencyGraphWindowKey.stored(LatencyGraphWindowKey.embedded)
    @AppStorage("LatencyGraphEmbeddedCollapsedV1") private var collapsed: Bool = false

    private var window: LatencyGraphWindow {
        LatencyGraphWindow(rawValue: windowRaw) ?? .fiveMinutes
    }

    var body: some View {
        VStack(spacing: 0) {
            LatencyGraphTitleBar(
                result: result,
                windowRaw: LatencyGraphWindowKey.binding($windowRaw, key: LatencyGraphWindowKey.embedded),
                compact: true,
                collapsed: $collapsed,
                onPopOut: { LatencyGraphPresenter.shared.show(result: result) }
            )
            if !collapsed {
                LatencyGraphView(result: result, window: window, compact: true)
                    .frame(height: graphBodyHeight)
            }
        }
    }
}

// MARK: - Window presenter

/// Opens and tracks one independent latency-graph window per target. The
/// windows are deliberately *not* "relevant" windows (see AppDelegate), so
/// closing them never stops an active ping session.
@MainActor
final class LatencyGraphPresenter: NSObject, NSWindowDelegate {
    static let shared = LatencyGraphPresenter()

    private var windowsByTarget: [UUID: NSWindow] = [:]
    private var targetByWindow: [ObjectIdentifier: UUID] = [:]

    func show(result: PingResult) {
        if let existing = windowsByTarget[result.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: LatencyGraphContainerView(result: result))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Latency — \(result.displayName)"
        window.identifier = NSUserInterfaceItemIdentifier("latency-graph-\(result.id.uuidString)")
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("LatencyGraphWindow-\(result.id.uuidString)")
        if window.frame.origin == .zero { window.center() }

        windowsByTarget[result.id] = window
        targetByWindow[ObjectIdentifier(window)] = result.id
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let targetID = targetByWindow[ObjectIdentifier(window)] else { return }
        windowsByTarget.removeValue(forKey: targetID)
        targetByWindow.removeValue(forKey: ObjectIdentifier(window))
    }
}
