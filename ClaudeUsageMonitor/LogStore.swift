import Foundation
import Combine

// アプリ内ログストア。ログウィンドウで表示する目的。
// 本ストア自体を @MainActor に固定することで、呼び出し側は
// actor 切替を意識せず log(...) を呼べる（メインスレッド前提の用途に限定）。
@MainActor
final class LogStore: ObservableObject {
  static let maxEntries = 1000

  // 閾値。この値以上の level のログだけ保持する。
  // 通常運用は .info。詳細追跡が必要なときはここを .debug にハードコーディング変更してビルドし直す
  static let minLevel: LogLevel = .info

  @Published private(set) var entries: [LogEntry] = []

  // 絶対行番号。新規ログごとに +1。clear() でリセット
  private var lineCounter: Int = 0

  // formatted の生成に使うフォーマッタ。LogEntry 側（非 isolated）からも
  // 参照するため nonisolated に固定する。DateFormatter は Sendable ではないが
  // フォーマットのみでスレッドセーフに扱えると割り切る（従来 AutomationManager
  // の statusTimeFormatter と同じ扱い）。
  nonisolated(unsafe) static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  func log(_ message: String, level: LogLevel = .info) {
    guard level >= Self.minLevel else { return }
    lineCounter += 1
    let entry = LogEntry(id: UUID(), lineNumber: lineCounter, timestamp: Date(), message: message, level: level)
    entries.append(entry)
    // 先頭から溢れ分を削除して maxEntries を維持
    if entries.count > Self.maxEntries {
      entries.removeFirst(entries.count - Self.maxEntries)
    }
  }

  func clear() {
    entries.removeAll()
    lineCounter = 0
  }
}

enum LogLevel: Int, Comparable {
  case debug = 0
  case info = 1
  case warn = 2
  case error = 3

  static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  var label: String {
    switch self {
    case .debug: return "DEBUG"
    case .info:  return "INFO "
    case .warn:  return "WARN "
    case .error: return "ERROR"
    }
  }
}

struct LogEntry: Identifiable, Equatable {
  let id: UUID
  let lineNumber: Int
  let timestamp: Date
  let message: String
  let level: LogLevel

  // NNNNN<space x2>HH:mm:ss<space>[LEVEL]<space x2><message> の等幅向け表示フォーマット
  var formatted: String {
    let line = String(format: "%05d", lineNumber)
    return "\(line)  \(LogStore.timeFormatter.string(from: timestamp)) [\(level.label)]  \(message)"
  }
}
