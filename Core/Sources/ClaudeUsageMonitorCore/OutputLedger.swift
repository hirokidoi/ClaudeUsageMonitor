import Foundation

/// 出力先 1 つぶんの「最後に出せた出力」。同じ出力先・同じ `fetched_at` なら出さない。
public struct OutputLedger: Sendable {
    private struct Entry: Sendable, Equatable {
        var destination: String
        var fetchedAt: String
    }

    private var last: Entry?

    public init() {}

    /// `destination` は出力先のキー (ファイルは書き込み先の絶対パス、POST はエンドポイント)。
    public func needsOutput(fetchedAt: String, destination: String) -> Bool {
        last != Entry(destination: destination, fetchedAt: fetchedAt)
    }

    /// 出力に成功したときだけ呼ぶ。
    public mutating func recordOutput(fetchedAt: String, destination: String) {
        last = Entry(destination: destination, fetchedAt: fetchedAt)
    }
}
