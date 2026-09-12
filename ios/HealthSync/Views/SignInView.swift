import SwiftUI

struct SignInView: View {
    let session: SessionStore
    let sync: SyncCoordinator

    @State private var server = SessionStore.defaultServer
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field {
        case username, password
    }

    private var canSignIn: Bool {
        !isSigningIn
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !server.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let reason = session.signedOutReason {
                    Section {
                        Label(reason, systemImage: "info.circle")
                    }
                }

                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                } footer: {
                    Text("Your HealthSync admin creates your account.")
                }

                Section {
                    TextField("Server", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Use healthsync-test.sunspinner.ca for the test server.")
                }

                Section {
                    Button(action: signIn) {
                        HStack {
                            Text("Sign In")
                            if isSigningIn {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!canSignIn)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("HealthSync")
        }
    }

    private func signIn() {
        guard canSignIn else { return }
        isSigningIn = true
        errorMessage = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await session.signIn(
                    server: server,
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password
                )
                password = ""
                await sync.startAfterSignIn()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
