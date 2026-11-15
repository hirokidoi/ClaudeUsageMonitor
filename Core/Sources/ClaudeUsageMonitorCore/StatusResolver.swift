import Foundation

public enum OutputKind: Sendable, Equatable {
    case file
    case post
}

public enum OutputAttempt: Sendable, Equatable {
    case succeeded
    case failed
}

/// 出力先の種類ごとに「出力の失敗が残っているか」を持つ。
public struct OutputFailureLedger: Sendable {
    private var failedKeys: [OutputKind: String] = [:]

    public init() {}

    /// 毎 tick、今の出力先のキー (未設定なら nil) と、試みたときだけ結果を渡す。
    /// 記録した出力先と今のキーが違えば、試みが無くても消える。
    public mutating func update(_ kind: OutputKind, currentKey: String?, attempt: OutputAttempt?) {
        switch attempt {
        case .failed:
            failedKeys[kind] = currentKey
        case .succeeded:
            failedKeys[kind] = nil
        case nil:
            if failedKeys[kind] != currentKey { failedKeys[kind] = nil }
        }
    }

    public func isFailing(_ kind: OutputKind) -> Bool {
        failedKeys[kind] != nil
    }

    /// 両方に残っていればファイル側。
    public var failing: OutputKind? {
        if isFailing(.file) { return .file }
        return isFailing(.post) ? .post : nil
    }
}

public enum ResolvedStatusKind: Sendable, Equatable {
    case ok
    case fetchFailed
    case outputFailed(OutputKind)
}

public struct ResolvedStatus: Sendable, Equatable {
    public var kind: ResolvedStatusKind
    public var isRed: Bool
}

public enum StatusResolver {
    /// 優先順位は 取得の警告 > 出力の失敗 > 取得の失敗 (警告前) > ok。
    /// 出力の失敗が残る間に Red と Normal が交互に出ないようにするため、出力の失敗は取得の失敗 (警告前) より先に見る。
    /// まだ取得を終えておらず (verdict が nil)、出力の失敗も無ければ nil。
    public static func resolve(verdict: FetchVerdict?, outputFailure: OutputKind?, tolerance: Int) -> ResolvedStatus? {
        if let verdict, isFetchWarning(verdict, tolerance: tolerance) { return ResolvedStatus(kind: .fetchFailed, isRed: true) }
        if let outputFailure { return ResolvedStatus(kind: .outputFailed(outputFailure), isRed: true) }
        guard let verdict else { return nil }
        if case .failure = verdict { return ResolvedStatus(kind: .fetchFailed, isRed: false) }
        return ResolvedStatus(kind: .ok, isRed: false)
    }

    public static func isFetchWarning(_ verdict: FetchVerdict, tolerance: Int) -> Bool {
        guard case let .failure(_, count) = verdict else { return false }
        return FetchTracker.isWarning(count: count, tolerance: tolerance)
    }
}

/// 取得失敗の警告の通知を、警告に入った瞬間だけ出す。
public struct FetchWarningNotifier: Sendable {
    private var wasWarning = false

    public init() {}

    /// 状態を当てるたびに「警告か」を渡す。前回が警告でなく今回が警告のときだけ true。
    public mutating func shouldNotify(isWarning: Bool) -> Bool {
        defer { wasWarning = isWarning }
        return isWarning && !wasWarning
    }
}
