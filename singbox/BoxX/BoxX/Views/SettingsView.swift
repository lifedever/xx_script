import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("singBoxPath") private var singBoxPath = "/opt/homebrew/bin/sing-box"
    @AppStorage("scriptDir") private var scriptDir = ""

    @State private var helperInstalled = false
    @State private var helperStatusMessage = ""
    @State private var isInstallingHelper = false
    @State private var helperError: String?

    private let helperManager = HelperManager.shared

    var body: some View {
        Form {
            // General
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }
            }

            // Paths
            Section("Paths") {
                LabeledContent("sing-box Path") {
                    HStack {
                        TextField("Path to sing-box binary", text: $singBoxPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            browseSingBoxPath()
                        }
                    }
                }

                LabeledContent("Script Directory") {
                    HStack {
                        TextField("Path to xx_script singbox directory", text: $scriptDir)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            browseScriptDir()
                        }
                    }
                }
            }

            // Privileged Helper
            Section("Privileged Helper") {
                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(helperInstalled ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(helperStatusMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button(helperInstalled ? "Reinstall Helper" : "Install Helper") {
                        Task { await installHelper() }
                    }
                    .disabled(isInstallingHelper)

                    if isInstallingHelper {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }

                if let err = helperError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 450, minHeight: 380)
        .onAppear {
            autoDetectScriptDir()
            refreshHelperStatus()
        }
    }

    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            helperError = "Launch at login: \(error.localizedDescription)"
            launchAtLogin = !enabled
        }
    }

    private func browseSingBoxPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select sing-box binary"
        if panel.runModal() == .OK, let url = panel.url {
            singBoxPath = url.path
        }
    }

    private func browseScriptDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Script Directory"
        if panel.runModal() == .OK, let url = panel.url {
            scriptDir = url.path
        }
    }

    private func autoDetectScriptDir() {
        guard scriptDir.isEmpty else { return }
        let candidates = [
            NSHomeDirectory() + "/Documents/Dev/myspace/xx_script/singbox",
            NSHomeDirectory() + "/xx_script/singbox",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path + "/generate.py") {
                scriptDir = path
                return
            }
        }
    }

    private func refreshHelperStatus() {
        helperInstalled = helperManager.isHelperInstalled
        helperStatusMessage = helperInstalled ? "Installed and running" : "Not installed"
    }

    private func installHelper() async {
        isInstallingHelper = true
        helperError = nil
        defer {
            isInstallingHelper = false
            refreshHelperStatus()
        }
        do {
            if helperInstalled {
                try helperManager.uninstallHelper()
            }
            try helperManager.installHelper()
        } catch {
            helperError = error.localizedDescription
        }
    }
}
