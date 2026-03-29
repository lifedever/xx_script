import Foundation
import ServiceManagement

final class HelperManager: @unchecked Sendable {
    static let shared = HelperManager()

    private let lock = NSLock()
    private var _xpcConnection: NSXPCConnection?

    var isHelperInstalled: Bool {
        let service = SMAppService.daemon(plistName: "com.boxx.helper.plist")
        return service.status == .enabled
    }

    func installHelper() throws {
        let service = SMAppService.daemon(plistName: "com.boxx.helper.plist")
        try service.register()
    }

    func uninstallHelper() throws {
        let service = SMAppService.daemon(plistName: "com.boxx.helper.plist")
        try service.unregister()
    }

    func getProxy() -> HelperProtocol? {
        lock.lock()
        defer { lock.unlock() }

        if let connection = _xpcConnection {
            return connection.remoteObjectProxy as? HelperProtocol
        }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.interruptionHandler = { }
        connection.invalidationHandler = { [weak self] in
            self?.lock.withLock { self?._xpcConnection = nil }
        }
        connection.resume()
        _xpcConnection = connection
        return connection.remoteObjectProxy as? HelperProtocol
    }

    func disconnect() {
        lock.withLock {
            _xpcConnection?.invalidate()
            _xpcConnection = nil
        }
    }
}
