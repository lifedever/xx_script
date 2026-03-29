import SwiftUI

struct SubscriptionsView: View {
    let configGenerator: ConfigGenerator
    let singBoxManager: SingBoxManager

    @State private var subscriptions: [Subscription] = []
    @State private var showAddSheet = false
    @State private var editingSubscription: Subscription? = nil
    @State private var isUpdating = false
    @State private var updateLog: [String] = []
    @State private var updateStatus: String? = nil

    private let manager = SubscriptionManager()

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
                        if let status = updateStatus {
                            Label(status, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
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

                // Update log
                if !updateLog.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(String(localized: "subs.progress_title"))
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                updateLog.removeAll()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(updateLog.indices, id: \.self) { i in
                                    Text(updateLog[i])
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                        .frame(height: 120)
                    }
                    .background(.bar)
                }
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
            subscriptions = manager.load()
        }
    }

    private func deleteSubscription(_ sub: Subscription) {
        subscriptions.removeAll { $0.name == sub.name }
        saveSubscriptions()
    }

    private func saveSubscriptions() {
        try? manager.save(subscriptions)
    }

    private func saveAndUpdate() async {
        saveSubscriptions()
        isUpdating = true
        updateStatus = nil
        updateLog.removeAll()
        defer { isUpdating = false }

        for await line in configGenerator.generate() {
            updateLog.append(line)
        }

        if singBoxManager.isRunning {
            updateLog.append("Restarting sing-box...")
            try? await singBoxManager.restart(configPath: configGenerator.configPath)
            updateLog.append("Done.")
        }

        updateStatus = String(localized: "subs.update_complete")
        try? await Task.sleep(for: .seconds(5))
        updateStatus = nil
    }
}

// MARK: - Subscription Card

struct SubscriptionCard: View {
    let subscription: Subscription
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
                    Text(subscription.name)
                        .font(.body.bold())

                    Text(subscription.url)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()
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
