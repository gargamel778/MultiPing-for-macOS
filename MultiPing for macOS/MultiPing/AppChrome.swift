import SwiftUI
import AppKit

// MARK: - Host actions (context menu)

/// Actions available from a host's right-click menu. All run on the main thread
/// (invoked from menu handlers) and operate on the host's target value.
enum HostActions {
    private static func lastSSHUserKey() -> String { "SSHUsername-last" }
    private static func sshUserKey(_ host: String) -> String { "SSHUsername-\(host)" }

    /// Bracket IPv6 literals for use in a URL; leave everything else as-is.
    private static func urlHost(for result: PingResult) -> String {
        result.targetType == .ipv6 ? "[\(result.targetValue)]" : result.targetValue
    }

    static func openHTTP(_ result: PingResult) { openWeb(scheme: "http", result) }
    static func openHTTPS(_ result: PingResult) { openWeb(scheme: "https", result) }

    private static func openWeb(scheme: String, _ result: PingResult) {
        guard let url = URL(string: "\(scheme)://\(urlHost(for: result))") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Open an SSH session to the host in iTerm2. Uses a saved username if there
    /// is one; otherwise prompts (with an option to remember it).
    static func openSSH(_ result: PingResult) {
        let host = result.targetValue
        if let saved = UserDefaults.standard.string(forKey: sshUserKey(host)), !saved.isEmpty {
            launchSSH(user: saved, host: host)
        } else {
            promptForUsernameAndConnect(host: host)
        }
    }

    private static func promptForUsernameAndConnect(host: String) {
        let alert = NSAlert()
        alert.messageText = "SSH to \(host)"
        alert.informativeText = "Enter the username for the SSH session in iTerm2."

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 24))
        field.placeholderString = "username"
        field.stringValue = UserDefaults.standard.string(forKey: lastSSHUserKey()) ?? ""
        let remember = NSButton(checkboxWithTitle: "Remember username for this host", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 4, width: 280, height: 20)
        remember.state = .on
        container.addSubview(field)
        container.addSubview(remember)
        alert.accessoryView = container

        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let user = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if remember.state == .on, !user.isEmpty {
            UserDefaults.standard.set(user, forKey: sshUserKey(host))
        }
        if !user.isEmpty {
            UserDefaults.standard.set(user, forKey: lastSSHUserKey())
        }
        launchSSH(user: user, host: host)
    }

    private static func launchSSH(user: String, host: String) {
        let target = user.isEmpty ? host : "\(user)@\(host)"
        // Escape for embedding in the AppleScript string literal.
        let safe = target
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text "ssh \(safe)"
            end tell
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error = error else { return }

        let failure = NSAlert()
        failure.messageText = "Couldn't open SSH in iTerm2"
        let detail = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown error."
        failure.informativeText = "\(detail)\n\nMake sure iTerm2 is installed. If this is the first time, allow MultiPing to control iTerm in System Settings ▸ Privacy & Security ▸ Automation."
        failure.runModal()
    }
}

// MARK: - Closure-based menu item

/// An NSMenuItem that runs a closure when selected — convenient for building
/// dynamic AppKit context menus (e.g. the list view's row menu).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { handler() }
}

/// Builds the shared host action menu items into an NSMenu (list view).
/// Called from the table's `menuNeedsUpdate` on the main thread.
func populateHostMenu(_ menu: NSMenu, for result: PingResult, manager: PingManager) {
    menu.addItem(ClosureMenuItem(title: "Open HTTP") { HostActions.openHTTP(result) })
    menu.addItem(ClosureMenuItem(title: "Open HTTPS") { HostActions.openHTTPS(result) })
    menu.addItem(ClosureMenuItem(title: "Open SSH") { HostActions.openSSH(result) })
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem(title: result.isPaused ? "Resume pinging" : "Pause pinging") {
        manager.setHostPaused(result, paused: !result.isPaused)
    })
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem(title: "Launch port scan…") {
        PortScanPresenter.shared.show(host: result.targetValue)
    })
}

// MARK: - Targets Collector reopening

/// Reopens the "Targets Collector" (target-list editor) after a monitoring
/// session has started. The original app closes that window when pinging begins,
/// leaving no way to edit the list — this brings it back.
@MainActor
final class TargetsCollectorPresenter {
    static let shared = TargetsCollectorPresenter()

    func show(manager: PingManager) {
        // Reuse the existing input window if it's still around (the initial
        // SwiftUI scene window, or one we opened earlier). Its identifier is
        // "ip-input"; the AppDelegate manages its delegate/lifecycle.
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "ip-input" }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: IPInputView(manager: manager))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Targets Collector"
        window.identifier = NSUserInterfaceItemIdentifier("ip-input")
        window.contentView = hostingView
        // Keep it allocated after Start-ping closes it, so a later reopen reuses
        // this same window (and its edited-in-progress state).
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Targets Collector Window")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - About window

/// Opens a roomy, scrollable About window. The standard AppKit about panel has a
/// fixed size and clips the longer description / fork text, so we use our own
/// window and reuse it across invocations.
@MainActor
func showMultiPingAboutPanel() {
    let aboutID = NSUserInterfaceItemIdentifier("multiping-about")
    if let existing = NSApp.windows.first(where: { $0.identifier == aboutID }) {
        existing.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 470, height: 580),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false
    )
    window.identifier = aboutID
    window.title = "About MultiPing for macOS"
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: MultiPingAboutView())
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

/// Contents of the About window. Everything lives in a ScrollView so no text is
/// clipped regardless of length or the viewer's text size.
struct MultiPingAboutView: View {
    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty { return "Version \(short) (\(build))" }
        return "Version \(short)"
    }

    private let githubURL = URL(string: "https://github.com/u5f2094ee/MultiPing-for-macOS")!

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 76, height: 76)
                }
                Text("MultiPing for macOS").font(.system(size: 20, weight: .bold))
                Text(versionText).font(.callout).foregroundColor(.secondary)

                Text("A lightweight network monitoring utility for pinging many targets at once — IPv4, IPv6, and domain-name hosts in one session — with live latency, packet-loss, and per-target latency-over-time graphs.\n\nBulk ICMP probing is handled by a bundled fping engine. List and Grid layouts, live filtering, DSCP marking, and CSV / HTML / Excel export are supported.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 2)

                VStack(spacing: 3) {
                    Text("Developed by").font(.caption).foregroundColor(.secondary)
                    Text("Zhang Zheng, Gemini, and Codex").font(.callout.weight(.medium))
                    Link("github.com/u5f2094ee/MultiPing-for-macOS", destination: githubURL).font(.caption)
                }

                Divider().padding(.vertical, 2)

                VStack(spacing: 6) {
                    Text("Fork · v2.0").font(.callout.weight(.semibold))
                    Text("A customized build adding latency-over-time graphs (single, embedded, and multi-host), live-editable probe settings, and a network scanner — Bonjour, local-subnet, and IP-range discovery with MAC address + vendor (OUI) identification and reverse-DNS host naming — plus HTTP / HTTPS / SSH launchers and per-host port scanning.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Menu bar (status item) at-a-glance

/// Open (or bring forward) a Ping Results window for `manager`. Unlike the
/// original opener this attaches no ping-stopping `onDisappear`, so closing the
/// window leaves the session running in the background for the menu-bar view.
@MainActor
func openMultiPingResultsWindow(manager: PingManager, mode: ResultsViewMode = .list) {
    if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "ping-results" }) {
        existing.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
        styleMask: [.titled, .closable, .resizable, .miniaturizable, .unifiedTitleAndToolbar],
        backing: .buffered, defer: false
    )
    // Now that the app survives window close (menu-bar lifecycle), the window must
    // NOT be released while its close animation is still running — that segfaults
    // in -[_NSWindowTransformAnimation dealloc]. Keep it alive (reused via the
    // "ping-results" identifier) and skip the transform animation.
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.center()
    window.setFrameAutosaveName("Ping Results Window - \(mode.rawValue)")
    window.title = "Ping Results"
    window.identifier = NSUserInterfaceItemIdentifier("ping-results")
    window.contentView = NSHostingView(rootView: PingResultsContainerView(manager: manager, initialMode: mode))
    if let appDelegate = NSApp.delegate as? AppDelegate { window.delegate = appDelegate }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

/// The menu-bar "Open MultiPing" action: front an existing window if any, else
/// show the live results (when a session is running) or the Targets Collector.
@MainActor
func openMainMultiPingWindow() {
    // An existing results window wins.
    if let win = NSApp.windows.first(where: { ($0.identifier?.rawValue == "ping-results" || $0.title.starts(with: "Ping Results")) && $0.isVisible }) {
        win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
    }
    // A live session prefers the results view over the collector.
    if let manager = AppDelegate.pingManagerInstance, manager.pingStarted, !manager.results.isEmpty {
        openMultiPingResultsWindow(manager: manager); return
    }
    // Otherwise front the collector, or open it.
    if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "ip-input" }) {
        win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
    }
    if let manager = AppDelegate.pingManagerInstance {
        TargetsCollectorPresenter.shared.show(manager: manager)
    }
}

// MARK: - Menu-bar preferences

/// Sort order for the at-a-glance list. Deliberately separate from the results
/// window's column sorting — the menu-bar view is a quick health check, so
/// "problems first" is often wanted there while the table stays as-is.
/// Raw values are stable codes, NOT display text, so labels can be reworded
/// without invalidating a saved preference (see `migrateSortOrderIfNeeded`).
enum MenuBarSortOrder: String, CaseIterable, Identifiable {
    case asEntered      = "asEntered"
    case name           = "name"
    case ipAddress      = "ipAddress"
    case problems       = "problems"
    case highestLatency = "highestLatency"
    case lowestLatency  = "lowestLatency"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .asEntered:      return "As entered"
        case .name:           return "Name (A–Z)"
        case .ipAddress:      return "IP address"
        case .problems:       return "Problems first"
        case .highestLatency: return "Highest latency"
        case .lowestLatency:  return "Lowest latency"
        }
    }

    /// Orders in which a row keeps its position as latencies change. Only these
    /// get the hover preview — under a latency/status sort the rows reshuffle
    /// under the pointer, so hovering would target a moving row.
    var isStableOrder: Bool {
        switch self {
        case .asEntered, .name, .ipAddress: return true
        case .problems, .highestLatency, .lowestLatency: return false
        }
    }
}

/// Keys + behaviour for the menu-bar preferences (Settings ⌘,).
enum MenuBarPrefs {
    static let showIconKey = "ShowMenuBarIconV1"
    static let menuBarOnlyKey = "MenuBarOnlyModeV1"
    static let showCountsKey = "MenuBarShowCountsV1"
    /// How many host rows the menu-bar view shows before scrolling. 0 = show all
    /// (still capped to the screen height).
    static let visibleRowsKey = "MenuBarVisibleRowsV1"
    static let defaultVisibleRows = 15   // must match one of the picker's tags
    /// Sort order for the at-a-glance list only (the results window keeps its own).
    static let sortOrderKey = "MenuBarSortOrderV1"

    /// The first version of this setting stored display text as its raw value.
    /// Map those onto the stable codes so an existing choice isn't silently lost
    /// when the labels are reworded.
    static func migrateSortOrderIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: sortOrderKey),
              MenuBarSortOrder(rawValue: raw) == nil else { return }
        let legacy: [String: MenuBarSortOrder] = [
            "As entered": .asEntered,
            "Name (A–Z)": .name,
            "Problems first": .problems,
            "Slowest first": .highestLatency,
            "Fastest first": .lowestLatency
        ]
        UserDefaults.standard.set((legacy[raw] ?? .asEntered).rawValue, forKey: sortOrderKey)
    }

    static var showIcon: Bool {
        UserDefaults.standard.object(forKey: showIconKey) as? Bool ?? true
    }
    static var menuBarOnly: Bool {
        UserDefaults.standard.bool(forKey: menuBarOnlyKey)
    }
    /// Counts widen the menu-bar item; on a full menu bar (especially a notched
    /// Mac) a narrower item is likelier to fit, so this can be turned off.
    static var showCounts: Bool {
        UserDefaults.standard.object(forKey: showCountsKey) as? Bool ?? true
    }

    /// Menu-bar-only mode hides the Dock icon. Only honoured while the menu-bar
    /// icon is actually shown — otherwise the app would have no visible entry
    /// point at all.
    @MainActor static func applyActivationPolicy() {
        let accessory = menuBarOnly && showIcon
        NSApp.setActivationPolicy(accessory ? .accessory : .regular)
        if !accessory { NSApp.activate(ignoringOtherApps: false) }
    }

    /// AppKit remembers each status item's slot in `NSStatusItem Preferred
    /// Position <autosaveName>` (SwiftUI's MenuBarExtra item is "Item-0").
    /// SMALLER value = further RIGHT. On a packed menu bar an unseeded item is
    /// placed left of everything — which on a notched Mac means underneath the
    /// notch, invisible. Seeding a sane slot on first run avoids that entirely.
    private static let positionKey = "NSStatusItem Preferred Position Item-0"
    /// Smaller = further right. 0 parks it at the right-hand end of the
    /// third-party items, which is the only slot guaranteed clear of the notch
    /// on a full menu bar.
    private static let defaultPosition = 0.0
    private static let rightmostPosition = 0.0

    /// Give the icon a visible slot the first time the app runs.
    static func seedIconPositionIfNeeded() {
        guard UserDefaults.standard.object(forKey: positionKey) == nil else { return }
        UserDefaults.standard.set(defaultPosition, forKey: positionKey)
    }

    /// Force the icon to the right-hand end of the menu bar, where it can't be
    /// swallowed by the notch. The item only re-reads its slot when it's
    /// recreated, so the caller re-inserts it after this.
    /// Move the icon to the right-hand end of the menu bar, clear of the notch.
    /// Removing a status item *erases* its stored slot, so the new position must
    /// be written while the item is out — hence remove ➝ write ➝ re-insert.
    static func moveIconIntoView() {
        UserDefaults.standard.set(false, forKey: showIconKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            UserDefaults.standard.set(rightmostPosition, forKey: positionKey)
            UserDefaults.standard.set(true, forKey: showIconKey)
        }
    }

    /// Self-heal: if the icon landed behind the notch, move it into view with no
    /// user action at all.
    @MainActor static func autoFixIconVisibility() {
        guard showIcon, iconHiddenBehindNotch() else { return }
        moveIconIntoView()
    }

    /// On a notched Mac a full menu bar pushes the newest status item left, into
    /// the camera-housing gap, where macOS simply doesn't draw it. Detect that so
    /// the UI can explain a "missing" icon instead of leaving the user guessing.
    @MainActor static func iconHiddenBehindNotch() -> Bool {
        guard showIcon,
              let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return false }
        // macOS refuses to draw a status item that overlaps the notch *at all*,
        // so test for any intersection, not just the item's centre.
        for window in NSApp.windows where String(describing: type(of: window)) == "NSStatusBarWindow" {
            let frame = window.frame
            guard frame.origin.y > 0 else { continue }   // parked/off-screen items
            if frame.minX < right.minX && frame.maxX > left.maxX { return true }
        }
        return false
    }
}

/// Settings window (⌘,): menu-bar icon options.
struct MultiPingSettingsView: View {
    @AppStorage(MenuBarPrefs.showIconKey) private var showMenuBarIcon = true
    @AppStorage(MenuBarPrefs.menuBarOnlyKey) private var menuBarOnly = false
    @AppStorage(MenuBarPrefs.showCountsKey) private var showCounts = true
    @AppStorage(MenuBarPrefs.visibleRowsKey) private var visibleRows = MenuBarPrefs.defaultVisibleRows
    @AppStorage(MenuBarPrefs.sortOrderKey) private var sortOrder = MenuBarSortOrder.asEntered
    @State private var hiddenBehindNotch = false

    var body: some View {
        Form {
            Section {
                Toggle("Show icon in the menu bar", isOn: $showMenuBarIcon)
                Toggle("Show reachable / failed counts next to the icon", isOn: $showCounts)
                    .disabled(!showMenuBarIcon)
                Toggle("Menu bar only (hide the Dock icon)", isOn: $menuBarOnly)
                    .disabled(!showMenuBarIcon)

                Picker("Hosts shown at a glance:", selection: $visibleRows) {
                    Text("5 lines").tag(5)
                    Text("10 lines").tag(10)
                    Text("15 lines").tag(15)
                    Text("20 lines").tag(20)
                    Text("30 lines").tag(30)
                    Text("50 lines").tag(50)
                    Divider()
                    Text("Show all").tag(0)
                }
                Picker("Sort at-a-glance list by:", selection: $sortOrder) {
                    ForEach(MenuBarSortOrder.allCases) { Text($0.label).tag($0) }
                }

                Text("These apply to the menu-bar view and the MultiPing Status window only — the results window keeps its own column sorting. Longer lists scroll; \"Show all\" grows to fit the screen.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pings keep running in the background when all windows are closed. The at-a-glance view is also available any time from Window ▸ MultiPing Status (⇧⌘0).")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if hiddenBehindNotch {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text("The icon is sitting behind this Mac's camera notch, where macOS can't draw it — your menu bar is full, so it got pushed into the gap.")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Move icon into view") { moveIconIntoView() }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                }

                Button("Reset icon position (move to the right end)") { moveIconIntoView() }
                    .disabled(!showMenuBarIcon)
            } header: {
                Text("Menu Bar").font(.headline)
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .onAppear { refreshNotchState() }
        .onChange(of: showMenuBarIcon) { newValue in
            if !newValue { menuBarOnly = false }   // never leave the app unreachable
            MenuBarPrefs.applyActivationPolicy()
            refreshNotchState()
        }
        .onChange(of: showCounts) { _ in refreshNotchState() }
        .onChange(of: menuBarOnly) { _ in MenuBarPrefs.applyActivationPolicy() }
    }

    /// Give AppKit a moment to lay the item out before measuring it.
    private func refreshNotchState() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            hiddenBehindNotch = MenuBarPrefs.iconHiddenBehindNotch()
        }
    }

    /// Write the new slot, then pull the item out and re-insert it — a status
    /// item only reads its preferred position when it is created, so this makes
    /// the move take effect without restarting the app.
    private func moveIconIntoView() {
        MenuBarPrefs.moveIconIntoView()   // handles remove ➝ reposition ➝ re-insert
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { refreshNotchState() }
    }
}

/// A normal window showing the same at-a-glance view as the menu-bar popover.
/// Guarantees access to it even when the menu bar is too full to show the icon.
@MainActor
func showMultiPingStatusWindow() {
    let statusID = NSUserInterfaceItemIdentifier("multiping-status")
    if let existing = NSApp.windows.first(where: { $0.identifier == statusID }) {
        existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
    }
    guard let manager = AppDelegate.pingManagerInstance else { return }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false
    )
    window.identifier = statusID
    window.title = "MultiPing Status"
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.contentView = NSHostingView(rootView: MenuBarContentView(manager: manager))
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

/// The menu-bar item's own label: the ping glyph plus live reachable/failed
/// counts, so the session status is readable straight from the menu bar.
struct MenuBarStatusLabel: View {
    @ObservedObject var manager: PingManager
    @AppStorage(MenuBarPrefs.showCountsKey) private var showCounts = true

    var body: some View {
        if manager.results.isEmpty || !showCounts {
            Image(systemName: "dot.radiowaves.left.and.right")
        } else {
            HStack(spacing: 3) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("\(manager.reachableCount)")
                if manager.failedCount > 0 { Text("/\(manager.failedCount)") }
            }
        }
    }
}

/// Compact, always-available status view shown from the menu-bar icon: overall
/// status, reachable/failed counts, a live per-host list, and buttons to open
/// the main window or quit.
struct MenuBarContentView: View {
    @ObservedObject var manager: PingManager
    @AppStorage(MenuBarPrefs.visibleRowsKey) private var visibleRows = MenuBarPrefs.defaultVisibleRows
    @AppStorage(MenuBarPrefs.sortOrderKey) private var sortOrder = MenuBarSortOrder.asEntered
    /// Host the pointer is over, for the 1-minute preview graph.
    @State private var hoveredHostID: UUID?

    private static let previewFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Hosts currently failing (excluding paused), for the failed-count tooltip.
    private var failedHosts: [PingResult] {
        manager.results.filter { !$0.isSuccessful && !$0.isPaused }
    }

    private var failedTooltip: String {
        let failed = failedHosts
        guard !failed.isEmpty else { return "No failed hosts" }
        let shown = failed.prefix(25).map { displayName($0) }
        var text = "Failed host\(failed.count == 1 ? "" : "s") (\(failed.count)):\n" + shown.joined(separator: "\n")
        if failed.count > shown.count { text += "\n… and \(failed.count - shown.count) more" }
        return text
    }

    /// The hovered host, but only while the order is stable enough to point at.
    private var previewHost: PingResult? {
        guard sortOrder.isStableOrder, let id = hoveredHostID else { return nil }
        return manager.results.first { $0.id == id }
    }

    /// The at-a-glance list in the user's chosen order. Unreachable hosts count
    /// as "worst" for latency sorting, so they lead "Highest latency" and trail
    /// "Lowest latency" rather than sorting as 0 ms.
    private var sortedResults: [PingResult] {
        let items = manager.results
        switch sortOrder {
        case .asEntered:
            return items
        case .name:
            return items.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
        case .ipAddress:
            // Numeric where possible so .2 sorts before .10; non-IPv4 targets
            // (hostnames, IPv6) fall to the end in natural order.
            return items.sorted { a, b in
                switch (LocalNetwork.ipv4ToInt(a.targetValue), LocalNetwork.ipv4ToInt(b.targetValue)) {
                case let (x?, y?): return x < y
                case (_?, nil):    return true
                case (nil, _?):    return false
                default:           return a.targetValue.localizedStandardCompare(b.targetValue) == .orderedAscending
                }
            }
        case .problems:
            return items.sorted { a, b in
                let ra = statusRank(a), rb = statusRank(b)
                if ra != rb { return ra < rb }
                return displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
            }
        case .highestLatency:
            return items.sorted { latencyForSort($0) > latencyForSort($1) }
        case .lowestLatency:
            return items.sorted { latencyForSort($0) < latencyForSort($1) }
        }
    }

    /// Last minute of latency for the host under the pointer. Rendered with the
    /// shared graph renderer so it matches the full graphs elsewhere.
    @ViewBuilder private func hoverPreview(for host: PingResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(displayName(host)).font(.caption.bold()).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("last 1m").font(.caption2).foregroundColor(.secondary)
            }
            TimelineView(.periodic(from: Date(), by: 1)) { timeline in
                Canvas { context, size in
                    var mutable = context
                    LatencyGraphRenderer(samples: host.latencyHistory, window: .oneMinute)
                        .render(into: &mutable, size: size, now: timeline.date,
                                formatter: Self.previewFormatter)
                }
                .frame(height: 96)
                .background(LatencyGraphPalette.plotBackground)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    /// 0 = failing, 1 = reachable, 2 = paused.
    private func statusRank(_ r: PingResult) -> Int {
        if r.isPaused { return 2 }
        return r.isSuccessful ? 1 : 0
    }

    /// Latency with unreachable/paused treated as the worst possible value.
    private func latencyForSort(_ r: PingResult) -> Double {
        r.currentLatencyMs ?? .greatestFiniteMagnitude
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("MultiPing").font(.headline)
                Spacer()
                Text(manager.pingStatus).font(.caption).foregroundColor(statusColor).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            HStack(spacing: 18) {
                countPill(manager.reachableCount, color: .green, label: "reachable")
                countPill(manager.failedCount, color: .red, label: "failed")
                    .help(failedTooltip)
                Spacer()
                Text("\(manager.results.count) host\(manager.results.count == 1 ? "" : "s")")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.bottom, 10)

            Divider()

            if manager.results.isEmpty {
                Text("No active session.\nOpen MultiPing to start pinging.")
                    .font(.callout).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sortedResults) { result in
                            HStack(spacing: 8) {
                                Circle().fill(ResultStatusPalette.swiftColor(for: result))
                                    .frame(width: 8, height: 8)
                                Text(displayName(result))
                                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    .strikethrough(result.isPaused)
                                Spacer(minLength: 8)
                                Text(currentText(result))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .background(hoveredHostID == result.id && sortOrder.isStableOrder
                                        ? Color.primary.opacity(0.08) : Color.clear)
                            .onHover { inside in
                                if inside { hoveredHostID = result.id }
                                else if hoveredHostID == result.id { hoveredHostID = nil }
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .frame(height: listHeight)
            }

            if let host = previewHost {
                Divider()
                hoverPreview(for: host)
            }

            Divider()

            HStack {
                Button("Open MultiPing") { openMainMultiPingWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .foregroundColor(.secondary)
            }
            .padding(12)
        }
        .frame(width: 360)
    }

    /// Height of the host list: as tall as the content needs, but no taller than
    /// the configured row count (0 = show all) and never taller than the screen
    /// can accommodate alongside the header and buttons.
    private var listHeight: CGFloat {
        let rowHeight: CGFloat = 21
        let listPadding: CGFloat = 10          // the VStack's .padding(.vertical, 5)
        let chromeHeight: CGFloat = 170        // header + counts + buttons + margins
        let screenCap = max(rowHeight * 4,
                            ((NSScreen.main?.visibleFrame.height ?? 900) - chromeHeight))
        let contentHeight = CGFloat(manager.results.count) * rowHeight + listPadding
        let requested = visibleRows <= 0
            ? screenCap
            : min(CGFloat(visibleRows) * rowHeight + listPadding, screenCap)
        return min(contentHeight, requested)
    }

    private var statusColor: Color {
        switch manager.pingStatus {
        case "Pinging...": return .green
        case "Paused":     return .orange
        default:           return .secondary
        }
    }

    private func displayName(_ result: PingResult) -> String {
        if let note = result.note, !note.isEmpty { return note }
        if let resolved = result.resolvedName { return resolved }
        return result.targetValue
    }

    private func currentText(_ result: PingResult) -> String {
        if result.isPaused { return "paused" }
        return result.currentLatencyMs.map { PingResult.formatLatency(milliseconds: $0) } ?? result.responseTime
    }

    @ViewBuilder private func countPill(_ count: Int, color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count)").font(.callout.weight(.semibold))
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }
}
