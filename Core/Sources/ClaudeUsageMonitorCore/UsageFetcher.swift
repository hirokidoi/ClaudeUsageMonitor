import Foundation

public enum FetchFailure: Error, Equatable, Sendable {
    case claudeNotFound
    case configFolderMissing(String)
    case launchFailed(String)
    case timedOut
    case exitFailure(code: Int32, detail: String)
    case cacheMissing(String)
    case cacheUnreadable
    case notLoggedIn
    /// 読めたが `fetchedAtMs` が前回見た値と同じ。
    case notUpdated
}

public struct FetchRequest: Sendable, Equatable {
    public var executable: URL?
    public var customFolder: String?
    public var cacheFile: URL

    public init(executable: URL?, customFolder: String?, cacheFile: URL) {
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
}

public enum UsageFetcher {
    /// 失敗の詳細として残す先頭の文字数 (設計値)。
    static let detailLimit = 200

    public static func run(
        _ request: FetchRequest,
        readBaselineFirst: Bool,
        inheriting: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = ClaudeRunner.timeout
    ) -> FetchResult {
        var preRead: Int64?
        if readBaselineFirst, case let .ok(cache) = UsageCacheReader.read(at: request.cacheFile) {
            preRead = cache.fetchedAtMs
        }
        func failed(_ failure: FetchFailure) -> FetchResult { FetchResult(preRead: preRead, outcome: .failed(failure)) }

        guard let executable = request.executable else { return failed(.claudeNotFound) }
        // claude は無いフォルダを作ってしまう (実測)。
        if let folder = request.customFolder, !ClaudeConfigFolder.folderExists(folder) {
            return failed(.configFolderMissing(folder))
        }
        let invocation = ClaudeInvocation.usage(executable: executable, customFolder: request.customFolder, inheriting: inheriting)
        switch ClaudeRunner.run(invocation, timeout: timeout) {
        case let .failure(.launch(detail)): return failed(.launchFailed(detail))
        case .failure(.timedOut): return failed(.timedOut)
        case let .success(reply):
            guard reply.exitCode == 0 else {
                return failed(.exitFailure(code: reply.exitCode, detail: reply.detail(limit: detailLimit)))
            }
        }
        switch UsageCacheReader.read(at: request.cacheFile) {
        case let .ok(cache): return FetchResult(preRead: preRead, outcome: .read(cache))
        case .missing: return failed(.cacheMissing(request.cacheFile.path(percentEncoded: false)))
        case .unreadable: return failed(.cacheUnreadable)
        case .notLoggedIn: return failed(.notLoggedIn)
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
