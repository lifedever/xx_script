import SwiftUI

struct Subscription: Identifiable, Codable {
    var id: String { name }
    var name: String
    var url: String
}

struct SubscriptionsView: View {
    @Environment(AppState.self) private var appState

    @State private var subscriptions: [Subscription] = []
    @State private var showAddSheet = false
    @State private var editingSubscription: Subscription? = nil
    @State private var isUpdating = false
    @State private var updateResults: [String: SubscriptionUpdateStatus] = [:]
    @State private var subscriptionInfos: [String: SubscriptionInfo] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if subscriptions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "subs.empty"))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "subs.empty_hint"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button(String(localized: "subs.add")) {
                        showAddSheet = true
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(subscriptions) { sub in
                            SubscriptionCard(
                                subscription: sub,
                                status: updateResults[sub.name],
                                info: subscriptionInfos[sub.name],
                                onEdit: { editingSubscription = sub },
                                onDelete: { deleteSubscription(sub) },
                                onUpdate: { Task { await updateSingle(sub) } }
                            )
                        }
                    }
                    .padding()
                }

                Divider()

                // Bottom action bar
                HStack {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label(String(localized: "subs.add"), systemImage: "plus")
                    }

                    Spacer()

                    if isUpdating {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(String(localized: "subs.updating"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task { await saveAndUpdate() }
                        } label: {
                            Label(String(localized: "subs.save_and_update"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .controlSize(.large)
                        .disabled(isUpdating)
                    }
                }
                .padding()
                .background(.bar)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            SubscriptionEditSheet(subscription: nil) { newSub in
                subscriptions.append(newSub)
                saveSubscriptions()
            }
        }
        .sheet(item: $editingSubscription) { sub in
            SubscriptionEditSheet(subscription: sub) { updated in
                if let idx = subscriptions.firstIndex(where: { $0.name == sub.name }) {
                    subscriptions[idx] = updated
                    saveSubscriptions()
                }
            }
        }
        .onAppear {
            subscriptions = Self.loadSubscriptions()
        }
        .task {
            await fetchAllSubscriptionInfos()
        }
    }

    private func deleteSubscription(_ sub: Subscription) {
        subscriptions.removeAll { $0.name == sub.name }
        saveSubscriptions()
    }

    private func saveSubscriptions() {
        Self.saveSubscriptions(subscriptions)
    }

    // MARK: - File I/O (shared with MenuBarView)

    static var subscriptionsFilePath: String {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BoxX")
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        return baseDir.appendingPathComponent("subscriptions.json").path
    }

    static func loadSubscriptions() -> [Subscription] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: subscriptionsFilePath)) else { return [] }
        return (try? JSONDecoder().decode([Subscription].self, from: data)) ?? []
    }

    static func saveSubscriptions(_ subs: [Subscription]) {
        guard let data = try? JSONEncoder().encode(subs),
              let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? pretty.write(to: URL(fileURLWithPath: subscriptionsFilePath))
    }

    private func fetchAllSubscriptionInfos() async {
        let fetcher = SubscriptionFetcher()
        for sub in subscriptions {
            guard let url = URL(string: sub.url) else { continue }
            if let result = try? await fetcher.fetch(url: url) {
                subscriptionInfos[sub.name] = result.info
            }
        }
    }

    private func updateSingle(_ sub: Subscription) async {
        guard let url = URL(string: sub.url) else {
            updateResults[sub.name] = .failure("Invalid URL")
            return
        }
        updateResults[sub.name] = .updating
        do {
            let result = try await appState.subscriptionService.updateSubscription(name: sub.name, url: url)
            updateResults[sub.name] = .success(result.nodeCount)
            if let info = result.info {
                subscriptionInfos[sub.name] = info
            }
        } catch {
            updateResults[sub.name] = .failure(error.localizedDescription)
        }

        if appState.isRunning {
            // sing-box restart is handled by ConfigEngine.onDeployComplete
        }

        try? await Task.sleep(for: .seconds(5))
        updateResults.removeValue(forKey: sub.name)
    }

    private func saveAndUpdate() async {
        saveSubscriptions()
        isUpdating = true
        updateResults.removeAll()
        defer { isUpdating = false }

        let subService = appState.subscriptionService
        for sub in subscriptions {
            guard let url = URL(string: sub.url) else {
                updateResults[sub.name] = .failure("Invalid URL")
                continue
            }
            updateResults[sub.name] = .updating
            do {
                let result = try await subService.updateSubscription(name: sub.name, url: url)
                updateResults[sub.name] = .success(result.nodeCount)
                if let info = result.info {
                    subscriptionInfos[sub.name] = info
                }
            } catch {
                updateResults[sub.name] = .failure(error.localizedDescription)
            }
        }

        if appState.isRunning {
            // sing-box restart is handled by ConfigEngine.onDeployComplete
        }

        // Clear success status after a delay
        try? await Task.sleep(for: .seconds(5))
        updateResults.removeAll()
    }
}

// MARK: - Update Status

enum SubscriptionUpdateStatus {
    case updating
    case success(Int)
    case failure(String)
}

// MARK: - Subscription Card

struct SubscriptionCard: View {
    let subscription: Subscription
    let status: SubscriptionUpdateStatus?
    let info: SubscriptionInfo?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onUpdate: () -> Void

    @State private var isHovering = false

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(subscription.name)
                            .font(.body.bold())

                        Spacer()

                        // Status indicator
                        if let status {
                            statusBadge(status)
                        }

                        // Per-subscription update button
                        Button {
                            onUpdate()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("更新此订阅")
                        .disabled(status != nil)
                    }

                    Text(subscription.url)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    // Subscription info: traffic usage and expiry
                    if let info {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: info.usagePercent, total: 100)
                                .tint(info.usagePercent > 80 ? .red : .blue)

                            HStack {
                                Text("已用 \(SubscriptionInfo.formatBytes(info.used)) / \(SubscriptionInfo.formatBytes(info.total))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("剩余 \(SubscriptionInfo.formatBytes(info.remaining))")
                                    .font(.caption2)
                                    .foregroundStyle(info.remaining < info.total / 10 ? .red : .green)
                            }

                            if let expire = info.expire {
                                Text("到期: \(Self.expiryFormatter.string(from: expire))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if info.total > 0 {
                                Text("到期: 长期有效")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(4)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit() }
        .contextMenu {
            Button(String(localized: "subs.edit")) { onEdit() }
            Divider()
            Button(String(localized: "subs.delete"), role: .destructive) { onDelete() }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isHovering ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    private static let expiryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @ViewBuilder
    private func statusBadge(_ status: SubscriptionUpdateStatus) -> some View {
        switch status {
        case .updating:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .success(let count):
            Label("\(count) nodes", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}

// MARK: - Edit Sheet

struct SubscriptionEditSheet: View {
    let subscription: Subscription?
    let onSave: (Subscription) -> Void

    @State private var name: String
    @State private var url: String
    @Environment(\.dismiss) private var dismiss

    init(subscription: Subscription?, onSave: @escaping (Subscription) -> Void) {
        self.subscription = subscription
        self.onSave = onSave
        _name = State(initialValue: subscription?.name ?? "")
        _url = State(initialValue: subscription?.url ?? "")
    }

    var isEditing: Bool { subscription != nil }

    var body: some View {
        VStack(spacing: 16) {
            Text(isEditing ? String(localized: "subs.edit") : String(localized: "subs.add"))
                .font(.headline)

            Form {
                TextField(String(localized: "subs.name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField(String(localized: "subs.url"), text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }
            .formStyle(.grouped)

            HStack {
                Button(String(localized: "subs.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "subs.save")) {
                    onSave(Subscription(name: name.trimmingCharacters(in: .whitespaces),
                                        url: url.trimmingCharacters(in: .whitespaces)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                          url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 500)
    }
}
