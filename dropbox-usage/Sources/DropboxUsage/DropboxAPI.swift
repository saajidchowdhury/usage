import CryptoKit
import Foundation
import Security
import DropboxUsageCore

struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

struct DropboxErrorResponse: Decodable {
    let errorDescription: String?
    let errorSummary: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case errorDescription = "error_description"
        case errorSummary = "error_summary"
        case error
    }
}

enum DropboxAPIError: LocalizedError {
    case invalidResponse
    case requestFailed(Int, String)
    case missingRefreshToken

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Dropbox returned an invalid response."
        case .requestFailed(let status, let message):
            return "Dropbox request failed (HTTP \(status)): \(message)"
        case .missingRefreshToken:
            return "Dropbox did not return a refresh token. Reconnect and approve offline access."
        }
    }
}

@MainActor
final class DropboxAPI {
    private let session: URLSession
    private var accessToken: String?
    private var expiresAt = Date.distantPast

    init(session: URLSession = .shared) {
        self.session = session
    }

    func authorizationURL(appKey: String, verifier: String) -> URL {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "scope", value: "account_info.read"),
        ]
        return components.url!
    }

    func exchange(code: String, appKey: String, verifier: String) async throws {
        let fields = [
            "code": code,
            "grant_type": "authorization_code",
            "client_id": appKey,
            "code_verifier": verifier,
        ]
        let response: TokenResponse = try await postForm(
            url: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            fields: fields
        )
        guard let refreshToken = response.refreshToken else {
            throw DropboxAPIError.missingRefreshToken
        }
        try Keychain.saveRefreshToken(refreshToken)
        accessToken = response.accessToken
        expiresAt = Date().addingTimeInterval(response.expiresIn)
    }

    func spaceUsage(appKey: String) async throws -> SpaceUsage {
        let token = try await validAccessToken(appKey: appKey)
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_space_usage")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("null".utf8)
        return try await send(request)
    }

    func disconnect() throws {
        accessToken = nil
        expiresAt = .distantPast
        try Keychain.deleteRefreshToken()
    }

    private func validAccessToken(appKey: String) async throws -> String {
        if let accessToken, expiresAt.timeIntervalSinceNow > 60.0 {
            return accessToken
        }
        guard let refreshToken = try Keychain.refreshToken() else {
            throw DropboxAPIError.missingRefreshToken
        }
        let fields = [
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "client_id": appKey,
        ]
        let response: TokenResponse = try await postForm(
            url: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            fields: fields
        )
        accessToken = response.accessToken
        expiresAt = Date().addingTimeInterval(response.expiresIn)
        return response.accessToken
    }

    private func postForm<T: Decodable>(url: URL, fields: [String: String]) async throws -> T {
        var components = URLComponents()
        components.queryItems = fields.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DropboxAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let decoded = try? JSONDecoder().decode(DropboxErrorResponse.self, from: data)
            let fallback = String(data: data, encoding: .utf8) ?? "Unknown error"
            let message = decoded?.errorDescription ?? decoded?.errorSummary ?? decoded?.error ?? fallback
            throw DropboxAPIError.requestFailed(httpResponse.statusCode, message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

func makeCodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 64)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "Secure random number generation failed")
    return Data(bytes).base64URLEncodedString()
}
