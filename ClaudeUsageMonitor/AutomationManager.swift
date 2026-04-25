import Foundation
import Combine
import WebKit
import AppKit
import UserNotifications

class AutomationManager: NSObject, ObservableObject {
  let webView: WKWebView
  let coordinator: WebViewCoordinator
  @Published private(set) var status: AutomationStatus = .red(.notYetFetched)
  // 直近の取得データ。メニュー表示と statusBarColor の計算に使う
  @Published private(set) var lastUsage: UsageSnapshot?

  let logStore: LogStore
  private let settings: AppSettings
  private var timer: Timer?
  private var consecutiveFailureCount = 0
  private var immediateFetchWorkItem: DispatchWorkItem?
  // tick 発火で「使用制限を更新」ボタンをクリックした後に届く API レスポンスを受け取るためのスロット。
  // pendingAPIHandler がセット中のときだけ `/api/organizations/.../usage` の capture を採用し、
  // timeout が来たら applyAPIResponseTimeout に流す
  private var pendingAPIHandler: ((Data) -> Void)?
  private var pendingAPITimeoutWorkItem: DispatchWorkItem?
  private var cancellables = Set<AnyCancellable>()
  // 直前の statusBarColor。orange への遷移時のみ通知発火するために保持
  private var previousStatusBarColor: StatusBarColor = .red

  // SwiftUI Window では close = destroy + hide 時に WebView が throttle される問題があったため
  // AppKit NSWindow を常時可視状態で保持し、hide 時は alphaValue=0 で不可視化する方式に変更
  private var mainWindow: NSWindow?
  private static let mainWindowInitialSize = NSSize(width: 500, height: 1280)
  private static let mainWindowMinSize = NSSize(width: 500, height: 570)

  // JSON 出力・表示は端末 TZ に依存せず常に JST で統一する
  static let jst: TimeZone = TimeZone(identifier: "Asia/Tokyo")!

  // JST 固定の Calendar。Date extension の roundedToNearestHour() や nextMonthFirstAtJST で共有する
  // (端末 TZ に依存せず常に JST 視点で時刻を分解・再構築するため)
  static let jstCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = AutomationManager.jst
    return c
  }()

  // tick で「使用制限を更新」ボタンクリック後、/api/organizations/.../usage レスポンスが
  // 届くまで待つ上限。ネットワーク RTT + サーバ処理分を見込む
  private static let apiResponseTimeoutSeconds: TimeInterval = 10

  // Enterprise プラン UI / JSON 出力を手元アカウントで検証するための開発フラグ。
  // true の間は extra_usage.is_enabled == true のレスポンスを (five_hour/seven_day の有無に関係なく)
  // Enterprise として分類する。本番配布時は必ず false に戻すこと
  private static let enterpriseTestMode: Bool = false
  // didFinish からページ描画が落ち着くまで待ってから tick を発火するまでの遅延
  private static let postLoadDelaySeconds: TimeInterval = 5

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = AutomationManager.jst
    return f
  }()

  private static let statusTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    // 1 桁時はゼロ埋めしない (例: 4:00:00)
    f.dateFormat = "H:mm:ss"
    return f
  }()

  private static let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.keyEncodingStrategy = .convertToSnakeCase
    return e
  }()

  // /api/organizations/.../usage のレスポンス内 resets_at は fractional あり/なしが混在し得るため
  // 2 段で試す (withFractionalSeconds 先、失敗したら plain)
  private static let iso8601WithFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let iso8601Plain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  init(settings: AppSettings, logStore: LogStore) {
    self.settings = settings
    self.logStore = logStore

    let config = WKWebViewConfiguration()
    config.limitsNavigationsToAppBoundDomains = false

    // fetch / XHR をラップして /api/organizations/.../usage のレスポンスを Swift に転送する JS を
    // atDocumentStart で注入する。userContentController は全 navigation で JS を自動再注入し、
    // OAuth ポップアップ (createWebViewWith) にも configuration 経由で継承される
    let userContentController = WKUserContentController()
    let script = WKUserScript(
      source: Self.interceptUsageJS,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    )
    userContentController.addUserScript(script)
    config.userContentController = userContentController

    let wv = WKWebView(frame: .zero, configuration: config)
    wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    self.webView = wv

    let coord = WebViewCoordinator(settings: settings, logStore: logStore)
    self.coordinator = coord
    wv.navigationDelegate = coord
    wv.uiDelegate = coord

    super.init()

    // super.init 後でないと self を WKScriptMessageHandler として登録できない。
    // AutomationManager はプロセス終了まで生存するので循環参照は許容する
    userContentController.add(self, name: "usageAPI")

    appLog("アプリ起動 v\(Bundle.main.appVersionLabel)")

    // automation の自己参照はここで解決する
    // (Swift の二段階初期化のため、self を渡すのは全プロパティ初期化後)

    if settings.url.isEmpty {
      status = .red(.urlNotConfigured)
    }

    coord.automation = self

    // WebView を NSWindow へ attach してアプリ起動時から可視扱いにする
    // SwiftUI Window では hide 中に WKWebView のレンダリング/JS 実行が throttle されて
    // DOM 取得に失敗する症状が出たため、AppKit NSWindow を画面外配置で常時可視状態に保つ
    installMainWindow()
    // 初回 URL ロードは後段の「起動 5 秒後 runManualFetch」に任せる
    // (二重ロード・二重 scheduleImmediateFetch の重複を避けるため)

    // intervalSeconds 変更でタイマー再貼付。同値への再代入では反応させない
    // (SAVE 時に値が変わっていないのに start() が走り scheduleImmediateFetch と競合するのを防ぐ)
    // removeDuplicates を先に置くのがポイント:
    //   - 初回 subscribe 時に CurrentValueSubject の初期値が removeDuplicates を通る
    //     → dropFirst がそれを捨てる
    //   - 以降の同値再代入は removeDuplicates が「前回値と一致」で filter する
    // 逆順 (dropFirst → removeDuplicates) だと初回 SAVE で同値再代入でも発火してしまう
    //
    // また、@Published の publisher は willSet タイミング (= プロパティ書き込み前) で
    // 発火するため、sink の中から settings.xxx を読むと古い値が返る。
    // start() / handleURLSettingChanged() は property を読むので、
    // DispatchQueue.main.async でプロパティ書込完了後に実行する
    settings.$intervalSeconds
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] value in
        self?.appLogDebug("intervalSeconds 変更を検知: \(value)")
        DispatchQueue.main.async { self?.start() }
      }
      .store(in: &cancellables)

    settings.$url
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] value in
        self?.appLogDebug("URL 設定変更を検知: \(value)")
        DispatchQueue.main.async { self?.handleURLSettingChanged() }
      }
      .store(in: &cancellables)

    // 起動時 start() を View 非依存で発火
    DispatchQueue.main.async { [weak self] in self?.start() }

    // 起動から 5 秒後に 1 回だけ手動更新相当を走らせる。
    // 初回ロード後の scheduleImmediateFetch は DOM 直読みのため claude.ai が
    // キャッシュした古い値を拾うことがあり、ボタンクリック経由の更新を確実に 1 回発火させる
    appLogDebug("起動 5 秒後に runManualFetch を予約")
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      self?.appLogDebug("起動 5 秒後スケジューラ発火")
      self?.runManualFetch()
    }

    // 通知許可の要求 (初回のみダイアログ表示、以降は macOS 設定で ON/OFF)
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
      if let error {
        self?.appLogWarn("通知許可リクエスト失敗: \(error)")
      } else {
        self?.appLogDebug("通知許可: \(granted ? "granted" : "denied")")
      }
    }
  }

  // LogStore は @MainActor だが AutomationManager 自体は非 isolated のため
  // 呼び出し側でディスパッチが必要。過去地雷 No.4 に倣い MainActor.assumeIsolated は
  // 使わず常に main.async に一本化する (main スレッドからの呼び出しでも同様)
  func appLog(_ message: String, level: LogLevel = .info) {
    DispatchQueue.main.async { [logStore] in
      logStore.log(message, level: level)
    }
  }

  // レベル別ショートハンド
  func appLogDebug(_ message: String) { appLog(message, level: .debug) }
  func appLogWarn(_ message: String)  { appLog(message, level: .warn) }
  func appLogError(_ message: String) { appLog(message, level: .error) }

  func start() {
    let interval = Double(settings.intervalSeconds)
    appLogDebug("Timer 再貼付: interval=\(interval)s")
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      DispatchQueue.main.async { [weak self] in
        self?.appLogDebug("Timer 発火")
        self?.tick()
      }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func runManualFetch() {
    // 手動更新: 設定URLを改めてロード。読み込み完了 (didFinish) 後に
    // scheduleImmediateFetch が連鎖で tick を発火する (click → API レスポンス待機)。
    // 読み込み先が設定URLと異なる (/login 等) 場合は tick 内のガードで失敗扱いになる。
    // タイマーリセットは tick() 冒頭で行うのでここでは start() を呼ばない
    cancelAllInFlightFetches()
    guard !settings.url.isEmpty, let url = URL(string: settings.url) else {
      applyURLNotConfigured()
      return
    }
    appLog("手動更新: URL 再ロード開始 \(url.absoluteString)")
    webView.load(URLRequest(url: url))
  }

  // 「使用制限を更新」ボタン押下後の API レスポンスを待つスロットを破棄する。
  // timeout と handler の両方をクリアするため tick 冒頭や reload 経路で必ず呼ぶ
  private func cancelPendingAPIWait() {
    pendingAPITimeoutWorkItem?.cancel()
    pendingAPITimeoutWorkItem = nil
    pendingAPIHandler = nil
  }

  // didFinish で予約した「5 秒後に tick」の即時 fetch をキャンセルする
  private func cancelImmediateFetch() {
    immediateFetchWorkItem?.cancel()
    immediateFetchWorkItem = nil
  }

  // reload 系操作 (手動更新 / セッションクリア / URL 設定変更 / 3 連続失敗自動リロード) では
  // 即時 fetch と API 応答待機の両方を潰して、新ページへの移行と in-flight 処理を分離する
  private func cancelAllInFlightFetches() {
    cancelImmediateFetch()
    cancelPendingAPIWait()
  }

  func scheduleImmediateFetch() {
    // didFinish 経由で呼ばれる。ページ描画が落ち着くのを postLoadDelaySeconds 待ってから
    // tick を発火し、「使用制限を更新」ボタン押下 → API レスポンス待機の流れに乗せる
    immediateFetchWorkItem?.cancel()
    appLogDebug("\(Int(Self.postLoadDelaySeconds)) 秒後に tick をスケジュール")
    let item = DispatchWorkItem { [weak self] in self?.tick() }
    immediateFetchWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.postLoadDelaySeconds, execute: item)
  }

  // MARK: - Main Window (AppKit)

  private func installMainWindow() {
    appLogDebug("installMainWindow: NSWindow 生成")
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.mainWindowInitialSize),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    // OAuthPopupController と同じく ObjC 追加 release による EXC_BAD_ACCESS を避ける
    window.isReleasedWhenClosed = false
    window.title = "Claude Usage Monitor"
    window.minSize = Self.mainWindowMinSize
    window.contentView = webView
    window.delegate = self

    // 画面外配置は macOS が自動クランプして左下に戻されるため、
    // 代わりに alphaValue で不可視化する。orderFrontRegardless で
    // 「on screen」扱いを維持し WKWebView の throttle を避ける。
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()

    mainWindow = window
  }

  func showMainWindow() {
    guard let window = mainWindow else { return }
    // ユーザーがリサイズしたサイズを保持するため setContentSize は呼ばない
    window.center()
    window.alphaValue = 1
    window.ignoresMouseEvents = false
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    appLogDebug("メインウィンドウ show")
  }

  private func hideMainWindow() {
    guard let window = mainWindow else { return }
    // orderOut / setFrameOrigin(offscreen) は throttle や macOS 自動クランプ
    // の原因になるため、alphaValue=0 でその場で不可視化する
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    appLogDebug("メインウィンドウ hide")
  }

  func clearSessionAndReload() {
    appLog("セッションクリア実行")
    cancelAllInFlightFetches()
    let store = WKWebsiteDataStore.default()
    store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
      DispatchQueue.main.async { [weak self] in
        guard let self, let url = URL(string: self.settings.url) else { return }
        self.webView.load(URLRequest(url: url))
      }
    }
  }

  private func loadCurrentURLIfPossible() {
    guard !settings.url.isEmpty, let url = URL(string: settings.url) else { return }
    appLog("URL ロード: \(url.absoluteString)")
    webView.load(URLRequest(url: url))
  }

  private func handleURLSettingChanged() {
    appLogDebug("handleURLSettingChanged 実行")
    // URL 変更は旧ページを対象にしていた fetch を無効化するため pending を全て cancel
    cancelAllInFlightFetches()
    if settings.url.isEmpty {
      // WebView も空にする (古い /settings/usage のページを残さない)
      if let blank = URL(string: "about:blank") {
        webView.load(URLRequest(url: blank))
      }
      applyURLNotConfigured()
      return
    }
    // .urlNotConfigured で止まっていたら未取得に戻す
    if case .red(.urlNotConfigured) = status {
      applyStatus(.red(.notYetFetched))
    }
    loadCurrentURLIfPossible()
  }

  private func tick() {
    appLogDebug("tick 開始")
    // tick 発火時点で次回自動 tick を intervalSeconds 後にリセットする。
    // 手動更新 / scheduleImmediateFetch 経由の tick でも周期を揃え、
    // 「手動 fetch 完了直後に Timer が発火」のような二重発火を防ぐ
    start()
    guard !webView.isLoading else {
      appLogDebug("tick skip: webView is loading")
      return
    }

    if settings.url.isEmpty {
      appLogDebug("tick skip: URL 未設定")
      applyURLNotConfigured()
      return
    }

    guard settings.matches(url: webView.url) else {
      appLogDebug("tick skip: 現在URL不一致 \(webView.url?.absoluteString ?? "nil")")
      applyNotOnSettingsPage()
      return
    }

    // API 応答待機スロットを差し替える。前回 tick の未解決スロットがあれば捨てる
    cancelPendingAPIWait()
    pendingAPIHandler = { [weak self] data in
      self?.handleCapturedAPIResponse(data)
    }
    let timeoutItem = DispatchWorkItem { [weak self] in
      self?.applyAPIResponseTimeout()
    }
    pendingAPITimeoutWorkItem = timeoutItem
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.apiResponseTimeoutSeconds, execute: timeoutItem)
    appLogDebug("API 応答待機スロット準備完了 (timeout=\(Int(Self.apiResponseTimeoutSeconds))s)")

    let clickJS = #"document.querySelector('button[aria-label="使用制限を更新"]')?.click();"#
    appLogDebug("「使用制限を更新」ボタン押下")
    webView.evaluateJavaScript(clickJS) { [weak self] _, error in
      guard let self else { return }
      if let error {
        self.appLogWarn("JS 評価エラー: \(error)")
        self.cancelPendingAPIWait()
        self.applyFailure(reason: .javaScriptError)
      }
    }
  }

  // プラン判定。Enterprise は five_hour/seven_day が両方 null + extra_usage.is_enabled==true。
  // Individual は少なくとも一方が非 null (片側 null は null フィールドで表現)。
  // 両方 null かつ extra_usage 無効は真に不明。
  // enterpriseTestMode=true のときは five_hour/seven_day の有無に関わらず
  // extra_usage.is_enabled==true で Enterprise として扱う (Enterprise UI/出力検証用)
  private func classifyPlan(json: [String: Any]) -> UsagePlan? {
    let fiveHourDict = json["five_hour"] as? [String: Any]
    let sevenDayDict = json["seven_day"] as? [String: Any]
    let extraUsage = json["extra_usage"] as? [String: Any]
    let extraEnabled = (extraUsage?["is_enabled"] as? Bool) ?? false

    if (Self.enterpriseTestMode || (fiveHourDict == nil && sevenDayDict == nil)) && extraEnabled {
      if Self.enterpriseTestMode && (fiveHourDict != nil || sevenDayDict != nil) {
        appLogDebug("enterpriseTestMode=true: Individual データを Enterprise として強制分類")
      }
      return .enterprise
    }
    if fiveHourDict != nil || sevenDayDict != nil {
      return .individual
    }
    return nil
  }

  // 捕捉した /usage API の JSON から UsageData (JSON 出力用) と UsageSnapshot (UI 用) を同時構築。
  // プラン判定不能なら nil (= .unknownPlan)
  private func buildUsagePayload(from json: [String: Any]) -> (UsageData, UsageSnapshot)? {
    guard let plan = classifyPlan(json: json) else { return nil }
    let now = Date()

    switch plan {
    case .individual:
      // five_hour / seven_day は片側 null があり得る → 各側独立に処理 (失敗にしない)
      let fh = json["five_hour"] as? [String: Any]
      let sd = json["seven_day"] as? [String: Any]

      let sessionPct: Int? = Self.asDouble(fh?["utilization"]).map { Int(round($0)) }
      let weeklyPct: Int? = Self.asDouble(sd?["utilization"]).map { Int(round($0)) }
      // utilization: 0.0 時などで resets_at: null が返るケースは正常扱い
      let sessionResetDate = (fh?["resets_at"] as? String).flatMap { Self.parseISO8601($0) }?.roundedToNearestHour()
      let weeklyResetDate  = (sd?["resets_at"] as? String).flatMap { Self.parseISO8601($0) }?.roundedToNearestHour()

      let data = UsageData(
        datetime: Self.dateFormatter.string(from: now),
        plan: plan.rawValue,
        sessionPct: sessionPct,
        sessionResetAt: sessionResetDate.map { Self.dateFormatter.string(from: $0) },
        weeklyPct: weeklyPct,
        weeklyResetAt: weeklyResetDate.map { Self.dateFormatter.string(from: $0) }
      )
      let snapshot = UsageSnapshot(
        plan: plan,
        sessionPct: sessionPct,
        sessionResetAt: sessionResetDate,
        weeklyPct: weeklyPct,
        weeklyResetAt: weeklyResetDate
      )
      return (data, snapshot)

    case .enterprise:
      guard
        let extra = json["extra_usage"] as? [String: Any],
        let util = Self.asDouble(extra["utilization"])
      else { return nil }

      let sessionPct = Int(round(util))
      let sessionResetDate = Self.nextMonthFirstAtJST(from: now)

      let data = UsageData(
        datetime: Self.dateFormatter.string(from: now),
        plan: plan.rawValue,
        sessionPct: sessionPct,
        sessionResetAt: sessionResetDate.map { Self.dateFormatter.string(from: $0) },
        weeklyPct: nil,
        weeklyResetAt: nil
      )
      let snapshot = UsageSnapshot(
        plan: plan,
        sessionPct: sessionPct,
        sessionResetAt: sessionResetDate,
        weeklyPct: nil,
        weeklyResetAt: nil
      )
      return (data, snapshot)
    }
  }

  private static func parseISO8601(_ s: String) -> Date? {
    iso8601WithFractional.date(from: s) ?? iso8601Plain.date(from: s)
  }

  // JSONSerialization は数値を NSNumber として扱うため、Double 互換で読めるケースもあれば
  // 整数値 (0 / 100 など) で as? Double が nil になるケースがあり得る。
  // utilization: 0 / 100 のような silent 欠落を防ぐため Double / Int / NSNumber の順で fallback する
  private static func asDouble(_ any: Any?) -> Double? {
    if let d = any as? Double { return d }
    if let i = any as? Int { return Double(i) }
    if let n = any as? NSNumber { return n.doubleValue }
    return nil
  }

  // Enterprise の session_reset_at に使う JST 来月 1 日 0:00
  private static func nextMonthFirstAtJST(from now: Date = Date()) -> Date? {
    let calendar = Self.jstCalendar
    let comps = calendar.dateComponents([.year, .month], from: now)
    guard let y = comps.year, let m = comps.month else { return nil }
    var next = DateComponents()
    next.year = (m == 12) ? y + 1 : y
    next.month = (m == 12) ? 1 : m + 1
    next.day = 1; next.hour = 0; next.minute = 0; next.second = 0
    next.timeZone = Self.jst
    return calendar.date(from: next)
  }

  // tick 中に届いた /api/organizations/.../usage レスポンス本体を処理する。
  // 正常系は UsageData を作って書き込み/POST、異常系は applyFailure
  private func handleCapturedAPIResponse(_ data: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      // パース失敗時は生ボディの先頭を DEBUG でダンプ (原因調査用)
      let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<not utf8>"
      appLogDebug("usageAPI JSON パース失敗 preview=\(preview)")
      applyFailure(reason: .jsonParseError)
      return
    }
    // トップレベルキー一覧と each-key の value type を DEBUG に残す (プラン判定の裏付け)
    let keySummary = json.keys.sorted().map { k -> String in
      let v = json[k]
      if v is NSNull { return "\(k)=null" }
      if v is [String: Any] { return "\(k)=dict" }
      return "\(k)=\(type(of: v ?? ""))"
    }.joined(separator: ", ")
    appLogDebug("usageAPI JSON パース成功 keys: \(keySummary)")

    guard let (usage, snapshot) = buildUsagePayload(from: json) else {
      appLogDebug("buildUsagePayload 失敗 (classifyPlan=nil または utilization 欠落)")
      applyFailure(reason: .unknownPlan)
      return
    }
    appLogDebug("buildUsagePayload 成功 plan=\(usage.plan) session=\(usage.sessionPct.map(String.init) ?? "nil")/\(usage.sessionResetAt ?? "nil") weekly=\(usage.weeklyPct.map(String.init) ?? "nil")/\(usage.weeklyResetAt ?? "nil")")
    lastUsage = snapshot
    logFetchSuccess(usage)

    guard let outputData = try? Self.jsonEncoder.encode(usage) else {
      appLogWarn("UsageData エンコード失敗")
      applyFailure(reason: .jsonEncodeError)
      return
    }

    // ファイル書き込みと API POST は独立した出力先。片方の失敗で他方をブロックしない
    let fileOutcome = writeUsageFileIfNeeded(outputData)
    postToAPIIfNeeded(outputData) { [weak self] postOutcome in
      self?.applyCombinedOutcome(file: fileOutcome, post: postOutcome)
    }
  }

  // fetch 成功時のサマリを INFO ログに出す。handleCapturedAPIResponse 本体を
  // 「構築 → ログ → encode → 書き込み/POST」の骨格で読めるように分離してある
  private func logFetchSuccess(_ usage: UsageData) {
    let sessionLabel = usage.sessionPct.map { "\($0)%" } ?? "----"
    let sReset = usage.sessionResetAt ?? "-"
    let weeklyLabel = usage.weeklyPct.map { "\($0)%" } ?? "----"
    let wReset = usage.weeklyResetAt ?? "-"
    appLog("fetch 成功: plan=\(usage.plan) session=\(sessionLabel) reset=\(sReset), weekly=\(weeklyLabel) reset=\(wReset)")
  }

  // タイムアウト時は pending スロットをクリアし失敗扱いにする
  private func applyAPIResponseTimeout() {
    pendingAPIHandler = nil
    pendingAPITimeoutWorkItem = nil
    appLogWarn("API レスポンスタイムアウト (\(Int(Self.apiResponseTimeoutSeconds))s)")
    applyFailure(reason: .apiResponseTimeout)
  }

  // ファイル書き込み。未設定は skipped、書き込み失敗は failed
  private func writeUsageFileIfNeeded(_ data: Data) -> FileOutcome {
    guard !settings.monitoringFileName.isEmpty else {
      appLogDebug("ファイル書込 skip（未設定）")
      return .skipped
    }
    let safeFileName = (settings.monitoringFileName as NSString).lastPathComponent
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(safeFileName)
    do {
      try data.write(to: fileURL, options: .atomic)
      appLogDebug("ファイル書込: \(fileURL.path)")
      return .success
    } catch {
      appLogWarn("ファイル書込失敗: \(error)")
      return .failed(.fileWriteFailed)
    }
  }

  // POST。未設定は skipped、成功は success、HTTP/通信失敗は failed
  // 起動直後の NSURLErrorNotConnectedToInternet (-1009) は URLSession のネットワーク
  // 把握が追いつかないだけのケースが多いため、2 秒後に 1 回だけリトライする
  private func postToAPIIfNeeded(_ data: Data, completion: @escaping (PostOutcome) -> Void) {
    let endpointUrl = settings.apiEndpointUrl
    guard !endpointUrl.isEmpty, let url = URL(string: endpointUrl) else {
      appLogDebug("API POST skip（未設定）")
      completion(.skipped)
      return
    }
    performPOST(url: url, endpointUrl: endpointUrl, data: data, allowRetry: true, completion: completion)
  }

  private func performPOST(url: URL, endpointUrl: String, data: Data, allowRetry: Bool, completion: @escaping (PostOutcome) -> Void) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data

    URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
      DispatchQueue.main.async {
        if let error {
          let nsError = error as NSError
          if allowRetry,
             nsError.domain == NSURLErrorDomain,
             nsError.code == NSURLErrorNotConnectedToInternet {
            self?.appLogDebug("API POST -1009 検知、2 秒後にリトライ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
              self?.performPOST(url: url, endpointUrl: endpointUrl, data: data, allowRetry: false, completion: completion)
            }
            return
          }
          self?.appLogWarn("API POST 失敗: \(error)")
          completion(.failed(.networkFailed))
          return
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          self?.appLogWarn("API POST: \(endpointUrl) → \(http.statusCode)")
          completion(.failed(.httpFailed(http.statusCode)))
          return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        self?.appLogDebug("API POST: \(endpointUrl) → \(status)")
        completion(.success)
      }
    }.resume()
  }

  // write と POST の結果を集約。どちらかが failed なら failure 扱い (ファイル失敗を優先)
  // consecutiveFailureCount の二重加算を防ぐため 1 tick あたり 1 回だけ反映する
  private func applyCombinedOutcome(file: FileOutcome, post: PostOutcome) {
    // Fetch (JS 実行/パース) までは成功しているためここで summary を構築
    let summary = OutcomeSummary(fetch: "success", api: post.summaryLabel, json: file.summaryLabel)
    if case .failed(let reason) = file {
      applyFailure(reason: reason, outcome: summary)
      return
    }
    if case .failed(let reason) = post {
      applyFailure(reason: reason, outcome: summary)
      return
    }
    applySuccess(outcome: summary)
  }

  private func applySuccess(outcome: OutcomeSummary? = nil) {
    consecutiveFailureCount = 0
    applyStatus(.green(lastSuccessAt: Date()), outcome: outcome)
  }

  private func applyFailure(reason: FailureReason, outcome: OutcomeSummary? = nil) {
    consecutiveFailureCount += 1
    appLogDebug("failure 詳細: count=\(consecutiveFailureCount) popup=\(OAuthPopupController.active.count) url=\(webView.url?.absoluteString ?? "nil") reason=\(reason)")
    appLogWarn("fetch 失敗: \(reason)")
    // outcome 未指定 = Fetch 段階での失敗。summary には Fetch: failed を入れておく
    let summary = outcome ?? OutcomeSummary(fetch: "failed", api: "-", json: "-")
    applyStatus(.red(.recentFailure(count: consecutiveFailureCount, lastReason: reason)), outcome: summary)
    guard consecutiveFailureCount >= 3,
          OAuthPopupController.active.isEmpty,
          let url = URL(string: settings.url) else { return }
    appLogError("3 連続失敗で自動リロード: \(url)")
    cancelAllInFlightFetches()
    consecutiveFailureCount = 0
    webView.load(URLRequest(url: url))
  }

  // URL 不一致 (未ログイン等) は自動リロード誘発ループを避けるため count 加算せず status のみ更新
  private func applyNotOnSettingsPage() {
    applyStatus(.red(.notOnSettingsPage))
  }

  // URL 未設定も同じく count に影響させない
  private func applyURLNotConfigured() {
    applyStatus(.red(.urlNotConfigured))
  }

  private func applyStatus(_ newStatus: AutomationStatus, outcome: OutcomeSummary? = nil) {
    let oldText = status.text
    let newText = newStatus.text
    if oldText != newText {
      if let outcome {
        appLog("status: \(oldText) → \(newText)  (\(outcome.display))")
      } else {
        appLog("status: \(oldText) → \(newText)")
      }
    }
    status = newStatus
    notifyIfOrangeTransition()
  }

  // statusBarColor が orange に遷移した瞬間のみ通知を発火する
  private func notifyIfOrangeTransition() {
    let current = statusBarColor
    defer { previousStatusBarColor = current }
    guard current == .orange, previousStatusBarColor != .orange else { return }
    let session = lastUsage?.sessionPct.map { "\($0)%" } ?? "----"
    let weekly = lastUsage?.weeklyPct.map { "\($0)%" } ?? "----"
    sendWarningNotification(session: session, weekly: weekly)
  }

  private func sendWarningNotification(session: String, weekly: String) {
    let content = UNMutableNotificationContent()
    content.title = "Claude Usage Warning"
    content.body = "Session limits: \(session), Weekly limits: \(weekly)"
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "claude-usage-warning-\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { [weak self] error in
      if let error {
        self?.appLogWarn("通知送信失敗: \(error)")
      } else {
        self?.appLog("通知送信: Claude Usage Warning (session=\(session), weekly=\(weekly))")
      }
    }
  }

  // メニューバーアイコンの 3 値色。status が失敗系なら red、
  // 成功系かつ使用率が threshold 以上なら orange、それ以外は green。
  // session/weekly が nil (Enterprise の weekly など) は 0% 扱いで判定する
  var statusBarColor: StatusBarColor {
    if case .red = status { return .red }
    guard let usage = lastUsage else { return .green }
    let threshold = settings.warningThresholdPct
    let sessionOver = (usage.sessionPct ?? 0) >= threshold
    let weeklyOver = (usage.weeklyPct ?? 0) >= threshold
    if sessionOver || weeklyOver { return .orange }
    return .green
  }
}

// 1 回の tick サイクルの各ステージ結果を 1 行にまとめるための値型
private struct OutcomeSummary {
  let fetch: String
  let api: String
  let json: String

  var display: String {
    "Fetch: \(fetch), API: \(api), JSON: \(json)"
  }
}

// MARK: - NSWindowDelegate
extension AutomationManager: NSWindowDelegate {
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // 閉じる操作は破棄ではなく画面外退避で代替する
    // (WebView を常時可視扱いにするため)
    guard sender === mainWindow else { return true }
    hideMainWindow()
    return false
  }
}

// MARK: - WebViewCoordinator
// 共有 WebView の navigation/UI delegate。ContentView の NSViewRepresentable から独立させて
// ウィンドウ開閉で状態(loopStep 等)が破棄されないようにする
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
  weak var automation: AutomationManager?
  let settings: AppSettings
  private let logStore: LogStore
  private var loopStep = 0
  private var loopWindowStart: Date?
  private var isResetting = false

  init(settings: AppSettings, logStore: LogStore) {
    self.settings = settings
    self.logStore = logStore
  }

  // LogStore は @MainActor。coordinator は非 isolated なので main ディスパッチで吸収。
  // 過去地雷 No.4 に倣い MainActor.assumeIsolated は使わず常に main.async に一本化
  private func appLog(_ message: String, level: LogLevel = .info) {
    DispatchQueue.main.async { [logStore] in
      logStore.log(message, level: level)
    }
  }

  private func appLogDebug(_ message: String) { appLog(message, level: .debug) }
  private func appLogWarn(_ message: String)  { appLog(message, level: .warn) }
  private func appLogError(_ message: String) { appLog(message, level: .error) }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    appLog("OAuth ポップアップ生成")
    let settingsURL = URL(string: settings.url)
    let controller = OAuthPopupController(configuration: configuration) { [weak self] in
      self?.appLog("OAuth ポップアップ閉じ")
      if let url = settingsURL {
        webView.load(URLRequest(url: url))
      } else {
        webView.reload()
      }
    }
    return controller.webView
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    appLog("ページ読込完了: \(webView.url?.absoluteString ?? "nil")")
    guard settings.matches(url: webView.url) else { return }
    automation?.scheduleImmediateFetch()
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = navigationAction.request.url?.absoluteString {
      let isLogin = url.contains("/login")
      let isLogout = url.contains("/logout")

      if isLogin || isLogout {
        let now = Date()
        let previousStep = loopStep
        if loopStep == 0 {
          if isLogin { loopStep = 1; loopWindowStart = now }
        } else if let start = loopWindowStart, now.timeIntervalSince(start) <= 5 {
          if isLogout && loopStep == 1 { loopStep = 2 }
          else if isLogin && loopStep == 2 { loopStep = 3 }
          else if isLogout && loopStep == 3 { loopStep = 4 }
        } else {
          loopStep = isLogin ? 1 : 0
          loopWindowStart = isLogin ? now : nil
        }

        if loopStep != previousStep {
          appLogDebug("ループ検出ステップ: \(previousStep) → \(loopStep)")
        }

        if loopStep >= 4 && !isResetting {
          isResetting = true
          loopStep = 0
          loopWindowStart = nil
          appLogError("/login↔/logout ループ検出、セッションクリア")
          DispatchQueue.main.async { [weak self] in
            self?.automation?.clearSessionAndReload()
          }
        }
      } else {
        isResetting = false
      }
    }
    decisionHandler(.allow)
  }
}

// MARK: - Types

// API レスポンスから判定されるプラン種別。JSON 出力の `plan` フィールドと UI 分岐に使う
enum UsagePlan: String, Codable {
  case individual = "individual"
  case enterprise = "enterprise"
}

struct UsageData: Codable {
  let datetime: String
  let plan: String
  // Enterprise では weekly が常に nil。Individual でも片側 null のケース (resets_at null 含む) があり得る
  let sessionPct: Int?
  let sessionResetAt: String?
  let weeklyPct: Int?
  let weeklyResetAt: String?

  // JSON 出力のフォーマット一貫性を守るため nil も必ず null として出力する
  // (synthesized Codable はデフォルトで nil キーを省略するので明示実装に置き換え)
  private enum CodingKeys: String, CodingKey {
    case datetime, plan, sessionPct, sessionResetAt, weeklyPct, weeklyResetAt
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(datetime, forKey: .datetime)
    try c.encode(plan, forKey: .plan)
    try c.encode(sessionPct, forKey: .sessionPct)
    try c.encode(sessionResetAt, forKey: .sessionResetAt)
    try c.encode(weeklyPct, forKey: .weeklyPct)
    try c.encode(weeklyResetAt, forKey: .weeklyResetAt)
  }
}

// メニュー表示と statusBarColor 判定のための UI 用スナップショット。
// Date フィールドを持つので View 側で好きな書式に整形できる
struct UsageSnapshot: Equatable {
  let plan: UsagePlan
  let sessionPct: Int?
  let sessionResetAt: Date?
  let weeklyPct: Int?
  let weeklyResetAt: Date?
}

enum AutomationStatus {
  case green(lastSuccessAt: Date)
  case red(RedReason)
}

enum RedReason {
  case notYetFetched
  case urlNotConfigured
  case notOnSettingsPage
  case recentFailure(count: Int, lastReason: FailureReason)
}

enum FailureReason {
  // URL 不一致は consecutiveFailureCount を加算しない専用パス (applyNotOnSettingsPage) を
  // 使うため、FailureReason 側の .notOnSettingsPage は廃止。URL 不一致状態の表現は
  // RedReason.notOnSettingsPage 側のみで行う
  case javaScriptError           // 「使用制限を更新」ボタンクリック JS 失敗
  case jsonParseError            // API レスポンス JSON のパース失敗
  case jsonEncodeError
  case fileWriteFailed
  case httpFailed(Int)
  case networkFailed
  case apiResponseTimeout        // click 後 API レスポンスが既定時間内に来ない
  case unknownPlan               // JSON は来たがプラン判定不能
}

// write / POST それぞれの結果。applyCombinedOutcome で集約する
private enum FileOutcome {
  case success
  case skipped
  case failed(FailureReason)

  var summaryLabel: String {
    switch self {
    case .success: return "success"
    case .skipped: return "skipped"
    case .failed:  return "failed"
    }
  }
}

private enum PostOutcome {
  case success
  case skipped
  case failed(FailureReason)

  var summaryLabel: String {
    switch self {
    case .success: return "success"
    case .skipped: return "skipped"
    case .failed:  return "failed"
    }
  }
}

// メニューバーアイコン色の 3 値表現。green = 取得成功かつ使用率が閾値未満、
// orange = 取得成功だが session% または weekly% が閾値以上、red = 取得失敗系
enum StatusBarColor {
  case green
  case orange
  case red
}

// status 自体の意味論は green / red の 2 値のまま。
// orange は「取得は成功しているが使用率警告」という UI 上の装飾のため `statusBarColor` で計算する
enum StatusColor {
  case green
  case red
}

extension AutomationStatus {
  var color: StatusColor {
    switch self {
    case .green: return .green
    case .red: return .red
    }
  }

  var text: String {
    switch self {
    case .green(let lastSuccessAt):
      return "正常 - 最終取得 \(AutomationManager.statusTimeString(from: lastSuccessAt))"
    case .red(.notYetFetched):
      return "取得待機中"
    case .red(.urlNotConfigured):
      return "異常 - URL 未設定"
    case .red(.notOnSettingsPage):
      return "異常 - ページを確認してください"
    case .red(.recentFailure(let count, _)):
      return "異常 - 取得失敗 (\(count)/3)"
    }
  }
}

extension AutomationManager {
  static func statusTimeString(from date: Date) -> String {
    statusTimeFormatter.string(from: date)
  }
}

// MARK: - WKScriptMessageHandler
// /api/organizations/.../usage の fetch/XHR レスポンスを JS ラッパから受け取るハンドラ。
// tick 中 (pendingAPIHandler がセット済み) の capture のみを採用し、それ以外はログのみで破棄する
extension AutomationManager: WKScriptMessageHandler {
  func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "usageAPI" else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self = self,
            let dict = message.body as? [String: Any],
            let body = dict["body"] as? String,
            let data = body.data(using: .utf8) else { return }

      let url = (dict["url"] as? String) ?? "?"
      let status = (dict["status"] as? Int) ?? -1
      let pendingLabel = self.pendingAPIHandler != nil ? "pending" : "passive"
      self.appLogDebug("usageAPI 受信 [\(pendingLabel)] status=\(status) bytes=\(data.count) url=\(url)")

      if let handler = self.pendingAPIHandler {
        self.cancelPendingAPIWait()
        handler(data)
      } else {
        // tick 外で届いた capture は lastUsage を更新しない (consecutiveFailureCount の管理単純化)
        self.appLogDebug("usageAPI: pending 外の capture を破棄")
      }
    }
  }
}

// MARK: - Date extension
// リセット時刻の時間単位四捨五入（3:30-4:29 → 4:00）。
// JSON 出力/API/表示が全て JST 固定である以上、分解-再構築も端末 TZ ではなく
// AutomationManager.jstCalendar (JST) を基準に行い、UTC 端末などでも挙動を揃える
extension Date {
  func roundedToNearestHour() -> Date {
    let calendar = AutomationManager.jstCalendar
    let minute = calendar.component(.minute, from: self)
    var components = calendar.dateComponents([.year, .month, .day, .hour], from: self)
    components.minute = 0
    components.second = 0
    guard let hourStart = calendar.date(from: components) else { return self }
    guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return hourStart }
    return minute >= 30 ? nextHour : hourStart
  }
}

// MARK: - Intercept JS
extension AutomationManager {
  // atDocumentStart で注入する fetch / XMLHttpRequest ラッパ。
  // /api/organizations/.../usage の URL に一致したら response.clone() から body を読み取り
  // window.webkit.messageHandlers.usageAPI.postMessage で Swift に転送する。
  // - 観測専用 (read-only tap): 元 response は無加工で page に返し DOM 更新やデータフローに干渉しない
  // - 例外は全て握りつぶす (ラッパがページ挙動を壊さないことを最優先)
  static let interceptUsageJS: String = """
  (function() {
    const USAGE_RE = /\\/api\\/organizations\\/[^/]+\\/usage(\\?|$)/;

    const origFetch = window.fetch;
    window.fetch = function(...args) {
      return origFetch.apply(this, args).then(response => {
        try {
          const url = response.url || (typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url));
          if (url && USAGE_RE.test(url)) {
            response.clone().text().then(body => {
              try {
                window.webkit.messageHandlers.usageAPI.postMessage({
                  url: url, body: body, status: response.status
                });
              } catch (e) {}
            }).catch(() => {});
          }
        } catch (e) {}
        return response;
      });
    };

    const OrigXHR = window.XMLHttpRequest;
    function WrappedXHR() {
      const xhr = new OrigXHR();
      let capturedUrl = null;
      const origOpen = xhr.open;
      xhr.open = function(method, url, ...rest) {
        capturedUrl = url;
        return origOpen.call(xhr, method, url, ...rest);
      };
      xhr.addEventListener('load', function() {
        try {
          if (capturedUrl && USAGE_RE.test(capturedUrl)) {
            window.webkit.messageHandlers.usageAPI.postMessage({
              url: capturedUrl, body: xhr.responseText || '', status: xhr.status
            });
          }
        } catch (e) {}
      });
      return xhr;
    }
    WrappedXHR.prototype = OrigXHR.prototype;
    window.XMLHttpRequest = WrappedXHR;
  })();
  """
}
