import Foundation
import SystemConfiguration

/// Manages macOS system proxy settings via networksetup command
public struct SystemProxy {

    /// Enable system HTTP/HTTPS proxy pointing to 127.0.0.1:port
    /// Note: SOCKS proxy is intentionally NOT set — it causes local discovery traffic
    /// (Bonjour, AirDrop) to flood the proxy port, since SOCKS has no skip-proxy mechanism.
    public static func enable(port: UInt16) throws {
        let services = try activeNetworkServices()
        for service in services {
            try run("networksetup", "-setwebproxy", service, "127.0.0.1", "\(port)")
            try run("networksetup", "-setsecurewebproxy", service, "127.0.0.1", "\(port)")
        }
        splog.info("Enabled HTTP/HTTPS proxy on port \(port) for services: \(services.joined(separator: ", "))", tag: "SystemProxy")
    }

    /// Disable system proxy
    public static func disable() throws {
        let services = try activeNetworkServices()
        for service in services {
            try run("networksetup", "-setwebproxystate", service, "off")
            try run("networksetup", "-setsecurewebproxystate", service, "off")
        }
        splog.info("Disabled", tag: "SystemProxy")
    }

    /// Check if system proxy is currently pointing to our port
    public static func isEnabled(port: UInt16) -> Bool {
        guard let services = try? activeNetworkServices(),
              let service = services.first else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getwebproxy", service]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return output.contains("Enabled: Yes") && output.contains("Port: \(port)")
        } catch {
            return false
        }
    }

    /// Get active network services (Wi-Fi, Ethernet, etc.)
    static func activeNetworkServices() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallnetworkservices"]
        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") && !$0.hasPrefix("An asterisk") }

        // Filter to active services by checking if they have an IP
        var active: [String] = []
        for service in lines {
            if isServiceActive(service) {
                active.append(service)
            }
        }

        // Fallback: if no active found, use Wi-Fi or first available
        if active.isEmpty {
            if lines.contains("Wi-Fi") { return ["Wi-Fi"] }
            if let first = lines.first { return [first] }
        }

        return active
    }

    private static func isServiceActive(_ service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getinfo", service]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // If service has an IP address, it's active
            return output.contains("IP address:") && !output.contains("IP address: none")
        } catch {
            return false
        }
    }

    @discardableResult
    private static func run(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0].hasPrefix("/") ? args[0] : "/usr/sbin/\(args[0])")
        process.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
