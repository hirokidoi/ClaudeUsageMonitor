import Foundation
import Testing
@testable import ClaudeUsageMonitorCore

struct AutoRefreshResumeTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let interval: TimeInterval = 300

    @Test func noPreviousAttemptFetchesNow() {
        #expect(AutoRefreshResume.decide(lastAttempt: nil, now: now, interval: interval) == .fetchNow)
    }

    @Test func attemptOlderThanIntervalFetchesNow() {
        let last = now.addingTimeInterval(-(interval + 1))
        #expect(AutoRefreshResume.decide(lastAttempt: last, now: now, interval: interval) == .fetchNow)
    }

    @Test func attemptExactlyOneIntervalAgoFetchesNow() {
        let last = now.addingTimeInterval(-interval)
        #expect(AutoRefreshResume.decide(lastAttempt: last, now: now, interval: interval) == .fetchNow)
    }

    @Test func recentAttemptWaitsForTheRest() {
        let elapsed: TimeInterval = 120
        let last = now.addingTimeInterval(-elapsed)
        #expect(AutoRefreshResume.decide(lastAttempt: last, now: now, interval: interval) == .waitThenFetch(interval - elapsed))
    }

    @Test func shorterIntervalIsUsedAsGiven() {
        let last = now.addingTimeInterval(-120)
        #expect(AutoRefreshResume.decide(lastAttempt: last, now: now, interval: 60) == .fetchNow)
    }
}
