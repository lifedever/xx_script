import SwiftUI

struct ServicesConfigView: View {
    @Environment(AppState.self) private var appState

    @State private var services: [ServiceConfig] = []
    @State private var editingService: ServiceConfig?
    @State private var showAddSheet = false
    @State private var isUpdating = false
    @State private var updateStatus: String?

    private let manager = ServiceConfigManager()

    var body: some View {
        VStack(spacing: 0) {
            // Service list with drag reorder
            List {
                ForEach(Array(services.enumerated()), id: \.element.id) { index, svc in
                    ServiceConfigRow(
                        service: svc,
                        isFirst: index == 0,
                        isLast: index == services.count - 1,
                        onMoveUp: { moveUp(svc) },
                        onMoveDown: { moveDown(svc) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editingService = svc }
                    .contextMenu {
                        Button(String(localized: "services.edit")) { editingService = svc }
                        Divider()
                        Button(String(localized: "subs.delete"), role: .destructive) { delete(svc) }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()

            // Bottom bar
            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label(String(localized: "services.add"), systemImage: "plus")
                }

                Spacer()

                if isUpdating {
                    ProgressView().scaleEffect(0.7)
                    Text(String(localized: "subs.updating"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if let status = updateStatus {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button {
                        Task { await saveAndUpdate() }
                    } label: {
                        Label(String(localized: "services.save_and_update"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.large)
                    .disabled(isUpdating)
                }
            }
            .padding()
            .background(.bar)
        }
        .sheet(isPresented: $showAddSheet) {
            ServiceEditSheet(service: nil) { newSvc in
                services.append(newSvc)
                save()
            }
        }
        .sheet(item: $editingService) { svc in
            ServiceEditSheet(service: svc) { updated in
                if let idx = services.firstIndex(where: { $0.name == svc.name }) {
                    services[idx] = updated
                    save()
                }
            }
        }
        .onAppear {
            services = manager.load()
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        services.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func moveUp(_ svc: ServiceConfig) {
        guard let idx = services.firstIndex(where: { $0.name == svc.name }), idx > 0 else { return }
        services.swapAt(idx, idx - 1)
        save()
    }

    private func moveDown(_ svc: ServiceConfig) {
        guard let idx = services.firstIndex(where: { $0.name == svc.name }), idx < services.count - 1 else { return }
        services.swapAt(idx, idx + 1)
        save()
    }

    private func delete(_ svc: ServiceConfig) {
        services.removeAll { $0.name == svc.name }
        save()
    }

    private func save() {
        try? manager.save(services)
    }

    private func saveAndUpdate() async {
        save()
        isUpdating = true
        updateStatus = nil
        defer { isUpdating = false }

        // TODO: v2 redesign - use ConfigEngine to rebuild and deploy runtime config
        // For now, just save and reload if running
        do {
            try appState.configEngine.save()
            let engine = appState.configEngine
            try await engine.deployRuntime()
        } catch {
            appState.showAlert(error.localizedDescription)
        }

        if appState.isRunning {
            _ = await appState.xpcClient.reload()
        }

        updateStatus = String(localized: "subs.update_complete")
        try? await Task.sleep(for: .seconds(3))
        updateStatus = nil
    }
}

// MARK: - Row

struct ServiceConfigRow: View {
    let service: ServiceConfig
    let isFirst: Bool
    let isLast: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Up/Down buttons
            VStack(spacing: 2) {
                Button { onMoveUp() } label: {
                    Image(systemName: "chevron.up").font(.caption2)
                }
                .buttonStyle(.plain)
                .disabled(isFirst)
                .foregroundStyle(isFirst ? Color.clear : Color.secondary)

                Button { onMoveDown() } label: {
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .buttonStyle(.plain)
                .disabled(isLast)
                .foregroundStyle(isLast ? Color.clear : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(service.name)
                    .font(.body.bold())

                HStack(spacing: 4) {
                    ForEach(service.geosite, id: \.self) { gs in
                        Text(gs)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    ForEach(service.custom_rules ?? [], id: \.name) { cr in
                        Text(cr.name)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1))
                            .foregroundStyle(Color.orange)
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            // Default outbound
            Text(service.default ?? "Proxy")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Flags
            if service.include_direct == true {
                Text("DIRECT")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.1))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Edit Sheet

struct ServiceEditSheet: View {
    let service: ServiceConfig?
    let onSave: (ServiceConfig) -> Void

    @State private var name: String
    @State private var geositeText: String
    @State private var customRules: [CustomRule]
    @State private var defaultOutbound: String
    @State private var includeDirect: Bool
    @State private var excludeHK: Bool
    @State private var newRuleName: String = ""
    @State private var newRuleURL: String = ""
    @Environment(\.dismiss) private var dismiss

    var isEditing: Bool { service != nil }

    init(service: ServiceConfig?, onSave: @escaping (ServiceConfig) -> Void) {
        self.service = service
        self.onSave = onSave
        _name = State(initialValue: service?.name ?? "")
        _geositeText = State(initialValue: service?.geosite.joined(separator: ", ") ?? "")
        _customRules = State(initialValue: service?.custom_rules ?? [])
        _defaultOutbound = State(initialValue: service?.default ?? "Proxy")
        _includeDirect = State(initialValue: service?.include_direct ?? false)
        _excludeHK = State(initialValue: service?.exclude_regions?.contains("🇭🇰香港") ?? false)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isEditing ? String(localized: "services.edit") : String(localized: "services.add"))
                .font(.headline)

            Form {
                Section {
                    TextField(String(localized: "services.name_field"), text: $name)
                        .textFieldStyle(.roundedBorder)

                    TextField(String(localized: "services.geosite_field"), text: $geositeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())

                    Picker(String(localized: "services.default_outbound"), selection: $defaultOutbound) {
                        Text("Proxy").tag("Proxy")
                        Text("DIRECT").tag("DIRECT")
                        Text("auto").tag("auto")
                    }

                    Toggle(String(localized: "services.include_direct"), isOn: $includeDirect)
                    Toggle(String(localized: "services.exclude_hk"), isOn: $excludeHK)
                }

                Section(String(localized: "services.custom_rules_section")) {
                    ForEach(customRules, id: \.name) { rule in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(rule.name).font(.caption.bold())
                                Text(rule.url).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { customRules.removeAll { $0.name == rule.name } } label: {
                                Image(systemName: "trash").foregroundStyle(.red)
                            }.buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField(String(localized: "services.rule_name"), text: $newRuleName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        TextField(String(localized: "services.rule_url"), text: $newRuleURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                        Button(String(localized: "services.add_rule")) {
                            let rule = CustomRule(
                                name: newRuleName.trimmingCharacters(in: .whitespaces),
                                url: newRuleURL.trimmingCharacters(in: .whitespaces),
                                type: "ruleset"
                            )
                            customRules.append(rule)
                            newRuleName = ""
                            newRuleURL = ""
                        }
                        .disabled(newRuleName.isEmpty || newRuleURL.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(String(localized: "subs.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "subs.save")) {
                    let geosite = geositeText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    var svc = ServiceConfig(
                        name: name.trimmingCharacters(in: .whitespaces),
                        geosite: geosite,
                        custom_rules: customRules.isEmpty ? nil : customRules,
                        default: defaultOutbound
                    )
                    if excludeHK { svc.exclude_regions = ["🇭🇰香港"] }
                    if includeDirect { svc.include_direct = true }
                    onSave(svc)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 560, height: 500)
    }
}
