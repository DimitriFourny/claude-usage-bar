import AppKit
import CryptoKit
import Foundation
import Network

struct OAuthCredentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String?
    var orgName: String?

    /// Refresh a few minutes early so a poll never races the expiry.
    var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 300 }
}

/// Claude subscription sign-in through the default browser, using the same public OAuth client and
/// loopback redirect as Claude Code (and oh-my-pi): PKCE, `http://localhost:<port>/callback`.
enum ClaudeOAuth {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    private static let tokenURL = URL(string: "https://api.anthropic.com/v1/oauth/token")!
    /// `/api/oauth/usage` only needs the profile scope; no inference access is requested.
    private static let scope = "user:profile"

    static func signIn() async throws -> OAuthCredentials {
        let verifier = randomToken(bytes: 64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomToken(bytes: 32)

        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        // Anthropic only accepts the `localhost` host with path `/callback`; any port is allowed.
        let redirectURI = "http://localhost:\(receiver.port)/callback"

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        let url = components.url!
        await MainActor.run { _ = NSWorkspace.shared.open(url) }

        let query = try await receiver.waitForCallback()
        if let error = query["error"] {
            throw OAuthError.denied(query["error_description"] ?? error)
        }
        guard query["state"] == state, var code = query["code"] else { throw OAuthError.invalidCallback }
        // With `code=true` the code may come back as `code#state`.
        if let hash = code.firstIndex(of: "#") { code = String(code[..<hash]) }

        return try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ], isRefresh: false)
    }

    /// Refresh tokens rotate: the returned credentials must replace the stored ones.
    static func refresh(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        var refreshed = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": clientID,
        ], isRefresh: true)
        refreshed.email = refreshed.email ?? credentials.email
        refreshed.orgName = refreshed.orgName ?? credentials.orgName
        if refreshed.refreshToken.isEmpty { refreshed.refreshToken = credentials.refreshToken }
        return refreshed
    }

    private struct TokenResponse: Decodable {
        struct Account: Decodable { let emailAddress: String? }
        struct Organization: Decodable { let name: String? }
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        let account: Account?
        let organization: Organization?
    }

    private static func tokenRequest(_ body: [String: String], isRefresh: Bool) async throws -> OAuthCredentials {
        var request = URLRequest(url: tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isRefresh { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // On refresh, invalid_grant means revoked or past the ~30-day grant lifetime: only a new sign-in helps.
            if isRefresh, body?["error"] as? String == "invalid_grant" { throw OAuthError.signInExpired }
            throw OAuthError.tokenEndpoint(status, body?["error_description"] as? String)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let token = try? decoder.decode(TokenResponse.self, from: data) else { throw OAuthError.invalidCallback }
        return OAuthCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(token.expiresIn),
            email: token.account?.emailAddress,
            orgName: token.organization?.name
        )
    }

    private static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthError: LocalizedError {
    case denied(String)
    case invalidCallback
    case signInExpired
    case tokenEndpoint(Int, String?)
    case listener(String)

    var errorDescription: String? {
        switch self {
        case .denied(let reason): "Sign-in was refused: \(reason)"
        case .invalidCallback: "Unexpected response from the Claude sign-in."
        case .signInExpired: "Your Claude sign-in expired. Sign in again."
        case .tokenEndpoint(let status, let detail): "Claude sign-in failed (HTTP \(status))\(detail.map { ": \($0)" } ?? ".")"
        case .listener(let reason): "Could not start the local sign-in listener: \(reason)"
        }
    }
}

/// One-shot HTTP listener on the loopback interface that captures the OAuth redirect's query string.
/// All mutable state is confined to `queue`.
private final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ClaudeUsageBar.oauth-loopback")
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?

    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> LoopbackReceiver {
        let parameters = NWParameters.tcp
        // Loopback only (IPv4 and IPv6, since browsers may resolve `localhost` to either); never reachable from the network.
        parameters.requiredInterfaceType = .loopback
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: .any) } catch { throw OAuthError.listener("\(error)") }

        let queue = DispatchQueue(label: "ClaudeUsageBar.oauth-loopback.start")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // The handler runs serially on `queue`.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: OAuthError.listener("\(error)"))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }

        let receiver = LoopbackReceiver(listener: listener, port: port)
        listener.newConnectionHandler = { [weak receiver] connection in receiver?.handle(connection) }
        return receiver
    }

    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let pending = self.pending {
                        self.pending = nil
                        continuation.resume(with: pending)
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            queue.async { self.deliver(.failure(CancellationError())) }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func deliver(_ result: Result<[String: String], Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        } else if pending == nil {
            pending = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            // Request line: "GET /callback?code=…&state=… HTTP/1.1"
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                .split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, let components = URLComponents(string: String(parts[1])),
                  components.path == "/callback" else {
                return Self.respond(connection, status: "404 Not Found", body: "Not found")
            }
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
            Self.respond(connection, status: "200 OK", body: query["error"] == nil
                ? "Claude Usage Bar received your sign-in. You can close this tab."
                : "Sign-in was cancelled. You can close this tab.")
            self.deliver(.success(query))
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let html = """
        <!doctype html><meta charset="utf-8"><title>Claude Usage Bar</title>
        <body style="font: 16px -apple-system, sans-serif; text-align: center; padding-top: 80px">\(body)</body>
        """
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
