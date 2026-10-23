import Foundation

/// One rate-limit window as reported by claude.ai (`five_hour`, `seven_day`, `seven_day_opus`, ...).
struct UsageWindow: Identifiable, Equatable, Sendable {
    let id: String
    /// Percentage used, 0–100.
    let utilization: Double
    let resetsAt: Date?

    var remaining: Double { max(0, min(100, 100 - utilization)) }

    var title: String {
        switch id {
        case "five_hour": "Session (5 hours)"
        case "seven_day": "Week (all models)"
        case "seven_day_oauth_apps": "Week (OAuth apps)"
        case "extra_usage": "Extra usage"
        case let id where id.hasPrefix("seven_day_"):
            "Week (\(id.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized))"
        default: id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Display order: the two headline windows first, then everything else alphabetically.
    fileprivate var sortKey: String {
        switch id {
        case "five_hour": "0"
        case "seven_day": "1"
        default: "2" + id
        }
    }
}

enum ClaudeAPIError: LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Claude rejected the sign-in. Sign in again."
        case .rateLimited: "Rate limited by Claude. Will retry later."
        case .http(let code): "Claude returned HTTP \(code)."
        case .badResponse: "Unexpected response from Claude."
        }
    }
}

enum ClaudeAPI {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The usage route rate-limits unknown clients hard; present the Claude Code CLI identity like other tools do.
    private static let userAgent = "claude-cli/2.1.280 (external, cli)"

    static func usage(accessToken: String) async throws -> [UsageWindow] {
        var request = URLRequest(url: usageURL, timeoutInterval: 30)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeAPIError.badResponse }
        switch http.statusCode {
        case 200..<300: return try parseUsage(data)
        case 401, 403: throw ClaudeAPIError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ClaudeAPIError.rateLimited(retryAfter: retryAfter)
        default: throw ClaudeAPIError.http(http.statusCode)
        }
    }

    /// Reads every top-level object carrying a numeric `utilization` (`five_hour`, `seven_day`, ...), so new
    /// windows show up without code changes, plus per-model weekly caps, which only arrive as
    /// `limits[] {kind: "weekly_scoped", percent, resets_at, scope.model.display_name}`.
    static func parseUsage(_ data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAPIError.badResponse
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            (value as? String).flatMap { withFraction.date(from: $0) ?? plain.date(from: $0) }
        }

        var windows = root.compactMap { key, value -> UsageWindow? in
            guard let dict = value as? [String: Any],
                  let utilization = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(id: key, utilization: utilization, resetsAt: date(dict["resets_at"]))
        }

        for entry in root["limits"] as? [[String: Any]] ?? [] {
            guard let kind = entry["kind"] as? String,
                  let percent = (entry["percent"] as? NSNumber)?.doubleValue else { continue }
            let id: String
            switch kind {
            case "session": id = "five_hour"
            case "weekly_all": id = "seven_day"
            case "weekly_scoped":
                guard let name = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
                      !name.isEmpty else { continue }
                id = "seven_day_" + name.lowercased()
            default: continue
            }
            // Legacy top-level buckets win when both are present.
            guard !windows.contains(where: { $0.id == id }) else { continue }
            windows.append(UsageWindow(id: id, utilization: percent, resetsAt: date(entry["resets_at"])))
        }

        guard windows.contains(where: { $0.id == "five_hour" || $0.id == "seven_day" }) else {
            throw ClaudeAPIError.badResponse
        }
        return windows.sorted { $0.sortKey < $1.sortKey }
    }
}
