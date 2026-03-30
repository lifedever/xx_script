import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label(String(localized: "settings.general"), systemImage: "gear")
                }

            AboutTab()
                .tabItem {
                    Label(String(localized: "settings.about"), systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 300)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("外观模式", selection: $appearanceMode) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            .onChange(of: appearanceMode) { _, newValue in
                applyAppearance(newValue)
            }

            Toggle(String(localized: "settings.launch_at_login"), isOn: $launchAtLogin)
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
                Text(err).font(.caption).foregroundStyle(.red)
            }

            LabeledContent(String(localized: "settings.open_config_dir")) {
                HStack {
                    Text(appState.configEngine.baseDir.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(String(localized: "settings.open_config_dir")) {
                        NSWorkspace.shared.open(appState.configEngine.baseDir)
                    }
                    .controlSize(.small)
                }
            }

            Text(String(localized: "settings.config_dir_description"))
                .font(.caption)
                .foregroundStyle(.tertiary)
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

            Text("v2.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
