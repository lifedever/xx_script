import Foundation

@objc protocol HelperProtocol {
    func startSingBox(configPath: String, withReply reply: @escaping (Bool, String?) -> Void)
    func stopSingBox(withReply reply: @escaping (Bool, String?) -> Void)
    func getStatus(withReply reply: @escaping (Bool, Int32) -> Void)
}

enum HelperConstants {
    static let machServiceName = "com.boxx.helper"
    static let singBoxPath = "/opt/homebrew/bin/sing-box"
}
