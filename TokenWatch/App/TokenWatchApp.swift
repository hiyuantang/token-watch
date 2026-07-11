import AppKit
import SwiftUI

final class TokenWatchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Token Watch intentionally lives in the menu bar, not the Dock.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
@MainActor
struct TokenWatchApp: App {
    @NSApplicationDelegateAdaptor(TokenWatchAppDelegate.self) private var appDelegate
    @StateObject private var usageStore: UsageStore

    init() {
        let store = UsageStore()
        _usageStore = StateObject(wrappedValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(store: usageStore)
        } label: {
            MenuBarLabel(snapshot: usageStore.snapshot(for: .day))
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Token Watch", id: "dashboard") {
            DashboardView(store: usageStore)
        }
        .defaultSize(width: 1_026, height: 670)

        Window("Token Watch Quick View", id: "quick-view") {
            QuickViewWindow(store: usageStore)
        }
        .windowResizability(.contentSize)
    }
}
