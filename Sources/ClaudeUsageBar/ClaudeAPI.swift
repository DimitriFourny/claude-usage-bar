import Foundation

/// One rate-limit window as reported by claude.ai (`five_hour`, `seven_day`, `seven_day_opus`, ...).
struct UsageWindow: Identifiable, Equatable, Sendable {
    let id: String
    /// Percentage used, 0–100.
    let utilization: Double
    let resetsAt: Date?

    var remaining: Double { max(0, min(100, 100 - utilization)) }

    /// Length of the window, used to find when it started (`resetsAt - duration`).
    var duration: TimeInterval? {
        switch id {
        case "five_hour": 5 * 3600
        case let id where id.hasPrefix("seven_day"): 7 * 86_400
        default: nil
        }
    }

    /// Where the window ends up if usage continues at its average rate since the window started.
    /// `nil` when there's no usage yet, the window is already used up, or it started too recently to tell.
    func pace(now: Date) -> Pace? {
        guard let resetsAt, let duration, utilization > 0, utilization < 100 else { return nil }
        let untilReset = resetsAt.timeIntervalSince(now)
        let elapsed = duration - untilReset
        // Early in a window a single message extrapolates wildly; wait for a meaningful sample.
        guard untilReset > 0, elapsed >= max(15 * 60, duration * 0.02) else { return nil }
        let ratePerSecond = utilization / elapsed
        let untilEmpty = remaining / ratePerSecond
        if untilEmpty < untilReset {
            return .runsOut(at: now.addingTimeInterval(untilEmpty), beforeReset: untilReset - untilEmpty)
        }
        return .lasts(usedAtReset: utilization + ratePerSecond * untilReset)
    }

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

enum Pace: Equatable, Sendable {
    /// Hits 0% left at `at`, `beforeReset` seconds before the window resets.
    case runsOut(at: Date, beforeReset: TimeInterval)
    /// Still has quota at reset; `usedAtReset` is the projected % used by then.
    case lasts(usedAtReset: Double)
}

/// An amount in minor units (cents for USD), as claude.ai reports money.
struct Money: Equatable, Sendable {
    let minorUnits: Int
    let exponent: Int
    let currency: String

    var amount: Decimal { Decimal(minorUnits) / pow(Decimal(10), exponent) }
    var formatted: String { amount.formatted(.currency(code: currency)) }
}

/// Pay-as-you-go credits used once the plan limits are hit ("extra usage"), capped by an optional
/// monthly spend limit, plus any prepaid credit balance.
struct ExtraUsage: Equatable, Sendable {
    let isEnabled: Bool
    let used: Money?
    let monthlyLimit: Money?
    let balance: Money?
    let limitReached: Bool
    let disabledReason: String?
    /// Server-computed % of the monthly limit used; only a fallback when the amounts are missing.
    let reportedUtilization: Double?

    /// % of the monthly limit used, 0–100; `nil` without a monthly limit.
    var utilization: Double? {
        if let used, let monthlyLimit, monthlyLimit.minorUnits > 0, used.currency == monthlyLimit.currency {
            let usedAmount = NSDecimalNumber(decimal: used.amount).doubleValue
            let limitAmount = NSDecimalNumber(decimal: monthlyLimit.amount).doubleValue
            return usedAmount / limitAmount * 100
        }
        return monthlyLimit == nil ? nil : reportedUtilization
    }

    var remaining: Double? { utilization.map { limitReached ? 0 : max(0, min(100, 100 - $0)) } }
}

struct UsageReport: Equatable, Sendable {
    let windows: [UsageWindow]
    let extraUsage: ExtraUsage?
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

    static func usage(accessToken: String) async throws -> UsageReport {
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
    static func parseUsage(_ data: Data) throws -> UsageReport {
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
            // Extra usage is money, not a rate-limit window; it gets its own section.
            guard key != "extra_usage", let dict = value as? [String: Any],
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
        return UsageReport(windows: windows.sorted { $0.sortKey < $1.sortKey }, extraUsage: parseExtraUsage(root))
    }

    /// Reads `spend {enabled, used, limit, balance}` (money as `{amount_minor, currency, exponent}`), falling back to
    /// the older `extra_usage {is_enabled, used_credits, monthly_limit, currency, decimal_places, utilization}`,
    /// whose amounts are minor units (cents).
    static func parseExtraUsage(_ root: [String: Any]) -> ExtraUsage? {
        let extra = root["extra_usage"] as? [String: Any]
        let spend = root["spend"] as? [String: Any]
        guard extra != nil || spend != nil else { return nil }
        let currency = extra?["currency"] as? String
        let exponent = number(extra?["decimal_places"]).map { Int($0) }
        func extraMoney(_ key: String) -> Money? { money(extra?[key], currency: currency, exponent: exponent) }

        let disabledReason = [extra?["disabled_reason"], spend?["disabled_reason"]]
            .compactMap { $0 as? String }.first { !$0.isEmpty }
        return ExtraUsage(
            isEnabled: extra?["is_enabled"] as? Bool == true || spend?["enabled"] as? Bool == true,
            used: money(spend?["used"]) ?? extraMoney("used_credits"),
            monthlyLimit: money(spend?["limit"]) ?? extraMoney("monthly_limit"),
            balance: money(spend?["balance"]) ?? money(root["promo_credits"]),
            limitReached: extra?["spend_limit_reached"] as? Bool == true,
            disabledReason: disabledReason,
            reportedUtilization: number(extra?["utilization"]) ?? number(spend?["percent"])
        )
    }

    /// A JSON number that isn't a boolean (`JSONSerialization` returns both as `NSNumber`).
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// Accepts `{amount_minor, currency, exponent}`, a wrapper holding one under `amount`, or a bare number of
    /// minor units (with `currency`/`exponent` from the surrounding object, defaulting to USD cents).
    private static func money(_ value: Any?, currency: String? = nil, exponent: Int? = nil) -> Money? {
        if let dict = value as? [String: Any] {
            guard let minor = number(dict["amount_minor"]) else { return money(dict["amount"], currency: currency, exponent: exponent) }
            return Money(
                minorUnits: Int(minor.rounded()),
                exponent: number(dict["exponent"]).map { Int($0) } ?? exponent ?? 2,
                currency: dict["currency"] as? String ?? currency ?? "USD"
            )
        }
        guard let minor = number(value) else { return nil }
        return Money(minorUnits: Int(minor.rounded()), exponent: exponent ?? 2, currency: currency ?? "USD")
    }
}
