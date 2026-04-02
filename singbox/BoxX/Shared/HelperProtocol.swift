import Foundation

@objc protocol HelperProtocol {
    func startSingBox(configPath: String, withReply reply: @escaping (Bool, String?) -> Void)
    func stopSingBox(withReply reply: @escaping (Bool, String?) -> Void)
    func getStatus(withReply reply: @escaping (Bool, Int32) -> Void)
    func reloadSingBox(withReply reply: @escaping (Bool, String?) -> Void)
    func flushDNS(withReply reply: @escaping (Bool) -> Void)
    func setSystemProxy(port: Int32, withReply reply: @escaping (Bool) -> Void)
    func clearSystemProxy(withReply reply: @escaping (Bool) -> Void)

    /// Long-poll: Helper holds reply until sing-box exits, then returns (wasRunning, exitCode).
    func watchProcessExit(withReply reply: @escaping (Bool, Int32) -> Void)

    /// Clean up legacy launchd daemon (one-time migration)
    func removeLegacyDaemon(withReply reply: @escaping (Bool) -> Void)
}

enum HelperConstants {
    static let machServiceName = "com.boxx.helper"
    static let singBoxPath = "/opt/homebrew/bin/sing-box"
}
