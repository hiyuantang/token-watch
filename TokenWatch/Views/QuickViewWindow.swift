import AppKit
import SwiftUI

struct QuickViewWindow: View {
    @ObservedObject var store: UsageStore
    @AppStorage("TokenWatch.quickView.alwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        MenuBarPopover(store: store)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .overlay(alignment: .topTrailing) {
                Button {
                    alwaysOnTop.toggle()
                } label: {
                    Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(alwaysOnTop ? "Stop keeping this window on top" : "Keep this window on top")
                .padding(.trailing, 8)
                .padding(.top, 6)
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
        window.styleMask.insert(.borderless)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.hasShadow = true
    }
}
