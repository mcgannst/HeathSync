import SwiftUI

/// Admin only: add family members and manage their accounts.
struct AccountsView: View {
    let api: APIClient
    let currentUserID: Int

    @State private var accounts: [UserAccount] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingNewAccount = false

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            ForEach($accounts) { $account in
                NavigationLink {
                    AccountDetailView(api: api, account: $account, isCurrentUser: account.id == currentUserID)
                } label: {
                    AccountRow(account: account)
                }
            }
        }
        .overlay {
            if isLoading && accounts.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle("Accounts")
        .toolbar {
            Button {
                showingNewAccount = true
            } label: {
                Label("Add Account", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingNewAccount) {
            NewAccountView(api: api) { account in
                accounts.append(account)
                accounts.sort { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            accounts = try await api.listAccounts()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AccountRow: View {
    let account: UserAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(account.displayName)
                if account.isAdmin {
                    Text("Admin")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                if !account.isActive {
                    Text("Disabled")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        let lastUpload = account.lastSyncAt.map { "last upload \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "no uploads yet"
        return "\(account.username) · \(lastUpload)"
    }
}

private struct NewAccountView: View {
    let api: APIClient
    let onCreate: (UserAccount) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isAdmin = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !isSaving
            && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && username.range(of: #"^[A-Za-z0-9._-]{2,50}$"#, options: .regularExpression) != nil
            && password.count >= 10
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $displayName)
                        .textContentType(.name)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Usernames use letters, numbers, dots, dashes or underscores.")
                }
                Section {
                    SecureField("Temporary password", text: $password)
                        .textContentType(.newPassword)
                } footer: {
                    Text("At least 10 characters. Share it with them privately.")
                }
                Section {
                    Toggle("Admin", isOn: $isAdmin)
                } footer: {
                    Text("Admins can add and manage accounts.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                let account = try await api.createAccount(NewAccount(
                    username: username,
                    displayName: displayName.trimmingCharacters(in: .whitespaces),
                    password: password,
                    isAdmin: isAdmin
                ))
                onCreate(account)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AccountDetailView: View {
    let api: APIClient
    @Binding var account: UserAccount
    let isCurrentUser: Bool

    @State private var displayName = ""
    @State private var newPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var passwordReset = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $displayName)
                    .onSubmit(saveName)
            }

            Section {
                LabeledContent("Username", value: account.username)
                LabeledContent("Last upload", value: account.lastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                LabeledContent("Time zone", value: account.timeZone)
            }

            Section {
                Toggle("Admin", isOn: Binding(
                    get: { account.isAdmin },
                    set: { save(AccountChanges(isAdmin: $0)) }
                ))
                Toggle("Active", isOn: Binding(
                    get: { account.isActive },
                    set: { save(AccountChanges(isActive: $0)) }
                ))
            } footer: {
                Text(isCurrentUser
                    ? "You can't remove your own admin access or disable your own account."
                    : "Disabling an account signs that person out of the app and Claude.")
            }
            .disabled(isCurrentUser || isSaving)

            Section {
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                Button("Reset Password") {
                    save(AccountChanges(password: newPassword)) {
                        newPassword = ""
                        passwordReset = true
                    }
                }
                .disabled(newPassword.count < 10 || isSaving)
            } header: {
                Text("Reset password")
            } footer: {
                Text(passwordReset
                    ? "Password changed. They've been signed out of the app and Claude."
                    : "At least 10 characters. Resetting signs them out of the app and Claude.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(account.displayName)
        .toolbar {
            if displayName.trimmingCharacters(in: .whitespaces) != account.displayName && !displayName.isEmpty {
                Button("Save", action: saveName)
                    .disabled(isSaving)
            }
        }
        .onAppear { displayName = account.displayName }
    }

    private func saveName() {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != account.displayName else { return }
        save(AccountChanges(displayName: name))
    }

    private func save(_ changes: AccountChanges, onSuccess: @escaping () -> Void = {}) {
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                account = try await api.updateAccount(id: account.id, changes)
                onSuccess()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
