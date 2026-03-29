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
                                onEdit: { editingSubscription = sub },
                                onDelete: { deleteSubscription(sub) }
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
        let scriptDir = UserDefaults.standard.string(forKey: "scriptDir")
            ?? (NSHomeDirectory() + "/Documents/Dev/myspace/xx_script/singbox")
        return scriptDir + "/subscriptions.json"
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
                let count = try await subService.updateSubscription(name: sub.name, url: url)
                updateResults[sub.name] = .success(count)
            } catch {
                updateResults[sub.name] = .failure(error.localizedDescription)
            }
        }

        if appState.isRunning {
            _ = await appState.xpcClient.reload()
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
    let onEdit: () -> Void
    let onDelete: () -> Void

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
                    }

                    Text(subscription.url)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
