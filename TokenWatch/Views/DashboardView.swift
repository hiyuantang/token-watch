import Charts
import SwiftUI

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case models
    case about

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .models: "cpu"
        case .about: "info.circle"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @State private var section: DashboardSection? = .overview
    @SceneStorage("TokenWatch.dashboard.range") private var selectedRangeRaw = UsageRange.week.rawValue

    private var selectedRange: UsageRange {
        UsageRange(rawValue: selectedRangeRaw) ?? .week
    }

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationTitle("Token Watch")
        } detail: {
            switch section ?? .overview {
            case .overview:
                OverviewView(snapshot: store.snapshot(for: selectedRange))
            case .models:
                ModelsView(snapshot: store.snapshot(for: selectedRange))
            case .about:
                AboutView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Date range", selection: $selectedRangeRaw) {
                    ForEach(UsageRange.allCases) { range in
                        Text(range.shortTitle).tag(range.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isRefreshing)
            }
        }
    }
}

private struct OverviewView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GlassEffectContainer(spacing: 14) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 14)], spacing: 14) {
                        MetricCard(
                            title: "Recorded tokens",
                            value: TokenFormatting.compact(snapshot.usage.recordedTotal),
                            symbol: "chart.bar.fill",
                            tint: .blue
                        )
                        MetricCard(
                            title: "Estimated cost",
                            value: TokenFormatting.usd(snapshot.cost.totalUSD),
                            detail: snapshot.cost.unpricedModelCount > 0
                                ? "\(snapshot.cost.unpricedModelCount) model(s) unpriced"
                                : nil,
                            symbol: "dollarsign.circle.fill",
                            tint: .green
                        )
                        MetricCard(
                            title: "Sessions",
                            value: TokenFormatting.full(snapshot.sessionCount),
                            symbol: "rectangle.stack",
                            tint: .purple
                        )
                        MetricCard(
                            title: "Cache read share",
                            value: TokenFormatting.cacheShareText(snapshot.cacheReadShare),
                            symbol: "arrow.trianglehead.2.clockwise",
                            tint: .mint
                        )
                    }
                }

                GroupBox("Activity") {
                    if snapshot.timeline.isEmpty {
                        ContentUnavailableView(
                            "No recorded token activity",
                            systemImage: "chart.bar.xaxis",
                            description: Text("Open Claude Code, Codex, or OpenCode to begin recording token metadata.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ActivityChart(snapshot: snapshot)
                    }
                }

                GroupBox("Provider split") {
                    VStack(spacing: 12) {
                        ForEach(snapshot.providers) { provider in
                            HStack {
                                Label(provider.provider.displayName, systemImage: providerSymbol(provider.provider))
                                    .foregroundStyle(provider.provider.tint)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(TokenFormatting.compact(provider.usage.recordedTotal))
                                            .monospacedDigit()
                                        Text("tokens")
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(TokenFormatting.usd(provider.costUSD))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Label(
                    "Estimated cost is a local illustration from published API rates and observed token totals — not an official invoice, quota, or account balance. Batch, peak, fast-mode, and data-residency pricing are not modeled.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }

}

private struct ActivityChart: View {
    let snapshot: UsageSnapshot

    private var slots: [Date] {
        let calendar = Calendar.current
        let now = snapshot.generatedAt
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let today = calendar.startOfDay(for: now)

        let start: Date
        let count: Int
        let component: Calendar.Component
        switch snapshot.range {
        case .today:
            start = today
            count = 24
            component = .hour
        case .day:
            start = calendar.date(byAdding: .hour, value: -23, to: currentHour) ?? currentHour
            count = 24
            component = .hour
        case .week:
            start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            count = 7
            component = .day
        case .month:
            start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            count = 30
            component = .day
        case .total:
            let first = snapshot.timeline.first?.date ?? now
            start = calendar.dateInterval(of: .month, for: first)?.start ?? first
            let currentMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
            count = max((calendar.dateComponents([.month], from: start, to: currentMonth).month ?? 0) + 1, 1)
            component = .month
        }

        return (0..<count).compactMap { calendar.date(byAdding: component, value: $0, to: start) }
    }

    var body: some View {
        GeometryReader { proxy in
            let slotCount = max(slots.count, 1)
            let minimumSlotWidth: CGFloat = snapshot.range == .total ? 38 : 26
            let chartWidth = max(proxy.size.width, CGFloat(slotCount) * minimumSlotWidth)
            let barWidth = min(max((chartWidth / CGFloat(slotCount)) * 0.68, 10), 64)

            ScrollView(.horizontal, showsIndicators: false) {
                Chart {
                    ForEach(slots, id: \.self) { slot in
                        PointMark(x: .value("Time slot", slotKey(for: slot)), y: .value("Baseline", 0))
                            .opacity(0)
                    }
                    ForEach(snapshot.timeline) { bucket in
                        BarMark(
                            x: .value(axisTitle, slotKey(for: bucket.date)),
                            y: .value("Recorded tokens", bucket.recordedTotal),
                            width: .fixed(barWidth)
                        )
                        .foregroundStyle(by: .value("Provider", bucket.provider.displayName))
                    }
                }
                .chartForegroundStyleScale(domain: UsageProvider.allCases.map(\.displayName), range: UsageProvider.allCases.map(\.tint))
                .chartXAxis {
                    AxisMarks(values: axisValues) { value in
                        AxisGridLine()
                        AxisValueLabel(centered: true, collisionResolution: .disabled) {
                            if let key = value.as(String.self), let date = slotDates[key] {
                                Text(date, format: axisFormat)
                            }
                        }
                    }
                }
                .chartXScale(
                    range: .plotDimension(
                        startPadding: barWidth / 2 + 8,
                        endPadding: barWidth / 2 + 8
                    )
                )
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let val = value.as(Int.self) {
                                Text(TokenFormatting.compact(val))
                            }
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(width: chartWidth, height: 250)
                .accessibilityLabel("Token activity chart")
            }
        }
        .frame(height: 250)
    }

    private var axisTitle: String {
        switch snapshot.range {
        case .today, .day: "Hour"
        case .week, .month: "Day"
        case .total: "Month"
        }
    }

    private var axisValues: [String] {
        switch snapshot.range {
        case .today, .day: slots.enumerated().compactMap { $0.offset.isMultiple(of: 3) ? slotKey(for: $0.element) : nil }
        case .month: slots.enumerated().compactMap { $0.offset.isMultiple(of: 3) ? slotKey(for: $0.element) : nil }
        case .week, .total: slots.map(slotKey)
        }
    }

    private var slotDates: [String: Date] {
        Dictionary(uniqueKeysWithValues: slots.map { (slotKey(for: $0), $0) })
    }

    private func slotKey(for date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate)
    }

    private var axisFormat: Date.FormatStyle {
        switch snapshot.range {
        case .today, .day: .dateTime.hour()
        case .week, .month: .dateTime.month(.abbreviated).day()
        case .total: .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }
}

private func providerSymbol(_ provider: UsageProvider) -> String {
    switch provider {
    case .claudeCode: "sparkles"
    case .codex: "terminal"
    case .openCode: "curlybraces"
    }
}

private struct AboutView: View {
    var body: some View {
        Form {
            Section("Privacy boundary") {
                Label("No network entitlement or network features", systemImage: "network.slash")
                Label("No prompts, responses, source files, paths, or session IDs are shown or persisted", systemImage: "lock")
                Label("No account, credential, quota, or rate-limit tracking", systemImage: "nosign")
            }

            Section("Cost estimate") {
                Text("Estimated cost multiplies observed token totals by a static, hand-maintained catalog of published API rates (see docs/pricing.md). It makes no network requests and is not an invoice; batch, peak/off-peak, fast-mode, data-residency, and write-premium pricing are not modeled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Affiliation") {
                Text("Token Watch is not affiliated with or endorsed by Anthropic, OpenAI, Z.ai, Moonshot, MiniMax, DeepSeek, or OpenCode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}
