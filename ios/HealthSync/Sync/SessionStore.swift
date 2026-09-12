import Foundation
import Observation
import UIKit

struct Session: Codable, Equatable {
    var serverURL: URL
    var token: String
    var user: UserAccount

    var api: APIClient { APIClient(baseURL: serverURL, token: token) }

    /// Upload progress is tracked separately for each server and account.
    var anchorScope: String { "\(serverURL.host() ?? "server")-\(user.id)" }
}

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()
    static let defaultServer = "healthsync.sunspinner.ca"
    private static let keychainAccount = "session"

    private(set) var session: Session?
    /// Shown on the sign-in screen when the server ended the session (password reset, account disabled).
    private(set) var signedOutReason: String?

    private init() {
        session = Keychain.load(Session.self, account: Self.keychainAccount)
    }

    func signIn(server: String, username: String, password: String) async throws {
        guard let serverURL = APIClient.serverURL(from: server) else { throw APIError.invalidServer }
        let response = try await APIClient(baseURL: serverURL)
            .login(username: username, password: password, deviceName: UIDevice.current.name)
        signedOutReason = nil
        save(Session(serverURL: serverURL, token: response.token, user: response.user))
    }

    /// Picks up changes an admin made, such as a new display name or admin access.
    func refreshUser() async {
        guard let current = session else { return }
        do {
            let user = try await current.api.me()
            if session?.token == current.token {
                session?.user = user
                save(session)
            }
        } catch APIError.unauthorized {
            sessionEnded()
        } catch {
            // Offline or server unavailable: keep the saved details.
        }
    }

    func signOut() async {
        if let session {
            try? await session.api.logout()
        }
        clear(reason: nil)
    }

    func sessionEnded() {
        clear(reason: "You were signed out. Sign in again to keep uploading.")
    }

    private func clear(reason: String?) {
        SyncCoordinator.shared.reset()
        save(nil)
        signedOutReason = reason
    }

    private func save(_ session: Session?) {
        self.session = session
        Keychain.save(session, account: Self.keychainAccount)
    }
}
