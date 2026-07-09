import AppKit
import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var events: [UsageEvent] = []
    @Published private(set) var sources: [SourceHealth] = UsageProvider.allCases.map(SourceHealth.unconfigured)
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastMessage: String?

    private var refreshTimer: Task<Void, Never>?

    deinit {
        refreshTimer?.cancel()
    }

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        refreshTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastMessage = nil

        let selectedFolders = Dictionary(uniqueKeysWithValues: UsageProvider.allCases.compactMap { provider in
            FolderAccessStore.url(for: provider).map { (provider, $0) }
        })
        let scopedFolders = selectedFolders.values.filter { $0.startAccessingSecurityScopedResource() }
        let scanner = TranscriptScanner()

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                scanner.scan(
                    claudeRoot: selectedFolders[.claudeCode],
                    codexRoot: selectedFolders[.codex]
                )
            }.value

            scopedFolders.forEach { $0.stopAccessingSecurityScopedResource() }
            guard let self else { return }
            self.events = result.events
            self.sources = result.sources
            self.isRefreshing = false
        }
    }

    func chooseFolder(for provider: UsageProvider) {
        switch FolderAccessStore.chooseFolder(for: provider) {
        case .success:
            lastMessage = "\(provider.displayName) access updated."
            refresh()
        case .failure(let error):
            lastMessage = error.errorDescription
        }
    }

    func revokeFolder(for provider: UsageProvider) {
        FolderAccessStore.remove(provider)
        events.removeAll { $0.provider == provider }
        sources = sources.map { source in
            source.provider == provider ? .unconfigured(provider) : source
        }
        lastMessage = "\(provider.displayName) access removed."
    }

    func snapshot(for range: UsageRange, now: Date = Date()) -> UsageSnapshot {
        UsageAggregator.snapshot(events: events, range: range, sources: sources, now: now)
    }
}

enum UsageAggregator {
    static func snapshot(
        events: [UsageEvent],
        range: UsageRange,
        sources: [SourceHealth],
        now: Date
    ) -> UsageSnapshot {
        let calendar = Calendar.current
        let start = rangeStart(range, now: now, calendar: calendar)
        let selectedEvents = events.filter { $0.timestamp >= start && $0.timestamp <= now }
        guard !selectedEvents.isEmpty else { return .empty(range: range, sources: sources) }

        var usage = TokenUsage.zero
        var providerUsage = Dictionary(uniqueKeysWithValues: UsageProvider.allCases.map { ($0, TokenUsage.zero) })
        var modelUsage: [ModelKey: TokenUsage] = [:]
        var sessionTokens = Set<UUID>()
        var timelineTotals: [TimelineKey: Int] = [:]

        for event in selectedEvents {
            usage = usage + event.usage
            providerUsage[event.provider, default: .zero] = providerUsage[event.provider, default: .zero] + event.usage
            let modelKey = ModelKey(provider: event.provider, model: event.model)
            modelUsage[modelKey, default: .zero] = modelUsage[modelKey, default: .zero] + event.usage
            sessionTokens.insert(event.sessionToken)

            let date = bucketDate(for: event.timestamp, range: range, calendar: calendar)
            let timelineKey = TimelineKey(date: date, provider: event.provider)
            timelineTotals[timelineKey, default: 0] += event.usage.recordedTotal
        }

        var timeline: [TimelineBucket] = []
        for (key, total) in timelineTotals {
            timeline.append(TimelineBucket(date: key.date, provider: key.provider, recordedTotal: total))
        }
        timeline.sort {
            $0.date == $1.date ? $0.provider.rawValue < $1.provider.rawValue : $0.date < $1.date
        }

        let cacheDenominator = usage.input + usage.cacheRead
        let cacheReadShare = cacheDenominator == 0 ? 0 : Double(usage.cacheRead) / Double(cacheDenominator)
        let models = modelUsage.map {
            ModelSummary(provider: $0.key.provider, model: $0.key.model, usage: $0.value)
        }.sorted { $0.usage.recordedTotal > $1.usage.recordedTotal }

        return UsageSnapshot(
            range: range,
            usage: usage,
            providers: UsageProvider.allCases.map { ProviderSummary(provider: $0, usage: providerUsage[$0, default: .zero]) },
            models: models,
            timeline: timeline,
            sessionCount: sessionTokens.count,
            cacheReadShare: cacheReadShare,
            currentStreak: currentStreak(events: selectedEvents, now: now, calendar: calendar),
            peakActivityLabel: peakActivityLabel(timeline: timeline, range: range),
            sources: sources
        )
    }

    private static func rangeStart(_ range: UsageRange, now: Date, calendar: Calendar) -> Date {
        guard let dayCount = range.dayCount else { return .distantPast }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
    }

    private static func bucketDate(for date: Date, range: UsageRange, calendar: Calendar) -> Date {
        if range == .day {
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        }
        if range == .total {
            return calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
        return calendar.startOfDay(for: date)
    }

    private static func currentStreak(events: [UsageEvent], now: Date, calendar: Calendar) -> Int {
        let activeDays = Set(events.map { calendar.startOfDay(for: $0.timestamp) })
        var day = calendar.startOfDay(for: now)
        var count = 0
        while activeDays.contains(day) {
            count += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previousDay
        }
        return count
    }

    private static func peakActivityLabel(timeline: [TimelineBucket], range: UsageRange) -> String {
        guard let peak = timeline.max(by: { $0.recordedTotal < $1.recordedTotal }) else { return "No activity yet" }
        if range == .day {
            return peak.date.formatted(date: .omitted, time: .shortened)
        }
        if range == .total {
            return peak.date.formatted(.dateTime.year().month(.abbreviated))
        }
        return peak.date.formatted(.dateTime.month(.abbreviated).day())
    }

    private struct ModelKey: Hashable {
        let provider: UsageProvider
        let model: String
    }

    private struct TimelineKey: Hashable {
        let date: Date
        let provider: UsageProvider
    }
}
