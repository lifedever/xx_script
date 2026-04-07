import Foundation
import Network

/// Local HTTP/SOCKS5 proxy listener
/// Accepts client connections, parses proxy requests, and forwards to the handler
public final class Inbound: @unchecked Sendable {
    private let listener: NWListener
    private let handler: @Sendable (NWConnection, ProxyRequest) -> Void
    private let queue = DispatchQueue(label: "shadowproxy.inbound")

    public struct ProxyRequest: Sendable {
        public let target: ProxyTarget
        public let initialData: Data?  // For plain HTTP requests, the full request data

        public init(target: ProxyTarget, initialData: Data? = nil) {
            self.target = target
            self.initialData = initialData
        }
    }

    public init(port: UInt16, handler: @escaping @Sendable (NWConnection, ProxyRequest) -> Void) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.handler = handler
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                splog.info("Listening on port \(self.listener.port?.rawValue ?? 0)", tag: "Inbound")
            case .failed(let error):
                splog.error("Failed: \(error)", tag: "Inbound")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    public var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        splog.debug("New connection from \(connection.endpoint)", tag: "Inbound")
        // Read initial bytes to determine protocol
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            if let error {
                splog.error("Read error: \(error)", tag: "Inbound")
                connection.cancel()
                return
            }
            guard let self, let data, !data.isEmpty else {
                splog.debug("Empty data or nil self", tag: "Inbound")
                connection.cancel()
                return
            }
            splog.debug("Received \(data.count) bytes, first byte: \(data.first ?? 0)", tag: "Inbound")
            self.parseRequest(connection: connection, data: data)
        }
    }

    private func parseRequest(connection: NWConnection, data: Data) {
        if data.first == 0x05 {
            // SOCKS5
            handleSOCKS5(connection: connection, data: data)
        } else {
            // HTTP
            handleHTTP(connection: connection, data: data)
        }
    }

    // MARK: - HTTP Proxy

    private func handleHTTP(connection: NWConnection, data: Data) {
        guard let requestStr = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }

        let lines = requestStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            connection.cancel()
            return
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }

        let method = String(parts[0])
        let target = String(parts[1])

        if method.uppercased() == "CONNECT" {
            // HTTPS tunnel: CONNECT host:port HTTP/1.1
            handleHTTPConnect(connection: connection, target: target)
        } else {
            // Plain HTTP: GET http://host/path HTTP/1.1
            handleHTTPPlain(connection: connection, requestData: data, target: target)
        }
    }

    private func handleHTTPConnect(connection: NWConnection, target: String) {
        guard let (host, port) = parseHostPort(target) else {
            connection.cancel()
            return
        }

        // Reply 200 Connection Established
        let response = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                connection.cancel()
                return
            }
            let request = ProxyRequest(target: ProxyTarget(host: host, port: port))
            self?.handler(connection, request)
        })
    }

    private func handleHTTPPlain(connection: NWConnection, requestData: Data, target: String) {
        // Parse URL from target like "http://host:port/path"
        guard let url = URL(string: target),
              let host = url.host else {
            connection.cancel()
            return
        }
        let port = UInt16(url.port ?? 80)
        let request = ProxyRequest(
            target: ProxyTarget(host: host, port: port),
            initialData: requestData
        )
        handler(connection, request)
    }

    // MARK: - SOCKS5

    private func handleSOCKS5(connection: NWConnection, data: Data) {
        // Client greeting: [version(1)][nmethods(1)][methods(nmethods)]
        guard data.count >= 3, data[0] == 0x05 else {
            connection.cancel()
            return
        }

        // Reply: no auth required
        let reply = Data([0x05, 0x00])
        connection.send(content: reply, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                connection.cancel()
                return
            }
            self?.readSOCKS5Request(connection: connection)
        })
    }

    private func readSOCKS5Request(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 512) { [weak self] data, _, _, error in
            guard let self, let data, error == nil, data.count >= 4 else {
                connection.cancel()
                return
            }
            self.parseSOCKS5Request(connection: connection, data: data)
        }
    }

    private func parseSOCKS5Request(connection: NWConnection, data: Data) {
        // [version(1)][cmd(1)][rsv(1)][atyp(1)]...
        guard data[0] == 0x05, data[1] == 0x01 else { // CMD = CONNECT
            connection.cancel()
            return
        }

        let atyp = data[3]
        var host: String
        var portOffset: Int

        switch atyp {
        case 0x01: // IPv4
            guard data.count >= 10 else { connection.cancel(); return }
            host = "\(data[4]).\(data[5]).\(data[6]).\(data[7])"
            portOffset = 8
        case 0x03: // Domain
            let domainLen = Int(data[4])
            guard data.count >= 5 + domainLen + 2 else { connection.cancel(); return }
            host = String(data: data[5..<(5 + domainLen)], encoding: .utf8) ?? ""
            portOffset = 5 + domainLen
        case 0x04: // IPv6
            guard data.count >= 22 else { connection.cancel(); return }
            // Simplified IPv6 representation
            let bytes = data[4..<20]
            host = bytes.map { String(format: "%02x", $0) }
                .chunks(of: 2).map { $0.joined() }.joined(separator: ":")
            portOffset = 20
        default:
            connection.cancel()
            return
        }

        let port = (UInt16(data[portOffset]) << 8) | UInt16(data[portOffset + 1])

        // Reply: success
        let reply = Data([0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        connection.send(content: reply, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                connection.cancel()
                return
            }
            let request = ProxyRequest(target: ProxyTarget(host: host, port: port))
            self?.handler(connection, request)
        })
    }

    // MARK: - Helpers

    private func parseHostPort(_ target: String) -> (String, UInt16)? {
        let parts = target.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }
}

// MARK: - Array Extension

extension Array {
    func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
