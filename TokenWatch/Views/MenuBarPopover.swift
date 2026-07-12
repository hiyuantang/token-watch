import AppKit
import Charts
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

struct MenuBarPopover: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @State private var range: UsageRange = .today
    @State private var breakdownMetric: PopoverBreakdownMetric = .tokens

    var body: some View {
        let snapshot = store.snapshot(for: range)

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

            HStack(spacing: 10) {
                Picker("Date range", selection: $range) {
                    ForEach(UsageRange.allCases) { range in
                        Text(range.shortTitle).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .tint(Color(white: 0.28))
                .labelsHidden()
                .accessibilityLabel("Date range")

                Picker("Breakdown", selection: $breakdownMetric) {
                    ForEach(PopoverBreakdownMetric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .tint(Color(white: 0.28))
                .labelsHidden()
                .frame(width: 104)
                .accessibilityLabel("Breakdown metric")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(breakdownMetric.summaryTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(breakdownMetric.formattedSummary(for: snapshot))
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.45), value: breakdownMetric)
                    .animation(.easeInOut(duration: 0.45), value: snapshot.usage.recordedTotal)
                    .animation(.easeInOut(duration: 0.45), value: snapshot.cost.totalUSD)
            }

            PopoverBreakdown(
                snapshot: snapshot,
                metric: $breakdownMetric
            )

            Divider()

            HStack(spacing: 18) {
                PopoverStat(title: "Input", value: TokenFormatting.compact(snapshot.usage.displayInput))
                PopoverStat(title: "Output", value: TokenFormatting.compact(snapshot.usage.output))
                PopoverStat(title: "Cache read", value: TokenFormatting.compact(snapshot.usage.cacheRead))
                PopoverStat(title: "Hit rate", value: TokenFormatting.cacheShareText(snapshot.cacheReadShare))
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
                    let modelRows: CGFloat = 20
                    let priceRows: CGFloat = 14
                    let vSpacing: CGFloat = 8
                    let visibleCount = 5
                    if snapshot.models.count <= visibleCount {
                        VStack(alignment: .leading, spacing: vSpacing) {
                            modelListContent(snapshot.models, totalRecorded: totalRecorded)
                        }
                    } else {
                        let pricedInFirst5 = snapshot.models.prefix(visibleCount).filter(\.priced).count
                        let scrollHeight = CGFloat(visibleCount) * modelRows
                            + CGFloat(pricedInFirst5) * priceRows
                            + CGFloat(visibleCount + pricedInFirst5 - 1) * vSpacing
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: vSpacing) {
                                modelListContent(snapshot.models, totalRecorded: totalRecorded)
                            }
                        }
                        .frame(height: scrollHeight)
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
}

private enum PopoverBreakdownMetric: String, CaseIterable, Identifiable {
    case tokens = "Token"
    case price = "Price"

    var id: Self { self }

    var summaryTitle: String {
        switch self {
        case .tokens: "Recorded tokens"
        case .price: "Estimated cost"
        }
    }

    func formattedSummary(for snapshot: UsageSnapshot) -> String {
        switch self {
        case .tokens: TokenFormatting.full(snapshot.usage.recordedTotal)
        case .price: TokenFormatting.usd(snapshot.cost.totalUSD)
        }
    }

    func value(for provider: ProviderSummary) -> Double {
        switch self {
        case .tokens: Double(provider.usage.recordedTotal)
        case .price: provider.costUSD
        }
    }

    func formattedValue(for provider: ProviderSummary) -> String {
        switch self {
        case .tokens: TokenFormatting.compact(provider.usage.recordedTotal)
        case .price: TokenFormatting.usd(provider.costUSD)
        }
    }

    func formattedTotal(for snapshot: UsageSnapshot) -> String {
        switch self {
        case .tokens: TokenFormatting.compact(snapshot.usage.recordedTotal)
        case .price: TokenFormatting.compactUSD(snapshot.cost.totalUSD)
        }
    }
}

private struct PopoverBreakdown: View {
    let snapshot: UsageSnapshot
    @Binding var metric: PopoverBreakdownMetric

    private var visibleProviders: [ProviderSummary] {
        snapshot.providers.filter { metric.value(for: $0) > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                ProviderRing(snapshot: snapshot, metric: metric)
                    .frame(width: 124, height: 124)

                VStack(spacing: 12) {
                    ForEach(visibleProviders) { provider in
                        HStack(spacing: 8) {
                            Image(provider.provider.logoName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                            Text(provider.provider.displayName)
                                .foregroundStyle(provider.provider.tint)
                            Spacer()
                            Text(metric.formattedValue(for: provider))
                                .monospacedDigit()
                                .foregroundStyle(provider.provider.tint)
                                .contentTransition(.numericText())
                        }
                        .font(.callout)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.45), value: metric)
            }

            if metric == .price, snapshot.cost.unpricedModelCount > 0 {
                Text("\(snapshot.cost.unpricedModelCount) unpriced")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("\(snapshot.cost.unpricedModelCount) model(s) have no published price in Token Watch's local catalog. Their tokens are counted but contribute $0 to this estimate.")
            }
        }
    }
}

private struct ProviderRing: View {
    let snapshot: UsageSnapshot
    let metric: PopoverBreakdownMetric

    private struct Slice: Identifiable, Equatable {
        let provider: UsageProvider
        let share: Double

        var id: UsageProvider { provider }
    }

    private var slices: [Slice] {
        let values = snapshot.providers.map { ($0.provider, metric.value(for: $0)) }
        let total = values.reduce(0) { $0 + $1.1 }

        return values.map { provider, value in
            let share = total > 0 ? value / total : 0
            return Slice(provider: provider, share: share)
        }
    }

    private var visibleSlices: [Slice] {
        slices.filter { $0.share > 0 }
    }

    private var accessibilityValue: String {
        slices
            .filter { $0.share > 0 }
            .map { "\($0.provider.displayName) \(TokenFormatting.percentage($0.share))" }
            .joined(separator: ", ")
    }

    var body: some View {
        ZStack {
            if visibleSlices.isEmpty {
                Circle()
                    .stroke(.quaternary, lineWidth: 16)
            } else {
                Chart(visibleSlices) { slice in
                    SectorMark(
                        angle: .value("Share", slice.share),
                        innerRadius: .ratio(0.72),
                        angularInset: visibleSlices.count > 1 ? 2.5 : 0
                    )
                    .cornerRadius(visibleSlices.count > 1 ? 3 : 0)
                    .foregroundStyle(slice.provider.tint)
                }
                .chartLegend(.hidden)
            }

            Text(metric.formattedTotal(for: snapshot))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .contentTransition(.numericText())
                .padding(22)
        }
        .animation(.easeInOut(duration: 0.45), value: slices)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.rawValue) share by provider")
        .accessibilityValue(accessibilityValue)
    }
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

private extension MenuBarPopover {
    @ViewBuilder
    func modelListContent(_ models: [ModelSummary], totalRecorded: Int) -> some View {
        ForEach(models) { model in
            let share = totalRecorded == 0
                ? 0
                : Double(model.usage.recordedTotal) / Double(totalRecorded)
            HStack(spacing: 8) {
                Image(model.provider.logoName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
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
