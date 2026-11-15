import Foundation

/// 自動更新を入れたときに、すぐ取得するか、前回の取得から間隔がたつまで待つか。
public enum AutoRefreshResume: Equatable, Sendable {
    case fetchNow
    case waitThenFetch(TimeInterval)

    /// 前回の取得 (試みた時刻) から間隔がたっていなければ、残りの秒数だけ待つ。
    public static func decide(lastAttempt: Date?, now: Date, interval: TimeInterval) -> AutoRefreshResume {
        guard let lastAttempt else { return .fetchNow }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed >= interval ? .fetchNow : .waitThenFetch(interval - elapsed)
    }
}
