import Foundation
import AuthenticationServices
import UIKit

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

enum AuthError: Error {
    case missingCredentials
    case notConnected
    case badResponse
    case userCancelled
}

let hidriveAuthorizeURL = "https://my.hidrive.com/client/authorize"
let hidriveTokenURL = "https://my.hidrive.com/oauth2/token"
let hidriveAPIBase = "https://api.hidrive.strato.com/2.1"

actor HiDriveAuth {
    static let shared = HiDriveAuth()

    private var cachedTokens: OAuthTokens?

    // Client id/secret baked in at build time via Info.plist, overridable from the credentials screen.
    nonisolated static func credentials() -> ClientCredentials? {
        if let id = KeychainStore.getString(account: "clientId"),
           let secret = KeychainStore.getString(account: "clientSecret"),
           !id.isEmpty, !secret.isEmpty {
            return ClientCredentials(id: id, secret: secret)
        }
        let info = Bundle.main.infoDictionary
        let id = info?["HiDriveClientID"] as? String ?? ""
        let secret = info?["HiDriveClientSecret"] as? String ?? ""
        if !id.isEmpty && !secret.isEmpty {
            return ClientCredentials(id: id, secret: secret)
        }
        return nil
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
        var tokens = try await requestToken(form: [
            "grant_type": "authorization_code",
            "code": code
        ])
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.badResponse
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

// Runs the ASWebAuthenticationSession flow; falls back to manual code paste in the UI if this fails.
@MainActor
final class OAuthWebFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthWebFlow()

    func authorize() async throws -> String {
        guard let creds = HiDriveAuth.credentials() else { throw AuthError.missingCredentials }
        var components = URLComponents(string: hidriveAuthorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: creds.id),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "user,rw"),
            URLQueryItem(name: "redirect_uri", value: "photovault://oauth")
        ]
        let url = components.url!
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "photovault") { callbackURL, error in
                if let callbackURL,
                   let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                   let code = items.first(where: { $0.name == "code" })?.value {
                    continuation.resume(returning: code)
                } else if error != nil {
                    continuation.resume(throwing: AuthError.userCancelled)
                } else {
                    continuation.resume(throwing: AuthError.badResponse)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.first?.keyWindow ?? ASPresentationAnchor()
        }
    }
}
