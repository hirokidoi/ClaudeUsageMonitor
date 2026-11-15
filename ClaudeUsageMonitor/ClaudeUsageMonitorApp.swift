import SwiftUI
import AppKit
import ClaudeUsageMonitorCore

@main
struct ClaudeUsageMonitorApp: App {
  @StateObject private var settings: AppSettings
  @StateObject private var automation: AutomationManager
  @StateObject private var logStore: LogStore
  @StateObject private var windows: AppWindows

  init() {
    let settings = AppSettings()
    let logStore = LogStore()
    let automation = AutomationManager(settings: settings, logStore: logStore)
    _settings = StateObject(wrappedValue: settings)
    _logStore = StateObject(wrappedValue: logStore)
    _automation = StateObject(wrappedValue: automation)
    _windows = StateObject(wrappedValue: AppWindows(settings: settings, automation: automation))
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContentView()
        .environmentObject(settings)
        .environmentObject(automation)
        .environmentObject(logStore)
        .environmentObject(windows)
    } label: {
      // MenuBarExtra の label は SF Symbol を template 化して色を落とすため、
      // NSImage を自前描画し isTemplate=false で色を確実に反映させる
      Image(nsImage: Self.statusBarIcon(color: automation.statusBarColor))
    }

    Window(LogWindow.title, id: LogWindow.id) {
      LogView()
        .environmentObject(logStore)
    }
    .defaultSize(width: 700, height: 500)
    .defaultLaunchBehavior(.suppressed)
    .windowResizability(.contentMinSize)
  }

  // メニューバー用アイコン。
  // green = Assets の StatusBarIcon (黒+alpha シルエット) を isTemplate=true で返し
  //         macOS のメニューバー色に自動追従させる (通常時は目立たない)。
  // orange / red = 同じシルエットに .sourceIn ブレンドで状態色を上書きし isTemplate=false で固定色化。
  // 素材読み込みに失敗した場合のみ単色ドットにフォールバック。
  private static func statusBarIcon(color: StatusBarColor) -> NSImage {
    guard let base = NSImage(named: "StatusBarIcon") else {
      return fallbackDotIcon(color: color)
    }
    if case .green = color {
      // Assets 側で template-rendering-intent が template なので isTemplate は true になるが
      // コピーを返して他の呼び出しで書き換えられないように保険をかける
      let img = base.copy() as? NSImage ?? base
      img.isTemplate = true
      return img
    }
    let fill: NSColor = (color == .orange) ? .systemOrange : .systemRed
    guard let baseCG = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return fallbackDotIcon(color: color)
    }
    let size = base.size == .zero ? NSSize(width: 22, height: 22) : base.size
    let tinted = NSImage(size: size, flipped: false) { rect in
      guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
      ctx.draw(baseCG, in: rect)
      ctx.setBlendMode(.sourceIn)
      ctx.setFillColor(fill.cgColor)
      ctx.fill(rect)
      return true
    }
    tinted.isTemplate = false
    return tinted
  }

  // 素材読み込みに失敗した場合の簡易フォールバック (従来の塗り丸)
  private static func fallbackDotIcon(color: StatusBarColor) -> NSImage {
    let fill: NSColor
    switch color {
    case .green:  fill = .systemGreen
    case .orange: fill = .systemOrange
    case .red:    fill = .systemRed
    }
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false) { rect in
      fill.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
      return true
    }
    image.isTemplate = false
    return image
  }
}

enum LogWindow {
  static let id = "log"
  static let title = "ログ"

  // activate() は他のアプリが使用中だと断られうるので、ウィンドウは必ず前に出す
  static func orderFront() {
    NSApp.windows.first { $0.title == title }?.orderFrontRegardless()
  }
}

struct MenuContentView: View {
  @EnvironmentObject var settings: AppSettings
  @EnvironmentObject var automation: AutomationManager
  @EnvironmentObject var windows: AppWindows
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    // プランに応じてサマリ行数・ラベルが変わる。クリック不可のラベル表示 (`.disabled` で macOS 標準のグレー化)
    summaryRows
    if let fetchedAt = automation.lastUsage?.fetchedAt {
      Text("最終取得 \(JST.dateTime(fetchedAt))").disabled(true)
    }
    Divider()
    ForEach(Array(automation.status.lines(lastFetchedAt: automation.lastUsage?.fetchedAt).enumerated()), id: \.offset) { _, line in
      Text(line).disabled(true)
    }
    Divider()
    // 更新間隔 0 は自動更新しない設定なので、切り替えを出さない
    if settings.intervalMinutes > 0 {
      Toggle("自動更新", isOn: $settings.autoRefreshEnabled)
      Divider()
    }
    Button("手動更新") {
      automation.runManualFetch()
    }
    Button("設定…") {
      windows.showSettings()
    }
    .keyboardShortcut(",", modifiers: .command)
    Button(LogWindow.title) {
      openWindow(id: LogWindow.id)
      NSApp.activate()
      // 開いた直後はウィンドウがまだ無いことがあるので、次の順番で探す
      DispatchQueue.main.async { LogWindow.orderFront() }
    }
    Button("\(Bundle.main.appName) について") {
      windows.showAbout()
    }
    Divider()
    Button("終了") {
      NSApp.terminate(nil)
    }
  }

  // プランごとの使用率サマリ。lastUsage == nil は individual 扱いで 4 行プレースホルダ
  @ViewBuilder
  private var summaryRows: some View {
    let usage = automation.lastUsage
    let plan: UsagePlan = usage?.plan ?? .individual
    // 現在時刻は描画のときに読む。リセット済みの枠の % はもう今の使用率ではない
    let now = Date()
    let sessionHasReset = usage?.sessionHasReset(asOf: now) ?? false
    let weeklyHasReset = usage?.weeklyHasReset(asOf: now) ?? false
    switch plan {
    case .individual:
      Text("Session limits (5h): \(percentText(sessionHasReset ? nil : usage?.sessionPct))").disabled(true)
      Text("  - Resets \(resetText(usage?.sessionResetAt, format: JST.time, hasReset: sessionHasReset))").disabled(true)
      Text("Weekly limits: \(percentText(weeklyHasReset ? nil : usage?.weeklyPct))").disabled(true)
      Text("  - Resets \(resetText(usage?.weeklyResetAt, format: JST.dateTime, hasReset: weeklyHasReset))").disabled(true)
    case .enterprise:
      Text("Monthly limits: \(percentText(sessionHasReset ? nil : usage?.sessionPct))").disabled(true)
      // 月次リセットは日付込みで表示する
      Text("  - Resets \(resetText(usage?.sessionResetAt, format: JST.dateTime, hasReset: sessionHasReset))").disabled(true)
    }
  }

  private func percentText(_ pct: Int?) -> String {
    pct.map { "\($0)%" } ?? "----"
  }

  // 表示する時刻は丸めた値のまま。過去かどうかは呼び出し側が判定した hasReset に従う
  private func resetText(_ date: Date?, format: (Date) -> String, hasReset: Bool) -> String {
    guard let date else { return "----" }
    return hasReset ? "\(format(date)) (経過)" : format(date)
  }
}

// MARK: - LogView

struct LogView: View {
  @EnvironmentObject var logStore: LogStore

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("\(logStore.entries.count) / \(LogStore.maxEntries) 行")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("クリア") {
          logStore.clear()
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      if logStore.entries.isEmpty {
        VStack {
          Spacer()
          Text("ログはまだありません")
            .foregroundStyle(.secondary)
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        LogTextView(entries: logStore.entries)
      }
    }
    .frame(minWidth: 500, minHeight: 300)
  }
}

// MARK: - LogTextView

private struct LogTextView: NSViewRepresentable {
  let entries: [LogEntry]

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.textColor = .textColor
    textView.textContainerInset = NSSize(width: 12, height: 8)
    textView.isVerticallyResizable = true
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    // 最終行番号で変化を検知する。FIFO 満杯後も lastLineNumber は増加するため
    // entries.count が 1000 固定でも末尾追従が正しく動く
    let lastLine = entries.last?.lineNumber ?? 0
    guard lastLine != context.coordinator.lastLineNumber else { return }
    context.coordinator.lastLineNumber = lastLine
    textView.string = entries.map(\.formatted).joined(separator: "\n")
    let end = textView.string.utf16.count
    textView.scrollRangeToVisible(NSRange(location: end, length: 0))
  }

  final class Coordinator {
    var lastLineNumber: Int = -1
  }
}
