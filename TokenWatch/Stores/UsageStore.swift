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
    private var pendingInputPaths: [UsageProvider: Set<String>] = [:]
    private var inputScans: [UsageProvider: [String: InputScan]] = [:]
    private var sessionTokens = InMemorySessionTokens()

    deinit {
        MainActor.assumeIsolated {
            watcher.stopAll()
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        watcher.onChange = { [weak self] change in self?.synchronize(change) }
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
        let sessionTokens = sessionTokens

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                scanner.scanDetailed(
                    claudeRoot: claudeRoot,
                    codexRoot: codexRoot,
                    openCodeRoot: openCodeRoot,
                    sessionTokens: sessionTokens
                )
            }.value

            guard let self else { return }
            self.applyDetailedScanResult(result)
            self.fullRefreshInProgress = false
            self.drainPendingRefreshes()
        }
    }

    /// Provider-wide recovery pass for dropped FSEvents or directory changes.
    func refreshProvider(_ provider: UsageProvider) {
        guard !fullRefreshInProgress, !refreshingProviders.contains(provider) else {
            pendingProviderRefreshes.insert(provider)
            pendingInputPaths.removeValue(forKey: provider)
            return
        }
        refreshingProviders.insert(provider)
        updateRefreshingState()

        let root = ProviderPaths.root(for: provider)
        let scanner = TranscriptScanner()
        let sessionTokens = sessionTokens

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                scanner.scanProviderDetailed(provider, root: root, sessionTokens: sessionTokens, now: Date())
            }.value

            guard let self else { return }
            self.applyDetailedScanResult(result)
            self.refreshingProviders.remove(provider)
            self.drainPendingRefreshes()
        }
    }

    private func synchronize(_ change: TranscriptChange) {
        if change.requiresProviderRescan {
            refreshProvider(change.provider)
        } else {
            refreshInputs(for: change.provider, paths: change.inputPaths)
        }
    }

    private func refreshInputs(for provider: UsageProvider, paths: Set<String>) {
        guard !paths.isEmpty else { return }
        guard !fullRefreshInProgress, !refreshingProviders.contains(provider), !pendingProviderRefreshes.contains(provider) else {
            pendingInputPaths[provider, default: []].formUnion(paths)
            return
        }
        refreshingProviders.insert(provider)
        updateRefreshingState()

        let scanner = TranscriptScanner()
        let sessionTokens = sessionTokens

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                scanner.scanInputs(provider, paths: paths, sessionTokens: sessionTokens)
            }.value

            guard let self else { return }
            self.applyInputScanBatch(result)
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

    private func applyDetailedScanResult(_ result: DetailedScanResult) {
        for providerScan in result.providers {
            let source = providerScan.source
            let hasLastKnownGood = !(inputScans[providerScan.provider]?.isEmpty ?? true)
            let allScannedFilesFailed = source.scannedFiles > 0 && source.unreadableFiles == source.scannedFiles
            if !hasLastKnownGood || !allScannedFilesFailed {
                inputScans[providerScan.provider] = Dictionary(
                    uniqueKeysWithValues: providerScan.inputs.map { ($0.path, $0) }
                )
            }
            updateSource(source)
        }
        sessionTokens = result.sessionTokens
        rebuildEvents()
    }

    private func applyInputScanBatch(_ batch: InputScanBatch) {
        var providerInputs = inputScans[batch.provider, default: [:]]
        for path in batch.removedPaths {
            providerInputs.removeValue(forKey: path)
        }
        for input in batch.inputs {
            if input.unreadable, let previous = providerInputs[input.path] {
                providerInputs[input.path] = InputScan(
                    provider: previous.provider,
                    path: previous.path,
                    events: previous.events,
                    malformedLines: previous.malformedLines,
                    unreadable: true
                )
            } else {
                providerInputs[input.path] = input
            }
        }
        inputScans[batch.provider] = providerInputs
        sessionTokens = batch.sessionTokens
        updateSource(incrementalSourceHealth(for: batch.provider, inputs: providerInputs.values, now: Date()))
        rebuildEvents()
    }

    private func rebuildEvents() {
        events = inputScans.values
            .flatMap(\.values)
            .flatMap(\.events)
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func incrementalSourceHealth(
        for provider: UsageProvider,
        inputs: Dictionary<String, InputScan>.Values,
        now: Date
    ) -> SourceHealth {
        var source = SourceHealth.unconfigured(provider)
        guard let root = ProviderPaths.root(for: provider) else { return source }
        let directory = root.appendingPathComponent(provider.expectedRelativeDirectory, isDirectory: true)
        guard directoryExists(directory) else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            return source
        }
        guard provider != .openCode || !inputs.isEmpty else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            return source
        }

        source.state = .ready
        source.scannedFiles = inputs.count
        source.usageRecords = inputs.map { $0.events.count }.reduce(0, +)
        source.malformedLines = inputs.map(\.malformedLines).reduce(0, +)
        source.unreadableFiles = inputs.filter(\.unreadable).count
        if provider == .openCode, source.unreadableFiles == source.scannedFiles {
            source.state = .inaccessible
        }
        source.lastRefresh = now
        return source
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
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
            pendingInputPaths.removeAll()
            refresh()
            return
        }

        let providers = pendingProviderRefreshes
        pendingProviderRefreshes.removeAll()
        for provider in providers {
            refreshProvider(provider)
        }
        let inputs = pendingInputPaths
        pendingInputPaths.removeAll()
        for (provider, paths) in inputs where !providers.contains(provider) {
            refreshInputs(for: provider, paths: paths)
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
        guard !selectedEvents.isEmpty else { return .empty(range: range, sources: sources, generatedAt: now) }

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
                let cacheWrite5mUSD = Double(event.usage.cacheWrite5m) * rate.cacheWrite5mPerMTok / mtok
                let cacheWrite1hUSD = Double(event.usage.cacheWrite1h) * rate.cacheWrite1hPerMTok / mtok
                let cacheWriteUSD = cacheWrite5mUSD + cacheWrite1hUSD
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
            sources: sources,
            cost: cost,
            generatedAt: now
        )
    }

    private static func rangeStart(_ range: UsageRange, now: Date, calendar: Calendar) -> Date {
        guard let dayCount = range.dayCount else { return .distantPast }
        let today = calendar.startOfDay(for: now)
        if range == .today { return today }
        if range == .day {
            let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            return calendar.date(byAdding: .hour, value: -23, to: currentHour) ?? currentHour
        }
        return calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
    }

    private static func bucketDate(for date: Date, range: UsageRange, calendar: Calendar) -> Date {
        if range == .today || range == .day {
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        }
        if range == .total {
            return calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
        return calendar.startOfDay(for: date)
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
        let cacheWrite = cacheEvents.map(\.usage.cacheWrite).reduce(0, +)
        let denom = cacheRead + input + cacheWrite
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
        var wider = Array(all[(start + 1)...])
        // .today should not fall back to .day because the rolling 24-hour window
        // is not always a superset of the calendar day.
        if range == .today, let dayIndex = wider.firstIndex(of: .day) {
            wider.remove(at: dayIndex)
        }
        return wider
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
