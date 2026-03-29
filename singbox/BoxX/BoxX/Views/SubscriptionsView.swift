import SwiftUI

struct SubscriptionsView: View {
    let configGenerator: ConfigGenerator
    let singBoxManager: SingBoxManager

    @State private var subscriptions: [Subscription] = []
    @State private var showAddSheet = false
    @State private var editingSubscription: Subscription? = nil
    @State private var isUpdating = false
    @State private var updateStatus: String? = nil

    private let manager = SubscriptionManager()

    var body: some View {
        Group {
            if subscriptions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "subs.empty"))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "subs.empty_hint"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(subscriptions) { sub in
                        SubscriptionRow(subscription: sub)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingSubscription = sub
                            }
                    }
                    .onDelete(perform: deleteSubscriptions)
                }
            }
        }
        .navigationTitle(String(localized: "subs.title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
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
                            Label(String(localized: "subs.save_and_update"), systemImage: "arrow.down.circle.fill")
                        }
                        .disabled(isUpdating)
                    }
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let status = updateStatus {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(status)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: updateStatus)
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
            subscriptions = manager.load()
        }
    }

    private func deleteSubscriptions(at offsets: IndexSet) {
        subscriptions.remove(atOffsets: offsets)
        saveSubscriptions()
    }

    private func saveSubscriptions() {
        try? manager.save(subscriptions)
    }

    private func saveAndUpdate() async {
        saveSubscriptions()
        isUpdating = true
        updateStatus = nil
        defer { isUpdating = false }
        for await _ in configGenerator.generate() {}
        if singBoxManager.isRunning {
            try? await singBoxManager.restart(configPath: configGenerator.configPath)
        }
        withAnimation {
            updateStatus = String(localized: "subs.update_complete")
        }
        try? await Task.sleep(for: .seconds(3))
        withAnimation {
            updateStatus = nil
        }
    }
}

struct SubscriptionRow: View {
    let subscription: Subscription

    private var maskedURL: String {
        let url = subscription.url
        if url.count > 30 {
            return String(url.prefix(30)) + "..."
        }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subscription.name)
                .font(.headline)
            Text(maskedURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

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
        VStack(spacing: 0) {
            Text(isEditing ? String(localized: "subs.edit") : String(localized: "subs.add"))
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Form {
                TextField(String(localized: "subs.name"), text: $name)
                TextField(String(localized: "subs.url"), text: $url)
            }
            .padding(.horizontal)

            HStack {
                Button(String(localized: "subs.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "subs.save")) {
                    let sub = Subscription(name: name, url: url)
                    onSave(sub)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 16)
        }
        .frame(width: 420)
    }
}
