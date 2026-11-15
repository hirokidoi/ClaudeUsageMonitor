import Foundation
import Testing
@testable import ClaudeUsageMonitorCore

struct UsagePayloadTests {
    private func individual(
        fetchedAt: Date = jst(2026, 11, 15, 12, 34, 56),
        fetchedExtraMs: Int64 = 789,
        five: String = window("42.4", resetsAt: "\"2026-11-15T05:04:59.572067+00:00\""),
        seven: String = window("17.5", resetsAt: "\"2026-11-20T00:00:00+00:00\"")
    ) -> UsageCache {
        parsedCache(cacheJSON(
            fetchedAtMs: String(milliseconds(fetchedAt, extra: fetchedExtraMs)),
            organizationType: "\"claude_max\"",
            fiveHour: five,
            sevenDay: seven
        ))
    }

    private func enterprise(fetchedAt: Date, utilization: String = "63.2") -> UsageCache {
        parsedCache(cacheJSON(
            fetchedAtMs: String(milliseconds(fetchedAt)),
            organizationType: "\"claude_enterprise\"",
            extraUsage: extra(enabled: true, utilization: utilization)
        ))
    }

    // MARK: 出力 JSON の形

    @Test func individualEncodesToTheFixedShape() throws {
        let text = try String(decoding: UsagePayload.make(from: individual()).data.jsonData(), as: UTF8.self)
        #expect(text == """
        {
          "fetched_at" : "2026-11-15T12:34:56+09:00",
          "plan" : "individual",
          "session_pct" : 42,
          "session_reset_at" : "2026-11-15T14:00:00+09:00",
          "weekly_pct" : 18,
          "weekly_reset_at" : "2026-11-20T09:00:00+09:00"
        }
        """)
    }

    @Test func missingValuesAreEncodedAsNullWithAllSixKeys() throws {
        let cache = individual(five: "null", seven: window("0", resetsAt: "null"))
        let text = try String(decoding: UsagePayload.make(from: cache).data.jsonData(), as: UTF8.self)
        #expect(text == """
        {
          "fetched_at" : "2026-11-15T12:34:56+09:00",
          "plan" : "individual",
          "session_pct" : null,
          "session_reset_at" : null,
          "weekly_pct" : 0,
          "weekly_reset_at" : null
        }
        """)
    }

    @Test func enterpriseEncodesMonthlyAsSessionAndWeeklyAsNull() throws {
        let cache = enterprise(fetchedAt: jst(2026, 11, 15, 9))
        let text = try String(decoding: UsagePayload.make(from: cache).data.jsonData(), as: UTF8.self)
        #expect(text == """
        {
          "fetched_at" : "2026-11-15T09:00:00+09:00",
          "plan" : "enterprise",
          "session_pct" : 63,
          "session_reset_at" : "2026-12-01T00:00:00+09:00",
          "weekly_pct" : null,
          "weekly_reset_at" : null
        }
        """)
    }

    @Test func fetchedAtDropsMilliseconds() {
        let almostNextSecond = individual(fetchedExtraMs: 999)
        #expect(UsagePayload.make(from: almostNextSecond).data.fetchedAt == "2026-11-15T12:34:56+09:00")
        #expect(UsagePayload.make(from: almostNextSecond).snapshot.fetchedAt == almostNextSecond.fetchedAt)
    }

    @Test func utcResetTimeIsEncodedWithJSTOffset() {
        let data = UsagePayload.make(from: individual(
            five: window("1", resetsAt: "\"2026-11-15T00:00:00+00:00\"")
        )).data
        #expect(data.sessionResetAt == "2026-11-15T09:00:00+09:00")
    }

    // MARK: 丸め

    @Test(arguments: [
        ("2026-11-15T05:04:59+00:00", "2026-11-15T14:00:00+09:00"),
        ("2026-11-15T05:05:00+00:00", "2026-11-15T14:10:00+09:00"),
        ("2026-11-15T14:54:59+00:00", "2026-11-15T23:50:00+09:00"),
        ("2026-11-15T14:55:00+00:00", "2026-11-16T00:00:00+09:00")
    ])
    func resetTimeRoundsToTheNearestTenMinutes(resetsAt: String, expected: String) {
        let data = UsagePayload.make(from: individual(five: window("1", resetsAt: "\"\(resetsAt)\""))).data
        #expect(data.sessionResetAt == expected)
    }

    // MARK: Enterprise の翌月 1 日

    @Test func enterpriseResetIsFirstOfNextMonthInJST() {
        let december = UsagePayload.make(from: enterprise(fetchedAt: jst(2026, 12, 20, 10))).snapshot
        #expect(december.sessionResetAt == jst(2027, 1, 1))
        // UTC 11/30 15:30 は JST では 12/1 0:30 で、翌々月ではなく 1 月 1 日。
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let utcStillNovember = utc.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 15, minute: 30))!
        let snapshot = UsagePayload.make(from: enterprise(fetchedAt: utcStillNovember)).snapshot
        #expect(snapshot.sessionResetAt == jst(2027, 1, 1))
    }

    @Test func enterpriseResetFollowsTheFetchTimeNotTheClock() {
        let old = UsagePayload.make(from: enterprise(fetchedAt: jst(2026, 3, 31, 23, 59, 59))).snapshot
        #expect(old.sessionResetAt == jst(2026, 4, 1))
    }

    // MARK: 過去のリセット判定

    @Test func hasResetUsesTheUnroundedDeadline() {
        // 表示は 14:00 に丸まるが、14:04:59 まではまだ有効。
        let snapshot = UsagePayload.make(from: individual(
            five: window("1", resetsAt: "\"2026-11-15T05:04:59+00:00\""),
            seven: window("1", resetsAt: "\"2026-11-15T05:04:59+00:00\"")
        )).snapshot
        #expect(snapshot.sessionResetAt == jst(2026, 11, 15, 14))
        #expect(snapshot.sessionHasReset(asOf: jst(2026, 11, 15, 14, 2)) == false)
        #expect(snapshot.sessionHasReset(asOf: jst(2026, 11, 15, 14, 4, 58)) == false)
        #expect(snapshot.sessionHasReset(asOf: jst(2026, 11, 15, 14, 4, 59)) == true)
        #expect(snapshot.sessionHasReset(asOf: jst(2026, 11, 15, 14, 5)) == true)
        #expect(snapshot.weeklyHasReset(asOf: jst(2026, 11, 15, 14, 2)) == false)
        #expect(snapshot.weeklyHasReset(asOf: jst(2026, 11, 15, 14, 5)) == true)
    }

    @Test func hasResetIsFalseWithoutDeadline() {
        let snapshot = UsagePayload.make(from: individual(five: "null", seven: "null")).snapshot
        #expect(snapshot.sessionHasReset(asOf: .distantFuture) == false)
        #expect(snapshot.weeklyHasReset(asOf: .distantFuture) == false)
    }

    @Test func enterpriseDeadlineEqualsTheEncodedResetTime() throws {
        let cache = enterprise(fetchedAt: jst(2026, 11, 15, 9))
        let (data, snapshot) = UsagePayload.make(from: cache)
        #expect(snapshot.sessionResetDeadline == snapshot.sessionResetAt)
        #expect(data.sessionResetAt == JST.iso8601(try #require(snapshot.sessionResetDeadline)))
        #expect(snapshot.weeklyResetDeadline == nil)
        #expect(snapshot.weeklyHasReset(asOf: .distantFuture) == false)
        #expect(snapshot.sessionHasReset(asOf: jst(2026, 12, 1)) == true)
        #expect(snapshot.sessionHasReset(asOf: jst(2026, 11, 30, 23, 59, 59)) == false)
    }

    @Test func snapshotCarriesPlanAndPercentages() {
        let snapshot = UsagePayload.make(from: individual()).snapshot
        #expect(snapshot.plan == .individual)
        #expect(snapshot.sessionPct == 42)
        #expect(snapshot.weeklyPct == 18)
    }
}
