import Foundation
import Testing
@testable import ClaudeUsageMonitorCore

struct UsageCacheTests {
    @Test func maxValuesAreRead() {
        let cache = parsedCache(cacheJSON(
            organizationType: "\"claude_max\"",
            fiveHour: window("42.0", resetsAt: "\"2026-11-15T05:04:59.572067+00:00\""),
            sevenDay: window("17.5", resetsAt: "\"2026-11-20T00:00:00+00:00\""),
            extraUsage: extra(enabled: false, utilization: "null")
        ))
        #expect(cache.fetchedAtMs == 1_790_000_000_000)
        #expect(cache.organizationType == "claude_max")
        #expect(cache.fiveHour?.utilization == 42.0)
        #expect(cache.sevenDay?.utilization == 17.5)
        #expect(cache.extraUsage == ExtraUsage(isEnabled: false, utilization: nil))
    }

    @Test func fractionalAndPlainResetTimesAreBothRead() throws {
        let cache = parsedCache(cacheJSON(
            fiveHour: window("1", resetsAt: "\"2026-11-15T05:04:59.572067+00:00\""),
            sevenDay: window("1", resetsAt: "\"2026-11-20T00:00:00+00:00\"")
        ))
        let fractional = try #require(cache.fiveHour?.resetsAt)
        let plain = try #require(cache.sevenDay?.resetsAt)
        #expect(abs(fractional.timeIntervalSince(jst(2026, 11, 15, 14, 4, 59)) - 0.572067) < 0.001)
        #expect(plain == jst(2026, 11, 20, 9))
    }

    @Test func enterpriseValuesAreRead() {
        let cache = parsedCache(cacheJSON(
            organizationType: "\"claude_enterprise\"",
            extraUsage: extra(enabled: true, utilization: "63.2")
        ))
        #expect(cache.organizationType == "claude_enterprise")
        #expect(cache.fiveHour == nil)
        #expect(cache.sevenDay == nil)
        #expect(cache.extraUsage == ExtraUsage(isEnabled: true, utilization: 63.2))
    }

    @Test func integerUtilizationIsNotDropped() {
        let cache = parsedCache(cacheJSON(
            fiveHour: window("0", resetsAt: "null"),
            sevenDay: window("100", resetsAt: "null"),
            extraUsage: extra(enabled: true, utilization: "100")
        ))
        #expect(cache.fiveHour?.utilization == 0)
        #expect(cache.sevenDay?.utilization == 100)
        #expect(cache.extraUsage?.utilization == 100)
    }

    @Test func nullAtAnyLevelBecomesNilWithoutFailing() {
        let cache = parsedCache(cacheJSON(
            organizationType: "null",
            fiveHour: "{ \"utilization\": null, \"resets_at\": null }",
            sevenDay: "null",
            extraUsage: "{ \"is_enabled\": null, \"utilization\": null }"
        ))
        #expect(cache.organizationType == nil)
        #expect(cache.fiveHour == UsageWindow(utilization: nil, resetsAt: nil))
        #expect(cache.sevenDay == nil)
        #expect(cache.extraUsage == ExtraUsage(isEnabled: false, utilization: nil))
    }

    @Test func wrongTypesBecomeNilWithoutFailing() {
        let cache = parsedCache(cacheJSON(
            organizationType: "42",
            fiveHour: "{ \"utilization\": \"high\", \"resets_at\": 123 }",
            sevenDay: "\"none\"",
            extraUsage: "[]"
        ))
        #expect(cache.organizationType == nil)
        #expect(cache.fiveHour == UsageWindow(utilization: nil, resetsAt: nil))
        #expect(cache.sevenDay == nil)
        #expect(cache.extraUsage == nil)
    }

    @Test func missingUtilizationObjectStillParses() {
        let json = #"{ "oauthAccount": {}, "cachedUsageUtilization": { "fetchedAtMs": 5 } }"#
        #expect(UsageCache.parse(Data(json.utf8)) == .ok(UsageCache(fetchedAtMs: 5)))
    }

    @Test func missingAccountOrCacheMeansNotLoggedIn() {
        #expect(UsageCache.parse(Data(cacheJSON(includeAccount: false).utf8)) == .notLoggedIn)
        #expect(UsageCache.parse(Data(cacheJSON(includeCache: false).utf8)) == .notLoggedIn)
        #expect(UsageCache.parse(Data(#"{ "oauthAccount": null, "cachedUsageUtilization": {} }"#.utf8)) == .notLoggedIn)
        #expect(UsageCache.parse(Data(#"{ "oauthAccount": {}, "cachedUsageUtilization": "x" }"#.utf8)) == .notLoggedIn)
        #expect(UsageCache.parse(Data("{}".utf8)) == .notLoggedIn)
    }

    @Test func brokenJSONOrMissingFetchTimeIsMalformed() {
        let whole = cacheJSON()
        #expect(UsageCache.parse(Data(whole.prefix(whole.count / 2).utf8)) == .malformed)
        #expect(UsageCache.parse(Data("[1, 2]".utf8)) == .malformed)
        #expect(UsageCache.parse(Data()) == .malformed)
        #expect(UsageCache.parse(Data(cacheJSON(fetchedAtMs: nil).utf8)) == .malformed)
        #expect(UsageCache.parse(Data(cacheJSON(fetchedAtMs: "\"1790000000000\"").utf8)) == .malformed)
        #expect(UsageCache.parse(Data(cacheJSON(fetchedAtMs: "true").utf8)) == .malformed)
        #expect(UsageCache.parse(Data(cacheJSON(fetchedAtMs: "null").utf8)) == .malformed)
    }
}
