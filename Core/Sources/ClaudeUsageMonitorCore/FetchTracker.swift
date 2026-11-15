import Foundation

public enum FetchVerdict: Sendable, Equatable {
    case success(UsageCache)
    case failure(FetchFailure, count: Int)
}

/// 成否は `fetchedAtMs` が前回見た値から変わったかだけで決める。
public struct FetchTracker: Sendable {
    private struct Baseline: Sendable {
        var file: URL
        var fetchedAtMs: Int64
    }

    private var baseline: Baseline?
    public private(set) var consecutiveFailures = 0

    public init() {}

    /// 比べる相手が無い (または別の場所の値) ときだけ true。
    public func needsBaseline(for file: URL) -> Bool {
        baseline?.file != file
    }

    public mutating func seed(_ preRead: Int64?, file: URL) {
        guard let preRead else { return }
        baseline = Baseline(file: file, fetchedAtMs: preRead)
    }

    public mutating func record(_ outcome: FetchOutcome, file: URL) -> FetchVerdict {
        switch outcome {
        case let .failed(failure):
            consecutiveFailures += 1
            return .failure(failure, count: consecutiveFailures)
        case let .read(cache):
            // 比べる相手が無いときは成功にする (CLI が初めてファイルを作った場合を失敗に見せない)。
            let changed = baseline.map { $0.file != file || $0.fetchedAtMs != cache.fetchedAtMs } ?? true
            baseline = Baseline(file: file, fetchedAtMs: cache.fetchedAtMs)
            if changed {
                consecutiveFailures = 0
                return .success(cache)
            }
            consecutiveFailures += 1
            return .failure(.notUpdated, count: consecutiveFailures)
        }
    }

    /// Red・通知・文言の「異常」の判定はすべてこれを通す。
    public static func isWarning(count: Int, tolerance: Int) -> Bool {
        count >= tolerance
    }
}
