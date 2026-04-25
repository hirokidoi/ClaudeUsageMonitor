import SwiftUI
import AppKit

@main
struct ClaudeUsageMonitorApp: App {
  @StateObject private var settings: AppSettings
  @StateObject private var automation: AutomationManager
  @StateObject private var logStore: LogStore

  init() {
    let settings = AppSettings()
    let logStore = LogStore()
    _settings = StateObject(wrappedValue: settings)
    _logStore = StateObject(wrappedValue: logStore)
    _automation = StateObject(wrappedValue: AutomationManager(settings: settings, logStore: logStore))
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContentView()
        .environmentObject(automation)
        .environmentObject(logStore)
    } label: {
      // MenuBarExtra の label は SF Symbol を template 化して色を落とすため、
      // NSImage を自前描画し isTemplate=false で色を確実に反映させる
      Image(nsImage: Self.statusBarIcon(color: automation.statusBarColor))
    }

    Settings {
      SettingsView()
        .environmentObject(settings)
        .environmentObject(automation)
    }

    Window("ログ", id: "log") {
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

struct MenuContentView: View {
  @EnvironmentObject var automation: AutomationManager
  @Environment(\.openWindow) private var openWindow

  // session reset: 5 時間以内なので時分のみ (1 桁時はゼロ埋めしない: 4:00)。
  // 端末 TZ に依存せず常に JST で表示する
  private static let sessionResetFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "H:mm"
    f.locale = Locale(identifier: "ja_JP")
    f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return f
  }()

  // weekly / Enterprise monthly reset: 「4/24 (金) 4:00」形式 (1 桁時はゼロ埋めしない)
  private static let weeklyResetFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "M/d (E) H:mm"
    f.locale = Locale(identifier: "ja_JP")
    f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return f
  }()

  var body: some View {
    // プランに応じてサマリ行数・ラベルが変わる。クリック不可のラベル表示 (`.disabled` で macOS 標準のグレー化)
    summaryRows
    Divider()
    Text(automation.status.text).disabled(true)
    Divider()
    Button("ウィンドウを表示") {
      automation.showMainWindow()
    }
    Button("手動更新") {
      automation.runManualFetch()
    }
    SettingsLink {
      Text("設定…")
    }
    Button("ログ") {
      openWindow(id: "log")
      NSApp.activate(ignoringOtherApps: true)
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
    switch plan {
    case .individual:
      Text("Session limits (5h): \(percentText(usage?.sessionPct))").disabled(true)
      Text("  - Resets \(usage.flatMap { Self.formatSessionReset($0.sessionResetAt) } ?? "----")").disabled(true)
      Text("Weekly limits: \(percentText(usage?.weeklyPct))").disabled(true)
      Text("  - Resets \(usage.flatMap { Self.formatWeeklyReset($0.weeklyResetAt) } ?? "----")").disabled(true)
    case .enterprise:
      Text("Monthly limits: \(percentText(usage?.sessionPct))").disabled(true)
      // Enterprise の月次リセットは日付込みで表示する必要があるため weeklyResetFormatter を流用
      Text("  - Resets \(usage.flatMap { Self.formatWeeklyReset($0.sessionResetAt) } ?? "----")").disabled(true)
    }
  }

  private func percentText(_ pct: Int?) -> String {
    pct.map { "\($0)%" } ?? "----"
  }

  private static func formatSessionReset(_ date: Date?) -> String? {
    date.map { sessionResetFormatter.string(from: $0) }
  }

  private static func formatWeeklyReset(_ date: Date?) -> String? {
    date.map { weeklyResetFormatter.string(from: $0) }
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
        // 全 entry を 1 つの Text にまとめて複数行選択を可能にする
        // 末尾マーカー (Color.clear) を置き scrollTo で自動末尾追従
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              Text(combinedLogText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
              Color.clear.frame(height: 1).id("log-bottom")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
          }
          .onChange(of: logStore.entries.count) { _, _ in
            withAnimation(.none) {
              proxy.scrollTo("log-bottom", anchor: .bottom)
            }
          }
          .onAppear {
            proxy.scrollTo("log-bottom", anchor: .bottom)
          }
        }
      }
    }
    .frame(minWidth: 500, minHeight: 300)
  }

  private var combinedLogText: String {
    logStore.entries.map(\.formatted).joined(separator: "\n")
  }
}
