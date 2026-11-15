import Testing
@testable import ClaudeUsageMonitorCore

struct OutputLedgerTests {
    private let fetchedAt = "2026-11-15T12:34:56+09:00"

    @Test func nothingRecordedNeedsOutput() {
        #expect(OutputLedger().needsOutput(fetchedAt: fetchedAt, destination: "/a/usage.json"))
    }

    @Test func sameDestinationAndFetchTimeNeedsNoOutput() {
        var ledger = OutputLedger()
        ledger.recordOutput(fetchedAt: fetchedAt, destination: "/a/usage.json")
        #expect(ledger.needsOutput(fetchedAt: fetchedAt, destination: "/a/usage.json") == false)
    }

    @Test func newFetchTimeNeedsOutput() {
        var ledger = OutputLedger()
        ledger.recordOutput(fetchedAt: fetchedAt, destination: "/a/usage.json")
        #expect(ledger.needsOutput(fetchedAt: "2026-11-15T12:35:56+09:00", destination: "/a/usage.json"))
    }

    @Test func newDestinationNeedsOutputWithTheSameFetchTime() {
        var ledger = OutputLedger()
        ledger.recordOutput(fetchedAt: fetchedAt, destination: "/a/usage.json")
        #expect(ledger.needsOutput(fetchedAt: fetchedAt, destination: "/b/usage.json"))
        #expect(ledger.needsOutput(fetchedAt: fetchedAt, destination: "/a/other.json"))
    }

    @Test func unrecordedValueIsNeededAgain() {
        var ledger = OutputLedger()
        ledger.recordOutput(fetchedAt: "old", destination: "/a/usage.json")
        // 失敗した出力は記録しないので、次も要る。
        #expect(ledger.needsOutput(fetchedAt: fetchedAt, destination: "/a/usage.json"))
        #expect(ledger.needsOutput(fetchedAt: fetchedAt, destination: "/a/usage.json"))
    }

    @Test func ledgersAreIndependentPerDestinationKind() {
        var file = OutputLedger()
        let post = OutputLedger()
        file.recordOutput(fetchedAt: fetchedAt, destination: "/a/usage.json")
        #expect(post.needsOutput(fetchedAt: fetchedAt, destination: "/a/usage.json"))
    }
}
