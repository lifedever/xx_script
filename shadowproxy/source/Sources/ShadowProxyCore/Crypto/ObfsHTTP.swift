import Foundation

/// obfs-http plugin for Shadowsocks
/// First request is disguised as an HTTP GET request
/// First response strips the HTTP header
/// Subsequent data is passed through directly
public struct ObfsHTTP: Sendable {
    public let host: String

    public init(host: String) {
        self.host = host
    }

    /// Wrap the first outgoing payload in an HTTP request (simple-obfs compatible)
    /// Format matches obfs-local: websocket upgrade with Content-Length for payload
    public func wrapRequest(_ payload: Data) -> Data {
        let path = "/" + randomHexString(length: 16)
        let wsKey = randomBase64Key()
        let header = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)",
            "User-Agent: curl/7.54.0",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(wsKey)",
            "Content-Length: \(payload.count)",
            "",
            "",
        ].joined(separator: "\r\n")

        return Data(header.utf8) + payload
    }

    /// Unwrap the first incoming HTTP response, return the payload after headers
    public func unwrapResponse(_ data: Data) -> (payload: Data, headerLength: Int)? {
        // Find \r\n\r\n
        let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = data.range(of: marker) else {
            return nil
        }
        let headerLength = range.upperBound
        let payload = data.suffix(from: headerLength)
        return (payload: Data(payload), headerLength: headerLength)
    }

    private func randomHexString(length: Int) -> String {
        (0..<length).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func randomBase64Key() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
    }
}
