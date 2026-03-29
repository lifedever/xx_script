import Foundation

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let level: String
    let message: String
    let timestamp: Date

    init(level: String, message: String) {
        self.level = level
        self.message = message
        self.timestamp = Date()
    }
}

struct LogMessage: Codable, Sendable {
    let type: String
    let payload: String
}
