import Foundation
import Testing
@testable import ClaudeUsageMonitorCore

struct UsageCacheReaderTests {
    private let url = URL(filePath: "/nonexistent/.claude.json")
    private let valid = Data(cacheJSON().utf8)
    private let broken = Data("{".utf8)

    @Test func brokenThenValidReadsAgainAfterTheConfiguredDelay() {
        var contents = [broken, valid]
        var loads = 0
        var sleeps: [TimeInterval] = []
        let result = UsageCacheReader.read(
            at: url,
            load: { _ in loads += 1; return contents.removeFirst() },
            sleep: { sleeps.append($0) }
        )
        guard case .ok = result else { Issue.record("expected ok, got \(result)"); return }
        #expect(loads == 2)
        #expect(sleeps == [UsageCacheReader.retryDelay])
    }

    @Test func alwaysBrokenReadsAsManyTimesAsAttemptsThenGivesUp() {
        var loads = 0
        var sleeps = 0
        let result = UsageCacheReader.read(
            at: url,
            load: { _ in loads += 1; return broken },
            sleep: { _ in sleeps += 1 }
        )
        #expect(result == .unreadable)
        #expect(loads == UsageCacheReader.attempts)
        #expect(sleeps == UsageCacheReader.attempts - 1)
    }

    @Test func readErrorsOtherThanMissingAreRetried() {
        var loads = 0
        let result = UsageCacheReader.read(
            at: url,
            load: { _ in loads += 1; throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) },
            sleep: { _ in }
        )
        #expect(result == .unreadable)
        #expect(loads == UsageCacheReader.attempts)
    }

    @Test func missingFileIsNotRetried() {
        var loads = 0
        var sleeps = 0
        let result = UsageCacheReader.read(
            at: url,
            load: { _ in loads += 1; throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError) },
            sleep: { _ in sleeps += 1 }
        )
        #expect(result == .missing)
        #expect(loads == 1)
        #expect(sleeps == 0)
    }

    @Test func notLoggedInIsNotRetried() {
        var loads = 0
        let result = UsageCacheReader.read(
            at: url,
            load: { _ in loads += 1; return Data(cacheJSON(includeAccount: false).utf8) },
            sleep: { _ in Issue.record("must not sleep") }
        )
        #expect(result == .notLoggedIn)
        #expect(loads == 1)
    }

    @Test func realFileIsReadWithDefaultLoader() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write(cacheJSON(fetchedAtMs: "1790000000123"), as: ".claude.json")
        guard case let .ok(cache) = UsageCacheReader.read(at: folder.path(".claude.json")) else {
            Issue.record("expected ok")
            return
        }
        #expect(cache.fetchedAtMs == 1_790_000_000_123)
    }

    @Test func realMissingFileIsMissing() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        #expect(UsageCacheReader.read(at: folder.path(".claude.json")) == .missing)
    }
}
