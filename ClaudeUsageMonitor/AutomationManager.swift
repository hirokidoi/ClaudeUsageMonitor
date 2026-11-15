import Foundation
import Combine
import AppKit
import UserNotifications
import ClaudeUsageMonitorCore

class AutomationManager: ObservableObject {
  @Published private(set) var status: AutomationStatus = .waiting
  // 直近の取得データ。メニュー表示と statusBarColor の計算に使う
  @Published private(set) var lastUsage: UsageSnapshot?

  let logStore: LogStore
  private let settings: AppSettings
  private var timer: Timer?
  private var tracker = FetchTracker()
  private var fileLedger = OutputLedger()
  private var postLedger = OutputLedger()
  private var outputFailures = OutputFailureLedger()
  private var warningNotifier = FetchWarningNotifier()
  // 保存先の書込確認の失敗で状態を決め直すために、直近の判定を持つ
  private var lastResolution: (verdict: FetchVerdict, tolerance: Int)?
  private var isFetching = false
  // 最後に取得を試みた時刻 (自動・手動・成否を問わない)
  private var lastTickAt: Date?
  private var cancellables = Set<AnyCancellable>()
  // 直前の statusBarColor。orange への遷移時のみ通知発火するために保持
  private var previousStatusBarColor: StatusBarColor = .red

  // 起動直後はネットワークが未確立のことがあるので、最初の取得を遅らせる (設計値)
  private static let startupFetchDelaySeconds: TimeInterval = 5
  // 自動の取得の開始に足す揺らぎの上限 (設計値)
  private static let maxFetchJitterSeconds: TimeInterval = 20
  private static let secondsPerMinute: TimeInterval = 60
  // POST の -1009 を取り直すまでの待ち (設計値)
  private static let postRetryDelaySeconds: TimeInterval = 2
  // 出力先が選ばれていないファイル出力のキー。実在のパスとは重ならない
  private static let unselectedFileKeyPrefix = "unselected:"

  private static let statusTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    // 1 桁時はゼロ埋めしない (例: 4:00:00)
    f.dateFormat = "H:mm:ss"
    f.timeZone = JST.timeZone
    return f
  }()

  init(settings: AppSettings, logStore: LogStore) {
    self.settings = settings
    self.logStore = logStore

    appLog("アプリ起動 v\(Bundle.main.appVersionLabel)")

    // removeDuplicates → dropFirst の順。@Published は willSet で発火するので、次の run loop で読む
    settings.$intervalMinutes
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] value in
        self?.appLogDebug("intervalMinutes 変更を検知: \(value)")
        DispatchQueue.main.async { self?.start() }
      }
      .store(in: &cancellables)

    settings.$autoRefreshEnabled
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        DispatchQueue.main.async { self?.autoRefreshChanged() }
      }
      .store(in: &cancellables)

    logChanges(settings.$intervalMinutes, \.intervalMinutes, "intervalMinutes")
    logChanges(settings.$autoRefreshEnabled, \.autoRefreshEnabled, "autoRefreshEnabled")
    logChanges(settings.$warningThresholdPct, \.warningThresholdPct, "warningThresholdPct")
    logChanges(settings.$failureTolerance, \.failureTolerance, "failureTolerance")
    logChanges(settings.$appearance, \.appearance, "appearance")
    logChanges(settings.$claudePath, \.claudePath, "claudePath")
    logChanges(settings.$claudeConfigDirectory, \.claudeConfigDirectory, "claudeConfigDirectory")
    logChanges(settings.$apiEndpointUrl, \.apiEndpointUrl, "apiEndpointUrl")
    logChanges(settings.$monitoringFileName, \.monitoringFileName, "monitoringFileName")
    logChanges(settings.$outputDirectoryMode, \.outputDirectoryMode, "outputDirectoryMode")
    logChanges(settings.$customOutputDirectory, \.customOutputDirectory, "customOutputDirectory")

    DispatchQueue.main.async { [weak self] in self?.start() }

    // 自動更新しないときは手動更新だけなので、起動直後の取得も予約しない
    if settings.isAutoRefreshActive {
      let delay = Self.startupFetchDelaySeconds + Self.fetchJitter()
      appLogDebug("起動 \(Int(delay)) 秒後に起動直後の取得を予約")
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.runStartupFetch()
      }
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
  // 呼び出し側でディスパッチが必要。MainActor.assumeIsolated は使わず常に main.async に一本化する
  func appLog(_ message: String, level: LogLevel = .info) {
    DispatchQueue.main.async { [logStore] in
      logStore.log(message, level: level)
    }
  }

  // レベル別ショートハンド
  func appLogDebug(_ message: String) { appLog(message, level: .debug) }
  func appLogWarn(_ message: String)  { appLog(message, level: .warn) }

  // 配信の時点ではプロパティはまだ旧値なので、旧 → 新を出せる
  private func logChanges<Value: Equatable>(_ publisher: Published<Value>.Publisher, _ keyPath: KeyPath<AppSettings, Value>, _ name: String) {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] value in
        guard let self else { return }
        self.appLog("設定変更: \(name) \(self.settings[keyPath: keyPath]) → \(value)")
      }
      .store(in: &cancellables)
  }

  private var intervalSeconds: TimeInterval {
    TimeInterval(settings.intervalMinutes) * Self.secondsPerMinute
  }

  private static func fetchJitter() -> TimeInterval {
    .random(in: 0...maxFetchJitterSeconds)
  }

  func start(firstFireIn: TimeInterval? = nil) {
    timer?.invalidate()
    timer = nil
    guard settings.isAutoRefreshActive else {
      appLogDebug("Timer 停止: 自動更新なし")
      return
    }
    let interval = intervalSeconds
    let firstFire = (firstFireIn ?? interval) + Self.fetchJitter()
    appLogDebug("Timer 再貼付: interval=\(interval)s first=\(Int(firstFire))s")
    let newTimer = Timer(fire: Date().addingTimeInterval(firstFire), interval: interval, repeats: true) { [weak self] _ in
      DispatchQueue.main.async { [weak self] in
        self?.appLogDebug("Timer 発火")
        self?.tick()
      }
    }
    RunLoop.main.add(newTimer, forMode: .default)
    timer = newTimer
  }

  // 続けて切り替えても取りに行きすぎないよう、前回の取得から間隔がたっていなければ残りを待つ
  private func autoRefreshChanged() {
    guard settings.isAutoRefreshActive else {
      start()
      return
    }
    switch AutoRefreshResume.decide(lastAttempt: lastTickAt, now: Date(), interval: intervalSeconds) {
    case .fetchNow:
      start(firstFireIn: 0)
    case .waitThenFetch(let remaining):
      start(firstFireIn: remaining)
    }
  }

  // 予約から発火までに、チェックが外されたり取得が済んだりしていることがあるので見直す
  private func runStartupFetch() {
    guard settings.isAutoRefreshActive,
          AutoRefreshResume.decide(lastAttempt: lastTickAt, now: Date(), interval: intervalSeconds) == .fetchNow else {
      appLogDebug("起動直後の取得 skip")
      return
    }
    appLog("起動直後の取得")
    tick()
  }

  func runManualFetch() {
    appLog("手動更新")
    tick()
  }

  // MARK: - Tick

  private func tick() {
    appLogDebug("tick 開始")
    guard !isFetching else {
      appLogDebug("tick skip: 取得中")
      return
    }
    isFetching = true
    lastTickAt = Date()
    // 手動更新経由でも周期を揃えるため、tick のたびに張り直す
    start()

    let file = settings.cacheFileURL
    let request = FetchRequest(executable: settings.resolvedClaudeExecutable, customFolder: settings.configFolderInput, cacheFile: file)
    let readBaselineFirst = tracker.needsBaseline(for: file)
    let tolerance = settings.failureTolerance
    DispatchQueue.global().async { [weak self] in
      let result = UsageFetcher.run(request, readBaselineFirst: readBaselineFirst)
      DispatchQueue.main.async {
        self?.finishFetch(result, file: file, tolerance: tolerance)
      }
    }
  }

  private func finishFetch(_ result: FetchResult, file: URL?, tolerance: Int) {
    for (index, failure) in result.retriedFailures.enumerated() {
      appLog("claude 失敗 (\(index + 1)/\(UsageFetcher.commandAttempts) 回目、再試行): \(failure.diagnostic)")
    }
    tracker.seed(result.preRead, file: file)
    let verdict = tracker.record(result.outcome, file: file)
    if case .failure(let failure, let count) = verdict {
      appLogWarn("fetch 失敗 (\(count)/\(tolerance)): \(failure.diagnostic)")
    }

    // 出力は成否に関係なく、取れた値を出力先ごとの要否に従って出す
    guard case .read(let cache) = result.outcome else {
      completeTick(verdict: verdict, tolerance: tolerance, fileAttempt: nil, postAttempt: nil)
      return
    }
    let (usage, snapshot) = UsagePayload.make(from: cache)
    if case .success = verdict { logFetchSuccess(usage, call: result.retriedFailures.count + 1) }
    lastUsage = snapshot
    guard let outputData = try? usage.jsonData() else {
      appLogWarn("UsageData エンコード失敗")
      completeTick(verdict: verdict, tolerance: tolerance, fileAttempt: .failed, postAttempt: nil)
      return
    }
    // ファイル書き込みと API POST は独立した出力先。片方の失敗で他方をブロックしない
    let fileAttempt = writeUsageFileIfNeeded(outputData, fetchedAt: usage.fetchedAt)
    postToAPIIfNeeded(outputData, fetchedAt: usage.fetchedAt) { [weak self] postAttempt in
      self?.completeTick(verdict: verdict, tolerance: tolerance, fileAttempt: fileAttempt, postAttempt: postAttempt)
    }
  }

  // 出力の失敗の記録と状態の更新を 1 回にまとめる。試みなし (nil) の tick でも今の出力先のキーを渡す
  private func completeTick(verdict: FetchVerdict, tolerance: Int, fileAttempt: OutputAttempt?, postAttempt: OutputAttempt?) {
    outputFailures.update(.file, currentKey: fileOutputKey, attempt: fileAttempt)
    outputFailures.update(.post, currentKey: postOutputKey, attempt: postAttempt)
    applyResolved(verdict: verdict, tolerance: tolerance)
    isFetching = false
  }

  // fetch 成功時のサマリを INFO ログに出す
  private func logFetchSuccess(_ usage: UsageData, call: Int) {
    let sessionLabel = usage.sessionPct.map { "\($0)%" } ?? "----"
    let sReset = usage.sessionResetAt ?? "-"
    let weeklyLabel = usage.weeklyPct.map { "\($0)%" } ?? "----"
    let wReset = usage.weeklyResetAt ?? "-"
    let callLabel = call > 1 ? " (\(call) 回目の呼び出しで取得)" : ""
    appLog("fetch 成功\(callLabel): plan=\(usage.plan) session=\(sessionLabel) reset=\(sReset), weekly=\(weeklyLabel) reset=\(wReset)")
  }

  // MARK: - Output

  // ファイル出力のキー。出力しない設定なら nil
  private var fileOutputKey: String? {
    guard !settings.monitoringFileName.isEmpty else { return nil }
    guard let directoryURL = settings.outputDirectoryURL else {
      return Self.unselectedFileKeyPrefix + settings.safeMonitoringFileName
    }
    return directoryURL.appendingPathComponent(settings.safeMonitoringFileName).path
  }

  // POST 出力のキー。送らない設定 (空・URL として読めない) なら nil
  private var postOutputKey: String? {
    let endpointUrl = settings.apiEndpointUrl
    guard !endpointUrl.isEmpty, URL(string: endpointUrl) != nil else { return nil }
    return endpointUrl
  }

  // 試みなし (nil) は、未設定か、同じ出力先に同じ fetched_at を出せている場合
  private func writeUsageFileIfNeeded(_ data: Data, fetchedAt: String) -> OutputAttempt? {
    guard let key = fileOutputKey else {
      appLogDebug("ファイル書込 skip（未設定）")
      return nil
    }
    guard fileLedger.needsOutput(fetchedAt: fetchedAt, destination: key) else {
      appLogDebug("ファイル書込 skip（同じ fetched_at）")
      return nil
    }
    guard let directoryURL = settings.outputDirectoryURL else {
      appLogWarn("ファイル書込失敗: 保存先フォルダ未選択")
      return .failed
    }
    let fileURL = directoryURL.appendingPathComponent(settings.safeMonitoringFileName)
    do {
      try data.write(to: fileURL, options: .atomic)
      appLogDebug("ファイル書込: \(fileURL.path)")
      fileLedger.recordOutput(fetchedAt: fetchedAt, destination: key)
      return .succeeded
    } catch {
      appLogWarn("ファイル書込失敗: \(error)")
      return .failed
    }
  }

  // 保存先・ファイル名の確定時に書き込みを試し、TCC の確認をユーザーの在席中に出させる。
  // 本来のファイル名に書くと既存の JSON を消してしまうため別名の隠しファイルを使う
  func probeOutputDirectory() {
    guard settings.outputDirectoryMode == .custom,
          !settings.monitoringFileName.isEmpty,
          let directoryURL = settings.outputDirectoryURL else { return }
    let probeURL = directoryURL.appendingPathComponent(".\(settings.safeMonitoringFileName).probe")
    do {
      try Data("{}".utf8).write(to: probeURL)
      try FileManager.default.removeItem(at: probeURL)
      appLog("保存先の書込確認: \(directoryURL.path)")
    } catch {
      appLogWarn("保存先の書込確認失敗: \(error)")
      outputFailures.update(.file, currentKey: fileOutputKey, attempt: .failed)
      applyResolved(verdict: lastResolution?.verdict, tolerance: lastResolution?.tolerance ?? settings.failureTolerance)
    }
  }

  // POST。試みなし (nil) は、未設定か、同じ出力先に同じ fetched_at を出せている場合
  private func postToAPIIfNeeded(_ data: Data, fetchedAt: String, completion: @escaping (OutputAttempt?) -> Void) {
    guard let key = postOutputKey, let url = URL(string: key) else {
      appLogDebug("API POST skip（未設定）")
      completion(nil)
      return
    }
    guard postLedger.needsOutput(fetchedAt: fetchedAt, destination: key) else {
      appLogDebug("API POST skip（同じ fetched_at）")
      completion(nil)
      return
    }
    performPOST(url: url, endpointUrl: key, data: data, allowRetry: true) { [weak self] attempt in
      if attempt == .succeeded {
        self?.postLedger.recordOutput(fetchedAt: fetchedAt, destination: key)
      }
      completion(attempt)
    }
  }

  // 起動直後の NSURLErrorNotConnectedToInternet (-1009) は URLSession のネットワーク
  // 把握が追いつかないだけのケースが多いため、少し待って 1 回だけリトライする
  private func performPOST(url: URL, endpointUrl: String, data: Data, allowRetry: Bool, completion: @escaping (OutputAttempt) -> Void) {
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
            self?.appLogDebug("API POST -1009 検知、\(Int(Self.postRetryDelaySeconds)) 秒後にリトライ")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.postRetryDelaySeconds) { [weak self] in
              self?.performPOST(url: url, endpointUrl: endpointUrl, data: data, allowRetry: false, completion: completion)
            }
            return
          }
          self?.appLogWarn("API POST 失敗: \(error)")
          completion(.failed)
          return
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          self?.appLogWarn("API POST: \(endpointUrl) → \(http.statusCode)")
          completion(.failed)
          return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        self?.appLogDebug("API POST: \(endpointUrl) → \(status)")
        completion(.succeeded)
      }
    }.resume()
  }

  // MARK: - Status

  private func applyResolved(verdict: FetchVerdict?, tolerance: Int) {
    guard let resolved = StatusResolver.resolve(verdict: verdict, outputFailure: outputFailures.failing, tolerance: tolerance) else {
      applyStatus(.waiting)
      return
    }
    switch (resolved.kind, verdict) {
    case (.outputFailed(let kind), _):
      applyStatus(.outputFailed(kind == .file ? .json : .api, isRed: resolved.isRed))
    case (_, .success(let cache)?):
      applyStatus(.ok(fetchedAt: cache.fetchedAt))
    case (_, .failure(let failure, let count)?):
      applyStatus(.fetchFailed(failure, count: count, tolerance: tolerance, isRed: resolved.isRed))
    case (_, nil):
      applyStatus(.waiting)
    }
    guard let verdict else { return }
    lastResolution = (verdict, tolerance)
    let isWarning = StatusResolver.isFetchWarning(verdict, tolerance: tolerance)
    if warningNotifier.shouldNotify(isWarning: isWarning), case .failure(let failure, let count) = verdict {
      sendFetchWarningNotification(failure: failure, count: count)
    }
  }

  private func applyStatus(_ newStatus: AutomationStatus) {
    let oldText = status.text
    let newText = newStatus.text
    if oldText != newText {
      appLog("status: \(oldText) → \(newText)")
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
    sendNotification(content, identifierPrefix: "claude-usage-warning", logLabel: "Claude Usage Warning (session=\(session), weekly=\(weekly))")
  }

  private func sendFetchWarningNotification(failure: FetchFailure, count: Int) {
    let content = UNMutableNotificationContent()
    content.title = "Claude Usage Fetch Failed"
    var body = "取得失敗が \(count) 回続いています (\(lastFetchedText))"
    if failure.suggestsRelogin { body += "\n" + AutomationStatus.reloginNotice }
    content.body = body
    sendNotification(content, identifierPrefix: "claude-usage-fetch-failed", logLabel: "Claude Usage Fetch Failed (count=\(count))")
  }

  // 識別子は毎回一意にして、遷移のたびに必ず出す
  private func sendNotification(_ content: UNMutableNotificationContent, identifierPrefix: String, logLabel: String) {
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "\(identifierPrefix)-\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { [weak self] error in
      if let error {
        self?.appLogWarn("通知送信失敗: \(error)")
      } else {
        self?.appLog("通知送信: \(logLabel)")
      }
    }
  }

  private var lastFetchedText: String {
    lastUsage.map { "最終取得 \(JST.dateTime($0.fetchedAt))" } ?? AutomationStatus.neverFetchedText
  }

  var statusBarColor: StatusBarColor {
    if status.isRed { return .red }
    if case .waiting = status { return .green }
    guard let usage = lastUsage else { return .green }
    let threshold = settings.warningThresholdPct
    let sessionOver = (usage.sessionPct ?? 0) >= threshold
    let weeklyOver = (usage.weeklyPct ?? 0) >= threshold
    if sessionOver || weeklyOver { return .orange }
    return .green
  }

  static func statusTimeString(from date: Date) -> String {
    statusTimeFormatter.string(from: date)
  }
}

// MARK: - Types

enum AutomationStatus {
  case waiting
  case ok(fetchedAt: Date)
  case fetchFailed(FetchFailure, count: Int, tolerance: Int, isRed: Bool)
  case outputFailed(OutputTarget, isRed: Bool)
}

enum OutputTarget: String {
  case json = "JSON"
  case api = "API"
}

enum StatusBarColor {
  case green
  case orange
  case red
}

extension AutomationStatus {
  static let reloginNotice = "ログインが切れている可能性があります。"
  static let neverFetchedText = "まだ一度も取得できていません"

  var isRed: Bool {
    switch self {
    case .waiting, .ok: return false
    case .fetchFailed(_, _, _, let isRed), .outputFailed(_, let isRed): return isRed
    }
  }

  // ログの遷移表示に使う 1 行目
  var text: String { lines(lastFetchedAt: nil)[0] }

  // メニューに並べる行。警告時の経過の行に最終取得の時刻を使う
  func lines(lastFetchedAt: Date?) -> [String] {
    switch self {
    case .waiting:
      return ["取得待機中"]
    case .ok(let fetchedAt):
      return ["正常 - 最終取得 \(AutomationManager.statusTimeString(from: fetchedAt))"]
    case .fetchFailed(let failure, let count, let tolerance, let isRed):
      let head = "取得失敗 (\(count)/\(tolerance)) - \(failure.reason)"
      guard isRed else { return [head] }
      var lines = ["異常 - \(head)"]
      lines.append(lastFetchedAt.map { "最終取得 \(JST.dateTime($0)) から取得できていません" } ?? Self.neverFetchedText)
      if failure.suggestsRelogin {
        lines.append("ログインが切れている可能性があります (ターミナルで claude を開いてログインし直す)")
      }
      return lines
    case .outputFailed(let target, _):
      return ["異常 - 出力失敗 (\(target.rawValue))"]
    }
  }
}

extension FetchFailure {
  var reason: String {
    switch self {
    case .claudeNotFound: return "claude が見つかりません (設定の Claude タブで場所を指定)"
    case .configFolderMissing: return "CLAUDE_CONFIG_DIR のフォルダがありません"
    case .configFolderInvalid: return "CLAUDE_CONFIG_DIR のパスが無効です"
    case .launchFailed: return "claude を起動できません"
    case .timedOut: return "claude が時間内に終わりません"
    case .exitFailure(let code, _): return "claude が異常終了しました (終了コード \(code))"
    case .cacheMissing: return "使用状況データが見つかりません (CLAUDE_CONFIG_DIR を設定している場合は Claude タブで指定)"
    case .cacheUnreadable: return "使用状況データが読めません"
    case .notLoggedIn: return "未ログイン (ターミナルで claude を開いてログイン)"
    case .notUpdated: return "値が更新されていません"
    }
  }

  // ログインを直せば解決しうる失敗だけ案内する
  var suggestsRelogin: Bool {
    switch self {
    case .notUpdated, .notLoggedIn, .exitFailure: return true
    default: return false
    }
  }

  // ログ用。理由に詳細 (パス・stderr など) を添える
  var diagnostic: String {
    switch self {
    case .configFolderMissing(let path), .configFolderInvalid(let path), .cacheMissing(let path): return "\(reason): \(path)"
    case .launchFailed(let detail), .exitFailure(_, let detail): return detail.isEmpty ? reason : "\(reason): \(detail)"
    default: return reason
    }
  }
}
