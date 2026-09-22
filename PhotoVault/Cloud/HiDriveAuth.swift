import Foundation
import SwiftUI
import SafariServices

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var alias: String?
    var home: String?
}

struct ClientCredentials {
    var id: String
    var secret: String
}

enum AuthError: LocalizedError {
    case missingCredentials
    case notConnected
    case badResponse
    case tokenRequestFailed(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Enter the HiDrive API credentials first (Settings → API credentials)."
        case .notConnected:
            return "Not connected to STRATO HiDrive."
        case .badResponse:
            return "Unexpected response from HiDrive."
        case .tokenRequestFailed(let status, let detail):
            return detail.isEmpty
                ? "HiDrive token request failed (HTTP \(status))."
                : "HiDrive token request failed (HTTP \(status)): \(detail)"
        }
    }
}

let hidriveAuthorizeURL = "https://my.hidrive.com/client/authorize"
let hidriveTokenURL = "https://my.hidrive.com/oauth2/token"
let hidriveAPIBase = "https://api.hidrive.strato.com/2.1"

// nil omits redirect_uri, so HiDrive applies the redirect registered for this "native" app ("oob"):
// after approval the page shows a short code for the user to paste. If the authorize page ever
// complains, flip this to "oob" or "urn:ietf:wg:oauth:2.0:oob".
let hidriveRedirectURI: String? = nil

actor HiDriveAuth {
    static let shared = HiDriveAuth()

    private var cachedTokens: OAuthTokens?

    // Only the in-app credentials screen supplies these; nothing is read from the build.
    nonisolated static func credentials() -> ClientCredentials? {
        guard let id = KeychainStore.getString(account: "clientId"),
              let secret = KeychainStore.getString(account: "clientSecret"),
              !id.isEmpty, !secret.isEmpty else {
            return nil
        }
        return ClientCredentials(id: id, secret: secret)
    }

    nonisolated static func storeCredentials(id: String, secret: String) {
        KeychainStore.setString(id, account: "clientId")
        KeychainStore.setString(secret, account: "clientSecret")
    }

    func tokens() -> OAuthTokens? {
        if cachedTokens == nil,
           let data = KeychainStore.get(account: "oauthTokens"),
           let decoded = try? JSONDecoder().decode(OAuthTokens.self, from: data) {
            cachedTokens = decoded
        }
        return cachedTokens
    }

    func store(_ tokens: OAuthTokens) {
        cachedTokens = tokens
        if let data = try? JSONEncoder().encode(tokens) {
            KeychainStore.set(data, account: "oauthTokens")
        }
    }

    func invalidateAccessToken() {
        guard var current = tokens() else { return }
        current.expiresAt = Date.distantPast
        store(current)
    }

    func disconnect() {
        cachedTokens = nil
        KeychainStore.delete(account: "oauthTokens")
    }

    var isConnected: Bool { tokens() != nil }

    func validAccessToken() async throws -> String {
        guard var current = tokens() else { throw AuthError.notConnected }
        if current.expiresAt.timeIntervalSinceNow > 60 {
            return current.accessToken
        }
        let refreshed = try await requestToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken
        ])
        current.accessToken = refreshed.accessToken
        current.expiresAt = refreshed.expiresAt
        if !refreshed.refreshToken.isEmpty { current.refreshToken = refreshed.refreshToken }
        store(current)
        return current.accessToken
    }

    func exchangeCode(_ code: String) async throws {
        var form = ["grant_type": "authorization_code", "code": code]
        // RFC 6749 §4.1.3: the token request must repeat redirect_uri if the authorize request sent one.
        if let hidriveRedirectURI {
            form["redirect_uri"] = hidriveRedirectURI
        }
        var tokens = try await requestToken(form: form)
        // Resolve alias + home once so all cloud paths are anchored in the user's home.
        if let me = try? await fetchUserInfo(accessToken: tokens.accessToken) {
            tokens.alias = me.alias
            tokens.home = me.home
        }
        store(tokens)
    }

    private struct TokenResponse: Codable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
    }

    private struct TokenErrorResponse: Codable {
        var error: String?
        var error_description: String?
    }

    private func requestToken(form: [String: String]) async throws -> OAuthTokens {
        guard let creds = HiDriveAuth.credentials() else { throw AuthError.missingCredentials }
        var body = form
        body["client_id"] = creds.id
        body["client_secret"] = creds.secret
        var request = URLRequest(url: URL(string: hidriveTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { key, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
            return "\(key)=\(escaped)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.badResponse }
        guard http.statusCode == 200 else {
            let parsed = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            let detail = [parsed?.error, parsed?.error_description].compactMap { $0 }.joined(separator: ": ")
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.tokenRequestFailed(status: http.statusCode,
                                               detail: detail.isEmpty ? String(raw.prefix(200)) : detail)
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? "",
            expiresAt: Date().addingTimeInterval(decoded.expires_in ?? 3600),
            alias: nil,
            home: nil)
    }

    private struct UserInfo: Codable {
        var alias: String?
        var home: String?
    }

    private func fetchUserInfo(accessToken: String) async throws -> UserInfo {
        var components = URLComponents(string: hidriveAPIBase + "/user/me")!
        components.queryItems = [URLQueryItem(name: "fields", value: "alias,home")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.badResponse
        }
        return try JSONDecoder().decode(UserInfo.self, from: data)
    }

    func homePath() async throws -> String {
        if let home = tokens()?.home, !home.isEmpty { return home }
        if let alias = tokens()?.alias, !alias.isEmpty { return "/users/\(alias)" }
        return "/"
    }

    func accountAlias() -> String? { tokens()?.alias }
}

// Authorization-code flow without a redirect back into the app: HiDrive displays the code
// (valid 5 minutes) and the user pastes it; exchangeCode() then redeems it.
enum OAuthWebFlow {
    static func authorizeURL() throws -> URL {
        guard let creds = HiDriveAuth.credentials() else { throw AuthError.missingCredentials }
        var items = [
            URLQueryItem(name: "client_id", value: creds.id),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "user,rw")
        ]
        if let hidriveRedirectURI {
            items.append(URLQueryItem(name: "redirect_uri", value: hidriveRedirectURI))
        }
        var components = URLComponents(string: hidriveAuthorizeURL)!
        components.queryItems = items
        guard let url = components.url else { throw AuthError.badResponse }
        return url
    }
}

struct SignInPage: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}
