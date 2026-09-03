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
  // in-flight の usage fetch (2 段 fetch) を識別する世代番号。進めることで
  // reload・キャンセルや多重発行時に古い completion / watchdog を無効化する
  private var usageFetchGeneration = 0
  private var usageFetchWatchdogWorkItem: DispatchWorkItem?
  // organizations 解決で得た org uuid のキャッシュ。無効化するのは
  // clearSessionAndReload / applyLoginRequired / usage fetch の 404 の 3 箇所
  private var cachedOrgUuid: String?
  // runManualFetch の 2 ステップナビゲーション用。about:blank ロード後にここへ遷移する
  // WebViewCoordinator (同ファイル内) からアクセスするため fileprivate
  fileprivate var pendingLoadURL: URL?
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

  // JST 固定の Calendar。Date extension の roundedToNearestTenMinutes() や nextMonthFirstAtJST で共有する
  // (端末 TZ に依存せず常に JST 視点で時刻を分解・再構築するため)
  static let jstCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = AutomationManager.jst
    return c
  }()

  // 2 段 fetch (organizations / usage) の各 fetch に適用する JS 側タイムアウト
  private static let fetchTimeoutSeconds: TimeInterval = 10
  // callAsyncJavaScript の completion が呼ばれないケースに備えた Swift 側の最終上限。
  // 2 段 fetch が各 timeout 直前まで粘る最悪ケース + マージンから導出する
  private static let fetchWatchdogSeconds: TimeInterval = fetchTimeoutSeconds * 2 + 5
  // usage fetch 失敗時の診断ログと JS 側の bodyHead 切り出しで共有する先頭文字数
  private static let bodyPreviewMaxLength = 400
  // fetch が same-origin で成立し得るページかどうかの判定に使う host
  private static let claudeHost = "claude.ai"

  // Enterprise プラン UI / JSON 出力を手元アカウントで検証するための開発フラグ。
  // true の間は extra_usage.is_enabled == true のレスポンスを (five_hour/seven_day の有無に関係なく)
  // Enterprise として分類する。本番配布時は必ず false に戻すこと
  private static let enterpriseTestMode: Bool = false
  // didFinish 連発時 (ログイン直後の複数ナビゲーション等) に tick を 1 回へ coalesce するための遅延
  private static let postLoadDelaySeconds: TimeInterval = 1

  // fetch が same-origin で成立し得るページか (host が claude.ai かサブドメイン)。
  // tick 冒頭と WebViewCoordinator.didFinish の両方から参照する
  static func isClaudeAiPage(_ url: URL?) -> Bool {
    guard let host = url?.host else { return false }
    return host == claudeHost || host.hasSuffix("." + claudeHost)
  }

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

    let wv = WKWebView(frame: .zero, configuration: config)
    wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    self.webView = wv

    let coord = WebViewCoordinator(settings: settings, logStore: logStore)
    self.coordinator = coord
    wv.navigationDelegate = coord
    wv.uiDelegate = coord

    super.init()

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
    // ログイン項目起動直後はネットワークが未確立のことがあり、初回ページロードの
    // 成功率を上げるための猶予として置く (runManualFetch 経由の一本化パスは維持する)
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
    // 手動更新: about:blank を挟む 2 ステップナビゲーションで設定 URL をフルリロードする。
    // fragment (#...) 付き URL を直接 load すると WKWebView が same-document navigation と
    // 判断してフルリロードしないケースがあるため、about:blank で一旦コンテキストを破棄してから
    // 目的 URL を再ロードする。didFinish 時に pendingLoadURL をチェックして 2 段目を発火する。
    // タイマーリセットは tick() 冒頭で行うのでここでは start() を呼ばない
    cancelAllInFlightFetches()
    guard !settings.url.isEmpty, let url = URL(string: settings.url) else {
      applyURLNotConfigured()
      return
    }
    appLog("手動更新: 強制リロード開始 \(url.absoluteString)")
    pendingLoadURL = url
    webView.load(URLRequest(url: URL(string: "about:blank")!))
  }

  // in-flight の usage fetch (2 段 fetch) を無効化する。世代を進めて古い completion /
  // watchdog の反映を破棄しつつ、watchdog の DispatchWorkItem 自体もキャンセルする。
  // tick 冒頭や reload 系操作で必ず呼ぶ
  private func invalidateInFlightFetch() {
    usageFetchGeneration += 1
    usageFetchWatchdogWorkItem?.cancel()
    usageFetchWatchdogWorkItem = nil
  }

  // didFinish で予約した「postLoadDelaySeconds 秒後に tick」の即時 fetch をキャンセルする
  private func cancelImmediateFetch() {
    immediateFetchWorkItem?.cancel()
    immediateFetchWorkItem = nil
  }

  // reload 系操作 (手動更新 / セッションクリア / URL 設定変更 / 3 連続失敗自動リロード) では
  // 即時 fetch と API 応答待機の両方を潰して、新ページへの移行と in-flight 処理を分離する
  private func cancelAllInFlightFetches() {
    cancelImmediateFetch()
    invalidateInFlightFetch()
    pendingLoadURL = nil
  }

  func scheduleImmediateFetch() {
    // didFinish 経由で呼ばれる。ログイン直後の複数ナビゲーション等で didFinish が
    // 連発しても tick が重複発火しないよう postLoadDelaySeconds だけ寝かせて 1 回へ coalesce する
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
    // セッションが変われば org も変わり得るためキャッシュを破棄する (要件 3)
    cachedOrgUuid = nil
    let store = WKWebsiteDataStore.default()
    store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // removeData は非同期のため、クリア開始〜完了の間に走った tick が消えかけの cookie で
        // fetch に成功し org uuid を再キャッシュし得る。リロード直前に無効化・破棄をやり直す
        self.invalidateInFlightFetch()
        self.cachedOrgUuid = nil
        guard let url = URL(string: self.settings.url) else { return }
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

    guard Self.isClaudeAiPage(webView.url) else {
      appLogDebug("tick skip: claude.ai 以外を表示中 \(webView.url?.absoluteString ?? "nil")")
      applyNotOnClaudePage()
      return
    }

    beginUsageFetch()
  }

  // 2 段 fetch (organizations → usage) の JS を発行し、結果を 1 回だけ状態へ反映する。
  // 多重発行・reload との競合は usageFetchGeneration で無効化する
  private func beginUsageFetch() {
    invalidateInFlightFetch()
    let generation = usageFetchGeneration

    let watchdog = DispatchWorkItem { [weak self] in
      guard let self, generation == self.usageFetchGeneration else { return }
      self.invalidateInFlightFetch()
      self.appLogWarn("usage fetch watchdog 発火 (\(Int(Self.fetchWatchdogSeconds))s)")
      self.applyFailure(reason: .fetchTimeout)
    }
    usageFetchWatchdogWorkItem = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fetchWatchdogSeconds, execute: watchdog)

    appLogDebug("usage fetch 開始 (org=\(cachedOrgUuid ?? "未解決"))")
    webView.callAsyncJavaScript(
      Self.usageFetchJS,
      arguments: [
        "orgUuid": cachedOrgUuid ?? "",
        "timeoutMs": Int(Self.fetchTimeoutSeconds * 1000),
        "previewLength": Self.bodyPreviewMaxLength,
      ],
      in: nil,
      in: .defaultClient
    ) { [weak self] result in
      // completion は main thread で呼ばれる (appLog 系ヘルパの main.async 一本化方針と整合)
      guard let self, generation == self.usageFetchGeneration else { return }
      self.invalidateInFlightFetch()
      switch result {
      case .failure(let error):
        self.appLogWarn("usage fetch JS 実行エラー: \(error)")
        self.applyFailure(reason: .javaScriptError)
      case .success(let value):
        self.handleUsageFetchResult(value)
      }
    }
  }

  // JS の resolve 値を分類する。JS は生の事実 (status/contentType/redirected/body) だけを返し、
  // 失敗の意味づけ (未ログイン判定・カウント加算) はすべてここで行う
  private func handleUsageFetchResult(_ value: Any?) {
    guard let dict = value as? [String: Any] else {
      appLogWarn("usage fetch: 戻り値が想定外 \(String(describing: value))")
      applyFailure(reason: .javaScriptError)
      return
    }
    let redirected = (dict["redirected"] as? Bool) ?? false
    let contentType = (dict["contentType"] as? String) ?? ""
    let status = dict["status"] as? Int

    if (dict["ok"] as? Bool) == true {
      // HTTP 200 でも非 JSON (ログイン HTML へのリダイレクト等) は未ログイン扱い (防御的判定)
      guard contentType.contains("json") else {
        appLogWarn("usage fetch: 非 JSON 応答 contentType=\(contentType) redirected=\(redirected)")
        applyLoginRequired()
        return
      }
      if let uuid = dict["orgUuid"] as? String, !uuid.isEmpty {
        if cachedOrgUuid == nil {
          let count = dict["orgCount"] as? Int
          appLogDebug("org uuid 解決: \(uuid)\(count.map { " (\($0) 件中先頭を採用)" } ?? "")")
        }
        cachedOrgUuid = uuid
      }
      guard let body = dict["body"] as? String, let data = body.data(using: .utf8) else {
        applyFailure(reason: .javaScriptError)
        return
      }
      handleUsageResponseBody(data)
      return
    }

    // ok == false: JS が返した stage / kind をもとに分類する
    let stage = UsageFetchStage(rawValue: (dict["stage"] as? String) ?? "") ?? .organizations
    let kind = (dict["kind"] as? String) ?? "unknown"
    let bodyHead = dict["bodyHead"] as? String
    appLogDebug("usage fetch 失敗詳細: stage=\(stage.rawValue) kind=\(kind) status=\(status.map(String.init) ?? "-") contentType=\(contentType) redirected=\(redirected) bodyHead=\(bodyHead ?? "-")")
    classifyAndApplyFetchFailure(stage: stage, kind: kind, status: status, contentType: contentType)
  }

  // JS の ok:false 結果を FailureReason / loginRequired に分類する。政策判断をこの 1 箇所に集約する。
  // 未ログイン時の実応答は防御的に判定する (401/403 と 200+非JSON の両様をカバー)。
  // 実測結果が想定と異なる場合はこの関数のみ調整すればよい
  private func classifyAndApplyFetchFailure(stage: UsageFetchStage, kind: String, status: Int?, contentType: String) {
    if let status, status == 401 || status == 403 {
      applyLoginRequired()
      return
    }
    if kind == "parse", !contentType.contains("json") {
      // organizations 段が HTTP 200 でログインページ HTML を返すケースの防御
      applyLoginRequired()
      return
    }
    switch kind {
    case "http":
      if stage == .usage, status == 404 {
        // org 消滅・権限喪失。次 tick で再解決させる
        cachedOrgUuid = nil
      }
      applyFailure(reason: .claudeApiHttpError(stage: stage, status: status ?? -1))
    case "timeout":
      applyFailure(reason: .fetchTimeout)
    case "network":
      applyFailure(reason: .fetchNetworkError)
    case "parse", "noOrg":
      applyFailure(reason: .orgResolutionFailed)
    default:
      // 想定外の kind (JS 側の戻り値形が壊れている等)
      applyFailure(reason: .javaScriptError)
    }
  }

  // ログイン状態の変化を陽性検出した (401/403、または 200+非JSON 応答)。
  // 再ログイン後は別アカウントの可能性があるため org キャッシュも破棄する
  private func applyLoginRequired() {
    cachedOrgUuid = nil
    applyStatus(.red(.loginRequired))
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
      let sessionResetDate = (fh?["resets_at"] as? String).flatMap { Self.parseISO8601($0) }?.roundedToNearestTenMinutes()
      let weeklyResetDate  = (sd?["resets_at"] as? String).flatMap { Self.parseISO8601($0) }?.roundedToNearestTenMinutes()

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
      // utilization: null が返るケースは正常扱い
      let extra = json["extra_usage"] as? [String: Any]
      let sessionPct: Int? = Self.asDouble(extra?["utilization"]).map { Int(round($0)) }
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

  // usage fetch 成功時のレスポンス本体を処理する。
  // 正常系は UsageData を作って書き込み/POST、異常系は applyFailure
  private func handleUsageResponseBody(_ data: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      // パース失敗時は生ボディの先頭を DEBUG でダンプ (原因調査用)
      let preview = String(data: data.prefix(Self.bodyPreviewMaxLength), encoding: .utf8) ?? "<not utf8>"
      appLogDebug("usage JSON パース失敗 preview=\(preview)")
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
    appLogDebug("usage JSON パース成功 keys: \(keySummary)")

    guard let (usage, snapshot) = buildUsagePayload(from: json) else {
      appLogDebug("buildUsagePayload 失敗 (classifyPlan=nil)")
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

  // fetch 成功時のサマリを INFO ログに出す。handleUsageResponseBody 本体を
  // 「構築 → ログ → encode → 書き込み/POST」の骨格で読めるように分離してある
  private func logFetchSuccess(_ usage: UsageData) {
    let sessionLabel = usage.sessionPct.map { "\($0)%" } ?? "----"
    let sReset = usage.sessionResetAt ?? "-"
    let weeklyLabel = usage.weeklyPct.map { "\($0)%" } ?? "----"
    let wReset = usage.weeklyResetAt ?? "-"
    appLog("fetch 成功: plan=\(usage.plan) session=\(sessionLabel) reset=\(sReset), weekly=\(weeklyLabel) reset=\(wReset)")
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
          completion(.failed(.postNetworkFailed))
          return
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          self?.appLogWarn("API POST: \(endpointUrl) → \(http.statusCode)")
          completion(.failed(.postHttpFailed(http.statusCode)))
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

  // claude.ai 以外を表示中は自動リロード誘発ループを避けるため count 加算せず status のみ更新
  private func applyNotOnClaudePage() {
    applyStatus(.red(.notOnClaudePage))
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
    // runManualFetch の 2 ステップナビゲーション: about:blank 完了後に目的 URL をロードする
    if webView.url?.absoluteString == "about:blank", let pendingURL = automation?.pendingLoadURL {
      automation?.pendingLoadURL = nil
      appLog("手動更新: 目的URL へ遷移 \(pendingURL.absoluteString)")
      webView.load(URLRequest(url: pendingURL))
      return
    }
    guard AutomationManager.isClaudeAiPage(webView.url) else { return }
    automation?.scheduleImmediateFetch()
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    if let url = automation?.pendingLoadURL {
      appLogWarn("手動更新: about:blank 暫定ナビゲーション失敗、pendingLoadURL クリア \(url)")
      automation?.pendingLoadURL = nil
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if let url = automation?.pendingLoadURL {
      appLogWarn("手動更新: ナビゲーション失敗、pendingLoadURL クリア \(url)")
      automation?.pendingLoadURL = nil
    }
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
  case notOnClaudePage
  case loginRequired
  case recentFailure(count: Int, lastReason: FailureReason)
}

// 2 段 fetch のどちらで失敗したか。ログ・失敗分類で使う
enum UsageFetchStage: String {
  case organizations  // GET /api/organizations (org uuid 解決)
  case usage          // GET /api/organizations/{uuid}/usage
}

enum FailureReason {
  // claude.ai 以外を表示中 / 未ログインは consecutiveFailureCount を加算しない専用パス
  // (applyNotOnClaudePage / applyLoginRequired) を使うため、FailureReason 側には
  // 対応する case を持たない。表現は RedReason 側のみで行う
  case javaScriptError    // usage fetch JS の実行自体が失敗、または戻り値が想定外
  case fetchTimeout       // JS 側 AbortSignal timeout、または Swift 側 watchdog 発火
  case fetchNetworkError  // JS fetch の TypeError 等 (オフライン・DNS 失敗など)
  case claudeApiHttpError(stage: UsageFetchStage, status: Int)  // claude.ai API の HTTP 非 200 (未ログイン分類に該当しないもの)
  case orgResolutionFailed  // organizations 応答の構造が想定外 (JSON 破損・空配列・uuid 欠落等)
  case jsonParseError     // usage レスポンス JSON のパース失敗
  case jsonEncodeError
  case fileWriteFailed
  case postHttpFailed(Int)  // API POST (出力側) の HTTP 非 200
  case postNetworkFailed    // API POST (出力側) の通信エラー
  case unknownPlan          // JSON は来たがプラン判定不能
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
    case .red(.notOnClaudePage):
      return "異常 - ページを確認してください"
    case .red(.loginRequired):
      return "異常 - 未ログイン (ウィンドウを表示してログイン)"
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

// MARK: - Date extension
// リセット時刻の 10 分単位四捨五入（15:55-16:04 → 16:00）。
// 「+5 分してから 10 分単位で切り捨て」で最も近い 10 分境界に丸める。
// JSON 出力/API/表示が全て JST 固定である以上、分解-再構築も端末 TZ ではなく
// AutomationManager.jstCalendar (JST) を基準に行い、UTC 端末などでも挙動を揃える
extension Date {
  private static let roundingStepMinutes = 10

  func roundedToNearestTenMinutes() -> Date {
    let step = Self.roundingStepMinutes
    let calendar = AutomationManager.jstCalendar
    guard let shifted = calendar.date(byAdding: .minute, value: step / 2, to: self) else { return self }
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: shifted)
    let minute = components.minute ?? 0
    components.minute = (minute / step) * step
    components.second = 0
    return calendar.date(from: components) ?? self
  }
}

// MARK: - Usage Fetch JS
extension AutomationManager {
  // callAsyncJavaScript の async function body。
  // arguments: orgUuid (String, 空文字 = 未解決) / timeoutMs (Int) / previewLength (Int)。
  // JS は reject せず、常に plist 互換の flat な辞書を resolve で返す。失敗の意味づけ
  // (未ログイン判定等) は Swift 側 classifyAndApplyFetchFailure に集約する。
  // organizations 段の JSON.parse 失敗も kind="parse" + contentType の生値で返すだけにし、
  // 「非 JSON = 未ログイン」の解釈は Swift 側に委ねる
  static let usageFetchJS: String = """
  const fetchJson = async (path) => {
    const res = await fetch(path, { signal: AbortSignal.timeout(timeoutMs) });
    return {
      status: res.status,
      contentType: res.headers.get('content-type') || '',
      redirected: res.redirected,
      body: await res.text(),
    };
  };
  const failure = (stage, kind, res, extra) => ({
    ok: false, stage, kind,
    status: res ? res.status : -1,
    contentType: res ? res.contentType : '',
    redirected: res ? res.redirected : false,
    bodyHead: res ? res.body.slice(0, previewLength) : '',
    ...(extra || {}),
  });
  let stage = 'organizations';
  try {
    let uuid = orgUuid;
    if (!uuid) {
      const res = await fetchJson('/api/organizations');
      if (res.status !== 200) { return failure(stage, 'http', res); }
      let orgs;
      try { orgs = JSON.parse(res.body); } catch (e) { return failure(stage, 'parse', res); }
      if (!Array.isArray(orgs) || orgs.length === 0 || !orgs[0] || !orgs[0].uuid) {
        return failure(stage, 'noOrg', res);
      }
      // org 選択ポリシー: 先頭の org を採用。複数 org 対応時はここを設定値参照に差し替える
      uuid = orgs[0].uuid;
      var orgCount = orgs.length;
    }
    stage = 'usage';
    const res = await fetchJson('/api/organizations/' + uuid + '/usage');
    if (res.status !== 200) { return failure(stage, 'http', res, { orgUuid: uuid }); }
    return {
      ok: true, orgUuid: uuid, orgCount: (typeof orgCount === 'number' ? orgCount : -1),
      status: res.status, contentType: res.contentType, redirected: res.redirected, body: res.body,
    };
  } catch (e) {
    const kind = (e && (e.name === 'TimeoutError' || e.name === 'AbortError')) ? 'timeout' : 'network';
    return failure(stage, kind, null, { error: String(e) });
  }
  """
}
