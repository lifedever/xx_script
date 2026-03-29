import Foundation
import ServiceManagement

actor XPCClient {
    private var connection: NSXPCConnection?

    func register() throws {
        try SMAppService.daemon(plistName: "com.boxx.helper.plist").register()
    }

    private func getConnection() -> NSXPCConnection {
        if let conn = connection { return conn }
        let conn = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { await self?.handleDisconnect() }
        }
        conn.resume()
        connection = conn
        return conn
    }

    private func handleDisconnect() {
        connection = nil
    }

    private func getProxy() -> HelperProtocol {
        getConnection().remoteObjectProxyWithErrorHandler { error in
            print("[XPCClient] remote object proxy error: \(error)")
        } as! HelperProtocol
    }

    func start(configPath: String) async -> (success: Bool, error: String?) {
        let proxy = getProxy()
        return await withCheckedContinuation { cont in
            proxy.startSingBox(configPath: configPath) { success, error in
                cont.resume(returning: (success, error))
            }
        }
    }

    func stop() async -> (success: Bool, error: String?) {
        let proxy = getProxy()
        return await withCheckedContinuation { cont in
            proxy.stopSingBox { success, error in
                cont.resume(returning: (success, error))
            }
        }
    }

    func reload() async -> (success: Bool, error: String?) {
        let proxy = getProxy()
        return await withCheckedContinuation { cont in
            proxy.reloadSingBox { success, error in
                cont.resume(returning: (success, error))
            }
        }
    }

    func getStatus() async -> (running: Bool, pid: Int32) {
        let proxy = getProxy()
        return await withCheckedContinuation { cont in
            proxy.getStatus { running, pid in
                cont.resume(returning: (running, pid))
            }
        }
    }

    func flushDNS() async -> Bool {
        let proxy = getProxy()
        return await withCheckedContinuation { cont in
            proxy.flushDNS { success in
                cont.resume(returning: success)
            }
        }
    }

    func setSystemProxy(port: Int32) async -> Bool {
        let proxy = getProxy()
        return await withCheckedContinuation { cont in
            proxy.setSystemProxy(port: port) { success in
                cont.resume(returning: success)
            }
        }
    }

    func clearSystemProxy() async -> Bool {
        let proxy = getProxy()
        return await withCheckedContinuation { cont in
            proxy.clearSystemProxy { success in
                cont.resume(returning: success)
            }
        }
    }
}
