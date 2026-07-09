import Charts
import SwiftUI

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case models
    case sources

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .models: "cpu"
        case .sources: "folder"
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
            case .sources:
                SourcesView(store: store)
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
                .frame(width: 210)
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

            ToolbarItem(placement: .secondaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .task { store.start() }
    }
}

private struct OverviewView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recorded tokens")
                        .font(.headline)
                    Text(snapshot.range == .total
                         ? "All recorded activity."
                         : "Local transcript metadata for the last \(snapshot.range.rawValue) calendar day\(snapshot.range == .day ? "" : "s").")
                        .foregroundStyle(.secondary)
                }

                GlassEffectContainer(spacing: 14) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 14)], spacing: 14) {
                        MetricCard(
                            title: "Recorded tokens",
                            value: TokenFormatting.compact(snapshot.usage.recordedTotal),
                            detail: "Input, output, and provider cache fields",
                            symbol: "chart.bar.fill",
                            tint: .blue
                        )
                        MetricCard(
                            title: "Sessions",
                            value: TokenFormatting.full(snapshot.sessionCount),
                            detail: "Opaque local session count",
                            symbol: "rectangle.stack",
                            tint: .purple
                        )
                        MetricCard(
                            title: "Cache read share",
                            value: TokenFormatting.percentage(snapshot.cacheReadShare),
                            detail: "Cached input ÷ observed input",
                            symbol: "arrow.trianglehead.2.clockwise",
                            tint: .mint
                        )
                        MetricCard(
                            title: "Current streak",
                            value: "\(snapshot.currentStreak) day\(snapshot.currentStreak == 1 ? "" : "s")",
                            detail: snapshot.peakActivityLabel == "No activity yet" ? "No peak activity yet" : "Peak: \(snapshot.peakActivityLabel)",
                            symbol: "flame",
                            tint: .orange
                        )
                    }
                }

                GroupBox("Activity") {
                    if snapshot.timeline.isEmpty {
                        ContentUnavailableView(
                            "No recorded token activity",
                            systemImage: "chart.bar.xaxis",
                            description: Text("Choose your Claude Code or Codex folder in Sources to begin.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        Chart(snapshot.timeline) { bucket in
                            BarMark(
                                x: .value(
                                    snapshot.range == .day ? "Hour" : (snapshot.range == .total ? "Month" : "Day"),
                                    bucket.date
                                ),
                                y: .value("Recorded tokens", bucket.recordedTotal)
                            )
                            .foregroundStyle(by: .value("Provider", bucket.provider.displayName))
                        }
                        .chartLegend(position: .bottom, alignment: .leading)
                        .frame(height: 250)
                        .accessibilityLabel("Token activity chart")
                    }
                }

                GroupBox("Provider split") {
                    VStack(spacing: 12) {
                        ForEach(snapshot.providers) { provider in
                            HStack {
                                Label(provider.provider.displayName, systemImage: provider.provider == .claudeCode ? "sparkles" : "terminal")
                                Spacer()
                                Text(TokenFormatting.compact(provider.usage.recordedTotal))
                                    .monospacedDigit()
                                Text("tokens")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Label(
                    "Recorded tokens are local transcript metadata, not an official quota, invoice, or provider usage balance.",
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
