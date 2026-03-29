import Foundation

final class ClashWebSocket: NSObject, @unchecked Sendable {
    private let baseURL: String
    private let secret: String
    private let lock = NSLock()
    private var _task: URLSessionWebSocketTask?
    private var _session: URLSession?

    private var task: URLSessionWebSocketTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }
    private var session: URLSession? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }

    init(baseURL: String = "http://127.0.0.1:9091", secret: String = "") {
        self.baseURL = baseURL.replacingOccurrences(of: "http://", with: "ws://")
        self.secret = secret
        super.init()
    }

    func connectLogs(level: String = "info") -> AsyncStream<LogEntry> {
        AsyncStream { continuation in
            let urlString = "\(baseURL)/logs?level=\(level)"
            guard let url = URL(string: urlString) else { continuation.finish(); return }
            var request = URLRequest(url: url)
            if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            let session = URLSession(configuration: config)
            let task = session.webSocketTask(with: request)
            self.session = session
            self.task = task
            task.resume()

            continuation.onTermination = { @Sendable _ in
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }

            Task { [weak self] in
                while self?.task != nil {
                    do {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            if let data = text.data(using: .utf8),
                               let log = try? JSONDecoder().decode(LogMessage.self, from: data) {
                                continuation.yield(LogEntry(level: log.type, message: log.payload))
                            }
                        case .data(let data):
                            if let log = try? JSONDecoder().decode(LogMessage.self, from: data) {
                                continuation.yield(LogEntry(level: log.type, message: log.payload))
                            }
                        @unknown default: break
                        }
                    } catch { continuation.finish(); return }
                }
            }
        }
    }

    func connectConnections() -> AsyncStream<ConnectionSnapshot> {
        AsyncStream { continuation in
            let urlString = "\(baseURL)/connections"
            guard let url = URL(string: urlString) else { continuation.finish(); return }
            var request = URLRequest(url: url)
            if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            let session = URLSession(configuration: config)
            let task = session.webSocketTask(with: request)
            self.session = session
            self.task = task
            task.resume()

            continuation.onTermination = { @Sendable _ in
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }

            Task { [weak self] in
                while self?.task != nil {
                    do {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            if let data = text.data(using: .utf8),
                               let snapshot = try? JSONDecoder().decode(ConnectionSnapshot.self, from: data) {
                                continuation.yield(snapshot)
                            }
                        case .data(let data):
                            if let snapshot = try? JSONDecoder().decode(ConnectionSnapshot.self, from: data) {
                                continuation.yield(snapshot)
                            }
                        @unknown default: break
                        }
                    } catch { continuation.finish(); return }
                }
            }
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}
