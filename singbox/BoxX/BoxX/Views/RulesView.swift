import SwiftUI

struct RulesView: View {
    let api: ClashAPI

    @State private var rules: [Rule] = []
    @State private var searchText = ""
    @State private var isLoading = false

    var filteredRules: [Rule] {
        if searchText.isEmpty { return rules }
        return rules.filter {
            $0.type.localizedCaseInsensitiveContains(searchText)
            || $0.payload.localizedCaseInsensitiveContains(searchText)
            || $0.proxy.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search rules…", text: $searchText)
                    .textFieldStyle(.plain)
                Spacer()
                Text("\(filteredRules.count) rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(Array(filteredRules.prefix(2000))) {
                    TableColumn("#") { rule in
                        Text("\(rule.id + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(50)
                    TableColumn("Type", value: \.type)
                        .width(min: 80, ideal: 120)
                    TableColumn("Payload", value: \.payload)
                        .width(min: 150, ideal: 250)
                    TableColumn("Proxy", value: \.proxy)
                        .width(min: 80, ideal: 120)
                }
            }
        }
        .task {
            await loadRules()
        }
    }

    private func loadRules() async {
        isLoading = true
        defer { isLoading = false }
        rules = (try? await api.getRules()) ?? []
    }
}
