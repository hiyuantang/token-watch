import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let snapshot: UsageSnapshot

    var body: some View {
        Label(
            "Token Watch \(TokenFormatting.compact(snapshot.usage.recordedTotal)) · \(TokenFormatting.usd(snapshot.cost.totalUSD))",
            systemImage: "chart.bar.fill"
        )
        .accessibilityLabel("Token Watch, today: \(TokenFormatting.full(snapshot.usage.recordedTotal)) recorded tokens, estimated \(TokenFormatting.usd(snapshot.cost.totalUSD))")
    }
}

/// Renders a formatted integer as per-digit characters so each digit can flip
/// individually with a staggered (left-to-right) wave when the value changes.
/// Unchanged digits do not animate. The wave is produced by indexing only the
/// digit positions that changed and offsetting their animation by position.
private struct WaveFlipNumber: View {
    let value: Int
    let formatter: NumberFormatter

    @State private var previousDigits: [Character] = []

    private var currentDigits: [Character] {
        Array(formatter.string(for: value) ?? "")
    }

    private static let digitDelay: CGFloat = 0.07

    var body: some View {
        let digits = currentDigits
        let prev = previousDigits
        // Index changed positions relative to the start of the whole string so
        // the wave always reads left-to-right regardless of which digits moved.
        let changedIndexes: Set<Int> = {
            guard !prev.isEmpty, prev.count == digits.count else { return [] }
            return Set(zip(digits, prev).enumerated().compactMap { idx, pair in
                pair.0 != pair.1 ? idx : nil
            })
        }()

        HStack(spacing: 0) {
            ForEach(Array(digits.enumerated()), id: \.offset) { idx, char in
                Text(String(char))
                    .contentTransition(.numericText())
                    .animation(
                        changedIndexes.contains(idx)
                            ? .easeInOut(duration: 0.42)
                                .delay(Double(idx) * Self.digitDelay)
                            : nil,
                        value: value
                    )
                    .id(char)
            }
        }
        .onAppear { previousDigits = digits }
        .onChange(of: value) { _, _ in previousDigits = digits }
    }
}

struct MenuBarPopover: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var range: UsageRange = .week

    private var snapshot: UsageSnapshot { store.snapshot(for: range) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token Watch")
                        .font(.title3.weight(.semibold))
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Recorded tokens")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                WaveFlipNumber(value: snapshot.usage.recordedTotal, formatter: Self.fullFormatter)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .monospacedDigit()
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Estimated cost")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(TokenFormatting.usd(snapshot.cost.totalUSD))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if snapshot.cost.unpricedModelCount > 0 {
                    Text("\(snapshot.cost.unpricedModelCount) unpriced")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("\(snapshot.cost.unpricedModelCount) model(s) have no published price in Token Watch's local catalog. Their tokens are counted but contribute $0 to this estimate.")
                }
            }

            VStack(spacing: 10) {
                ForEach(snapshot.providers) { provider in
                    HStack {
                        Text(provider.provider.displayName)
                        Spacer()
                        Text(TokenFormatting.compact(provider.usage.recordedTotal))
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }

            Divider()

            HStack(spacing: 18) {
                PopoverStat(title: "Input", value: TokenFormatting.compact(snapshot.usage.input))
                PopoverStat(title: "Output", value: TokenFormatting.compact(snapshot.usage.output))
                PopoverStat(title: "Cache read", value: TokenFormatting.cacheShareText(snapshot.cacheReadShare))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Models")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if snapshot.models.isEmpty {
                    Text("No model metadata yet")
                        .font(.subheadline)
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
                                .frame(width: 16)
                            Text(Pricing.displayName(for: model.model))
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(TokenFormatting.compact(model.usage.recordedTotal))
                                .font(.callout)
                                .monospacedDigit()
                            Text(TokenFormatting.percentage(share))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        if model.priced {
                            HStack(spacing: 8) {
                                Text("").frame(width: 16)
                                Text(TokenFormatting.usd(model.costUSD))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Spacer()
                            }
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
        .padding(20)
        .frame(width: 400)
    }

    private static let fullFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}

private struct PopoverStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
