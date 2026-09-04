import SwiftUI

// AppDelegate to handle application lifecycle events AND window events
@MainActor class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate { // Added NSWindowDelegate
    static weak var pingManagerInstance: PingManager?
    private var windowObservation: NSKeyValueObservation? // KVO handle for new windows

    override init() {
        super.init()
        // Must happen before the MenuBarExtra scene creates its status item —
        // the item reads its preferred slot only at creation time.
        MenuBarPrefs.seedIconPositionIfNeeded()
        MenuBarPrefs.migrateSortOrderIfNeeded()
        // Set up KVO for new windows as early as possible.
        windowObservation = NSApp.observe(\.windows, options: [.initial, .new]) { [weak self] app, change in
            // .initial ensures this runs for windows existing at the time of observation.
            // .new ensures it runs for newly added windows.
            print("AppDelegate: KVO detected change in application windows.")
            Task { @MainActor in
                self?.assignDelegateToAllWindows()
            }
        }
    }

    // This method is called after the application has finished launching and has processed its initial events.
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("AppDelegate: applicationDidFinishLaunching.")
        // KVO with .initial should have already called assignDelegateToAllWindows.
        // Calling it again here is a safeguard.
        assignDelegateToAllWindows()
        MenuBarPrefs.applyActivationPolicy()
        // Give AppKit a moment to place the status item, then rescue it if it
        // landed somewhere macOS won't draw (e.g. under the camera notch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            MenuBarPrefs.autoFixIconVisibility()
        }
    }

    // Helper method to assign this AppDelegate instance as the delegate
    // to relevant application windows.
    func assignDelegateToAllWindows() {
        DispatchQueue.main.async { // Ensure UI updates (like setting a delegate) are on the main thread
            for window in NSApp.windows {
                // We are interested in the main "Targets Collector" window and "Ping Results" windows.
                let isRelevantWindowType = self.isRelevantWindow(window)

                // Only assign if it's a relevant window and the delegate is not already this instance.
                if isRelevantWindowType && !(window.delegate is AppDelegate) {
                    print("AppDelegate: Assigning self as delegate to window: '\(window.title)' (ID: \(window.identifier?.rawValue ?? "N/A"))")
                    window.delegate = self
                }
            }
        }
    }

    // Called just before the application terminates. This is our main cleanup point.
    func applicationWillTerminate(_ notification: Notification) {
        print("AppDelegate: Application will terminate. Performing final cleanup.")
        if let manager = AppDelegate.pingManagerInstance {
            manager.prepareForAppTermination(clearResults: true)
        }
        windowObservation?.invalidate()
        windowObservation = nil
        print("AppDelegate: applicationWillTerminate finished.")
    }

    // Called when the user clicks the red close button on a window. The app now
    // lives in the menu bar: closing a window (even the last) no longer stops
    // pinging or quits — the session keeps running in the background and stays
    // visible in the menu-bar at-a-glance view. Cleanup happens on quit.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }

    // Stay alive in the menu bar when all windows are closed — the MenuBarExtra
    // scene is the always-available at-a-glance monitor and reopen control.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Clicking the Dock icon (or reopening the app) with no windows open brings
    // the session back — a reopen path that works even if the menu-bar item is
    // tucked away by a menu-bar manager.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainMultiPingWindow() }
        return true
    }

    private func isRelevantWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "ip-input" ||
        window.identifier?.rawValue == "ping-results" ||
        window.title.starts(with: "Ping Results")
    }

    deinit {
        windowObservation?.invalidate() // Ensure KVO is cleaned up
    }
}

@main
struct MultiPingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = PingManager()
    /// Menu-bar preferences (see MultiPingSettingsView).
    @AppStorage(MenuBarPrefs.showIconKey) private var showMenuBarIcon = true
    @AppStorage(MenuBarPrefs.menuBarOnlyKey) private var menuBarOnly = false

    var body: some Scene {
        Window("Targets Collector", id: "ip-input") { // ID "ip-input" is used by AppDelegate
            IPInputView(manager: manager)
                .onAppear {
                    print("MultiPingApp: IPInputView appeared, assigning PingManager (\(ObjectIdentifier(manager))) to AppDelegate.")
                    AppDelegate.pingManagerInstance = manager
                    MenuBarPrefs.applyActivationPolicy()
                    // AppDelegate's KVO with .initial should handle setting the window delegate for this initial window.
                }
        }
        .commands {
            // Route the app-menu "About" to our custom, non-clipping About window.
            CommandGroup(replacing: .appInfo) {
                Button("About MultiPing for macOS") { showMultiPingAboutPanel() }
            }
            CommandGroup(after: .windowList) {
                Divider()
                Button("MultiPing Status…") { showMultiPingStatusWindow() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
        }

        Settings {
            MultiPingSettingsView()
        }

        // Menu-bar item: at-a-glance status + reopen control. As a persistent
        // scene it also keeps the app (and its background pings) alive when all
        // windows are closed, even when the icon itself is hidden.
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContentView(manager: manager)
        } label: {
            MenuBarStatusLabel(manager: manager)
        }
        .menuBarExtraStyle(.window)
    }
}
