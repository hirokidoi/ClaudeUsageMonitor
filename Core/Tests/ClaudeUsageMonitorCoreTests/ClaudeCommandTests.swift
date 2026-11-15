import Foundation
import Testing
@testable import ClaudeUsageMonitorCore

struct ClaudeCommandTests {
    private let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    private let executable = URL(filePath: "/opt/tools/bin/claude")
    private let parent = [
        "HOME": "/Users/tester", "USER": "tester", "LOGNAME": "tester", "TMPDIR": "/var/tmp/x/", "SHELL": "/bin/zsh", "LANG": "ja_JP.UTF-8",
        "PATH": "/should/not/leak", "CLAUDE_CODE_OAUTH_TOKEN": "secret-token", "ANTHROPIC_API_KEY": "secret-key",
        "CLAUDECODE": "1", "CLAUDE_CONFIG_DIR": "/parent/config", "DISABLE_TELEMETRY": "0", "OTHER": "x"
    ]

    // MARK: 引数

    @Test func usageArgumentsMatchTheFixedCommand() {
        let invocation = ClaudeInvocation.usage(executable: executable, customFolder: nil, inheriting: parent)
        #expect(invocation.executable == executable)
        #expect(invocation.arguments == [
            "-p", "/usage", "--no-session-persistence", "--safe-mode", "--setting-sources", "",
            "--strict-mcp-config", "--no-chrome", "--tools", "", "--max-budget-usd", "0.01"
        ])
    }

    @Test func probeCallsTheCheapestModelOnce() {
        let invocation = ClaudeInvocation.probe(executable: executable, customFolder: nil, inheriting: parent)
        #expect(invocation.arguments == [
            "-p", "Hi!", "--safe-mode", "--setting-sources", "", "--tools", "", "--strict-mcp-config",
            "--no-session-persistence", "--model", "haiku", "--effort", "low", "--output-format", "json"
        ])
    }

    @Test func versionAsksForTheVersionOnly() {
        #expect(ClaudeInvocation.version(executable: executable, inheriting: parent).arguments == ["--version"])
    }

    // MARK: 環境

    private func invocations(customFolder: String?) -> [ClaudeInvocation] {
        [
            .usage(executable: executable, customFolder: customFolder, inheriting: parent),
            .probe(executable: executable, customFolder: customFolder, inheriting: parent),
            .version(executable: executable, inheriting: parent)
        ]
    }

    @Test func onlyAllowedVariablesAreInheritedAndSecretsNeverPass() {
        for invocation in invocations(customFolder: nil) {
            let environment = invocation.environment
            for name in ClaudeInvocation.inheritedVariables {
                #expect(environment[name] == parent[name])
            }
            for name in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDECODE", "CLAUDE_CONFIG_DIR", "OTHER"] {
                #expect(environment[name] == nil)
            }
            let allowed = Set(ClaudeInvocation.inheritedVariables).union(["PATH", "DISABLE_TELEMETRY"])
            #expect(Set(environment.keys) == allowed)
        }
    }

    @Test func telemetryIsDisabledAndTrafficIsNotRestricted() {
        for invocation in invocations(customFolder: nil) {
            #expect(invocation.environment["DISABLE_TELEMETRY"] == "1")
            #expect(invocation.environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == nil)
        }
    }

    @Test func configDirIsPassedOnlyWhenSetAndNeverToVersion() {
        let custom = invocations(customFolder: "/data/claude-config")
        #expect(custom[0].environment["CLAUDE_CONFIG_DIR"] == "/data/claude-config")
        #expect(custom[1].environment["CLAUDE_CONFIG_DIR"] == "/data/claude-config")
        #expect(custom[2].environment["CLAUDE_CONFIG_DIR"] == nil)
        for invocation in invocations(customFolder: nil) {
            #expect(invocation.environment["CLAUDE_CONFIG_DIR"] == nil)
        }
    }

    @Test func pathStartsWithTheExecutableFolder() {
        for invocation in invocations(customFolder: nil) {
            let path = invocation.environment["PATH"] ?? ""
            #expect(path.hasPrefix("/opt/tools/bin:"))
            #expect(path.hasSuffix(ClaudeInvocation.systemPath))
        }
    }

    @Test func runsFromARootDirectory() {
        for invocation in invocations(customFolder: nil) {
            #expect(invocation.directory.path(percentEncoded: false) == "/")
        }
    }

    @Test func executableParentFolderKeepsItsSpelling() {
        // 標準化は連続した / をまとめる。
        let kept = URL(filePath: "/opt//tools/claude")
        let path = ClaudeInvocation.version(executable: kept, inheriting: parent).environment["PATH"] ?? ""
        #expect(path.hasPrefix("/opt//tools:"))
    }

    // MARK: resolve / folderExists / cacheFile

    private func resolved(_ input: String) -> ClaudeConfigFolder.Input {
        ClaudeConfigFolder.resolve(input, home: home)
    }

    @Test func emptyInputMeansNoCustomFolder() {
        #expect(resolved("") == .none)
        #expect(resolved("  \n") == .none)
    }

    @Test func tildeIsExpandedAndTrailingSlashesAreDropped() {
        #expect(resolved("~/cfg/") == .folder("/Users/tester/cfg"))
        #expect(resolved("/a/b///") == .folder("/a/b"))
        #expect(resolved("  /a/b  ") == .folder("/a/b"))
        #expect(resolved("/") == .folder("/"))
    }

    @Test func dotSegmentsAreInvalid() {
        for input in ["/a/b/../c", "/a/./b", "~/../x", "/a/..", "/."] {
            #expect(resolved(input) == .invalid(input))
        }
        #expect(resolved("/a/.hidden/..b/c.") == .folder("/a/.hidden/..b/c."))
    }

    @Test func relativeAndBareTildeAreInvalid() {
        #expect(resolved("relative/dir") == .invalid("relative/dir"))
        #expect(resolved(" ~ ") == .invalid("~"))
        #expect(resolved("~user/x") == .invalid("~user/x"))
    }

    @Test func symlinksInTheTypedPathAreNotResolved() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let real = folder.url.appending(path: "real/sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = folder.path("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
        let typed = link.path(percentEncoded: false) + "/sub/"
        #expect(resolved(typed) == .folder(link.path(percentEncoded: false) + "/sub"))
    }

    @Test func folderExistsOnlyForExistingDirectories() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write("x", as: "file.txt")
        #expect(ClaudeConfigFolder.folderExists(folder.url.path(percentEncoded: false)))
        #expect(ClaudeConfigFolder.folderExists(folder.path("file.txt").path(percentEncoded: false)) == false)
        #expect(ClaudeConfigFolder.folderExists(folder.path("nope").path(percentEncoded: false)) == false)
    }

    @Test func cacheFileFollowsTheCustomFolderOrHomeAndInvalidHasNone() {
        #expect(ClaudeConfigFolder.cacheFile(for: .folder("/data/cfg"), home: home)?.path(percentEncoded: false) == "/data/cfg/.claude.json")
        #expect(ClaudeConfigFolder.cacheFile(for: .none, home: home)?.path(percentEncoded: false) == "/Users/tester/.claude.json")
        #expect(ClaudeConfigFolder.cacheFile(for: .invalid("x"), home: home) == nil)
    }

    // MARK: ClaudeLocator

    @Test func configuredPathIsUsedWithoutCheckingExecutability() {
        let resolved = ClaudeLocator.resolve(configured: " ~/bin/claude ", home: home, isExecutable: { _ in false })
        #expect(resolved.url?.path(percentEncoded: false) == "/Users/tester/bin/claude")
        let absolute = ClaudeLocator.resolve(configured: "/x/claude", home: home, isExecutable: { _ in false })
        #expect(absolute.url?.path(percentEncoded: false) == "/x/claude")
    }

    @Test func configuredPathThatIsRelativeOrHasDotSegmentsIsInvalid() {
        for input in ["claude", "bin/claude", "./claude", "~", "~claude", "/x/../claude", "/x/./claude", "~/../claude"] {
            #expect(ClaudeLocator.resolve(configured: input, home: home, isExecutable: { _ in true }) == .invalid)
        }
    }

    @Test func emptyConfiguredPicksTheFirstExecutableCandidate() {
        let expanded = ClaudeLocator.candidates.map { ClaudeLocator.expand($0, home: home) }
        #expect(ClaudeLocator.resolve(configured: "", home: home, isExecutable: { _ in true }) == .found(expanded[0]))
        #expect(ClaudeLocator.resolve(configured: "", home: home, isExecutable: { $0 == expanded[2] || $0 == expanded[4] }) == .found(expanded[2]))
        #expect(ClaudeLocator.resolve(configured: "  ", home: home, isExecutable: { _ in false }) == .notFound)
    }

    @Test func homeRelativeCandidatesStartUnderHome() {
        let expanded = ClaudeLocator.candidates.filter { $0.hasPrefix("~/") }.map { ClaudeLocator.expand($0, home: home).path(percentEncoded: false) }
        #expect(!expanded.isEmpty)
        #expect(expanded.allSatisfy { $0.hasPrefix("/Users/tester/") })
    }
}
