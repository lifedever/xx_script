// BoxX/Services/ClashYAMLParser.swift
import Foundation

struct ClashYAMLParser: ProxyParser {

    // MARK: - ProxyParser

    func canParse(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Must contain "proxies:" and must NOT look like JSON
        return trimmed.contains("proxies:") && !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[")
    }

    func parse(_ data: Data) throws -> [ParsedProxy] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParserError.invalidFormat("Cannot decode data as UTF-8")
        }
        let blocks = splitProxyBlocks(text)
        if blocks.isEmpty {
            throw ParserError.invalidFormat("No proxies found in YAML")
        }
        return blocks.compactMap { block in
            parseProxyBlock(block)
        }
    }

    // MARK: - YAML splitting

    /// Find the `proxies:` section and split into individual proxy blocks.
    private func splitProxyBlocks(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")

        // Find the line containing "proxies:"
        guard let proxiesIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxies:") }) else {
            return []
        }

        // Collect lines after "proxies:" until we hit another top-level key
        var proxyLines: [String] = []
        for i in (proxiesIdx + 1)..<lines.count {
            let line = lines[i]
            // Stop at next top-level key (no leading whitespace, ends with ':')
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.hasSuffix(":") && trimmed != "proxies:" {
                break
            }
            proxyLines.append(line)
        }

        // Split by "  - " (list item markers) - items starting with "  -" at 2+ spaces
        var blocks: [String] = []
        var current: [String] = []

        for line in proxyLines {
            let stripped = line.replacingOccurrences(of: "\t", with: "    ")
            if isListItemStart(stripped) {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }

        return blocks
    }

    /// Detect lines like "  - name:" or "  - {" - a YAML list item at indentation >= 2
    private func isListItemStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .init(charactersIn: " "))
        guard trimmed.hasPrefix("- ") || trimmed == "-" else { return false }
        // Must have leading whitespace (it's under proxies:)
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        return leadingSpaces >= 2
    }

    // MARK: - Parse a single proxy block into key-value dict

    private func parseProxyBlock(_ block: String) -> ParsedProxy? {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)

        // Detect inline format: "  - { key: value, key: value }"
        let afterDash: String
        if trimmed.hasPrefix("- ") {
            afterDash = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else {
            afterDash = trimmed
        }

        let dict: [String: JSONValue]
        if afterDash.hasPrefix("{") && afterDash.hasSuffix("}") {
            // Inline YAML flow mapping
            dict = parseInlineYAML(afterDash)
        } else {
            // Multi-line indented format
            dict = parseYAMLBlock(block)
        }

        guard let name = stringVal(dict["name"]),
              let typeStr = stringVal(dict["type"]),
              let server = stringVal(dict["server"]),
              let port = intVal(dict["port"]) else {
            return nil
        }

        let proxyType: ProxyType
        switch typeStr {
        case "vmess": proxyType = .vmess
        case "ss": proxyType = .shadowsocks
        case "trojan": proxyType = .trojan
        case "hysteria2", "hy2": proxyType = .hysteria2
        case "vless": proxyType = .vless
        default: return nil
        }

        let rawJSON = convertToSingBox(dict: dict, type: proxyType, server: server, port: port, name: name)

        return ParsedProxy(
            tag: name,
            type: proxyType,
            server: server,
            port: port,
            rawJSON: rawJSON
        )
    }

    // MARK: - Inline YAML flow mapping parser

    /// Parse an inline YAML flow mapping like `{ key: value, key: value, nested: { k: v } }`
    private func parseInlineYAML(_ text: String) -> [String: JSONValue] {
        var content = text.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("{") { content = String(content.dropFirst()) }
        if content.hasSuffix("}") { content = String(content.dropLast()) }
        content = content.trimmingCharacters(in: .whitespaces)

        var result: [String: JSONValue] = [:]
        let pairs = splitRespectingBraces(content)

        for pair in pairs {
            let trimmedPair = pair.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmedPair.firstIndex(of: ":") else { continue }
            var key = String(trimmedPair[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmedPair[trimmedPair.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            // Remove quotes from key (JSON style: "name" → name)
            if (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")) {
                key = String(key.dropFirst().dropLast())
            }

            // Remove quotes from value
            if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast())
            }

            // Check for nested object
            if value.hasPrefix("{") && value.hasSuffix("}") {
                result[key] = .object(parseInlineYAML(value))
            } else {
                result[key] = parseScalar(value)
            }
        }
        return result
    }

    /// Split string by commas, but don't split inside nested `{ }` or quotes.
    private func splitRespectingBraces(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inQuote = false
        var quoteChar: Character = "'"

        for char in text {
            if !inQuote && (char == "'" || char == "\"") {
                inQuote = true
                quoteChar = char
                current.append(char)
            } else if inQuote && char == quoteChar {
                inQuote = false
                current.append(char)
            } else if !inQuote && char == "{" {
                depth += 1
                current.append(char)
            } else if !inQuote && char == "}" {
                depth -= 1
                current.append(char)
            } else if !inQuote && char == "," && depth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(current)
        }
        return result
    }

    // MARK: - Minimal YAML parser (for Clash proxy blocks)

    /// Parse a YAML block into a nested dictionary of JSONValue.
    /// Handles: scalar values, simple nested objects (by indentation), quoted strings.
    private func parseYAMLBlock(_ block: String) -> [String: JSONValue] {
        let lines = block.components(separatedBy: "\n")
        var result: [String: JSONValue] = [:]
        var i = 0

        // Find the first list item marker and strip it
        while i < lines.count {
            let stripped = lines[i].replacingOccurrences(of: "\t", with: "    ")
            let trimmed = stripped.trimmingCharacters(in: .init(charactersIn: " "))
            if trimmed.hasPrefix("- ") {
                // First line: "  - key: value" → treat as "key: value" at base indent
                let afterDash = String(trimmed.dropFirst(2))
                if let colonIdx = afterDash.firstIndex(of: ":") {
                    let key = String(afterDash[afterDash.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let val = String(afterDash[afterDash.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                    result[key] = parseScalar(val)
                }
                i += 1
                break
            }
            i += 1
        }

        // Parse remaining lines - determine base indent
        let baseIndent = findBaseIndent(lines: lines, startIndex: i)

        while i < lines.count {
            let line = lines[i].replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .init(charactersIn: " "))
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            let indent = line.prefix(while: { $0 == " " }).count
            if indent < baseIndent {
                break
            }

            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let afterColon = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

                if afterColon.isEmpty {
                    // Nested object - collect child lines
                    var childLines: [String] = []
                    let childStart = i + 1
                    var j = childStart
                    while j < lines.count {
                        let childLine = lines[j].replacingOccurrences(of: "\t", with: "    ")
                        let childTrimmed = childLine.trimmingCharacters(in: .init(charactersIn: " "))
                        if childTrimmed.isEmpty || childTrimmed.hasPrefix("#") {
                            childLines.append(lines[j])
                            j += 1
                            continue
                        }
                        let childIndent = childLine.prefix(while: { $0 == " " }).count
                        if childIndent > indent {
                            childLines.append(lines[j])
                            j += 1
                        } else {
                            break
                        }
                    }
                    result[key] = .object(parseNestedYAML(childLines, baseIndent: indent + 2))
                    i = j
                } else {
                    result[key] = parseScalar(afterColon)
                    i += 1
                }
            } else {
                i += 1
            }
        }

        return result
    }

    private func parseNestedYAML(_ lines: [String], baseIndent: Int) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        var i = 0

        while i < lines.count {
            let line = lines[i].replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .init(charactersIn: " "))
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            let indent = line.prefix(while: { $0 == " " }).count

            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let afterColon = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

                if afterColon.isEmpty {
                    // Sub-nested object
                    var childLines: [String] = []
                    var j = i + 1
                    while j < lines.count {
                        let childLine = lines[j].replacingOccurrences(of: "\t", with: "    ")
                        let childTrimmed = childLine.trimmingCharacters(in: .init(charactersIn: " "))
                        if childTrimmed.isEmpty || childTrimmed.hasPrefix("#") {
                            childLines.append(lines[j])
                            j += 1
                            continue
                        }
                        let childIndent = childLine.prefix(while: { $0 == " " }).count
                        if childIndent > indent {
                            childLines.append(lines[j])
                            j += 1
                        } else {
                            break
                        }
                    }
                    result[key] = .object(parseNestedYAML(childLines, baseIndent: indent + 2))
                    i = j
                } else {
                    result[key] = parseScalar(afterColon)
                    i += 1
                }
            } else {
                i += 1
            }
        }

        return result
    }

    private func findBaseIndent(lines: [String], startIndex: Int) -> Int {
        for i in startIndex..<lines.count {
            let line = lines[i].replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .init(charactersIn: " "))
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                return line.prefix(while: { $0 == " " }).count
            }
        }
        return 4
    }

    // MARK: - Scalar parsing

    private func parseScalar(_ value: String) -> JSONValue {
        if value.isEmpty { return .null }

        // Quoted string
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            let unquoted = String(value.dropFirst().dropLast())
            return .string(unquoted)
        }

        // Boolean
        let lower = value.lowercased()
        if lower == "true" { return .bool(true) }
        if lower == "false" { return .bool(false) }
        if lower == "null" || lower == "~" { return .null }

        // Number
        if let intVal = Int(value) {
            return .number(Double(intVal))
        }
        if let doubleVal = Double(value) {
            return .number(doubleVal)
        }

        // Plain string
        return .string(value)
    }

    // MARK: - Helpers to extract values

    private func stringVal(_ val: JSONValue?) -> String? {
        switch val {
        case .string(let s): return s
        case .number(let n):
            guard n.isFinite else { return nil }
            return n == n.rounded() ? String(Int(n)) : String(n)
        default: return nil
        }
    }

    private func intVal(_ val: JSONValue?) -> Int? {
        switch val {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private func boolVal(_ val: JSONValue?) -> Bool? {
        switch val {
        case .bool(let b): return b
        case .string(let s): return s.lowercased() == "true"
        default: return nil
        }
    }

    // MARK: - Clash → sing-box conversion

    private func convertToSingBox(dict: [String: JSONValue], type: ProxyType, server: String, port: Int, name: String) -> JSONValue {
        var obj: [String: JSONValue] = [
            "type": .string(type.rawValue),
            "tag": .string(name),
            "server": .string(server),
            "server_port": .number(Double(port)),
        ]

        switch type {
        case .vmess:
            convertVMess(dict: dict, into: &obj)
        case .shadowsocks:
            convertShadowsocks(dict: dict, into: &obj)
        case .trojan:
            convertTrojan(dict: dict, into: &obj)
        case .hysteria2:
            convertHysteria2(dict: dict, into: &obj)
        case .vless:
            convertVLESS(dict: dict, into: &obj)
        }

        return .object(obj)
    }

    // MARK: VMess

    private func convertVMess(dict: [String: JSONValue], into obj: inout [String: JSONValue]) {
        if let uuid = stringVal(dict["uuid"]) {
            obj["uuid"] = .string(uuid)
        }
        if let alterId = intVal(dict["alterId"]) {
            obj["alter_id"] = .number(Double(alterId))
        }
        let security = stringVal(dict["cipher"]) ?? "auto"
        obj["security"] = .string(security)

        // TLS
        if boolVal(dict["tls"]) == true {
            let serverName = stringVal(dict["servername"]) ?? stringVal(dict["sni"]) ?? stringVal(dict["server"]) ?? ""
            var tls: [String: JSONValue] = [
                "enabled": .bool(true),
                "server_name": .string(serverName),
            ]
            if let insecure = boolVal(dict["skip-cert-verify"]) {
                tls["insecure"] = .bool(insecure)
            }
            obj["tls"] = .object(tls)
        }

        // Transport
        if let transport = buildTransport(dict: dict) {
            obj["transport"] = transport
        }
    }

    // MARK: Shadowsocks

    private func convertShadowsocks(dict: [String: JSONValue], into obj: inout [String: JSONValue]) {
        if let method = stringVal(dict["cipher"]) {
            obj["method"] = .string(method)
        }
        if let password = stringVal(dict["password"]) {
            obj["password"] = .string(password)
        }
        // Plugin
        if let plugin = stringVal(dict["plugin"]) {
            if let pluginOptsObj = dict["plugin-opts"], case .object(let opts) = pluginOptsObj {
                if plugin == "obfs" {
                    obj["plugin"] = .string("obfs-local")
                    let mode = stringVal(opts["mode"]) ?? "http"
                    let host = stringVal(opts["host"]) ?? ""
                    obj["plugin_opts"] = .string("obfs=\(mode);obfs-host=\(host)")
                } else if plugin == "v2ray-plugin" {
                    obj["plugin"] = .string("v2ray-plugin")
                    let mode = stringVal(opts["mode"]) ?? ""
                    let host = stringVal(opts["host"]) ?? ""
                    let tlsEnabled = boolVal(opts["tls"]) == true
                    var optsStr = "mode=\(mode);host=\(host)"
                    if tlsEnabled { optsStr += ";tls" }
                    obj["plugin_opts"] = .string(optsStr)
                }
            }
        }
    }

    // MARK: Trojan

    private func convertTrojan(dict: [String: JSONValue], into obj: inout [String: JSONValue]) {
        if let password = stringVal(dict["password"]) {
            obj["password"] = .string(password)
        }
        // TLS (trojan always uses TLS)
        let serverName = stringVal(dict["sni"]) ?? stringVal(dict["servername"]) ?? stringVal(dict["server"]) ?? ""
        var tls: [String: JSONValue] = [
            "enabled": .bool(true),
            "server_name": .string(serverName),
        ]
        if let insecure = boolVal(dict["skip-cert-verify"]) {
            tls["insecure"] = .bool(insecure)
        }
        obj["tls"] = .object(tls)

        if let transport = buildTransport(dict: dict) {
            obj["transport"] = transport
        }
    }

    // MARK: Hysteria2

    private func convertHysteria2(dict: [String: JSONValue], into obj: inout [String: JSONValue]) {
        if let password = stringVal(dict["password"]) {
            obj["password"] = .string(password)
        }
        let serverName = stringVal(dict["sni"]) ?? stringVal(dict["servername"]) ?? stringVal(dict["server"]) ?? ""
        var tls: [String: JSONValue] = [
            "enabled": .bool(true),
            "server_name": .string(serverName),
        ]
        if let insecure = boolVal(dict["skip-cert-verify"]) {
            tls["insecure"] = .bool(insecure)
        }
        obj["tls"] = .object(tls)
    }

    // MARK: VLESS

    private func convertVLESS(dict: [String: JSONValue], into obj: inout [String: JSONValue]) {
        if let uuid = stringVal(dict["uuid"]) {
            obj["uuid"] = .string(uuid)
        }
        if let flow = stringVal(dict["flow"]) {
            obj["flow"] = .string(flow)
        }

        // TLS
        if boolVal(dict["tls"]) == true {
            let serverName = stringVal(dict["servername"]) ?? stringVal(dict["sni"]) ?? stringVal(dict["server"]) ?? ""
            var tls: [String: JSONValue] = [
                "enabled": .bool(true),
                "server_name": .string(serverName),
            ]
            if let insecure = boolVal(dict["skip-cert-verify"]) {
                tls["insecure"] = .bool(insecure)
            }
            // Reality
            if let realityOpts = dict["reality-opts"], case .object(let reality) = realityOpts {
                var realityObj: [String: JSONValue] = ["enabled": .bool(true)]
                if let pubKey = stringVal(reality["public-key"]) {
                    realityObj["public_key"] = .string(pubKey)
                }
                if let shortId = stringVal(reality["short-id"]) {
                    realityObj["short_id"] = .string(shortId)
                }
                tls["reality"] = .object(realityObj)
                // Reality requires uTLS
                let fingerprint = stringVal(dict["client-fingerprint"]) ?? "chrome"
                tls["utls"] = .object([
                    "enabled": .bool(true),
                    "fingerprint": .string(fingerprint),
                ])
            }
            // Also add utls if client-fingerprint is set (even without reality)
            if dict["reality-opts"] == nil, let fp = stringVal(dict["client-fingerprint"]) {
                tls["utls"] = .object([
                    "enabled": .bool(true),
                    "fingerprint": .string(fp),
                ])
            }
            obj["tls"] = .object(tls)
        }

        if let transport = buildTransport(dict: dict) {
            obj["transport"] = transport
        }
    }

    // MARK: - Transport builder

    private func buildTransport(dict: [String: JSONValue]) -> JSONValue? {
        guard let network = stringVal(dict["network"]) else { return nil }

        switch network {
        case "ws":
            var transport: [String: JSONValue] = ["type": .string("ws")]
            if let wsOpts = dict["ws-opts"], case .object(let opts) = wsOpts {
                if let path = stringVal(opts["path"]) {
                    transport["path"] = .string(path)
                }
                if let headers = opts["headers"], case .object(let hdrs) = headers {
                    var headerObj: [String: JSONValue] = [:]
                    for (k, v) in hdrs {
                        if let s = stringVal(v) {
                            headerObj[k] = .string(s)
                        }
                    }
                    if !headerObj.isEmpty {
                        transport["headers"] = .object(headerObj)
                    }
                }
            }
            return .object(transport)

        case "grpc":
            var transport: [String: JSONValue] = ["type": .string("grpc")]
            if let grpcOpts = dict["grpc-opts"], case .object(let opts) = grpcOpts {
                if let serviceName = stringVal(opts["grpc-service-name"]) {
                    transport["service_name"] = .string(serviceName)
                }
            }
            return .object(transport)

        default:
            return nil
        }
    }
}
