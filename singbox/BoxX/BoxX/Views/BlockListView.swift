import SwiftUI

struct BlockListView: View {
    @Environment(AppState.self) private var appState
    @State private var entries: [BlockEntry] = []
    @State private var searchText = ""
    @State private var showAddSheet = false

    private var filteredEntries: [BlockEntry] {
        if searchText.isEmpty { return entries }
        return entries.filter {
            $0.value.localizedCaseInsensitiveContains(searchText) ||
            $0.type.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var manager: BlockListManager {
        BlockListManager(baseDir: appState.configEngine.baseDir)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                Text("封锁列表")
                    .font(.title2)
                    .bold()
                Text(String(format: String(localized: "block.count"), entries.count))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(String(localized: "block.search"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button {
                    showAddSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text(String(localized: "block.add"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    let mgr = manager
                    mgr.removeAll()
                    entries = []
                    appState.pendingReload = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text(String(localized: "block.clear"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(entries.isEmpty)
            }
            .padding()

            Divider()

            if entries.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "block.empty_title"), systemImage: "nosign")
                } description: {
                    Text(String(localized: "block.empty_desc"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Table header
                        HStack(spacing: 0) {
                            Text("#")
                                .frame(width: 40, alignment: .leading)
                            Text(String(localized: "block.type"))
                                .frame(width: 140, alignment: .leading)
                            Text(String(localized: "block.value"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("操作")
                                .frame(width: 80, alignment: .center)
                        }
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)

                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                                HStack(spacing: 0) {
                                    Text("\(index + 1)")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40, alignment: .leading)

                                    Text(entry.type.displayName)
                                        .monospaced()
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .foregroundStyle(entry.type == .ipCIDR ? Color.orange : Color.blue)
                                        .background(entry.type == .ipCIDR ? Color.orange.opacity(0.12) : Color.blue.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .frame(width: 140, alignment: .leading)

                                    Text(entry.value)
                                        .monospaced()
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Button(String(localized: "block.delete")) {
                                        let mgr = manager
                                        mgr.remove(entry: entry)
                                        entries = mgr.load()
                                        appState.pendingReload = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(.red)
                                    .frame(width: 80, alignment: .center)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(index % 2 == 0 ? Color.clear : Color.gray.opacity(0.06))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            entries = manager.load()
        }
        .sheet(isPresented: $showAddSheet) {
            AddBlockSheet(manager: manager) {
                entries = manager.load()
                appState.pendingReload = true
            }
        }
    }
}

// MARK: - Add Block Sheet

struct AddBlockSheet: View {
    let manager: BlockListManager
    let onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "block.add_title"))
                .font(.headline)

            Text(String(localized: "block.add_desc"))
                .foregroundStyle(.secondary)
                .font(.callout)

            TextEditor(text: $inputText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .border(Color.gray.opacity(0.3))

            HStack {
                Spacer()
                Button(String(localized: "block.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "block.confirm")) {
                    addEntries()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 450)
    }

    private func addEntries() {
        let lines = inputText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let entries = lines.map { line -> BlockEntry in
            let type = BlockListManager.detectType(line)
            let value = BlockListManager.normalizeValue(line, type: type)
            return BlockEntry(type: type, value: value)
        }

        guard !entries.isEmpty else { return }
        manager.add(entries: entries)
        onAdded()
    }
}
