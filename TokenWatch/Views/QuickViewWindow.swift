import AppKit
import SwiftUI

struct QuickViewWindow: View {
    @ObservedObject var store: UsageStore
    @AppStorage("TokenWatch.quickView.alwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .ignoresSafeArea()

            MenuBarPopover(store: store)
        }
        .fixedSize()
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarSpacer(.flexible)

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
        .background {
            WindowLevelSetter(level: alwaysOnTop ? .floating : .normal)
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
        guard let window = window else { return }
        window.level = level
        window.styleMask.remove(.resizable)
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.hasShadow = true
    }
}
