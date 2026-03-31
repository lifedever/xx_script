import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("通用", systemImage: "gear")
                }

            AdvancedSettingsTab()
                .tabItem {
                    Label("高级", systemImage: "wrench.and.screwdriver")
                }

            AboutTab()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("singboxRunAtLoad") private var singboxRunAtLoad = false
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("speedTestURL") private var speedTestURL = "http://cp.cloudflare.com/generate_204"
    @AppStorage("urlTestInterval") private var urlTestInterval = "3m"
    @AppStorage("urlTestTolerance") private var urlTestTolerance = 50
    @AppStorage("ruleSetUpdateInterval") private var ruleSetUpdateInterval = 24
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("开机启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = !newValue
                        }
                    }
                if let err = loginError {
                    Text(err).foregroundStyle(.red)
                }
                Toggle("sing-box 开机自启", isOn: $singboxRunAtLoad)
                    .onChange(of: singboxRunAtLoad) { _, newValue in
                        Task {
                            await appState.singBoxProcess.updateRunAtLoad(newValue)
                        }
                    }
                Text("系统启动时自动运行代理服务，需要先启动一次以安装服务")
                    .foregroundStyle(.tertiary)
                Picker("外观模式", selection: $appearanceMode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .onChange(of: appearanceMode) { _, newValue in
                    applyAppearance(newValue)
                }
            }

            Section("URLTest 设置") {
                Picker("测速 URL", selection: $speedTestURL) {
                    Text("Cloudflare").tag("http://cp.cloudflare.com/generate_204")
                    Text("Google").tag("http://www.gstatic.com/generate_204")
                    Text("Apple").tag("http://captive.apple.com/generate_204")
                }
                Picker("测速间隔", selection: $urlTestInterval) {
                    Text("1 分钟").tag("1m")
                    Text("3 分钟").tag("3m")
                    Text("5 分钟").tag("5m")
                    Text("10 分钟").tag("10m")
                }
                Picker("切换容差", selection: $urlTestTolerance) {
                    Text("30ms").tag(30)
                    Text("50ms（默认）").tag(50)
                    Text("100ms").tag(100)
                    Text("150ms").tag(150)
                    Text("200ms").tag(200)
                }
                Text("仅当新节点比当前节点快超过容差值时才会自动切换")
                    .foregroundStyle(.tertiary)
            }

            Section("规则集") {
                Picker("默认更新间隔", selection: $ruleSetUpdateInterval) {
                    Text("6 小时").tag(6)
                    Text("12 小时").tag(12)
                    Text("24 小时（默认）").tag(24)
                    Text("48 小时").tag(48)
                    Text("72 小时").tag(72)
                }
                Text("远程规则集未单独设置更新间隔时，使用此默认值")
                    .foregroundStyle(.tertiary)
            }

            Section("配置管理") {
                HStack(spacing: 10) {
                    Button("打开配置目录") {
                        NSWorkspace.shared.open(appState.configEngine.baseDir)
                    }
                    Button("导出配置") { exportConfig() }
                    Button("导入配置") { importConfig() }
                }
                HStack(spacing: 10) {
                    Button("初始化配置") { resetConfig() }
                        .foregroundStyle(.red)
                    Text("清除订阅和自定义规则，恢复为默认配置")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { applyAppearance(appearanceMode) }
    }

    private func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.title = "导出 BoxX 配置"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "BoxX-config-\(fmt.string(from: Date())).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // zip -r <output> <source> -x <excludes> — 排除项必须放最后
        task.arguments = ["-r", url.path, ".", "-x", "*/cache.db", "*/runtime-config.json"]
        task.currentDirectoryURL = appState.configEngine.baseDir
        let errPipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errPipe
        try? task.run()
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            let ok = NSAlert()
            ok.messageText = "导出成功"
            ok.informativeText = "配置已导出到: \(url.lastPathComponent)"
            ok.runModal()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "未知错误"
            let err = NSAlert()
            err.messageText = "导出失败"
            err.informativeText = errMsg
            err.alertStyle = .critical
            err.runModal()
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.title = "导入 BoxX 配置"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

            let alert = NSAlert()
            alert.messageText = "确认导入"
            alert.informativeText = "导入将覆盖当前所有配置文件，建议先导出备份。确定继续？"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "导入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            task.arguments = ["-o", url.path, "-d", appState.configEngine.baseDir.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                try? appState.configEngine.load()
                appState.pendingReload = true
                let ok = NSAlert()
                ok.messageText = "导入成功"
                ok.informativeText = "配置已导入，请点击「应用配置」生效。"
                ok.runModal()
            } else {
                let err = NSAlert()
                err.messageText = "导入失败"
                err.informativeText = "解压失败，请检查 zip 文件。"
                err.alertStyle = .critical
                err.runModal()
            }
    }

    private func resetConfig() {

        let alert = NSAlert()
        alert.messageText = "确认初始化配置？"
        alert.informativeText = "将清除所有订阅、代理节点和自定义规则，恢复为默认配置。\n\n建议先导出配置备份。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "初始化")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try appState.configEngine.resetUserContent()
            appState.configVersion += 1
            appState.pendingReload = true
            let ok = NSAlert()
            ok.messageText = "初始化成功"
            ok.informativeText = "配置已恢复为默认状态，请点击「应用配置」或重启 sing-box 生效。"
            ok.runModal()
        } catch {
            let err = NSAlert()
            err.messageText = "初始化失败"
            err.informativeText = error.localizedDescription
            err.alertStyle = .critical
            err.runModal()
        }
    }
}

// MARK: - Apply saved appearance on launch
func applySavedAppearance() {
    let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
    switch mode {
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    default: NSApp.appearance = nil
    }
}

// MARK: - Advanced

struct AdvancedSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var ntpEnabled = true
    @State private var ntpServer = "time.apple.com"
    @State private var tunStack = "mixed"
    @State private var tunAddress = "172.19.0.1/30"
    @State private var ipv6Enabled = false
    @State private var logLevel = "info"
    @State private var saved = false

    var body: some View {
        Form {
            Section("TUN 网卡") {
                Picker("协议栈", selection: $tunStack) {
                    Text("mixed（推荐）").tag("mixed")
                    Text("system").tag("system")
                    Text("gvisor").tag("gvisor")
                }
                TextField("虚拟 IP 段", text: $tunAddress, prompt: Text("172.19.0.1/30"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Toggle("启用 IPv6", isOn: $ipv6Enabled)
                Text("关闭后 TUN 不接管 IPv6 流量，可解决微信发图等国内应用的 IPv6 兼容问题")
                    .foregroundStyle(.tertiary)
            }

            Section("NTP 时间同步") {
                Toggle("启用 NTP", isOn: $ntpEnabled)
                if ntpEnabled {
                    Picker("NTP 服务器", selection: $ntpServer) {
                        Text("Apple (time.apple.com)").tag("time.apple.com")
                        Text("阿里云 (ntp.aliyun.com)").tag("ntp.aliyun.com")
                        Text("腾讯 (ntp.tencent.com)").tag("ntp.tencent.com")
                        Text("Google (time.google.com)").tag("time.google.com")
                    }
                    Text("确保系统时间准确，TLS 握手和代理协议依赖正确的时间")
                        .foregroundStyle(.tertiary)
                }
            }

            Section("日志") {
                Picker("日志级别", selection: $logLevel) {
                    Text("debug — 全部日志").tag("debug")
                    Text("info — 一般信息（推荐）").tag("info")
                    Text("warn — 仅警告").tag("warn")
                    Text("error — 仅错误").tag("error")
                }
                Text("日志文件：/tmp/boxx-singbox.log，自动按日期滚动保留 3 天")
                    .foregroundStyle(.tertiary)
            }

            Section {
                HStack {
                    Spacer()
                    if saved {
                        Text("已保存，应用配置后生效")
                            .foregroundStyle(.green)
                    }
                    Button("保存") { saveAdvanced() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadAdvanced() }
    }

    private func loadAdvanced() {
        let config = appState.configEngine.config
        for inb in config.inbounds {
            if inb["type"]?.stringValue == "tun" {
                tunStack = inb["stack"]?.stringValue ?? "mixed"
                if case .array(let addrs) = inb["address"] {
                    let v4 = addrs.compactMap(\.stringValue).first { !$0.contains(":") }
                    tunAddress = v4 ?? "172.19.0.1/30"
                    ipv6Enabled = addrs.compactMap(\.stringValue).contains { $0.contains(":") }
                } else {
                    tunAddress = inb["inet4_address"]?.stringValue ?? "172.19.0.1/30"
                    ipv6Enabled = inb["inet6_address"] != nil
                }
                break
            }
        }
        if let ntp = config.unknownFields["ntp"] {
            ntpEnabled = ntp["enabled"]?.boolValue ?? true
            ntpServer = ntp["server"]?.stringValue ?? "time.apple.com"
        }
        let configURL = appState.configEngine.baseDir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let log = raw["log"] as? [String: Any] {
            logLevel = log["level"] as? String ?? "info"
        }
    }

    private func saveAdvanced() {
        for i in appState.configEngine.config.inbounds.indices {
            if appState.configEngine.config.inbounds[i]["type"]?.stringValue == "tun" {
                if case .object(var dict) = appState.configEngine.config.inbounds[i] {
                    dict["stack"] = .string(tunStack)
                    var addrs: [JSONValue] = [.string(tunAddress)]
                    if ipv6Enabled {
                        addrs.append(.string("fdfe:dcba:9876::1/126"))
                    }
                    dict["address"] = .array(addrs)
                    dict.removeValue(forKey: "inet4_address")
                    dict.removeValue(forKey: "inet6_address")
                    appState.configEngine.config.inbounds[i] = .object(dict)
                }
                break
            }
        }
        appState.configEngine.config.unknownFields["ntp"] = .object([
            "enabled": .bool(ntpEnabled),
            "server": .string(ntpServer),
            "interval": .string("30m"),
        ])
        do {
            try appState.configEngine.save(restartRequired: true)
            let configURL = appState.configEngine.baseDir.appendingPathComponent("config.json")
            if let data = try? Data(contentsOf: configURL),
               var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var log = raw["log"] as? [String: Any] ?? [:]
                log["level"] = logLevel
                raw["log"] = log
                let newData = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
                try newData.write(to: configURL, options: .atomic)
            }
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
        } catch {
            appState.showAlert("保存失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            Text("BoxX")
                .font(.title.bold())
            Text("sing-box macOS Client")
                .foregroundStyle(.secondary)
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
