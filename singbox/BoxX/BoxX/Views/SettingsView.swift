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
    @State private var loginError: String?

    var body: some View {
        Form {
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
