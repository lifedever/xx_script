import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var snapshot: ConnectionSnapshot?
    @State private var clashConfig: ClashConfig?
    @State private var isOperating = false
    @State private var statsTimer: Timer?
    @State private var downloadSpeed: Int64 = 0
    @State private var uploadSpeed: Int64 = 0
    @State private var showPortSheet = false
    @State private var showRestartAlert = false

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - Status + Actions
                HStack(spacing: 12) {
                    // Status card (large)
                    dashboardCard {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(appState.isRunning ? Color.green : Color.red.opacity(0.5))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appState.isRunning ? "运行中" : "已停止")
                                    .font(.headline)
                                Text("sing-box")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Action button: context-aware single button
                            if isOperating {
                                ProgressView().controlSize(.small)
                            } else if appState.isRunning {
                                HStack(spacing: 8) {
                                    Button("重启") { Task { await doRestart() } }
                                        .controlSize(.small)
                                        .buttonStyle(.bordered)
                                    Button("停止") { Task { await doStop() } }
                                        .controlSize(.small)
                                        .buttonStyle(.bordered)
                                        .tint(.red)
                                }
                            } else {
                                Button("启动") { Task { await doStart() } }
                                    .controlSize(.regular)
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                            }
                        }
                    }

                    // Proxy mode
                    dashboardCard {
                        VStack(spacing: 6) {
                            Text("代理模式")
                                .font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { clashConfig?.mode ?? "rule" },
                                set: { newMode in
                                    Task {
                                        try? await appState.api.setMode(newMode)
                                        clashConfig = try? await appState.api.getConfig()
                                    }
                                }
                            )) {
                                Text("规则").tag("rule")
                                Text("全局").tag("global")
                                Text("直连").tag("direct")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                }

                // MARK: - Speed row
                HStack(spacing: 12) {
                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2).foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("下载").font(.caption).foregroundStyle(.secondary)
                                Text(speedString(downloadSpeed))
                                    .font(.title3.monospacedDigit().bold())
                            }
                            Spacer()
                            Text(byteFormatter.string(fromByteCount: snapshot?.downloadTotal ?? 0))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("上传").font(.caption).foregroundStyle(.secondary)
                                Text(speedString(uploadSpeed))
                                    .font(.title3.monospacedDigit().bold())
                            }
                            Spacer()
                            Text(byteFormatter.string(fromByteCount: snapshot?.uploadTotal ?? 0))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: - Stats row (connections + memory + monitor)
                HStack(spacing: 12) {
                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("活跃连接").font(.caption).foregroundStyle(.secondary)
                                Text("\(snapshot?.connections?.count ?? 0)")
                                    .font(.title3.monospacedDigit().bold())
                            }
                            Spacer()
                            Button("监控") { openWindow(id: "monitor") }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                        }
                    }

                    if let mem = snapshot?.memory {
                        dashboardCard {
                            HStack(spacing: 10) {
                                Image(systemName: "memorychip")
                                    .font(.title2).foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("内存").font(.caption).foregroundStyle(.secondary)
                                    Text(byteFormatter.string(fromByteCount: mem))
                                        .font(.title3.monospacedDigit().bold())
                                }
                                Spacer()
                            }
                        }
                    }
                }

                // MARK: - Proxy info
                HStack(spacing: 12) {
                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "network")
                                .font(.title2).foregroundStyle(.blue)
                            let inbound = appState.configEngine.proxyInbound
                            VStack(alignment: .leading, spacing: 2) {
                                Text(inbound.isMixed ? "HTTP/SOCKS" : "HTTP / SOCKS")
                                    .font(.caption).foregroundStyle(.secondary)
                                if inbound.isMixed {
                                    Text(verbatim: "127.0.0.1:\(inbound.mixedPort)")
                                        .font(.title3.monospaced().bold())
                                        .textSelection(.enabled)
                                } else {
                                    HStack(spacing: 4) {
                                        Text(verbatim: "HTTP:\(inbound.httpPort)")
                                        Text("|").foregroundStyle(.secondary)
                                        Text(verbatim: "SOCKS:\(inbound.socksPort)")
                                    }
                                    .font(.title3.monospaced().bold())
                                    .textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Button("修改") { showPortSheet = true }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                        }
                    }
                    infoCard(icon: "antenna.radiowaves.left.and.right", iconColor: .purple, title: "Clash API",
                             value: appState.configEngine.config.experimental?.clashApi?.externalController ?? "127.0.0.1:9091")
                }

                HStack(spacing: 12) {
                    // Config directory
                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .font(.title2).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("配置目录").font(.caption).foregroundStyle(.secondary)
                                Text(appState.configEngine.baseDir.path)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button {
                                NSWorkspace.shared.open(appState.configEngine.baseDir)
                            } label: {
                                Text("打开")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    // Env copy
                    dashboardCard {
                        HStack(spacing: 10) {
                            Image(systemName: "terminal.fill")
                                .font(.title2).foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("环境变量").font(.caption).foregroundStyle(.secondary)
                                Text("https_proxy / http_proxy / all_proxy")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                let inb = appState.configEngine.proxyInbound
                                let httpPort = inb.isMixed ? inb.mixedPort : inb.httpPort
                                let socksPort = inb.isMixed ? inb.mixedPort : inb.socksPort
                                let env = "export https_proxy=http://127.0.0.1:\(httpPort)\nexport http_proxy=http://127.0.0.1:\(httpPort)\nexport all_proxy=socks5://127.0.0.1:\(socksPort)"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(env, forType: .string)
                            } label: {
                                Text("复制")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding()
        }
        .task { await refresh() }
        .onChange(of: appState.isRunning) { _, running in
            if running { startStatsPolling() } else { stopStatsPolling(); resetStats() }
        }
        .onDisappear { stopStatsPolling() }
        .sheet(isPresented: $showPortSheet) {
            ProxyPortSheet(onSaved: {
                if appState.isRunning { showRestartAlert = true }
            })
            .environment(appState)
        }
        .alert("端口已修改", isPresented: $showRestartAlert) {
            Button("立即重启") { Task { await doRestart() } }
            Button("稍后手动重启", role: .cancel) {}
        } message: {
            Text("修改监听端口需要重启 sing-box 才能生效，是否立即重启？")
        }
    }

    // MARK: - Card wrapper

    @ViewBuilder
    private func dashboardCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func infoCard(icon: String, iconColor: Color, title: String, value: String) -> some View {
        dashboardCard {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2).foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value)
                        .font(.title3.monospaced().bold())
                        .textSelection(.enabled)
                }
                Spacer()
            }
        }
    }

    private func speedString(_ bytesPerSecond: Int64) -> String {
        byteFormatter.string(fromByteCount: bytesPerSecond) + "/s"
    }

    // MARK: - Stats polling

    private func startStatsPolling() {
        stopStatsPolling()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in await pollStats() }
        }
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func pollStats() async {
        guard appState.isRunning else { return }
        let newSnapshot = try? await appState.api.getConnections()
        if let prev = snapshot, let curr = newSnapshot {
            downloadSpeed = max(0, (curr.downloadTotal - prev.downloadTotal) / 2)
            uploadSpeed = max(0, (curr.uploadTotal - prev.uploadTotal) / 2)
        }
        snapshot = newSnapshot
    }

    private func resetStats() {
        snapshot = nil
        clashConfig = nil
        downloadSpeed = 0
        uploadSpeed = 0
    }

    // MARK: - Actions

    private func doStart() async {
        isOperating = true; defer { isOperating = false }
        do {
            try appState.configEngine.deployRuntime()
            let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
            try await appState.singBoxProcess.start(configPath: runtimePath, mixedPort: appState.configEngine.mixedPort)
        } catch {
            appState.showAlert(error.localizedDescription)
        }
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func doStop() async {
        isOperating = true; defer { isOperating = false }
        await appState.singBoxProcess.stop()
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func doRestart() async {
        isOperating = true; defer { isOperating = false }
        do {
            try appState.configEngine.deployRuntime()
            let runtimePath = appState.configEngine.baseDir.appendingPathComponent("runtime-config.json").path
            try await appState.singBoxProcess.restart(configPath: runtimePath, mixedPort: appState.configEngine.mixedPort)
        } catch {
            appState.showAlert(error.localizedDescription)
        }
        StatusPoller.shared.nudge(appState: appState)
        await refresh()
    }

    private func refresh() async {
        guard appState.isRunning else { resetStats(); return }
        snapshot = try? await appState.api.getConnections()
        clashConfig = try? await appState.api.getConfig()
        startStatsPolling()
    }
}

// MARK: - Proxy Port Edit Sheet

struct ProxyPortSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var onSaved: () -> Void

    @State private var isMixed = true
    @State private var mixedPortText = "7890"
    @State private var httpPortText = "7890"
    @State private var socksPortText = "7891"
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("代理端口设置")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            Form {
                Picker("模式", selection: $isMixed) {
                    Text("共用端口 (Mixed)").tag(true)
                    Text("独立端口 (HTTP + SOCKS)").tag(false)
                }
                .pickerStyle(.radioGroup)

                if isMixed {
                    HStack {
                        Text("监听端口")
                        Spacer()
                        TextField("端口", text: $mixedPortText)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                    }
                    Text("HTTP 和 SOCKS5 共用同一端口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("HTTP 端口")
                        Spacer()
                        TextField("端口", text: $httpPortText)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                    }
                    HStack {
                        Text("SOCKS5 端口")
                        Spacer()
                        TextField("端口", text: $socksPortText)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                    }
                }

                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 360)
        .onAppear {
            let current = appState.configEngine.proxyInbound
            isMixed = current.isMixed
            mixedPortText = "\(current.mixedPort)"
            httpPortText = "\(current.httpPort)"
            socksPortText = "\(current.socksPort)"
        }
    }

    private func save() {
        if isMixed {
            guard let port = Int(mixedPortText), (1...65535).contains(port) else {
                errorMessage = "端口号无效，请输入 1-65535"
                return
            }
            let newConfig = ConfigEngine.ProxyInboundConfig(
                isMixed: true, mixedPort: port, httpPort: port, socksPort: port
            )
            applyAndDismiss(newConfig)
        } else {
            guard let hp = Int(httpPortText), (1...65535).contains(hp) else {
                errorMessage = "HTTP 端口号无效"
                return
            }
            guard let sp = Int(socksPortText), (1...65535).contains(sp) else {
                errorMessage = "SOCKS5 端口号无效"
                return
            }
            guard hp != sp else {
                errorMessage = "HTTP 和 SOCKS5 端口不能相同"
                return
            }
            let newConfig = ConfigEngine.ProxyInboundConfig(
                isMixed: false, mixedPort: hp, httpPort: hp, socksPort: sp
            )
            applyAndDismiss(newConfig)
        }
    }

    private func applyAndDismiss(_ newConfig: ConfigEngine.ProxyInboundConfig) {
        let current = appState.configEngine.proxyInbound
        // No change
        if current.isMixed == newConfig.isMixed &&
            current.mixedPort == newConfig.mixedPort &&
            current.httpPort == newConfig.httpPort &&
            current.socksPort == newConfig.socksPort {
            dismiss()
            return
        }
        appState.configEngine.applyProxyInbound(newConfig)
        do {
            try appState.configEngine.save(restartRequired: false)
            dismiss()
            onSaved()
        } catch {
            errorMessage = "保存失败: \(error.localizedDescription)"
        }
    }
}
