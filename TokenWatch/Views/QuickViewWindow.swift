import AppKit
import SwiftUI

struct QuickViewWindow: View {
    @ObservedObject var store: UsageStore
    @AppStorage("TokenWatch.quickView.alwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        MenuBarPopover(store: store)
            .background {
                WindowLevelSetter(level: alwaysOnTop ? .floating : .normal)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $alwaysOnTop) {
                        Label(
                            "Always on Top",
                            systemImage: alwaysOnTop ? "pin.fill" : "pin"
                        )
                    }
                    .toggleStyle(.button)
                    .help(alwaysOnTop ? "Stop keeping this window on top" : "Keep this window on top")
                }
            }
    }
}

private struct WindowLevelSetter: NSViewRepresentable {
    let level: NSWindow.Level

    func makeNSView(context: Context) -> WindowLevelView {
        WindowLevelView(level: level)
    }

    func updateNSView(_ nsView: WindowLevelView, context: Context) {
        nsView.level = level
    }
}

private final class WindowLevelView: NSView {
    var level: NSWindow.Level {
        didSet { applyLevel() }
    }

    init(level: NSWindow.Level) {
        self.level = level
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLevel()
    }

    private func applyLevel() {
        window?.level = level
    }
}
