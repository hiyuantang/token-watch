import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let snapshot: UsageSnapshot

    var body: some View {
        Label(
            "Token Watch \(TokenFormatting.compact(snapshot.usage.recordedTotal))",
            systemImage: "chart.bar.fill"
        )
        .accessibilityLabel("Token Watch, today: \(TokenFormatting.full(snapshot.usage.recordedTotal)) recorded tokens")
    }
}

struct MenuBarPopover: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var range: UsageRange = .week

    private var snapshot: UsageSnapshot { store.snapshot(for: range) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token Watch")
                        .font(.headline)
                    Text("Local transcript metadata only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing local transcript metadata")
                }
            }

            Picker("Date range", selection: $range) {
                ForEach(UsageRange.allCases) { range in
                    Text(range.shortTitle).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Date range")

            VStack(alignment: .leading, spacing: 4) {
                Text("Recorded tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(TokenFormatting.compact(snapshot.usage.recordedTotal))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("Observed in local \(range.shortTitle) transcript records")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(snapshot.providers) { provider in
                    HStack {
                        Text(provider.provider.displayName)
                        Spacer()
                        Text(TokenFormatting.compact(provider.usage.recordedTotal))
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }

            Divider()

            HStack(spacing: 18) {
                PopoverStat(title: "Input", value: TokenFormatting.compact(snapshot.usage.input))
                PopoverStat(title: "Output", value: TokenFormatting.compact(snapshot.usage.output))
                PopoverStat(title: "Cache read", value: TokenFormatting.percentage(snapshot.cacheReadShare))
            }

            if let topModel = snapshot.models.first {
                Label("Top model: \(topModel.model)", systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let message = store.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Open Dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("o", modifiers: .command)

                Spacer()

                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh local transcript metadata")
                .disabled(store.isRefreshing)

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Open Token Watch settings")
            }
        }
        .padding(18)
        .frame(width: 360)
        .task {
            store.start()
            store.refresh()
        }
    }
}

private struct PopoverStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
