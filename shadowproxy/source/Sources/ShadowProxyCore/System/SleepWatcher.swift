import Foundation
import AppKit

/// Monitors sleep/wake events and triggers recovery
public final class SleepWatcher: @unchecked Sendable {
    private let onWake: () async -> Void
    private var observers: [NSObjectProtocol] = []

    public init(onWake: @escaping () async -> Void) {
        self.onWake = onWake
    }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter

        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            splog.info("System woke up, recovering in 2 seconds...", tag: "SleepWatcher")
            Task {
                // Wait for network to come back up
                try? await Task.sleep(for: .seconds(2))
                await self.onWake()
            }
        }

        let sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            splog.info("System going to sleep", tag: "SleepWatcher")
        }

        observers = [wakeObserver, sleepObserver]
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }
}
