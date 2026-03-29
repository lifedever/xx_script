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
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("scriptDir") private var scriptDir = ""
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

            LabeledContent(String(localized: "settings.script_directory")) {
                HStack {
                    Text(scriptDir.isEmpty ? "–" : scriptDir)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(String(localized: "settings.browse")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            scriptDir = url.path
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if scriptDir.isEmpty {
                let candidate = NSHomeDirectory() + "/Documents/Dev/myspace/xx_script/singbox"
                if FileManager.default.fileExists(atPath: candidate + "/generate.py") {
                    scriptDir = candidate
                }
            }
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

            Text("v1.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
