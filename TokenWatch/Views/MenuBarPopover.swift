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
                Text(TokenFormatting.full(snapshot.usage.recordedTotal))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if snapshot.models.isEmpty {
                    Text("No model metadata yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let totalRecorded = snapshot.usage.recordedTotal
                    ForEach(snapshot.models.prefix(5)) { model in
                        let share = totalRecorded == 0
                            ? 0
                            : Double(model.usage.recordedTotal) / Double(totalRecorded)
                        HStack(spacing: 8) {
                            Image(systemName: model.provider == .claudeCode ? "sparkles" : (model.provider == .codex ? "terminal" : "curlybraces"))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Text(model.model)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(TokenFormatting.compact(model.usage.recordedTotal))
                                .font(.caption)
                                .monospacedDigit()
                            Text(TokenFormatting.percentage(share))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
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

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .labelStyle(.iconOnly)
                .help("Quit Token Watch")
            }
        }
        .padding(18)
        .frame(width: 360)
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
