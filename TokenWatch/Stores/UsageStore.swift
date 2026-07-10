import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var events: [UsageEvent] = []
    @Published private(set) var sources: [SourceHealth] = UsageProvider.allCases.map(SourceHealth.unconfigured)
    @Published private(set) var isRefreshing = false

    private let watcher = TranscriptWatcher()
    private var hasStarted = false
    private var fullRefreshInProgress = false
    private var pendingFullRefresh = false
    private var refreshingProviders: Set<UsageProvider> = []
    private var pendingProviderRefreshes: Set<UsageProvider> = []

    deinit {
        MainActor.assumeIsolated {
            watcher.stopAll()
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        watcher.onChange = { [weak self] provider in self?.refreshProvider(provider) }
        refresh()
        for provider in UsageProvider.allCases {
            if let url = ProviderPaths.root(for: provider) {
                watcher.start(for: provider, directory: url)
            }
        }
    }

    /// Full initial sync — re-scans all three providers. Used at launch and by manual sync.
    func refresh() {
        guard !fullRefreshInProgress, refreshingProviders.isEmpty else {
            pendingFullRefresh = true
            return
        }
        fullRefreshInProgress = true
        updateRefreshingState()

        let claudeRoot = ProviderPaths.claudeRoot()
        let codexRoot = ProviderPaths.codexRoot()
        let openCodeRoot = ProviderPaths.openCodeRoot()
        let scanner = TranscriptScanner()

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                scanner.scan(
                    claudeRoot: claudeRoot,
                    codexRoot: codexRoot,
                    openCodeRoot: openCodeRoot
                )
            }.value

            guard let self else { return }
            self.applyScanResult(result)
            self.fullRefreshInProgress = false
            self.drainPendingRefreshes()
        }
    }

    /// Incremental per-provider refresh — only re-scans the provider whose files changed.
    /// Used by the file watcher so a change in one provider does not re-scan the other two.
    func refreshProvider(_ provider: UsageProvider) {
        guard !fullRefreshInProgress, !refreshingProviders.contains(provider) else {
            pendingProviderRefreshes.insert(provider)
            return
        }
        refreshingProviders.insert(provider)
        updateRefreshingState()

        let root = ProviderPaths.root(for: provider)
        let scanner = TranscriptScanner()

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                scanner.scanProvider(provider, root: root)
            }.value

            guard let self else { return }
            let providerEvents = result.events
            let providerSource = result.source

            self.events = Self.mergedProviderEvents(
                existing: self.events,
                provider: provider,
                scanned: providerEvents,
                source: providerSource
            ).sorted { $0.timestamp < $1.timestamp }
            self.updateSource(providerSource)
            self.refreshingProviders.remove(provider)
            self.drainPendingRefreshes()
        }
    }

    func manualSync() {
        refresh()
    }

    func snapshot(for range: UsageRange, now: Date = Date()) -> UsageSnapshot {
        UsageAggregator.snapshot(events: events, range: range, sources: sources, now: now)
    }

    static func mergedProviderEvents(
        existing: [UsageEvent],
        provider: UsageProvider,
        scanned: [UsageEvent],
        source: SourceHealth
    ) -> [UsageEvent] {
        let hasLastKnownGood = existing.contains { $0.provider == provider }
        let allScannedFilesFailed = source.scannedFiles > 0 && source.unreadableFiles == source.scannedFiles
        if hasLastKnownGood, allScannedFilesFailed {
            return existing
        }
        return existing.filter { $0.provider != provider } + scanned
    }

    private func applyScanResult(_ result: ScanResult) {
        var mergedEvents = events
        for provider in UsageProvider.allCases {
            guard let source = result.sources.first(where: { $0.provider == provider }) else { continue }
            mergedEvents = Self.mergedProviderEvents(
                existing: mergedEvents,
                provider: provider,
                scanned: result.events.filter { $0.provider == provider },
                source: source
            )
            updateSource(source)
        }
        events = mergedEvents.sorted { $0.timestamp < $1.timestamp }
    }

    private func updateSource(_ source: SourceHealth) {
        if let index = sources.firstIndex(where: { $0.provider == source.provider }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
    }

    private func drainPendingRefreshes() {
        guard !fullRefreshInProgress, refreshingProviders.isEmpty else {
            updateRefreshingState()
            return
        }

        if pendingFullRefresh {
            pendingFullRefresh = false
            pendingProviderRefreshes.removeAll()
            refresh()
            return
        }

        let providers = pendingProviderRefreshes
        pendingProviderRefreshes.removeAll()
        for provider in providers {
            refreshProvider(provider)
        }
        updateRefreshingState()
    }

    private func updateRefreshingState() {
        isRefreshing = fullRefreshInProgress || !refreshingProviders.isEmpty
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
        var providerCost = Dictionary(uniqueKeysWithValues: UsageProvider.allCases.map { ($0, 0.0) })
        var modelUsage: [ModelKey: TokenUsage] = [:]
        var modelCost: [ModelKey: Double] = [:]
        var modelPriced: [ModelKey: Bool] = [:]
        var unpricedModels = Set<ModelKey>()
        var sessionTokens = Set<UUID>()
        var timelineTotals: [TimelineKey: Int] = [:]

        var costInput = 0.0
        var costOutput = 0.0
        var costCacheRead = 0.0
        var costCacheWrite = 0.0

        let mtok = 1_000_000.0
        for event in selectedEvents {
            usage = usage + event.usage
            providerUsage[event.provider, default: .zero] = providerUsage[event.provider, default: .zero] + event.usage
            let modelKey = ModelKey(provider: event.provider, model: event.model)
            modelUsage[modelKey, default: .zero] = modelUsage[modelKey, default: .zero] + event.usage
            sessionTokens.insert(event.sessionToken)

            let date = bucketDate(for: event.timestamp, range: range, calendar: calendar)
            let timelineKey = TimelineKey(date: date, provider: event.provider)
            timelineTotals[timelineKey, default: 0] += event.usage.recordedTotal

            // Cost estimate — same single pass, no second loop. Unknown models
            // contribute $0 and are tracked in `unpricedModels` so the UI can
            // surface the gap rather than silently understating cost.
            if let rate = Pricing.rate(for: event.model) {
                modelPriced[modelKey] = true
                let inputUSD = Double(event.usage.input) * rate.inputPerMTok / mtok
                let cacheReadUSD = Double(event.usage.cacheRead) * rate.cachedInputPerMTok / mtok
                let cacheWriteUSD = Double(event.usage.cacheWrite) * rate.inputPerMTok / mtok
                let outputUSD = Double(event.usage.output) * rate.outputPerMTok / mtok
                let reasoningUSD = Double(event.usage.reasoningOutput) * rate.outputPerMTok / mtok
                let eventCost = inputUSD + cacheReadUSD + cacheWriteUSD + outputUSD + reasoningUSD
                costInput += inputUSD
                costCacheRead += cacheReadUSD
                costCacheWrite += cacheWriteUSD
                costOutput += outputUSD + reasoningUSD
                providerCost[event.provider, default: 0] += eventCost
                modelCost[modelKey, default: 0] += eventCost
            } else {
                modelPriced[modelKey] = false
                unpricedModels.insert(modelKey)
            }
        }

        var timeline: [TimelineBucket] = []
        for (key, total) in timelineTotals {
            timeline.append(TimelineBucket(date: key.date, provider: key.provider, recordedTotal: total))
        }
        timeline.sort {
            $0.date == $1.date ? $0.provider.rawValue < $1.provider.rawValue : $0.date < $1.date
        }

        let cacheReadShare = computeCacheShare(from: selectedEvents, allEvents: events, range: range, now: now, calendar: calendar)
        let models = modelUsage.map { key, value in
            ModelSummary(
                provider: key.provider,
                model: key.model,
                usage: value,
                costUSD: modelCost[key, default: 0],
                priced: modelPriced[key, default: false]
            )
        }.sorted { $0.usage.recordedTotal > $1.usage.recordedTotal }

        let cost = CostEstimate(
            totalUSD: costInput + costOutput + costCacheRead + costCacheWrite,
            inputUSD: costInput,
            outputUSD: costOutput,
            cacheReadUSD: costCacheRead,
            cacheWriteUSD: costCacheWrite,
            unpricedModelCount: unpricedModels.count
        )

        return UsageSnapshot(
            range: range,
            usage: usage,
            providers: UsageProvider.allCases.map {
                ProviderSummary(provider: $0, usage: providerUsage[$0, default: .zero], costUSD: providerCost[$0, default: 0])
            },
            models: models,
            timeline: timeline,
            sessionCount: sessionTokens.count,
            cacheReadShare: cacheReadShare,
            currentStreak: currentStreak(events: selectedEvents, now: now, calendar: calendar),
            peakActivityLabel: peakActivityLabel(timeline: timeline, range: range),
            sources: sources,
            cost: cost
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

    private static func computeCacheShare(
        from selectedEvents: [UsageEvent],
        allEvents: [UsageEvent],
        range: UsageRange,
        now: Date,
        calendar: Calendar
    ) -> CacheShare? {
        if let share = cacheShare(over: selectedEvents) {
            return share
        }
        for wider in widerRanges(after: range) {
            let start = rangeStart(wider, now: now, calendar: calendar)
            let window = allEvents.filter { $0.timestamp >= start && $0.timestamp <= now }
            if let share = cacheShare(over: window) {
                return .init(value: share.value, inferred: true)
            }
        }
        return nil
    }

    private static func cacheShare(over events: [UsageEvent]) -> CacheShare? {
        let cacheEvents = events.filter(reportsCacheTokens)
        let cacheRead = cacheEvents.map(\.usage.cacheRead).reduce(0, +)
        let input = cacheEvents.map(\.usage.input).reduce(0, +)
        let denom = cacheRead + input
        guard denom > 0 else { return nil }
        return .init(value: Double(cacheRead) / Double(denom), inferred: false)
    }

    private static func reportsCacheTokens(_ event: UsageEvent) -> Bool {
        event.provider != .openCode
        || !CacheReporting.nonReportingOpenCodeProviders.contains(event.openCodeProviderID ?? "")
    }

    private static func widerRanges(after range: UsageRange) -> [UsageRange] {
        let all = UsageRange.allCases
        guard let start = all.firstIndex(of: range) else { return [] }
        return Array(all[(start + 1)...])
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
