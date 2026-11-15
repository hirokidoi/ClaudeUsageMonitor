import Foundation

public enum ClaudeConnection {
    static let connectedMessage = "接続できました"
    static let authMessage = "claude の認証が無効です。ターミナルで claude を起動してログインし直してください"
    static let usageLimitMessage = "claude の使用量の上限に達しました"
    static let timedOutMessage = "時間内に応答がありませんでした"
    // CLI 2.1.311 のバイナリの文字列から確かめた文言 (実応答は未確認)。小文字で比べる。
    static let authPhrases = ["failed to authenticate", "invalid api key", "please run /login"]
    static let usageLimitPhrases = ["hit your limit", "usage limit reached", "reached your weekly usage limit"]
    static let unauthorizedStatus = 401

    /// 結果の 1 行。同期でふさぐので、主スレッドから呼ばない。
    public static func test(
        executable: URL?,
        customFolder: String?,
        inheriting: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = ClaudeRunner.timeout
    ) -> String {
        guard let executable else { return "claude が見つかりません" }
        if let customFolder, !ClaudeConfigFolder.folderExists(customFolder) {
            return "CLAUDE_CONFIG_DIR のフォルダが存在しません: \(customFolder)"
        }
        let invocation = ClaudeInvocation.probe(executable: executable, customFolder: customFolder, inheriting: inheriting)
        switch ClaudeRunner.run(invocation, timeout: timeout) {
        case let .failure(.launch(detail)): return "claude を起動できません: \(detail)"
        case .failure(.timedOut): return timedOutMessage
        case let .success(reply): return message(for: reply)
        }
    }

    static func message(for reply: ClaudeReply) -> String {
        let object = (try? JSONSerialization.jsonObject(with: reply.stdout)) as? [String: Any]
        let detail = reply.detail(limit: UsageFetcher.detailLimit)
        guard reply.exitCode != 0 || object?["is_error"] as? Bool == true else {
            return object?["result"] is String ? connectedMessage : "応答を読めませんでした"
        }
        let text = [object?["result"] as? String, detail].compactMap { $0 }.first { !$0.isEmpty } ?? "終了コード \(reply.exitCode)"
        let status = (object?["api_error_status"] as? Int) ?? (object?["api_error_status"] as? String).flatMap { Int($0) }
        let lowered = text.lowercased()
        if status == unauthorizedStatus || authPhrases.contains(where: lowered.contains) { return authMessage }
        if usageLimitPhrases.contains(where: lowered.contains) { return usageLimitMessage }
        return String(text.prefix(UsageFetcher.detailLimit))
    }
}

public struct ClaudeVersionFailure: Error, Equatable, Sendable {
    public var message: String
}

public enum ClaudeVersion {
    /// 成功は stdout の最初の空でない行、失敗は「取得できませんでした: 詳細」。
    public static func fetch(
        executable: URL,
        inheriting: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = ClaudeRunner.timeout
    ) -> Result<String, ClaudeVersionFailure> {
        let invocation = ClaudeInvocation.version(executable: executable, inheriting: inheriting)
        func unavailable(_ detail: String) -> Result<String, ClaudeVersionFailure> { .failure(ClaudeVersionFailure(message: "取得できませんでした: \(detail)")) }
        switch ClaudeRunner.run(invocation, timeout: timeout) {
        case let .failure(.launch(detail)): return unavailable(detail)
        case .failure(.timedOut): return unavailable(ClaudeConnection.timedOutMessage)
        case let .success(reply):
            let detail = reply.detail(limit: UsageFetcher.detailLimit)
            guard reply.exitCode == 0 else { return unavailable(detail.isEmpty ? "終了コード \(reply.exitCode)" : detail) }
            let line = String(decoding: reply.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return line.map { .success($0) } ?? unavailable("出力が空です")
        }
    }
}
