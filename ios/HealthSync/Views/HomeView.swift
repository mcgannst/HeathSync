import SwiftUI

struct HomeView: View {
    let session: SessionStore
    let sync: SyncCoordinator
    let current: Session

    @State private var confirmingSignOut = false
    @State private var copiedConnectorURL = false

    private var connectorURL: String {
        current.serverURL.appending(path: "mcp").absoluteString
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Signed in as", value: current.user.displayName)
                    LabeledContent("Server", value: current.serverURL.host() ?? "")
                    LabeledContent("Last upload") {
                        Text(sync.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    }
                    statusRow
                    Button {
                        Task { await sync.sync() }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(sync.isSyncing)
                }

                Section {
                    ForEach(DataGroup.allCases) { group in
                        Toggle(isOn: binding(for: group)) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title)
                                    Text(group.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: group.systemImage)
                            }
                        }
                    }
                } header: {
                    Text("Data to upload")
                } footer: {
                    Text("Turning a group off stops future uploads; data already on the server stays. The first upload covers the last two years and can take a while. Keep the app open, or leave your iPhone charging overnight.")
                }

                Section {
                    NavigationLink {
                        UploadedDataView(sync: sync)
                    } label: {
                        LabeledContent("Uploaded data", value: uploadedSummary)
                    }
                }

                Section {
                    Text(connectorURL)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button(copiedConnectorURL ? "Copied" : "Copy Connector URL") {
                        UIPasteboard.general.string = connectorURL
                        copiedConnectorURL = true
                    }
                } header: {
                    Text("Connect Claude")
                } footer: {
                    Text("In Claude, open Settings → Connectors → Add custom connector and paste this URL, then sign in with your HealthSync username and password. Claude gets read-only access to your data only.")
                }

                if current.user.isAdmin {
                    Section {
                        NavigationLink {
                            AccountsView(api: current.api, currentUserID: current.user.id)
                        } label: {
                            Label("Accounts", systemImage: "person.2")
                        }
                    }
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        confirmingSignOut = true
                    }
                }
            }
            .navigationTitle("HealthSync")
            .refreshable { await sync.sync() }
            .task { await sync.refreshServerStatus() }
            .confirmationDialog("Sign out of HealthSync?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task { await session.signOut() }
                }
            } message: {
                Text("Uploads from this iPhone stop. Your data stays on the server.")
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch sync.status {
        case .idle:
            EmptyView()
        case let .syncing(message):
            HStack(spacing: 10) {
                ProgressView()
                Text(message)
                    .foregroundStyle(.secondary)
            }
        case .succeeded:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var uploadedSummary: String {
        guard let status = sync.serverStatus else { return "—" }
        let readings = status.samples.reduce(0) { $0 + $1.count }
        return "\(readings.formatted()) readings"
    }

    private func binding(for group: DataGroup) -> Binding<Bool> {
        Binding(
            get: { sync.enabledGroups.contains(group) },
            set: { sync.setGroup(group, enabled: $0) }
        )
    }
}

struct UploadedDataView: View {
    let sync: SyncCoordinator

    var body: some View {
        List {
            if let status = sync.serverStatus {
                Section {
                    LabeledContent("Workouts", value: status.workoutCount.formatted())
                    LabeledContent("Daily summaries", value: status.dailySummaryCount.formatted())
                }
                Section("Readings") {
                    ForEach(status.samples) { coverage in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(HealthMetric.title(for: coverage.type))
                                Spacer()
                                Text(coverage.count.formatted())
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(coverage.first.formatted(date: .abbreviated, time: .omitted)) – \(coverage.last.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Nothing uploaded yet",
                    systemImage: "icloud.and.arrow.up",
                    description: Text("Pull down to check again.")
                )
            }
        }
        .navigationTitle("Uploaded Data")
        .refreshable { await sync.refreshServerStatus() }
        // Refreshes on open, then every few seconds while an upload runs so the counts don't look stuck.
        // Restarts when syncing starts or stops, and is cancelled when the screen closes.
        .task(id: sync.isSyncing) {
            repeat {
                await sync.refreshServerStatus()
                guard sync.isSyncing else { return }
                try? await Task.sleep(for: .seconds(5))
            } while !Task.isCancelled
        }
    }
}
