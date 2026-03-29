import Foundation

@objc protocol HelperProtocol {
    // v1 existing
    func startSingBox(configPath: String, withReply reply: @escaping (Bool, String?) -> Void)
    func stopSingBox(withReply reply: @escaping (Bool, String?) -> Void)
    func getStatus(withReply reply: @escaping (Bool, Int32) -> Void)

    // v2 new
    func reloadSingBox(withReply reply: @escaping (Bool, String?) -> Void)
    func flushDNS(withReply reply: @escaping (Bool) -> Void)
    func setSystemProxy(port: Int32, withReply reply: @escaping (Bool) -> Void)
    func clearSystemProxy(withReply reply: @escaping (Bool) -> Void)
}

enum HelperConstants {
    static let machServiceName = "com.boxx.helper"
    static let singBoxPath = "/opt/homebrew/bin/sing-box"
}
