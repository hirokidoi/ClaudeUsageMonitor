import Foundation
import Testing
@testable import ClaudeUsageMonitorCore

struct StatusResolverTests {
    private let tolerance = 3
    private let success = FetchVerdict.success(UsageCache(fetchedAtMs: 1))

    private func failure(_ count: Int) -> FetchVerdict { .failure(.notUpdated, count: count) }

    private func resolve(_ verdict: FetchVerdict?, output: OutputKind? = nil) -> ResolvedStatus? {
        StatusResolver.resolve(verdict: verdict, outputFailure: output, tolerance: tolerance)
    }

    @Test func noVerdictWithoutOutputFailureIsUnresolved() {
        #expect(resolve(nil) == nil)
    }

    @Test func noVerdictWithOutputFailureIsOutputFailed() {
        #expect(resolve(nil, output: .file) == ResolvedStatus(kind: .outputFailed(.file), isRed: true))
    }

    // MARK: 状態を 1 つに決める

    @Test func successWithoutOutputFailureIsOk() {
        #expect(resolve(success) == ResolvedStatus(kind: .ok, isRed: false))
    }

    @Test func successWithOutputFailureIsOutputFailed() {
        #expect(resolve(success, output: .file) == ResolvedStatus(kind: .outputFailed(.file), isRed: true))
        #expect(resolve(success, output: .post) == ResolvedStatus(kind: .outputFailed(.post), isRed: true))
    }

    @Test func fetchFailureBelowToleranceIsNotRed() {
        #expect(resolve(failure(tolerance - 1)) == ResolvedStatus(kind: .fetchFailed, isRed: false))
    }

    @Test func fetchFailureAtToleranceIsRed() {
        #expect(resolve(failure(tolerance)) == ResolvedStatus(kind: .fetchFailed, isRed: true))
        #expect(resolve(failure(tolerance + 5)) == ResolvedStatus(kind: .fetchFailed, isRed: true))
    }

    @Test func fetchWarningBeatsOutputFailure() {
        #expect(resolve(failure(tolerance), output: .file) == ResolvedStatus(kind: .fetchFailed, isRed: true))
    }

    @Test func outputFailureBeatsFetchFailureBelowTolerance() {
        // 出力の失敗が残る間に Red と Normal が交互に出ない。
        #expect(resolve(failure(1), output: .post) == ResolvedStatus(kind: .outputFailed(.post), isRed: true))
        #expect(resolve(failure(tolerance - 1), output: .file) == ResolvedStatus(kind: .outputFailed(.file), isRed: true))
    }

    @Test func commandFailureKindsFollowTheSamePriority() {
        let timedOut = FetchVerdict.failure(.timedOut, count: 1)
        #expect(resolve(timedOut, output: .file) == ResolvedStatus(kind: .outputFailed(.file), isRed: true))
        #expect(resolve(timedOut) == ResolvedStatus(kind: .fetchFailed, isRed: false))
    }

    @Test func toleranceOfOneMakesTheFirstFailureAWarning() {
        let status = StatusResolver.resolve(verdict: failure(1), outputFailure: nil, tolerance: 1)
        #expect(status == ResolvedStatus(kind: .fetchFailed, isRed: true))
    }

    @Test func isFetchWarningIsFalseForSuccess() {
        #expect(StatusResolver.isFetchWarning(success, tolerance: 1) == false)
        #expect(StatusResolver.isFetchWarning(failure(tolerance - 1), tolerance: tolerance) == false)
        #expect(StatusResolver.isFetchWarning(failure(tolerance), tolerance: tolerance))
    }

    // MARK: 出力の失敗の記録

    @Test func failureStaysUntilTheSameDestinationSucceeds() {
        var ledger = OutputFailureLedger()
        ledger.update(.file, currentKey: "/a/usage.json", attempt: .failed)
        #expect(ledger.isFailing(.file))
        ledger.update(.file, currentKey: "/a/usage.json", attempt: .succeeded)
        #expect(ledger.isFailing(.file) == false)
        #expect(ledger.failing == nil)
    }

    @Test func failureStaysWhenTheSameDestinationIsNotAttempted() {
        var ledger = OutputFailureLedger()
        ledger.update(.file, currentKey: "/a/usage.json", attempt: .failed)
        // コマンドの失敗などで出力を試みなかった tick。
        ledger.update(.file, currentKey: "/a/usage.json", attempt: nil)
        ledger.update(.file, currentKey: "/a/usage.json", attempt: nil)
        #expect(ledger.isFailing(.file))
    }

    @Test func failureClearsWhenAnotherDestinationKeyArrivesWithoutAttempt() {
        var ledger = OutputFailureLedger()
        ledger.update(.file, currentKey: "/a/usage.json", attempt: .failed)
        ledger.update(.file, currentKey: "/b/usage.json", attempt: nil)
        #expect(ledger.isFailing(.file) == false)
    }

    @Test func failureClearsWhenTheDestinationIsUnset() {
        var ledger = OutputFailureLedger()
        ledger.update(.post, currentKey: "https://example.test/api", attempt: .failed)
        ledger.update(.post, currentKey: nil, attempt: nil)
        #expect(ledger.isFailing(.post) == false)
    }

    @Test func failureOnTheNewDestinationReplacesTheOldRecord() {
        var ledger = OutputFailureLedger()
        ledger.update(.file, currentKey: "/a/usage.json", attempt: .failed)
        ledger.update(.file, currentKey: "/b/usage.json", attempt: .failed)
        #expect(ledger.isFailing(.file))
        // 前の出力先に戻しても、記録は新しい出力先のものなので試みなしで消える。
        ledger.update(.file, currentKey: "/a/usage.json", attempt: nil)
        #expect(ledger.isFailing(.file) == false)
    }

    @Test func kindsAreRecordedIndependentlyAndFileComesFirst() {
        var ledger = OutputFailureLedger()
        ledger.update(.post, currentKey: "https://example.test/api", attempt: .failed)
        #expect(ledger.failing == .post)
        ledger.update(.file, currentKey: "/a/usage.json", attempt: .failed)
        #expect(ledger.failing == .file)
        ledger.update(.file, currentKey: "/a/usage.json", attempt: .succeeded)
        #expect(ledger.failing == .post)
        #expect(ledger.isFailing(.file) == false)
    }

    @Test func neverFailedStaysClean() {
        var ledger = OutputFailureLedger()
        ledger.update(.file, currentKey: nil, attempt: nil)
        ledger.update(.file, currentKey: "/a/usage.json", attempt: .succeeded)
        #expect(ledger.failing == nil)
    }

    // MARK: 警告の通知

    @Test func notifiesOnlyOnEnteringWarning() {
        var notifier = FetchWarningNotifier()
        #expect(notifier.shouldNotify(isWarning: false) == false)
        #expect(notifier.shouldNotify(isWarning: true) == true)
        #expect(notifier.shouldNotify(isWarning: true) == false)
        #expect(notifier.shouldNotify(isWarning: true) == false)
    }

    @Test func notifiesAgainAfterLeavingWarning() {
        var notifier = FetchWarningNotifier()
        #expect(notifier.shouldNotify(isWarning: true) == true)
        #expect(notifier.shouldNotify(isWarning: false) == false)
        #expect(notifier.shouldNotify(isWarning: true) == true)
    }
}
