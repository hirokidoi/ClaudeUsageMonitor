import Foundation

public enum FetchFailure: Error, Equatable, Sendable {
    case claudeNotFound
    case configFolderMissing(String)
    case configFolderInvalid(String)
    case launchFailed(String)
    case timedOut
    case exitFailure(code: Int32, detail: String)
    case cacheMissing(String)
    case cacheUnreadable
    case notLoggedIn
    /// 読めたが `fetchedAtMs` が前回見た値と同じ。
    case notUpdated

    /// 取得の中で claude を呼び直す失敗。
    public var isRetryable: Bool {
        switch self {
        case .timedOut, .exitFailure: return true
        default: return false
        }
    }
}

public struct FetchRequest: Sendable, Equatable {
    public var executable: URL?
    public var customFolder: ClaudeConfigFolder.Input
    /// 設定フォルダの入力が無効なら nil。
    public var cacheFile: URL?

    public init(executable: URL?, customFolder: ClaudeConfigFolder.Input, cacheFile: URL?) {
        self.executable = executable
        self.customFolder = customFolder
        self.cacheFile = cacheFile
    }
}

public enum FetchOutcome: Sendable, Equatable {
    case read(UsageCache)
    case failed(FetchFailure)
}

public struct FetchResult: Sendable, Equatable {
    /// 実行の直前に読んだ `fetchedAtMs`。読まなかった・読めなかったら nil。
    public var preRead: Int64?
    public var outcome: FetchOutcome
    /// 呼び直す前に失敗した claude の呼び出し。古い順。
    public var retriedFailures: [FetchFailure] = []
}

public enum UsageFetcher {
    /// 失敗の詳細として残す先頭の文字数 (設計値)。
    static let detailLimit = 200
    /// 初回を含む claude の呼び出しの回数と、呼び直すまでの待ち (設計値)。
    public static let commandAttempts = 3
    public static let commandRetryDelay: TimeInterval = 10

    public static func run(
        _ request: FetchRequest,
        readBaselineFirst: Bool,
        inheriting: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = ClaudeRunner.timeout,
        attempts: Int = UsageFetcher.commandAttempts,
        retryDelay: TimeInterval = UsageFetcher.commandRetryDelay,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> FetchResult {
        var preRead: Int64?
        if readBaselineFirst, let file = request.cacheFile, case let .ok(cache) = UsageCacheReader.read(at: file) {
            preRead = cache.fetchedAtMs
        }
        var retried: [FetchFailure] = []
        func failed(_ failure: FetchFailure) -> FetchResult {
            FetchResult(preRead: preRead, outcome: .failed(failure), retriedFailures: retried)
        }

        guard let executable = request.executable else { return failed(.claudeNotFound) }
        // 無効のまま進むと CLAUDE_CONFIG_DIR を渡さずに起動してしまう。
        if case let .invalid(input) = request.customFolder { return failed(.configFolderInvalid(input)) }
        // claude は無いフォルダを作ってしまう (実測)。
        if let folder = request.customFolder.folderPath, !ClaudeConfigFolder.folderExists(folder) {
            return failed(.configFolderMissing(folder))
        }
        let invocation = ClaudeInvocation.usage(executable: executable, customFolder: request.customFolder.folderPath, inheriting: inheriting)
        let tries = max(attempts, 1)
        for attempt in 1...tries {
            guard let failure = runCommand(invocation, timeout: timeout) else { break }
            guard failure.isRetryable, attempt < tries else { return failed(failure) }
            retried.append(failure)
            sleep(retryDelay)
        }
        guard let cacheFile = request.cacheFile else { return failed(.cacheUnreadable) }
        switch UsageCacheReader.read(at: cacheFile) {
        case let .ok(cache): return FetchResult(preRead: preRead, outcome: .read(cache), retriedFailures: retried)
        case .missing: return failed(.cacheMissing(cacheFile.path(percentEncoded: false)))
        case .unreadable: return failed(.cacheUnreadable)
        case .notLoggedIn: return failed(.notLoggedIn)
        }
    }

    private static func runCommand(_ invocation: ClaudeInvocation, timeout: TimeInterval) -> FetchFailure? {
        switch ClaudeRunner.run(invocation, timeout: timeout) {
        case let .failure(.launch(detail)): return .launchFailed(detail)
        case .failure(.timedOut): return .timedOut
        case let .success(reply):
            return reply.exitCode == 0 ? nil : .exitFailure(code: reply.exitCode, detail: reply.detail(limit: detailLimit))
        }
    }
}

extension ClaudeReply {
    /// stderr、無ければ stdout の先頭。
    func detail(limit: Int) -> String {
        let texts = [stderr, stdout].map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(texts.first { !$0.isEmpty }?.prefix(limit) ?? "")
    }
}
