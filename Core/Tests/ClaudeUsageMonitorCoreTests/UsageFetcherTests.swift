import Foundation
import Testing
@testable import ClaudeUsageMonitorCore

/// 偽の claude (シェルスクリプト) を実際に起動して通す。
struct UsageFetcherTests {
    private let shortTimeout: TimeInterval = 0.5

    private func newCache(_ ms: Int64) -> String { cacheJSON(fetchedAtMs: String(ms)) }

    private func parentEnvironment(home: URL) -> [String: String] {
        [
            "HOME": home.path(percentEncoded: false), "LANG": "C",
            "CLAUDE_CODE_OAUTH_TOKEN": "secret-token", "ANTHROPIC_API_KEY": "secret-key",
            "CLAUDECODE": "1", "CLAUDE_CONFIG_DIR": "/parent/config"
        ]
    }

    private func lines(_ url: URL) throws -> [String] {
        var parts = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private func writeCache(_ json: String) -> String {
        "cat > \"$CLAUDE_CONFIG_DIR/.claude.json\" <<'JSON'\n\(json)\nJSON"
    }

    private let noSleep: (TimeInterval) -> Void = { _ in }

    /// 呼ばれた回数を数えてから body を実行する偽の claude。body では回数を `$n` で読める。
    private func countingScript(_ folder: TempFolder, _ body: String) throws -> URL {
        let counter = folder.path("count").path(percentEncoded: false)
        return try folder.script("""
        n=$(( $(cat "\(counter)" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "\(counter)"
        \(body)
        """)
    }

    private func calls(_ folder: TempFolder) throws -> Int {
        let text = try String(contentsOf: folder.path("count"), encoding: .utf8)
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    @Test func customFolderRunReadsTheNewValueWithAScrubbedEnvironment() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let config = folder.url.appending(path: "config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let scriptURL = try folder.script("""
        env > "\(folder.path("env.txt").path(percentEncoded: false))"
        printf '%s\\n' "$@" > "\(folder.path("args.txt").path(percentEncoded: false))"
        \(writeCache(newCache(1_790_000_000_555)))
        """)
        let custom = config.path(percentEncoded: false)
        let request = FetchRequest(executable: scriptURL, customFolder: .folder(custom), cacheFile: config.appending(path: ".claude.json"))

        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))

        #expect(result.outcome == .read(UsageCache(
            fetchedAtMs: 1_790_000_000_555, organizationType: "claude_max",
            fiveHour: nil, sevenDay: nil, extraUsage: nil
        )))
        let environment = try lines(folder.path("env.txt"))
        #expect(environment.contains("CLAUDE_CONFIG_DIR=\(custom)"))
        #expect(environment.contains("DISABLE_TELEMETRY=1"))
        #expect(environment.contains("HOME=\(folder.url.path(percentEncoded: false))"))
        for secret in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDECODE", "secret-token", "secret-key", "/parent/config"] {
            #expect(environment.contains { $0.contains(secret) } == false)
        }
        #expect(try lines(folder.path("args.txt")).prefix(2) == ["-p", "/usage"])
    }

    @Test func withoutCustomFolderTheDefaultFileUnderHomeIsRead() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try folder.script("cat > \"$HOME/.claude.json\" <<'JSON'\n\(newCache(1_790_000_000_001))\nJSON")
        let request = FetchRequest(
            executable: scriptURL, customFolder: .none,
            cacheFile: ClaudeConfigFolder.cacheFile(for: .none, home: folder.url)
        )
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        guard case let .read(cache) = result.outcome else { Issue.record("expected read, got \(result.outcome)"); return }
        #expect(cache.fetchedAtMs == 1_790_000_000_001)
    }

    @Test func baselineIsReadBeforeRunning() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write(newCache(111), as: ".claude.json")
        let scriptURL = try folder.script("cat > \"$HOME/.claude.json\" <<'JSON'\n\(newCache(222))\nJSON")
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: folder.path(".claude.json"))
        let environment = parentEnvironment(home: folder.url)

        let withBaseline = UsageFetcher.run(request, readBaselineFirst: true, inheriting: environment)
        #expect(withBaseline.preRead == 111)
        guard case let .read(cache) = withBaseline.outcome else { Issue.record("expected read"); return }
        #expect(cache.fetchedAtMs == 222)

        try folder.write(newCache(111), as: ".claude.json")
        #expect(UsageFetcher.run(request, readBaselineFirst: false, inheriting: environment).preRead == nil)
    }

    @Test func nonZeroExitIsAFailureAndTheFileIsNotRead() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write(newCache(111), as: ".claude.json")
        let scriptURL = try folder.script("echo boom >&2\nexit 3")
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: folder.path(".claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url), sleep: noSleep)
        #expect(result.outcome == .failed(.exitFailure(code: 3, detail: "boom")))
    }

    @Test func exitDetailFallsBackToStdoutAndIsTruncated() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try folder.script("printf '%0500d' 0\nexit 1")
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: folder.path(".claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url), sleep: noSleep)
        guard case let .failed(.exitFailure(code, detail)) = result.outcome else { Issue.record("expected exitFailure"); return }
        #expect(code == 1)
        #expect(detail.count == UsageFetcher.detailLimit)
    }

    @Test func hangingCommandTimesOutOnEveryCallAndReturnsPromptly() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try countingScript(folder, "exec sleep 60")
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: folder.path(".claude.json"))
        let started = Date()
        let result = UsageFetcher.run(
            request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url), timeout: shortTimeout, sleep: noSleep
        )
        #expect(result.outcome == .failed(.timedOut))
        #expect(try calls(folder) == UsageFetcher.commandAttempts)
        #expect(Date().timeIntervalSince(started) < shortTimeout * 20 * Double(UsageFetcher.commandAttempts))
    }

    @Test(arguments: Array(1...UsageFetcher.commandAttempts))
    func failedCallsAreRetriedUntilOneSucceeds(succeedingCall: Int) throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try countingScript(folder, """
        if [ "$n" -lt \(succeedingCall) ]; then echo boom >&2; exit 3; fi
        cat > "$HOME/.claude.json" <<'JSON'
        \(newCache(222))
        JSON
        """)
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: folder.path(".claude.json"))
        var sleeps: [TimeInterval] = []
        let result = UsageFetcher.run(
            request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url), sleep: { sleeps.append($0) }
        )
        guard case let .read(cache) = result.outcome else { Issue.record("expected read, got \(result.outcome)"); return }
        #expect(cache.fetchedAtMs == 222)
        #expect(try calls(folder) == succeedingCall)
        #expect(result.retriedFailures == Array(repeating: FetchFailure.exitFailure(code: 3, detail: "boom"), count: succeedingCall - 1))
        #expect(sleeps == Array(repeating: UsageFetcher.commandRetryDelay, count: succeedingCall - 1))
    }

    @Test func callsThatAllFailReturnTheLastFailure() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try countingScript(folder, "echo \"boom $n\" >&2\nexit 3")
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: folder.path(".claude.json"))
        var sleeps: [TimeInterval] = []
        let result = UsageFetcher.run(
            request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url), sleep: { sleeps.append($0) }
        )
        let attempts = UsageFetcher.commandAttempts
        #expect(result.outcome == .failed(.exitFailure(code: 3, detail: "boom \(attempts)")))
        #expect(try calls(folder) == attempts)
        #expect(result.retriedFailures == (1..<attempts).map { FetchFailure.exitFailure(code: 3, detail: "boom \($0)") })
        #expect(sleeps.count == attempts - 1)
    }

    @Test func baselineIsReadOnlyBeforeTheFirstCall() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write(newCache(111), as: ".claude.json")
        let lastCall = UsageFetcher.commandAttempts
        let scriptURL = try countingScript(folder, """
        cat > "$HOME/.claude.json" <<JSON
        \(cacheJSON(fetchedAtMs: "$n"))
        JSON
        if [ "$n" -lt \(lastCall) ]; then exit 3; fi
        """)
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: folder.path(".claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: true, inheriting: parentEnvironment(home: folder.url), sleep: noSleep)
        #expect(result.preRead == 111)
        guard case let .read(cache) = result.outcome else { Issue.record("expected read, got \(result.outcome)"); return }
        #expect(cache.fetchedAtMs == Int64(lastCall))
    }

    @Test func cacheFailureAfterASuccessfulCallIsNotRetried() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try countingScript(folder, "exit 0")
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: folder.path(".claude.json"))
        var sleeps: [TimeInterval] = []
        let result = UsageFetcher.run(
            request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url), sleep: { sleeps.append($0) }
        )
        guard case .failed(.cacheMissing) = result.outcome else { Issue.record("expected cacheMissing, got \(result.outcome)"); return }
        #expect(try calls(folder) == 1)
        #expect(result.retriedFailures.isEmpty)
        #expect(sleeps.isEmpty)
    }

    @Test func onlyTimeoutAndAbnormalExitAreRetryable() {
        let retryable: [FetchFailure] = [.timedOut, .exitFailure(code: 1, detail: "")]
        let notRetryable: [FetchFailure] = [
            .claudeNotFound, .configFolderMissing("/x"), .configFolderInvalid("x"), .launchFailed("x"),
            .cacheMissing("/x"), .cacheUnreadable, .notLoggedIn, .notUpdated
        ]
        #expect(retryable.allSatisfy { $0.isRetryable })
        #expect(notRetryable.allSatisfy { !$0.isRetryable })
    }

    @Test func nonExecutablePathIsALaunchFailure() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write("#!/bin/sh\n", as: "claude")
        let request = FetchRequest(executable: folder.path("claude"), customFolder: .none, cacheFile: folder.path(".claude.json"))
        var sleeps: [TimeInterval] = []
        let result = UsageFetcher.run(
            request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url), sleep: { sleeps.append($0) }
        )
        guard case .failed(.launchFailed) = result.outcome else { Issue.record("expected launchFailed, got \(result.outcome)"); return }
        #expect(result.retriedFailures.isEmpty)
        #expect(sleeps.isEmpty)
    }

    @Test func missingExecutableIsClaudeNotFound() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let request = FetchRequest(executable: nil, customFolder: .none, cacheFile: folder.path(".claude.json"))
        #expect(UsageFetcher.run(request, readBaselineFirst: false).outcome == .failed(.claudeNotFound))
    }

    @Test func missingCustomFolderFailsWithoutStartingTheCommand() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let marker = folder.path("started").path(percentEncoded: false)
        let scriptURL = try folder.script("touch \"\(marker)\"")
        let missing = folder.path("nope").path(percentEncoded: false)
        let request = FetchRequest(executable: scriptURL, customFolder: .folder(missing), cacheFile: folder.path("nope/.claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        #expect(result.outcome == .failed(.configFolderMissing(missing)))
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test func invalidCustomFolderFailsWithoutStartingTheCommand() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let marker = folder.path("started").path(percentEncoded: false)
        let scriptURL = try folder.script("touch \"\(marker)\"")
        try FileManager.default.createDirectory(at: folder.path("sub"), withIntermediateDirectories: true)
        // `..` を含んでも OS は存在すると答えるフォルダ。
        let typed = folder.url.path(percentEncoded: false) + "/sub/.."
        let request = FetchRequest(executable: scriptURL, customFolder: .invalid(typed), cacheFile: nil)
        let result = UsageFetcher.run(request, readBaselineFirst: true, inheriting: parentEnvironment(home: folder.url))
        #expect(result.outcome == .failed(.configFolderInvalid(typed)))
        #expect(result.preRead == nil)
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test func commandThatWritesNothingIsCacheMissing() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try folder.script("exit 0")
        let cacheFile = folder.path(".claude.json")
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: cacheFile)
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        #expect(result.outcome == .failed(.cacheMissing(cacheFile.path(percentEncoded: false))))
    }

    @Test func brokenJSONIsUnreadableAfterRetries() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try folder.script("printf '{' > \"$HOME/.claude.json\"")
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: folder.path(".claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        #expect(result.outcome == .failed(.cacheUnreadable))
    }

    @Test func fileWithoutAccountIsNotLoggedIn() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try folder.script("cat > \"$HOME/.claude.json\" <<'JSON'\n\(cacheJSON(includeAccount: false))\nJSON")
        let request = FetchRequest(executable: scriptURL, customFolder: .none, cacheFile: folder.path(".claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        #expect(result.outcome == .failed(.notLoggedIn))
    }
}
