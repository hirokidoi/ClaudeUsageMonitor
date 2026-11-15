import Foundation
import Testing
@testable import ClaudeUsageMonitorCore

struct FetchTrackerTests {
    private let file = URL(filePath: "/home/a/.claude.json")
    private let otherFile = URL(filePath: "/home/b/.claude.json")

    private func read(_ ms: Int64) -> FetchOutcome { .read(UsageCache(fetchedAtMs: ms)) }

    private func isFailure(_ verdict: FetchVerdict, _ failure: FetchFailure, count: Int) -> Bool {
        verdict == .failure(failure, count: count)
    }

    @Test func unchangedValueCountsUpAndChangeResetsToZero() {
        var tracker = FetchTracker()
        tracker.seed(100, file: file)
        #expect(isFailure(tracker.record(read(100), file: file), .notUpdated, count: 1))
        #expect(isFailure(tracker.record(read(100), file: file), .notUpdated, count: 2))
        #expect(isFailure(tracker.record(read(100), file: file), .notUpdated, count: 3))
        #expect(tracker.record(read(200), file: file) == .success(UsageCache(fetchedAtMs: 200)))
        #expect(tracker.consecutiveFailures == 0)
        #expect(isFailure(tracker.record(read(200), file: file), .notUpdated, count: 1))
    }

    @Test func commandFailuresCountAndKeepTheBaseline() {
        var tracker = FetchTracker()
        tracker.seed(100, file: file)
        #expect(isFailure(tracker.record(.failed(.timedOut), file: file), .timedOut, count: 1))
        #expect(isFailure(tracker.record(.failed(.cacheUnreadable), file: file), .cacheUnreadable, count: 2))
        // 失敗は baseline を変えないので、同じ値は更新なし、新しい値は成功。
        #expect(isFailure(tracker.record(read(100), file: file), .notUpdated, count: 3))
        #expect(tracker.record(read(101), file: file) == .success(UsageCache(fetchedAtMs: 101)))
    }

    @Test func noBaselineMeansTheFirstReadIsASuccess() {
        var tracker = FetchTracker()
        #expect(tracker.needsBaseline(for: file))
        #expect(tracker.record(read(100), file: file) == .success(UsageCache(fetchedAtMs: 100)))
        #expect(tracker.needsBaseline(for: file) == false)
        #expect(isFailure(tracker.record(read(100), file: file), .notUpdated, count: 1))
    }

    @Test func seedWithoutAValueLeavesNoBaseline() {
        var tracker = FetchTracker()
        tracker.seed(nil, file: file)
        #expect(tracker.needsBaseline(for: file))
    }

    @Test func changingTheFileNeedsABaselineAndDoesNotCompareWithTheOldFile() {
        var tracker = FetchTracker()
        tracker.seed(100, file: file)
        #expect(tracker.needsBaseline(for: file) == false)
        #expect(tracker.needsBaseline(for: otherFile))
        // 前の場所と同じ値でも、別の場所では比べる相手が無いので成功。
        #expect(tracker.record(read(100), file: otherFile) == .success(UsageCache(fetchedAtMs: 100)))
        #expect(tracker.needsBaseline(for: otherFile) == false)
        #expect(tracker.needsBaseline(for: file))
    }

    @Test func seedReplacesTheBaselineOfAnotherFile() {
        var tracker = FetchTracker()
        tracker.seed(100, file: file)
        tracker.seed(500, file: otherFile)
        #expect(isFailure(tracker.record(read(500), file: otherFile), .notUpdated, count: 1))
    }

    @Test(arguments: [1, 3, 10])
    func warningStartsExactlyAtTheTolerance(tolerance: Int) {
        #expect(FetchTracker.isWarning(count: tolerance - 1, tolerance: tolerance) == false)
        #expect(FetchTracker.isWarning(count: tolerance, tolerance: tolerance) == true)
        #expect(FetchTracker.isWarning(count: tolerance + 1, tolerance: tolerance) == true)
    }
}
