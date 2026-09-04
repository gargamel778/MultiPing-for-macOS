import SwiftUI
import AppKit

// MARK: - Model

/// Backing store for the multi-host graph window: the hosts being graphed and
/// the subset the user has hidden via the legend. Shared/reused by the presenter
/// so re-opening with a new selection updates the same window.
@MainActor
final class MultiGraphModel: ObservableObject {
    @Published var results: [PingResult] = []
    @Published var hidden: Set<UUID> = []
}

// MARK: - Renderer

/// Draws several targets as distinctly colored latency lines on one plot, with a
/// neutral grid and a shared auto-scaled y-axis. Packet-loss bands are omitted
/// here (they would overlap across hosts); per-host loss is shown in the legend.
struct MultiLatencyGraphRenderer {
    struct Series {
        let samples: [LatencySample]
        let color: Color
    }

    let series: [Series]
    let window: LatencyGraphWindow

    private let leftInset: CGFloat = 54
    private let rightInset: CGFloat = 12
    private let topInset: CGFloat = 12
    private let bottomInset: CGFloat = 26
    private let axisFontSize: CGFloat = 12

    private struct Column {
        var sum: Double = 0
        var count: Int = 0
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
        context.fill(Path(plot), with: .color(LatencyGraphPalette.plotBackground))

        let duration = window.duration
        let tEnd = now.timeIntervalSince1970
        let tStart = tEnd - duration
        let columnCount = max(1, Int(plot.width.rounded()))

        // Bucket each series into pixel columns; keep in-window samples for the
        // per-host loss lanes; track the global max for scaling.
        var perSeriesColumns: [[Column]] = []
        var perSeriesWindowSamples: [[LatencySample]] = []
        var globalMax = 0.0
        for singleSeries in series {
            var columns = [Column](repeating: Column(), count: columnCount)
            var windowSamples: [LatencySample] = []
            for sample in singleSeries.samples {
                let t = sample.time.timeIntervalSince1970
                guard t >= tStart, t <= tEnd else { continue }
                windowSamples.append(sample)
                var index = Int(((t - tStart) / duration) * Double(columnCount))
                if index < 0 { index = 0 }
                if index >= columnCount { index = columnCount - 1 }
                if let latency = sample.latencyMs {
                    columns[index].sum += latency
                    columns[index].count += 1
                    columns[index].hasSuccess = true
                    globalMax = max(globalMax, latency)
                } else {
                    columns[index].hasLoss = true
                }
            }
            perSeriesColumns.append(columns)
            perSeriesWindowSamples.append(windowSamples)
        }

        let (yMax, yStep) = LatencyGraphRenderer.niceAxis(forMax: globalMax)

        // Reserve a strip at the bottom for one packet-loss lane per host, so an
        // unreachable host still shows a red block without its band covering the
        // other hosts' latency lines.
        let stripTopPad: CGFloat = 6
        let hostCount = series.count
        let desiredStrip = hostCount > 0 ? stripTopPad + CGFloat(hostCount) * 7 : 0
        let stripHeight = min(desiredStrip, plot.height * 0.4)
        let lineBottom = plot.maxY - stripHeight   // y where latency 0 sits

        func xFor(column index: Int) -> CGFloat {
            plot.minX + (CGFloat(index) + 0.5) / CGFloat(columnCount) * plot.width
        }
        func xFor(epoch t: Double) -> CGFloat {
            plot.minX + CGFloat((t - tStart) / duration) * plot.width
        }
        func yFor(_ latency: Double) -> CGFloat {
            lineBottom - CGFloat(min(latency, yMax) / yMax) * (lineBottom - plot.minY)
        }

        // Horizontal grid + y labels.
        var value = 0.0
        while value <= yMax + 0.0001 {
            let y = yFor(value)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(LatencyGraphPalette.neutralGrid), lineWidth: 0.5)
            context.draw(
                Text(LatencyGraphRenderer.formatLatencyAxis(value))
                    .font(.system(size: axisFontSize, design: .monospaced))
                    .foregroundColor(LatencyGraphPalette.neutralAxisText),
                at: CGPoint(x: plot.minX - 6, y: y),
                anchor: .trailing
            )
            value += yStep
        }

        // Vertical grid + time labels.
        let tick = window.tickInterval
        var tickTime = (floor(tStart / tick) + 1) * tick
        while tickTime <= tEnd + 0.001 {
            let x = xFor(epoch: tickTime)
            if x >= plot.minX - 0.5 {
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(LatencyGraphPalette.neutralGrid), lineWidth: 0.5)
                context.draw(
                    Text(window.tickLabel(for: Date(timeIntervalSince1970: tickTime), formatter: formatter))
                        .font(.system(size: axisFontSize, design: .monospaced))
                        .foregroundColor(LatencyGraphPalette.neutralAxisText),
                    at: CGPoint(x: x, y: plot.maxY + 5),
                    anchor: .top
                )
            }
            tickTime += tick
        }

        // Each series as its own colored line (outages break the line; the most
        // recent value is held out to the right edge).
        for (seriesIndex, columns) in perSeriesColumns.enumerated() {
            let color = series[seriesIndex].color
            let seriesSamples = perSeriesWindowSamples[seriesIndex]
            let spacing = medianSpacing(of: seriesSamples)
            let gapThresholdSeconds = 4 * spacing

            // Vertices (success columns), noting an outage since the previous one.
            var vertices: [(column: Int, point: CGPoint, lossBefore: Bool)] = []
            var lossPending = false
            for index in 0..<columnCount {
                if columns[index].hasSuccess {
                    vertices.append((index, CGPoint(x: xFor(column: index), y: yFor(columns[index].average)), lossPending))
                    lossPending = false
                } else if columns[index].hasLoss {
                    lossPending = true
                }
            }
            func gapSeconds(_ from: Int, _ to: Int) -> Double { Double(to - from) / Double(columnCount) * duration }

            // Break on outages or on a local spike (a gap much larger than both
            // neighbours) — an interval change is a sustained change, not a spike.
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
            // Hold to the right edge only while the host is still reporting (based
            // on the recent spacing, robust to a changed interval).
            if let lastPoint = current.last {
                let newestSampleTime = seriesSamples.last?.time.timeIntervalSince1970 ?? -.greatestFiniteMagnitude
                if tEnd - newestSampleTime <= 2.5 * trailingSpacing(of: seriesSamples), lastPoint.x < plot.maxX {
                    current.append(CGPoint(x: plot.maxX, y: lastPoint.y))
                }
                segments.append(current)
            }

            // Enter from the left edge at the interpolated value (matches the
            // single-host graph), so scrolling out is smooth, not a snap.
            if let priorSample = series[seriesIndex].samples.last(where: { $0.time.timeIntervalSince1970 < tStart && $0.latencyMs != nil }),
               let priorLatency = priorSample.latencyMs,
               let firstInWindow = seriesSamples.first(where: { $0.latencyMs != nil }),
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
                if points.count == 1 {
                    let dot = CGRect(x: points[0].x - 1.5, y: points[0].y - 1.5, width: 3, height: 3)
                    context.fill(Path(ellipseIn: dot), with: .color(color))
                } else if points.count > 1 {
                    var line = Path()
                    line.addLines(points)
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }

        // Per-host packet-loss lanes: one thin lane per host in the bottom strip,
        // red where that host had loss. A fully-unreachable host shows a solid red
        // lane. A host-colored tick in the left margin identifies each lane.
        if stripHeight > 0 {
            var separator = Path()
            separator.move(to: CGPoint(x: plot.minX, y: lineBottom))
            separator.addLine(to: CGPoint(x: plot.maxX, y: lineBottom))
            context.stroke(separator, with: .color(LatencyGraphPalette.neutralGrid), lineWidth: 0.5)

            let laneStep = (stripHeight - stripTopPad) / CGFloat(max(1, hostCount))
            let laneHeight = max(2, laneStep - 2)

            for (seriesIndex, windowSamples) in perSeriesWindowSamples.enumerated() {
                let laneY = lineBottom + stripTopPad + CGFloat(seriesIndex) * laneStep
                let tick = CGRect(x: plot.minX - 10, y: laneY, width: 6, height: laneHeight)
                context.fill(Path(tick), with: .color(series[seriesIndex].color))

                guard !windowSamples.isEmpty else { continue }
                let spacing = medianSpacing(of: windowSamples)
                let hasPriorData = series[seriesIndex].samples.contains { $0.time.timeIntervalSince1970 < tStart }
                var sampleIndex = 0
                while sampleIndex < windowSamples.count {
                    guard windowSamples[sampleIndex].latencyMs == nil else {
                        sampleIndex += 1
                        continue
                    }
                    let runStartIndex = sampleIndex
                    let runStart = windowSamples[sampleIndex].time.timeIntervalSince1970
                    var runEnd = runStart
                    while sampleIndex < windowSamples.count && windowSamples[sampleIndex].latencyMs == nil {
                        runEnd = windowSamples[sampleIndex].time.timeIntervalSince1970
                        sampleIndex += 1
                    }
                    let ongoing = (sampleIndex >= windowSamples.count)
                    let startsAtWindowEdge = (runStartIndex == 0 && hasPriorData)
                    let left = startsAtWindowEdge ? plot.minX : max(plot.minX, xFor(epoch: runStart - spacing / 2))
                    let right = ongoing ? plot.maxX : min(plot.maxX, xFor(epoch: runEnd + spacing / 2))
                    guard right > left else { continue }
                    let rect = CGRect(x: left, y: laneY, width: max(1, right - left), height: laneHeight)
                    context.fill(Path(rect), with: .color(LatencyGraphPalette.loss))
                }
            }
        }

        context.stroke(Path(plot), with: .color(LatencyGraphPalette.neutralGrid.opacity(1.6)), lineWidth: 0.75)
        context.draw(
            Text("ms").font(.system(size: axisFontSize, design: .monospaced)).foregroundColor(LatencyGraphPalette.neutralAxisText),
            at: CGPoint(x: plot.minX - 6, y: plot.minY - 3),
            anchor: .bottomTrailing
        )

        if series.isEmpty {
            context.draw(
                Text("No hosts to show — select rows and reopen, or un-hide from the legend.")
                    .font(.system(size: 11)).foregroundColor(LatencyGraphPalette.neutralAxisText),
                at: CGPoint(x: plot.midX, y: plot.midY), anchor: .center
            )
        } else if globalMax == 0 {
            context.draw(
                Text("Waiting for data…").font(.system(size: 11)).foregroundColor(LatencyGraphPalette.neutralAxisText.opacity(0.8)),
                at: CGPoint(x: plot.midX, y: plot.midY), anchor: .center
            )
        }
    }

    /// Spacing of the most recent samples (current ping rate), for the right-edge
    /// "still live?" check — robust to a changed interval.
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

    /// Typical probe spacing in the window, used to size loss lanes so a single
    /// dropped probe still shows a visible block and consecutive drops merge.
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
}

// MARK: - Legend chip

/// One legend entry. Clicking toggles that host's visibility on the graph.
struct MultiLegendChip: View {
    @ObservedObject var result: PingResult
    let color: Color
    let isHidden: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .opacity(isHidden ? 0.25 : 1)
                Text(result.displayName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .strikethrough(isHidden)
                    .foregroundColor(isHidden ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(PingResult.latencyDisplay(result.currentLatencyMs))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(isHidden ? 0.15 : 0.55), lineWidth: 1))
            .opacity(isHidden ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .help(isHidden ? "Click to show \(result.displayName)" : "Click to hide \(result.displayName)")
    }
}

// MARK: - Multi-host graph view

/// Floating window content: the time-window picker, the multi-series graph, and
/// a clickable legend for showing/hiding individual hosts.
struct MultiLatencyGraphView: View {
    @ObservedObject var model: MultiGraphModel
    // This window's own live selection, seeded from / saved to the per-type default.
    @State private var windowRaw: String = LatencyGraphWindowKey.stored(LatencyGraphWindowKey.multi)

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var window: LatencyGraphWindow {
        LatencyGraphWindow(rawValue: windowRaw) ?? .fiveMinutes
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            TimelineView(.periodic(from: Date(), by: window.redrawInterval)) { timeline in
                Canvas { context, size in
                    var mutableContext = context
                    let visibleSeries: [MultiLatencyGraphRenderer.Series] = model.results.enumerated().compactMap { index, result in
                        guard !model.hidden.contains(result.id) else { return nil }
                        return MultiLatencyGraphRenderer.Series(
                            samples: result.latencyHistory,
                            color: LatencyGraphPalette.seriesColor(index)
                        )
                    }
                    MultiLatencyGraphRenderer(series: visibleSeries, window: window)
                        .render(into: &mutableContext, size: size, now: timeline.date, formatter: Self.dateFormatter)
                }
                .background(LatencyGraphPalette.plotBackground)
            }

            legend
        }
        .frame(minWidth: 540, minHeight: 380)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("Multi-Host Latency")
                .font(.system(size: 13, weight: .semibold))
            Text("\(model.results.count - model.hidden.count)/\(model.results.count) shown")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            Picker("", selection: Binding(get: { window }, set: { newValue in
                windowRaw = newValue.rawValue
                UserDefaults.standard.set(newValue.rawValue, forKey: LatencyGraphWindowKey.multi)
            })) {
                ForEach(LatencyGraphWindow.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
            .labelsHidden()
            .help("Time window shown on the graph")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var legend: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 6) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                    MultiLegendChip(
                        result: result,
                        color: LatencyGraphPalette.seriesColor(index),
                        isHidden: model.hidden.contains(result.id),
                        onToggle: {
                            if model.hidden.contains(result.id) {
                                model.hidden.remove(result.id)
                            } else {
                                model.hidden.insert(result.id)
                            }
                        }
                    )
                }
            }
            .padding(8)
        }
        .frame(minHeight: 44, maxHeight: 110)
        .background(.bar)
    }
}

// MARK: - Presenter

/// Opens (and reuses) a single floating multi-host graph window. Re-invoking with
/// a new selection re-populates the same window.
@MainActor
final class MultiLatencyGraphPresenter: NSObject, NSWindowDelegate {
    static let shared = MultiLatencyGraphPresenter()

    private let model = MultiGraphModel()
    private var window: NSWindow?

    func show(results: [PingResult]) {
        model.results = results
        // Drop any hidden ids that are no longer part of the shown set.
        let ids = Set(results.map(\.id))
        model.hidden = model.hidden.intersection(ids)

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: MultiLatencyGraphView(model: model))
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Multi-Host Latency"
        newWindow.identifier = NSUserInterfaceItemIdentifier("multi-latency-graph")
        newWindow.contentView = hostingView
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()
        newWindow.setFrameAutosaveName("MultiLatencyGraphWindow")
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
