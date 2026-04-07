import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var viewModel: ProxyViewModel

    var body: some View {
        Form {
            Section("代理") {
                HStack {
                    Text("监听端口")
                    Spacer()
                    TextField("", value: $viewModel.settingsPort, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("DNS 服务器")
                    Spacer()
                    TextField("", text: $viewModel.settingsDNS)
                        .frame(width: 240)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
                Picker("日志级别", selection: $viewModel.settingsLogLevel) {
                    Text("Debug").tag("debug")
                    Text("Info").tag("info")
                    Text("Warning").tag("warning")
                    Text("Error").tag("error")
                }
            }

            Section("通用") {
                Toggle("开机自启", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { newValue in
                        viewModel.launchAtLogin = newValue
                        if newValue {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                    }
                ))
                Toggle("启动时自动刷新订阅", isOn: $viewModel.autoRefreshSubs)
            }

            Section {
                HStack {
                    Spacer()
                    Text("修改端口或 DNS 后需要重启代理生效")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
    }
}
