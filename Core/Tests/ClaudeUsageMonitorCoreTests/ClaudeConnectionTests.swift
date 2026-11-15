import Foundation
import Testing
@testable import ClaudeUsageMonitorCore

/// 偽の claude (シェルスクリプト) を実際に起動して通す。
struct ClaudeConnectionTests {
    private func environment(_ folder: TempFolder) -> [String: String] {
        ["HOME": folder.url.path(percentEncoded: false)]
    }

    private func test(_ body: String) throws -> String {
        let folder = try TempFolder()
        defer { folder.remove() }
        let script = try folder.script(body)
        return ClaudeConnection.test(executable: .found(script), customFolder: .none, inheriting: environment(folder))
    }

    @Test func successfulResultIsConnected() throws {
        let message = try test(#"echo '{"type":"result","is_error":false,"result":"Hi"}'"#)
        #expect(message == "接続できました")
    }

    @Test func authenticationErrorTextGivesTheLoginMessage() throws {
        let message = try test(#"echo '{"type":"result","is_error":true,"result":"Failed to authenticate. Please run /login"}'; exit 1"#)
        #expect(message == "claude の認証が無効です。ターミナルで claude を起動してログインし直してください")
    }

    @Test func unauthorizedStatusGivesTheLoginMessage() throws {
        let message = try test(#"echo '{"is_error":true,"result":"x","api_error_status":401}'"#)
        #expect(message == "claude の認証が無効です。ターミナルで claude を起動してログインし直してください")
    }

    @Test func usageLimitTextGivesTheLimitMessage() throws {
        let message = try test(#"echo '{"is_error":true,"result":"You hit your limit"}'; exit 1"#)
        #expect(message == "claude の使用量の上限に達しました")
    }

    @Test func otherFailureShowsTheDetail() throws {
        #expect(try test("echo 'something broke' >&2; exit 1") == "something broke")
        #expect(try test("exit 7") == "終了コード 7")
    }

    @Test func successWithoutResultStringIsUnreadable() throws {
        #expect(try test("echo '{}'") == "応答を読めませんでした")
    }

    @Test func timeoutShowsTheTimeoutMessage() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let script = try folder.script("exec sleep 60")
        let message = ClaudeConnection.test(executable: .found(script), customFolder: .none, inheriting: environment(folder), timeout: 0.5)
        #expect(message == "時間内に応答がありませんでした")
    }

    @Test func launchFailureShowsTheReason() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        try folder.write("#!/bin/sh\n", as: "claude")
        let message = ClaudeConnection.test(executable: .found(folder.path("claude")), customFolder: .none, inheriting: environment(folder))
        #expect(message.hasPrefix("claude を起動できません: "))
    }

    @Test func missingExecutableShowsNotFound() {
        #expect(ClaudeConnection.test(executable: .notFound, customFolder: .none) == "claude が見つかりません")
    }

    @Test func invalidExecutableShowsInvalid() {
        #expect(ClaudeConnection.test(executable: .invalid, customFolder: .none) == "claude のパスが無効です")
        #expect(ClaudeConnection.test(executable: .invalid, customFolder: .invalid("x")) == "claude のパスが無効です")
    }

    @Test func invalidCustomFolderDoesNotStartEvenWhenItWouldExist() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let marker = folder.path("started").path(percentEncoded: false)
        let script = try folder.script("touch \"\(marker)\"")
        // `..` を含んでも OS は存在すると答えるフォルダ。
        let typed = folder.url.path(percentEncoded: false) + "/sub/.."
        try FileManager.default.createDirectory(at: folder.path("sub"), withIntermediateDirectories: true)
        let message = ClaudeConnection.test(executable: .found(script), customFolder: .invalid(typed), inheriting: environment(folder))
        #expect(message == "CLAUDE_CONFIG_DIR のパスが無効です")
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test func missingCustomFolderShowsThePathAndDoesNotStart() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let marker = folder.path("started").path(percentEncoded: false)
        let script = try folder.script("touch \"\(marker)\"")
        let missing = folder.path("nope").path(percentEncoded: false)
        let message = ClaudeConnection.test(executable: .found(script), customFolder: .folder(missing), inheriting: environment(folder))
        #expect(message == "CLAUDE_CONFIG_DIR のフォルダが存在しません: \(missing)")
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test func customFolderIsPassedToTheProbe() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let out = folder.path("dir.txt").path(percentEncoded: false)
        let script = try folder.script("printf '%s' \"$CLAUDE_CONFIG_DIR\" > \"\(out)\"; echo '{\"result\":\"Hi\"}'")
        let custom = folder.url.path(percentEncoded: false)
        let message = ClaudeConnection.test(executable: .found(script), customFolder: .folder(custom), inheriting: environment(folder))
        #expect(message == "接続できました")
        #expect(try String(contentsOfFile: out, encoding: .utf8) == custom)
    }

    // MARK: バージョン

    @Test func versionIsTheFirstNonEmptyLine() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let script = try folder.script("printf '\\n  2.1.311 (Claude Code)\\nextra\\n'")
        #expect(ClaudeVersion.fetch(executable: script, inheriting: environment(folder)) == .success("2.1.311 (Claude Code)"))
    }

    @Test func versionFailureCarriesTheDetail() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let script = try folder.script("echo bad >&2; exit 2")
        #expect(ClaudeVersion.fetch(executable: script, inheriting: environment(folder))
            == .failure(ClaudeVersionFailure(message: "取得できませんでした: bad")))
    }

    @Test func versionWithEmptyOutputFails() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let script = try folder.script("exit 0")
        guard case .failure = ClaudeVersion.fetch(executable: script, inheriting: environment(folder)) else {
            Issue.record("expected failure")
            return
        }
    }
}
