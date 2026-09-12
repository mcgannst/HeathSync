import Foundation

enum APIError: LocalizedError {
    case invalidServer
    case unauthorized(String)
    case server(status: Int, message: String)
    case unreachable(URLError)

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            "Enter the server address, for example healthsync.sunspinner.ca."
        case let .unauthorized(message):
            message
        case let .server(_, message):
            message
        case let .unreachable(error):
            "Couldn't reach the HealthSync server. \(error.localizedDescription)"
        }
    }
}

struct APIClient: Sendable {
    let baseURL: URL
    var token: String?
    var session: URLSession = .shared

    /// Accepts "healthsync.sunspinner.ca", "https://healthsync.sunspinner.ca/" and similar. HTTPS only.
    static func serverURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard let url = URL(string: text), url.scheme == "https", let host = url.host(), !host.isEmpty else {
            return nil
        }
        return url
    }

    // MARK: Account

    func login(username: String, password: String, deviceName: String) async throws -> LoginResponse {
        try await send("POST", "api/v1/auth/login", body: LoginRequest(username: username, password: password, deviceName: deviceName))
    }

    func logout() async throws {
        _ = try await perform(makeRequest("POST", "api/v1/auth/logout"))
    }

    func me() async throws -> UserAccount {
        try await send("GET", "api/v1/me")
    }

    // MARK: Uploads

    func uploadSamples(_ upload: SamplesUpload) async throws -> UploadResult {
        try await send("POST", "api/v1/sync/samples", body: upload)
    }

    func uploadWorkouts(_ upload: WorkoutsUpload) async throws -> UploadResult {
        try await send("POST", "api/v1/sync/workouts", body: upload)
    }

    func uploadDaily(_ upload: DailyUpload) async throws -> UploadResult {
        try await send("POST", "api/v1/sync/daily", body: upload)
    }

    func status() async throws -> SyncStatus {
        try await send("GET", "api/v1/sync/status")
    }

    // MARK: Admin

    func listAccounts() async throws -> [UserAccount] {
        try await send("GET", "api/v1/admin/users")
    }

    func createAccount(_ account: NewAccount) async throws -> UserAccount {
        try await send("POST", "api/v1/admin/users", body: account)
    }

    func updateAccount(id: Int, _ changes: AccountChanges) async throws -> UserAccount {
        try await send("PATCH", "api/v1/admin/users/\(id)", body: changes)
    }

    // MARK: Transport

    private func send<Response: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> Response {
        var request = makeRequest(method, path)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.api.encode(body)
        }
        return try JSONDecoder.api.decode(Response.self, from: try await perform(request))
    }

    private func makeRequest(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.unreachable(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = Self.errorMessage(data) ?? "The server returned an error (\(status))."
            throw status == 401 ? APIError.unauthorized(message) : APIError.server(status: status, message: message)
        }
        return data
    }

    /// FastAPI errors are {"detail": "message"}, or a list of {"msg": ...} for validation errors.
    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = object["detail"] as? String {
            return detail
        }
        if let items = object["detail"] as? [[String: Any]] {
            let messages = items.compactMap { $0["msg"] as? String }
            return messages.isEmpty ? nil : messages.joined(separator: "\n")
        }
        return nil
    }
}
