import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label(String(localized: "settings.general"), systemImage: "gear")
                }

            HelperSettingsTab()
                .tabItem {
                    Label(String(localized: "settings.helper"), systemImage: "lock.shield")
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

// MARK: - Helper

struct HelperSettingsTab: View {
    @State private var helperInstalled = false
    @State private var statusMessage = ""
    @State private var isInstalling = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            LabeledContent(String(localized: "settings.helper.status")) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(helperInstalled ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(statusMessage)
                        .foregroundStyle(helperInstalled ? .primary : .secondary)
                }
            }

            LabeledContent("") {
                HStack {
                    Button(helperInstalled
                           ? String(localized: "settings.helper.reinstall")
                           : String(localized: "settings.helper.install")) {
                        install()
                    }
                    .disabled(isInstalling)

                    if isInstalling {
                        ProgressView().scaleEffect(0.7)
                    }
                }
            }

            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Text(String(localized: "settings.helper.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func refresh() {
        helperInstalled = HelperManager.shared.isHelperInstalled
        statusMessage = helperInstalled
            ? String(localized: "settings.helper.installed")
            : String(localized: "settings.helper.not_installed")
    }

    private func install() {
        isInstalling = true
        errorMessage = nil
        defer { isInstalling = false; refresh() }
        do {
            if helperInstalled { try HelperManager.shared.uninstallHelper() }
            try HelperManager.shared.installHelper()
        } catch {
            errorMessage = error.localizedDescription
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
