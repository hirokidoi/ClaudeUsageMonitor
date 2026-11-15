import Foundation

public struct UsageWindow: Sendable, Equatable {
    public var utilization: Double?
    public var resetsAt: Date?

    public init(utilization: Double?, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct ExtraUsage: Sendable, Equatable {
    public var isEnabled: Bool
    public var utilization: Double?

    public init(isEnabled: Bool, utilization: Double?) {
        self.isEnabled = isEnabled
        self.utilization = utilization
    }
}

/// `.claude.json` の解析結果。必須は `fetchedAtMs` だけで、他は欠落・null・型違いを nil にする。
public struct UsageCache: Sendable, Equatable {
    public var fetchedAtMs: Int64
    public var organizationType: String?
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var extraUsage: ExtraUsage?

    public init(
        fetchedAtMs: Int64,
        organizationType: String? = nil,
        fiveHour: UsageWindow? = nil,
        sevenDay: UsageWindow? = nil,
        extraUsage: ExtraUsage? = nil
    ) {
        self.fetchedAtMs = fetchedAtMs
        self.organizationType = organizationType
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.extraUsage = extraUsage
    }

    public var fetchedAt: Date { Date(timeIntervalSince1970: Double(fetchedAtMs) / Self.millisecondsPerSecond) }

    static let millisecondsPerSecond = 1000.0

    public static func parse(_ data: Data) -> UsageCacheParse {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .malformed }
        guard let account = root["oauthAccount"] as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any]
        else { return .notLoggedIn }
        guard let fetchedAtMs = integer(cached["fetchedAtMs"]) else { return .malformed }
        let utilization = cached["utilization"] as? [String: Any]
        return .ok(UsageCache(
            fetchedAtMs: fetchedAtMs,
            organizationType: account["organizationType"] as? String,
            fiveHour: window(utilization?["five_hour"]),
            sevenDay: window(utilization?["seven_day"]),
            extraUsage: extra(utilization?["extra_usage"])
        ))
    }

    private static func window(_ any: Any?) -> UsageWindow? {
        guard let dict = any as? [String: Any] else { return nil }
        return UsageWindow(
            utilization: double(dict["utilization"]),
            resetsAt: (dict["resets_at"] as? String).flatMap(parseISO8601)
        )
    }

    private static func extra(_ any: Any?) -> ExtraUsage? {
        guard let dict = any as? [String: Any] else { return nil }
        return ExtraUsage(isEnabled: dict["is_enabled"] as? Bool ?? false, utilization: double(dict["utilization"]))
    }

    // resets_at は小数秒ありとなしが混在する。
    private static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    // JSONSerialization は数を NSNumber で返し、整数 (0 や 100) は `as? Double` で取りこぼす経路がある。
    private static func double(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, !isBoolean(n) else { return nil }
        return n.doubleValue
    }

    private static func integer(_ any: Any?) -> Int64? {
        guard let n = any as? NSNumber, !isBoolean(n) else { return nil }
        return n.int64Value
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

public enum UsageCacheParse: Sendable, Equatable {
    case ok(UsageCache)
    case notLoggedIn
    case malformed
}

public enum UsageCacheRead: Sendable, Equatable {
    case ok(UsageCache)
    case missing
    case unreadable
    case notLoggedIn
}

public enum UsageCacheReader {
    /// 初回を含む。CLI がファイルを書き直す途中を避けるための短い待ち (設計値)。
    public static let attempts = 3
    public static let retryDelay: TimeInterval = 0.2

    /// 無いファイルは読み直さない。読めない・壊れているときだけ読み直す。
    public static func read(
        at url: URL,
        attempts: Int = UsageCacheReader.attempts,
        retryDelay: TimeInterval = UsageCacheReader.retryDelay,
        load: (URL) throws -> Data = { try Data(contentsOf: $0) },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> UsageCacheRead {
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 { sleep(retryDelay) }
            let data: Data
            do { data = try load(url) } catch {
                if isMissing(error) { return .missing }
                continue
            }
            switch UsageCache.parse(data) {
            case let .ok(cache): return .ok(cache)
            case .notLoggedIn: return .notLoggedIn
            case .malformed: continue
            }
        }
        return .unreadable
    }

    static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError)
    }
}
