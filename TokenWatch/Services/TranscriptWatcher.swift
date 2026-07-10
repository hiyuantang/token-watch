import CoreServices
import Foundation

@MainActor
final class TranscriptWatcher {
    var onChange: ((UsageProvider) -> Void)?

    private struct Watch: @unchecked Sendable {
        let stream: FSEventStreamRef
        let providerRoot: URL
        let watchedDirectory: URL
        let provider: UsageProvider
    }

    private struct FileEvent: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    private var watches: [UsageProvider: Watch] = [:]
    private var pendingChanges: [UsageProvider: Task<Void, Never>] = [:]
    private let debounceDuration: Duration

    init(debounceDuration: Duration = .milliseconds(750)) {
        self.debounceDuration = debounceDuration
    }

    deinit {
        for task in pendingChanges.values {
            task.cancel()
        }
        for watch in watches.values {
            FSEventStreamStop(watch.stream)
            FSEventStreamInvalidate(watch.stream)
            FSEventStreamRelease(watch.stream)
        }
    }

    func start(for provider: UsageProvider, directory: URL) {
        stop(for: provider)

        let providerRoot = directory.resolvingSymlinksInPath()
        let watchedDirectory = Self.watchedDirectory(for: provider, providerRoot: providerRoot)
        let infoBox = WatchInfoBox(provider: provider, watcher: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(infoBox).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<WatchInfoBox>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, eventCount, eventPaths, eventFlags, _ in
                guard let info else { return }
                let box = Unmanaged<WatchInfoBox>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
                let events = (0..<Int(eventCount)).compactMap { index -> FileEvent? in
                    guard index < paths.count, let path = paths[index] as? String else { return nil }
                    return FileEvent(path: path, flags: eventFlags[index])
                }
                DispatchQueue.main.async { box.watcher.receive(events, for: box.provider) }
            },
            &context,
            [watchedDirectory.path as NSString] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            Unmanaged<WatchInfoBox>.fromOpaque(context.info!).release()
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        watches[provider] = Watch(
            stream: stream,
            providerRoot: providerRoot,
            watchedDirectory: watchedDirectory,
            provider: provider
        )
    }

    func stop(for provider: UsageProvider) {
        pendingChanges.removeValue(forKey: provider)?.cancel()
        guard let watch = watches.removeValue(forKey: provider) else { return }
        FSEventStreamStop(watch.stream)
        FSEventStreamInvalidate(watch.stream)
        FSEventStreamRelease(watch.stream)
    }

    func stopAll() {
        for provider in watches.keys {
            stop(for: provider)
        }
    }

    func isWatching(for provider: UsageProvider) -> Bool {
        watches[provider] != nil
    }

    func dispatchChange(_ provider: UsageProvider) {
        pendingChanges.removeValue(forKey: provider)?.cancel()
        let debounceDuration = debounceDuration
        pendingChanges[provider] = Task { [weak self] in
            try? await Task.sleep(for: debounceDuration)
            guard !Task.isCancelled, let self else { return }
            self.pendingChanges.removeValue(forKey: provider)
            self.onChange?(provider)
        }
    }

    private func receive(_ events: [FileEvent], for provider: UsageProvider) {
        guard let watch = watches[provider] else { return }
        guard events.contains(where: {
            Self.isRelevant(path: $0.path, flags: $0.flags, for: provider, providerRoot: watch.providerRoot)
        }) else { return }

        let preferredDirectory = Self.watchedDirectory(for: provider, providerRoot: watch.providerRoot)
        let rootChanged = events.contains { $0.flags & Self.rootChangedFlag != 0 }
        if rootChanged || preferredDirectory.standardizedFileURL != watch.watchedDirectory.standardizedFileURL {
            start(for: provider, directory: watch.providerRoot)
        }
        dispatchChange(provider)
    }

    static func isRelevant(
        path: String,
        flags: FSEventStreamEventFlags,
        for provider: UsageProvider,
        providerRoot: URL
    ) -> Bool {
        if flags & recoveryFlags != 0 { return true }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        switch provider {
        case .claudeCode, .codex:
            let inputDirectory = providerRoot
                .appendingPathComponent(provider.expectedRelativeDirectory, isDirectory: true)
                .standardizedFileURL
            guard isWithin(url, directory: inputDirectory) else { return false }
            if flags & directoryMutationFlags != 0, flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
                return true
            }
            return url.pathExtension.lowercased() == "jsonl" && flags & contentChangeFlags != 0

        case .openCode:
            return isWithin(url, directory: providerRoot)
                && isOpenCodeDatabaseArtifact(url.lastPathComponent)
                && flags & contentChangeFlags != 0
        }
    }

    private static let rootChangedFlag = UInt32(kFSEventStreamEventFlagRootChanged)
    private static let recoveryFlags: FSEventStreamEventFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs) | rootChangedFlag
    private static let contentChangeFlags: FSEventStreamEventFlags = UInt32(
        kFSEventStreamEventFlagItemCreated
        | kFSEventStreamEventFlagItemModified
        | kFSEventStreamEventFlagItemRemoved
        | kFSEventStreamEventFlagItemRenamed
    )
    private static let directoryMutationFlags: FSEventStreamEventFlags = UInt32(
        kFSEventStreamEventFlagItemCreated
        | kFSEventStreamEventFlagItemRemoved
        | kFSEventStreamEventFlagItemRenamed
    )

    private static func watchedDirectory(for provider: UsageProvider, providerRoot: URL) -> URL {
        guard provider != .openCode else { return providerRoot }
        let inputDirectory = providerRoot.appendingPathComponent(provider.expectedRelativeDirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        let inputExists = FileManager.default.fileExists(atPath: inputDirectory.path, isDirectory: &isDirectory)
        return inputExists && isDirectory.boolValue ? inputDirectory : providerRoot
    }

    private static func isWithin(_ url: URL, directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }

    private static func isOpenCodeDatabaseArtifact(_ name: String) -> Bool {
        let databaseName: String
        if name.hasSuffix("-wal") || name.hasSuffix("-shm") {
            databaseName = String(name.dropLast(4))
        } else {
            databaseName = name
        }

        guard databaseName.hasSuffix(".db") else { return false }
        let stem = databaseName.dropLast(3)
        if stem == "opencode" { return true }
        guard stem.hasPrefix("opencode-") else { return false }
        let channel = stem.dropFirst("opencode-".count)
        return !channel.isEmpty && channel.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private final class WatchInfoBox {
        let provider: UsageProvider
        let watcher: TranscriptWatcher
        init(provider: UsageProvider, watcher: TranscriptWatcher) {
            self.provider = provider
            self.watcher = watcher
        }
    }
}
