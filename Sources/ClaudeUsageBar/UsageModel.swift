import AppKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class UsageModel {
    private(set) var windows: [UsageWindow] = []
    private(set) var lastUpdated: Date?
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var isSigningIn = false
    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self.error = "Launch at login: \(error.localizedDescription)"
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private var credentials: OAuthCredentials?
    private var loop: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    /// Set after a 429 so the next poll honours the server's back-off.
    private var rateLimitedUntil: Date?

    /// Polling cadence; the usage endpoint rate-limits aggressive polling.
    private static let pollInterval: TimeInterval = 180

    init() {
        credentials = Keychain.read()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartLoop() }
        }
        restartLoop()
    }

    var hasSession: Bool { credentials != nil }
    var account: String? {
        let parts = [credentials?.email, credentials?.orgName].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var fiveHour: UsageWindow? { windows.first { $0.id == "five_hour" } }
    var weekly: UsageWindow? { windows.first { $0.id == "seven_day" } }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// Opens the Claude authorization page in the default browser and waits for its redirect.
    func signIn() {
        signInTask?.cancel()
        isSigningIn = true
        error = nil
        signInTask = Task {
            defer { if !Task.isCancelled { isSigningIn = false } }
            do {
                let credentials = try await ClaudeOAuth.signIn()
                Keychain.save(credentials)
                self.credentials = credentials
                windows = []
                lastUpdated = nil
                restartLoop()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        isSigningIn = false
    }

    func signOut() {
        cancelSignIn()
        Keychain.delete()
        credentials = nil
        windows = []
        lastUpdated = nil
        error = nil
        loop?.cancel()
    }

    func refreshNow() {
        Task { await refresh() }
    }

    /// Called when the popover opens: avoid hammering the API, but don't show minutes-old data either.
    func refreshIfStale() {
        guard let lastUpdated else { return refreshNow() }
        if Date().timeIntervalSince(lastUpdated) > 60 { refreshNow() }
    }

    private func restartLoop() {
        loop?.cancel()
        guard hasSession else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.nextDelay()))
            }
        }
    }

    /// Poll every `pollInterval`, but wake up just after a window resets so the bar flips to 100% promptly.
    private func nextDelay() -> TimeInterval {
        let now = Date()
        if let rateLimitedUntil, rateLimitedUntil > now { return rateLimitedUntil.timeIntervalSince(now) }
        let nextReset = windows.compactMap(\.resetsAt).filter { $0 > now }.min()
        guard let nextReset else { return Self.pollInterval }
        return max(10, min(Self.pollInterval, nextReset.timeIntervalSince(now) + 5))
    }

    private func refresh() async {
        guard var current = credentials, !isRefreshing else { return }
        if let rateLimitedUntil, rateLimitedUntil > Date() { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            if current.needsRefresh { current = try await refreshCredentials(current) }
            let result: [UsageWindow]
            do {
                result = try await ClaudeAPI.usage(accessToken: current.accessToken)
            } catch ClaudeAPIError.unauthorized {
                // Access token revoked or expired early: rotate once before giving up.
                current = try await refreshCredentials(current)
                result = try await ClaudeAPI.usage(accessToken: current.accessToken)
            }
            guard credentials?.refreshToken == current.refreshToken else { return }
            windows = result
            lastUpdated = Date()
            error = nil
        } catch OAuthError.signInExpired {
            signOut()
            error = OAuthError.signInExpired.localizedDescription
        } catch ClaudeAPIError.rateLimited(let retryAfter) {
            rateLimitedUntil = Date().addingTimeInterval(max(retryAfter ?? 0, 300))
            error = ClaudeAPIError.rateLimited(retryAfter: retryAfter).localizedDescription
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refreshCredentials(_ old: OAuthCredentials) async throws -> OAuthCredentials {
        let new = try await ClaudeOAuth.refresh(old)
        // The old refresh token is now dead; persist the rotated one before anything else can fail.
        guard credentials?.refreshToken == old.refreshToken else { throw CancellationError() }
        Keychain.save(new)
        credentials = new
        return new
    }
}
