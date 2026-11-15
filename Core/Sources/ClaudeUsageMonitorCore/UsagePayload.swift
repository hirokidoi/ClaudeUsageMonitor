import Foundation

/// JSON 出力・表示は端末の TZ に依存せず常に JST。
public enum JST {
    public static let timeZone = TimeZone(identifier: "Asia/Tokyo")!

    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    private static func formatter(_ format: String, locale: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: locale)
        formatter.timeZone = timeZone
        return formatter
    }

    private static let isoFormatter = formatter("yyyy-MM-dd'T'HH:mm:ssxxx", locale: "en_US_POSIX")
    private static let timeFormatter = formatter("H:mm", locale: "ja_JP")
    private static let dateTimeFormatter = formatter("M/d (E) H:mm", locale: "ja_JP")

    /// JSON 出力用。秒未満は切り捨てる。
    public static func iso8601(_ date: Date) -> String { isoFormatter.string(from: date) }
    /// メニューのセッションの時刻。
    public static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    /// メニューの週・月・最終取得の時刻。
    public static func dateTime(_ date: Date) -> String { dateTimeFormatter.string(from: date) }

    /// `date` の翌月 1 日 0:00。
    public static func nextMonthFirst(from date: Date) -> Date? {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return nil }
        var next = DateComponents()
        next.year = month == 12 ? year + 1 : year
        next.month = month == 12 ? 1 : month + 1
        next.day = 1
        next.hour = 0
        next.minute = 0
        next.second = 0
        next.timeZone = timeZone
        return calendar.date(from: next)
    }

    static let roundingStepMinutes = 10

    /// 最も近い刻みの境界に丸める。
    public static func roundedToNearestStep(_ date: Date) -> Date {
        let step = roundingStepMinutes
        guard let shifted = calendar.date(byAdding: .minute, value: step / 2, to: date) else { return date }
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: shifted)
        components.minute = ((components.minute ?? 0) / step) * step
        components.second = 0
        return calendar.date(from: components) ?? date
    }
}

public enum UsagePlan: String, Sendable, Equatable {
    case individual
    case enterprise

    /// `organizationType` で決める。five_hour が空なことだけで Enterprise にはしない (未取得でも空になる)。
    public static func decide(_ cache: UsageCache) -> UsagePlan {
        switch cache.organizationType {
        case "claude_enterprise": return .enterprise
        case "claude_max", "claude_pro": return .individual
        default:
            if cache.fiveHour != nil || cache.sevenDay != nil { return .individual }
            return cache.extraUsage?.isEnabled == true ? .enterprise : .individual
        }
    }
}

public struct UsageData: Codable, Sendable, Equatable {
    public let fetchedAt: String
    public let plan: String
    // Enterprise では weekly が常に nil。Individual でも片側 null がありうる。
    public let sessionPct: Int?
    public let sessionResetAt: String?
    public let weeklyPct: Int?
    public let weeklyResetAt: String?

    // 全キー常在にするため、nil も null で出す。
    private enum CodingKeys: String, CodingKey {
        case fetchedAt, plan, sessionPct, sessionResetAt, weeklyPct, weeklyResetAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(plan, forKey: .plan)
        try container.encode(sessionPct, forKey: .sessionPct)
        try container.encode(sessionResetAt, forKey: .sessionResetAt)
        try container.encode(weeklyPct, forKey: .weeklyPct)
        try container.encode(weeklyResetAt, forKey: .weeklyResetAt)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(self)
    }
}

/// メニュー表示と警告判定用。`*ResetAt` は表示用に丸めた値で、判定には `*ResetDeadline` を使う。
public struct UsageSnapshot: Sendable, Equatable {
    public let plan: UsagePlan
    public let fetchedAt: Date
    public let sessionPct: Int?
    public let sessionResetAt: Date?
    public let sessionResetDeadline: Date?
    public let weeklyPct: Int?
    public let weeklyResetAt: Date?
    public let weeklyResetDeadline: Date?

    public func sessionHasReset(asOf now: Date) -> Bool { Self.hasReset(sessionResetDeadline, asOf: now) }
    public func weeklyHasReset(asOf now: Date) -> Bool { Self.hasReset(weeklyResetDeadline, asOf: now) }

    private static func hasReset(_ deadline: Date?, asOf now: Date) -> Bool {
        guard let deadline else { return false }
        return deadline <= now
    }
}

public enum UsagePayload {
    /// 現在時刻は使わない。
    public static func make(from cache: UsageCache) -> (data: UsageData, snapshot: UsageSnapshot) {
        let plan = UsagePlan.decide(cache)
        let fetchedAt = cache.fetchedAt
        // 出力は秒まで。
        let fetchedAtText = JST.iso8601(fetchedAt)

        switch plan {
        case .individual:
            let sessionDeadline = cache.fiveHour?.resetsAt
            let weeklyDeadline = cache.sevenDay?.resetsAt
            let sessionResetAt = sessionDeadline.map(JST.roundedToNearestStep)
            let weeklyResetAt = weeklyDeadline.map(JST.roundedToNearestStep)
            let sessionPct = percent(cache.fiveHour?.utilization)
            let weeklyPct = percent(cache.sevenDay?.utilization)
            return (
                UsageData(
                    fetchedAt: fetchedAtText,
                    plan: plan.rawValue,
                    sessionPct: sessionPct,
                    sessionResetAt: sessionResetAt.map(JST.iso8601),
                    weeklyPct: weeklyPct,
                    weeklyResetAt: weeklyResetAt.map(JST.iso8601)
                ),
                UsageSnapshot(
                    plan: plan,
                    fetchedAt: fetchedAt,
                    sessionPct: sessionPct,
                    sessionResetAt: sessionResetAt,
                    sessionResetDeadline: sessionDeadline,
                    weeklyPct: weeklyPct,
                    weeklyResetAt: weeklyResetAt,
                    weeklyResetDeadline: weeklyDeadline
                )
            )
        case .enterprise:
            // 応答にリセット時刻は無いので、取得時刻の翌月 1 日とみなす。
            let reset = JST.nextMonthFirst(from: fetchedAt)
            let sessionPct = percent(cache.extraUsage?.utilization)
            return (
                UsageData(
                    fetchedAt: fetchedAtText,
                    plan: plan.rawValue,
                    sessionPct: sessionPct,
                    sessionResetAt: reset.map(JST.iso8601),
                    weeklyPct: nil,
                    weeklyResetAt: nil
                ),
                UsageSnapshot(
                    plan: plan,
                    fetchedAt: fetchedAt,
                    sessionPct: sessionPct,
                    sessionResetAt: reset,
                    sessionResetDeadline: reset,
                    weeklyPct: nil,
                    weeklyResetAt: nil,
                    weeklyResetDeadline: nil
                )
            )
        }
    }

    private static func percent(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int(value.rounded())
    }
}
