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
        let request = FetchRequest(executable: scriptURL, customFolder: custom, cacheFile: config.appending(path: ".claude.json"))

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
            executable: scriptURL, customFolder: nil,
            cacheFile: ClaudeConfigFolder.cacheFile(customFolder: nil, home: folder.url)
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
        let request = FetchRequest(executable: scriptURL, customFolder: nil, cacheFile: folder.path(".claude.json"))
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
        let request = FetchRequest(executable: scriptURL, customFolder: nil, cacheFile: folder.path(".claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        #expect(result.outcome == .failed(.exitFailure(code: 3, detail: "boom")))
    }

    @Test func exitDetailFallsBackToStdoutAndIsTruncated() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try folder.script("printf '%0500d' 0\nexit 1")
        let request = FetchRequest(executable: scriptURL, customFolder: nil, cacheFile: folder.path(".claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        guard case let .failed(.exitFailure(code, detail)) = result.outcome else { Issue.record("expected exitFailure"); return }
        #expect(code == 1)
        #expect(detail.count == UsageFetcher.detailLimit)
    }

    @Test func hangingCommandTimesOutAndReturnsPromptly() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try folder.script("exec sleep 60")
        let request = FetchRequest(executable: scriptURL, customFolder: nil, cacheFile: folder.path(".claude.json"))
        let started = Date()
        let result = UsageFetcher.run(
            request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url), timeout: shortTimeout
        )
        #expect(result.outcome == .failed(.timedOut))
        #expect(Date().timeIntervalSince(started) < shortTimeout * 20)
    }

    @Test func nonExecutablePathIsALaunchFailure() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write("#!/bin/sh\n", as: "claude")
        let request = FetchRequest(executable: folder.path("claude"), customFolder: nil, cacheFile: folder.path(".claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        guard case .failed(.launchFailed) = result.outcome else { Issue.record("expected launchFailed, got \(result.outcome)"); return }
    }

    @Test func missingExecutableIsClaudeNotFound() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let request = FetchRequest(executable: nil, customFolder: nil, cacheFile: folder.path(".claude.json"))
        #expect(UsageFetcher.run(request, readBaselineFirst: false).outcome == .failed(.claudeNotFound))
    }

    @Test func missingCustomFolderFailsWithoutStartingTheCommand() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let marker = folder.path("started").path(percentEncoded: false)
        let scriptURL = try folder.script("touch \"\(marker)\"")
        let missing = folder.path("nope").path(percentEncoded: false)
        let request = FetchRequest(executable: scriptURL, customFolder: missing, cacheFile: folder.path("nope/.claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        #expect(result.outcome == .failed(.configFolderMissing(missing)))
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test func commandThatWritesNothingIsCacheMissing() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try folder.script("exit 0")
        let cacheFile = folder.path(".claude.json")
        let request = FetchRequest(executable: scriptURL, customFolder: nil, cacheFile: cacheFile)
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        #expect(result.outcome == .failed(.cacheMissing(cacheFile.path(percentEncoded: false))))
    }

    @Test func brokenJSONIsUnreadableAfterRetries() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try folder.script("printf '{' > \"$HOME/.claude.json\"")
        let request = FetchRequest(executable: scriptURL, customFolder: nil, cacheFile: folder.path(".claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        #expect(result.outcome == .failed(.cacheUnreadable))
    }

    @Test func fileWithoutAccountIsNotLoggedIn() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let scriptURL = try folder.script("cat > \"$HOME/.claude.json\" <<'JSON'\n\(cacheJSON(includeAccount: false))\nJSON")
        let request = FetchRequest(executable: scriptURL, customFolder: nil, cacheFile: folder.path(".claude.json"))
        let result = UsageFetcher.run(request, readBaselineFirst: false, inheriting: parentEnvironment(home: folder.url))
        #expect(result.outcome == .failed(.notLoggedIn))
    }
}
