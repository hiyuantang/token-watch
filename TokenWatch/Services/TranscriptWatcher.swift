import CoreServices
import Foundation

@MainActor
final class TranscriptWatcher {
    var onChange: ((UsageProvider) -> Void)?

    private struct Watch: @unchecked Sendable {
        let stream: FSEventStreamRef
        let directory: URL
        let provider: UsageProvider
    }

    private var watches: [UsageProvider: Watch] = [:]

    deinit {
        for watch in watches.values {
            FSEventStreamStop(watch.stream)
            FSEventStreamInvalidate(watch.stream)
            FSEventStreamRelease(watch.stream)
        }
    }

    func start(for provider: UsageProvider, directory: URL) {
        stop(for: provider)

        let resolvedDirectory = directory.resolvingSymlinksInPath()
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
        let flags: FSEventStreamCreateFlags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let box = Unmanaged<WatchInfoBox>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async { box.watcher.dispatchChange(box.provider) }
            },
            &context,
            [resolvedDirectory.path as NSString] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            Unmanaged<WatchInfoBox>.fromOpaque(context.info!).release()
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        watches[provider] = Watch(stream: stream, directory: resolvedDirectory, provider: provider)
    }

    func stop(for provider: UsageProvider) {
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

    @MainActor
    fileprivate func dispatchChange(_ provider: UsageProvider) {
        onChange?(provider)
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