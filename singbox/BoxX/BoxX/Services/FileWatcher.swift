// BoxX/Services/FileWatcher.swift
import Foundation

final class FileWatcher {
    private let path: String
    private let callback: @Sendable () -> Void
    private let debounceInterval: TimeInterval
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.boxx.filewatcher")

    init(path: String, debounceInterval: TimeInterval = 0.5, callback: @escaping @Sendable () -> Void) {
        self.path = path
        self.callback = callback
        self.debounceInterval = debounceInterval
    }

    func start() {
        let pathsToWatch = [path] as CFArray
        var context = FSEventStreamContext()

        // Store self pointer in context for the C callback
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { (_, info, _, _, _, _) in
            guard let info = info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleEvent()
        }

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,  // Latency — FSEvents coalesces events within this window
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func handleEvent() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.callback()
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    deinit {
        stop()
    }
}
