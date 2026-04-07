import Foundation

public struct RequestRecord: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let host: String
    public let port: UInt16
    public let requestProtocol: String
    public let policy: String
    public let node: String?
    public let matchedRule: String?
    public var elapsed: Int?
    public var status: RequestStatus

    public init(host: String, port: UInt16, requestProtocol: String, policy: String,
                node: String? = nil, matchedRule: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.host = host
        self.port = port
        self.requestProtocol = requestProtocol
        self.policy = policy
        self.node = node
        self.matchedRule = matchedRule
        self.elapsed = nil
        self.status = .active
    }
}

public enum RequestStatus: Sendable {
    case active, completed, failed
}
