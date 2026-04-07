import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }
}

/// Simple file + console logger for ShadowProxy
public final class SPLogger: @unchecked Sendable {
    public static let shared = SPLogger()

    public var level: LogLevel = .debug
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "shadowproxy.logger")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Callback for UI log display (called on arbitrary queue)
    public var onLog: (@Sendable (String) -> Void)?

    private init() {}

    /// Set up file logging to the given path
    public func setLogFile(_ path: String) {
        queue.sync {
            // Create file if needed
            let fm = FileManager.default
            let dir = (path as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

            // Truncate on each app launch to avoid unbounded growth
            fm.createFile(atPath: path, contents: nil)
            fileHandle = FileHandle(forWritingAtPath: path)
            fileHandle?.seekToEndOfFile()
        }
    }

    public func debug(_ message: String, tag: String = "") {
        log(level: .debug, message: message, tag: tag)
    }

    public func info(_ message: String, tag: String = "") {
        log(level: .info, message: message, tag: tag)
    }

    public func warning(_ message: String, tag: String = "") {
        log(level: .warning, message: message, tag: tag)
    }

    public func error(_ message: String, tag: String = "") {
        log(level: .error, message: message, tag: tag)
    }

    private func log(level: LogLevel, message: String, tag: String) {
        guard level >= self.level else { return }
        let timestamp = formatter.string(from: Date())
        let tagStr = tag.isEmpty ? "" : "[\(tag)] "
        let line = "[\(timestamp)] [\(level.label)] \(tagStr)\(message)"

        queue.async { [weak self] in
            // Console
            print(line)
            // File
            if let data = (line + "\n").data(using: .utf8) {
                self?.fileHandle?.write(data)
            }
            // UI callback
            self?.onLog?(line)
        }
    }
}

/// Convenience global accessor
public let splog = SPLogger.shared
