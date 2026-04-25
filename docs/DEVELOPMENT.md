# DEVELOPMENT.md

今後の追加開発・保守で読んでおくべき事項を網羅的に記録。

最終更新: 2026-04-19 JST

---

## アーキテクチャ

### 全体の流れ

```
ClaudeUsageMonitorApp (@main)
  ├─ AppSettings         … UserDefaults 永続化、matches(url:) 判定、defaultUrl / warningThresholdPct
  ├─ LogStore            … アプリ内ログ（@MainActor、FIFO 最大 1000 行、LogLevel 閾値）
  └─ AutomationManager   … 共有 WKWebView / WebViewCoordinator 所有
                          AppKit NSWindow 所有（mainWindow）+ NSWindowDelegate
                          タイマー、JS 実行、データ処理、送信
                          Combine 購読、@Published status / @Published lastUsage
                          UNUserNotificationCenter で使用率警告通知を送出
                          statusBarColor（green/orange/red）を計算
                          appLog / appLogDebug / appLogWarn / appLogError ヘルパで LogStore へ記録

Scene 構成 (3 つ):
  ├─ MenuBarExtra              … 常駐アイコン（NSImage 自前描画）+ MenuContentView
  ├─ Window(id: "log")         … LogView（初期 700x500、リサイズ可、.defaultLaunchBehavior(.suppressed)）
  └─ Settings                  … SettingsView

メイン WebView ウィンドウ（SwiftUI Scene ではない）:
  AutomationManager が AppKit NSWindow を直接生成・所有し、
  contentView に共有 WKWebView を attach。
  起動時に alphaValue=0 + orderFrontRegardless で「不可視だが on screen」扱いに保つ
  （hide しない = WKWebView の throttle 回避）。

OAuth ポップアップ（navigationDelegate 経由で生成される別ウィンドウ）:
  OAuthPopupController（ContentView.swift に定義）が NSWindow + WKWebView を生成。
```

※ 正常状態（Normalアイコン時）= green, 警告状態（Orangeアイコン時）= orange, 異常状態（Redアイコン時）= red と表現する。

- `AutomationManager` が `WKWebView` / `WebViewCoordinator` / メインウィンドウ用 `NSWindow` / `LogStore` 参照を**強参照**で所有する（SoT）
- メイン WebView ウィンドウは SwiftUI Scene ではなく AppKit `NSWindow`。`styleMask = [.titled, .closable, .resizable]`、`contentView = webView`
- ウィンドウを「閉じる」操作は `NSWindowDelegate.windowShouldClose` で `false` を返してインターセプトし、`hideMainWindow()` で `alphaValue = 0` + `ignoresMouseEvents = true` による不可視化に置き換える（= 破棄はしない）
- 「ウィンドウを表示」は `center()` + `alphaValue = 1` + `makeKeyAndOrderFront` + `NSApp.activate` で画面中央に前面表示。ユーザーがリサイズしたサイズを保持するため `setContentSize` は呼ばない
- `WebViewCoordinator` は `AppSettings` / `LogStore` の参照を持ち、ナビゲーション監視・ループ検出に加えて `appLog` 系ヘルパ（AutomationManager と同じディスパッチ方式）でログも記録
- Timer のライフサイクルは View 非依存。`AutomationManager.init` 末尾で `start()` を発火し、アプリ終了まで停止しない

### 各クラスの責務

| クラス / 構造体 | 役割 |
|----------------|------|
| `ClaudeUsageMonitorApp` | SwiftUI エントリポイント。`AppSettings` / `LogStore` / `AutomationManager` を `StateObject` で生成し、`MenuBarExtra` / `Window(id: "log")` / `Settings` の 3 Scene を宣言。`statusBarIcon(color:)` で `Assets.xcassets/StatusBarIcon` のシルエットを取り、`.green` は `isTemplate = true` で macOS 自動色、`.orange` / `.red` は CGContext の `.sourceIn` ブレンドで `systemOrange` / `systemRed` に上書きして返す。素材読み込み失敗時のみ `fallbackDotIcon(color:)` で従来の塗り丸へフォールバック |
| `MenuContentView` | MenuBarExtra の中身。先頭に使用率サマリをプランに応じて表示する `summaryRows` ビュー（Individual: 4 行 / Enterprise: 2 行）に続き、状態ラベル、4 つのメニュー項目（ウィンドウを表示 / 手動更新 / 設定… / ログ）+ 区切り + 終了。`sessionResetFormatter` (`H:mm`) と `weeklyResetFormatter` (`M/d (E) H:mm` / `ja_JP`) を同居し、両者とも `timeZone = Asia/Tokyo` を固定。`automation.lastUsage` が nil の場合は individual レイアウト扱いで `----` プレースホルダを 4 行表示 |
| `LogView` | ログウィンドウ UI。`LogStore.entries` を 1 つの `Text` にまとめて `textSelection(.enabled)` で複数行選択可。`ScrollViewReader` + 末尾マーカー (`Color.clear` + `id`) で新規追記時と表示直後に自動末尾スクロール。ヘッダに「N / 1000 行」と「クリア」ボタン |
| `LogStore` | `@MainActor` 固定の `ObservableObject`。`@Published private(set) var entries: [LogEntry]`、最大 `maxEntries = 1000` の FIFO（先頭から `removeFirst` で調整）、`lineCounter` による絶対行番号、`minLevel` 閾値でフィルタ、`log(_:level:)` / `clear()` を提供 |
| `LogEntry` | `Identifiable, Equatable`。`id` / `lineNumber` / `timestamp` / `message` / `level` を保持。`formatted` 計算プロパティで `NNNNN  HH:mm:ss [LEVEL]  message` の表示文字列を返す |
| `LogLevel` | `Int` raw + `Comparable` enum。`.debug` / `.info` / `.warn` / `.error`。`label` で 5 文字幅（`INFO ` / `WARN ` 等）の固定幅ラベルを返す |
| `OAuthPopupController` | OAuth ポップアップ用の `NSWindow` + `WKWebView`。`ContentView.swift` 内に定義。ウィンドウクローズをポーリングで検出し `onClose` を呼ぶ |
| `AutomationManager` | `NSObject` サブクラス。`WKScriptMessageHandler` 実装（`usageAPI` 名で `/api/organizations/.../usage` の傍受メッセージを受信）、共有 `WKWebView` / `WebViewCoordinator` / メインウィンドウ用 `NSWindow` / `LogStore` 参照の所有、`NSWindowDelegate` 実装（windowShouldClose で hide 置換）、`installMainWindow` / `showMainWindow` / `hideMainWindow`、タイマー制御、`tick()` → ボタンクリック JS → API レスポンス待機（`pendingAPIHandler` + 10 秒 timeout）、プラン判定 → パース、ファイル出力、HTTP POST（-1009 リトライ付き）、失敗カウント、セッションクリア、`@Published status` / `@Published lastUsage: UsageSnapshot?`、computed `statusBarColor: StatusBarColor`、`runManualFetch()`、init で `WKUserContentController` に fetch/XHR ラッパ JS を `.atDocumentStart` で登録、init 末尾で `UNUserNotificationCenter.requestAuthorization`、`applyStatus` 末尾の `notifyIfOrangeTransition()` で Orange 遷移時のみユーザー通知を 1 回発火、`appLog` / `appLogDebug` / `appLogWarn` / `appLogError` ヘルパ |
| `WebViewCoordinator` | `WKNavigationDelegate` / `WKUIDelegate`。OAuth ポップアップ生成、`didFinish` で即時 fetch スケジュール、`decidePolicyFor` でのループ検出。`LogStore` を保持し `appLog` 系ヘルパ（AutomationManager と同じディスパッチ方式）でログ記録 |
| `AppSettings` | `UserDefaults` 永続化。`@Published` プロパティの `didSet` で自動保存。`matches(url:)` で設定 URL と任意 URL を host+path 比較。`static let defaultUrl = "https://claude.ai/settings/usage"` を公開し、`url` の初期値と `SettingsView` の placeholder から共通参照。`warningThresholdPct`（Int、初期値 90、`Keys.warningThresholdPct`）も併せて永続化 |
| `SettingsView` | 設定画面 UI（URL、間隔、API エンドポイント、ファイル名、警告閾値）。`@State` の編集バッファを持ち、**Save で commit / Cancel で破棄**する方式。`warningThresholdDraft` は `Stepper` で 1〜100% を 1 刻み。フィールド変更は INFO、Save / Cancel ボタン操作は DEBUG で `appLog` する。Save/Cancel 行はバッファ方式フィールドの直下に配置し、その下（Divider 区切り）に Save/Cancel 対象外の即時動作ボタンを並べる: ログイン時起動トグル（Button スタイル、`SMAppService.mainApp` 経由で即時 register / unregister）、セッションクリア |

---

## 状態モデル

`AutomationManager.swift` 末尾に同居する enum 群。メニューバーアイコン色・状態ラベル・自動リロードのトリガー判定・使用率警告通知を一元化する。

### `AutomationStatus`
- `.green(lastSuccessAt: Date)` — 直近の tick が成功、かつ起動以降に少なくとも 1 回成功している
- `.red(RedReason)` — それ以外

`AutomationStatus.color` が `StatusColor`（`.green` / `.red`）を返し、自動リロード判定などの統計的な成否判定に使う。`AutomationStatus.text` が表示用文言を返す（計算プロパティ。`status` 以外に状態ソースを増やさないため）。`.green` 時の時刻表記は `HH:mm:ss`（`AutomationManager.statusTimeFormatter`）。

### `UsageSnapshot`
`handleCapturedAPIResponse` が成功したときに `AutomationManager.@Published var lastUsage: UsageSnapshot?` にセットされる UI 用スナップショット。`plan: UsagePlan` / `sessionPct: Int?` / `sessionResetAt: Date?` / `weeklyPct: Int?` / `weeklyResetAt: Date?` を保持し、View 側で好きな書式に整形できる。JSON 出力用の `UsageData`（文字列フィールドでフォーマット済み）とは別立てに分けている（責務分離: JSON シリアライゼーションと UI 表示で必要な型が異なるため、`buildUsagePayload(from:)` が両方を同時に構築して返す）。

### `UsagePlan`
`UsageSnapshot` / `UsageData` で保持するプラン種別（`.individual` / `.enterprise`）。`String` rawValue（`"individual"` / `"enterprise"`）が JSON の `plan` フィールドにそのまま出力される。Pro / Max は `.individual` に統一する（区別しない）。判定ロジックは `classifyPlan(json:)` を参照。

### `StatusBarColor`
メニューバーアイコンの 3 値表現。`.green` / `.orange` / `.red`。`AutomationManager.statusBarColor` が `status` と `lastUsage` と `settings.warningThresholdPct` から以下の優先順で計算する:

1. `status` が `.red` → `.red`
2. `lastUsage == nil`（成功時だが取得データがまだ無い場合は基本的に起きない）→ `.green`
3. `(lastUsage.sessionPct ?? 0) >= threshold || (lastUsage.weeklyPct ?? 0) >= threshold` → `.orange`
4. それ以外 → `.green`

`sessionPct` / `weeklyPct` は `Int?`（Enterprise の weekly、Individual で片側 null のケースなど）。nil は `0` 扱いで閾値判定する（Orange へ遷移しない）。

### `StatusColor` との並存関係
`StatusColor`（`.green` / `.red` の 2 値）は `AutomationStatus.color` 専用。自動リロードや「成功 / 失敗」の二値判定で使われる。アイコン色は `AutomationManager.statusBarColor`（= `StatusBarColor`）を、status 自体の意味論は `AutomationStatus.color`（= `StatusColor`）を使う、と棲み分ける。

### `RedReason`
- `.notYetFetched` — 起動直後で一度も成功していない（文言: `取得待機中`）
- `.urlNotConfigured` — 設定 URL が空（文言: `異常 - URL 未設定`）
- `.notOnSettingsPage` — URL は設定済みだが現在 WebView のページが一致しない（文言: `異常 - ページを確認してください`）
- `.recentFailure(count: Int, lastReason: FailureReason)` — 直近 tick が失敗（文言: `異常 - 取得失敗 (n/3)`）

### `FailureReason`
tick サイクルの各失敗原因を enum で表現する。`.recentFailure` の `lastReason` に埋め込まれる。

- `.javaScriptError` — 「使用制限を更新」ボタンクリック JS の実行失敗
- `.jsonParseError` — 捕捉した API レスポンス本体の JSON パース失敗
- `.jsonEncodeError` — `UsageData` エンコード失敗
- `.fileWriteFailed` — ファイル書き込み失敗
- `.httpFailed(Int)` — HTTP 非 200 系
- `.networkFailed` — 通信エラー
- `.apiResponseTimeout` — ボタンクリック後 10 秒以内に `/api/organizations/.../usage` レスポンスが届かない
- `.unknownPlan` — レスポンス JSON は届いたがプラン判定不能（`classifyPlan` が nil）

### `FileOutcome` / `PostOutcome`
`writeUsageFileIfNeeded` / `postToAPIIfNeeded` の戻り値を 3 値で表す private enum。

- `.success`
- `.skipped` — ファイル名 or API URL 未設定（失敗扱いにしない）
- `.failed(FailureReason)`

`applyCombinedOutcome(file:post:)` が 2 つの Outcome を受け取り、**どちらかが `.failed` なら failure、両方 `.skipped` または `.success` なら success** と判定する。これにより 1 tick あたり `consecutiveFailureCount` を最大 1 回しか加算しない（write 失敗 → POST 失敗で 2 回加算される事故を防ぐ）。

### 状態遷移ルール

| トリガー | `AutomationStatus` | `StatusBarColor` | `consecutiveFailureCount` |
|---|---|---|---|
| `init` 直後 | `.red(.notYetFetched)` | `.red` | 0 |
| 設定 URL が空で `init` / URL 変更 | `.red(.urlNotConfigured)` | `.red` | 変化なし |
| `tick()` で URL 不一致 | `.red(.notOnSettingsPage)` | `.red` | 変化なし |
| `applyCombinedOutcome` が success 判定、使用率 < 閾値 | `.green(lastSuccessAt: Date())` | `.green` | 0 にリセット |
| `applyCombinedOutcome` が success 判定、session% または weekly% ≥ 閾値 | `.green(lastSuccessAt: Date())` | `.orange`（前回 `.orange` 以外なら通知 1 回発火） | 0 にリセット |
| `applyCombinedOutcome` が failed 判定 | `.red(.recentFailure(count, lastReason))` | `.red` | +1。3 以上で自動リロード |
| `.skipped` のみ | `applyCombinedOutcome` 内で success 扱い | 使用率による | 0 にリセット |
| ボタンクリック後 10 秒で API レスポンスなし | `.red(.recentFailure(count, .apiResponseTimeout))` | `.red` | +1。3 以上で自動リロード |
| 届いた API JSON がプラン判定不能 | `.red(.recentFailure(count, .unknownPlan))` | `.red` | +1。3 以上で自動リロード |

**重要**: `.notOnSettingsPage` と `.urlNotConfigured` は `consecutiveFailureCount` に加算されず、3 回連続失敗リロードの対象外。未ログイン状態での無限リロードループを避けるため。

**StatusBarColor は status の派生**: 上表の `StatusBarColor` 列は `applyStatus` 完了後に `statusBarColor` computed プロパティで再計算される。`notifyIfOrangeTransition()` は `applyStatus` 末尾で呼ばれ、`previousStatusBarColor != .orange && current == .orange` の瞬間に限り通知を送る。

---

## 設定画面の保存方式

`SettingsView` は**編集バッファ方式**を採用する。

### 構造
- `@State` プロパティ（`urlDraft` / `intervalDraft` / `apiEndpointDraft` / `monitoringFileNameDraft`）を画面内に保持
- `onAppear` の `loadDrafts()` で `AppSettings` の現在値をバッファへロード
- フォームの各フィールドはバッファを双方向バインドするだけで、`AppSettings.@Published` には直接書き込まない
- 「SAVE」ボタン押下時のみ `commit()` で一括書き戻し → `AppSettings` の `didSet` が発火し `UserDefaults` と Combine 購読者（`AutomationManager` の interval / url sink）にまとめて通知される
- 「Cancel」ボタン（Esc）は `dismiss()` のみでバッファを破棄

### 挙動上の違い（即時保存 → SAVE/Cancel 方式）
- 入力途中の中間値が `AppSettings` に漏れないため、**タイマー再起動や URL 再ロードは SAVE 時点で 1 回だけ**発生する
- 秒を 1 桁ずつ編集している途中に Timer が走り回るような挙動が抑止される

### 独立した即時実行ボタン
- SAVE / Cancel で commit されるのは**バッファ方式フィールド（URL / 実行間隔 / API エンドポイント / ファイル名 / 警告閾値）のみ**
- 以下は SAVE / Cancel とは別枠の即時動作で、画面上も Save/Cancel 行より下（Divider 区切り）に配置して責務を視覚的に分離する:
  - **ログイン時起動トグル**: 押下即座に `toggleLaunchAtLogin()` を呼び、`SMAppService.mainApp` を register / unregister する。詳細は「ログイン時起動」セクション参照
  - **「セッションをクリアして再読み込み」**: 押下即座に `automation.clearSessionAndReload()` を実行し、`dismiss()` は呼ばない。破壊的操作なので `role: .destructive` を付与

### 新しい設定項目を追加するときの注意
- `AppSettings` にプロパティを追加したら、`SettingsView` では必ず**対応するドラフト `@State` を追加**し、`loadDrafts()` と `commit()` にも反映する
- 直接 `$settings.xxx` で bind してしまうと SAVE / Cancel の対象外になり挙動が混在するため避ける

---

## 外部依存箇所（claude.ai の API / 挙動）

以下の URL パターン・JSON 構造・ボタン要素に依存しているため、claude.ai 側の変更で動作しなくなる可能性がある。

### API エンドポイント依存（`AutomationManager.interceptUsageJS` の傍受対象）
- URL パターン（JS の `USAGE_RE` 正規表現）: `/api/organizations/[^/]+/usage(\?|$)`
- レスポンス JSON の主要キー:
  - `five_hour`（Individual: 5 時間セッション。null の場合あり）
    - `utilization: Double` … 使用率（0〜100）
    - `resets_at: String`（ISO 8601）… `utilization: 0.0` 時は null になり得る
  - `seven_day`（Individual: 週次。null の場合あり）
    - `utilization: Double`
    - `resets_at: String`（ISO 8601）
  - `extra_usage`（Enterprise 判定用）
    - `is_enabled: Bool`
    - `utilization: Double`（Enterprise の月次使用率に使う）
- プラン判定（`classifyPlan`）:
  - `five_hour != nil || seven_day != nil` → `.individual`（片側 null は null フィールドで表現）
  - `five_hour == nil && seven_day == nil && extra_usage.is_enabled == true` → `.enterprise`
  - それ以外 → nil（`.unknownPlan` 失敗）

### 更新ボタン
- `button[aria-label="使用制限を更新"]` … `tick()` で click（ページ側が `/usage` API を叩く契機）

### ナビゲーションループ検出対象 URL（`WebViewCoordinator.decidePolicyFor`）
- URL 文字列に `/login` または `/logout` を含むもの

### セッションリセットに使う API
- `WKWebsiteDataStore.default().removeData(ofTypes: .allWebsiteDataTypes, modifiedSince: .distantPast)` で全クッキー・ストレージを削除

---

## リセット時刻の丸め

API レスポンスの `resets_at`（ISO 8601）を `Date.roundedToNearestHour()` で時間単位に四捨五入する:

- 分 `0〜29` → 切り捨て、`30〜59` → 切り上げ
- 秒は常に無視
- 例: `3:29` → `3:00`、`3:30` → `4:00`、`4:29` → `4:00`

丸めは `AutomationManager.jstCalendar`（JST 固定）で分解・再構築するため、端末 TZ が非 JST でも JST 視点で正しく丸まる。

---

## ループ検出の仕組み

`WebViewCoordinator.decidePolicyFor` 内のステートマシン:

- ステート 0: 初期状態
- ステート 1: `/login` を検出（タイマー開始）
- ステート 2: `/logout` を検出
- ステート 3: `/login` を検出
- ステート 4: `/logout` を検出 → `clearSessionAndReload()` 発火

制約:
- ステップ間の時間は累計 5 秒以内（`loopWindowStart` から 5 秒以内に次のステップが来ないとリセット）
- `/login` と `/logout` 以外の URL（`about:blank`、`*.claude.ai` サブドメイン、`/settings/usage` など）はステート変化に影響しない（無視される）
- `isResetting` フラグで多重トリガー防止。ループ外の URL に到達したら `false` にリセット（次のループも検出可能にする）

### この方式を採る理由
- `/logout` 回数カウント方式では `about:blank` などの中間 URL で counter がリセットされる
- `/login` と `/logout` 以外の URL を完全に無視するステートマシン + 時間ウィンドウ方式にしている
- 5 秒の時間ウィンドウは、通常のログインフロー（数秒）とリダイレクトループ（高速）を区別するため

---

## 失敗検出・自動リカバリの仕組み

### 失敗検出のパス

1. **URL 不一致**（`tick()` 先頭）: `settings.matches(url: webView.url)` で現在 URL のホスト+パスが設定 URL と一致するか確認。不一致なら `applyNotOnSettingsPage()` に流す。**`consecutiveFailureCount` には加算せず**、3 回連続失敗リロードの対象外。
2. **JS 実行失敗**（click JS の `evaluateJavaScript` コールバック）: `applyFailure(reason: .javaScriptError)`。
3. **API レスポンス タイムアウト**（10 秒）: `applyFailure(reason: .apiResponseTimeout)`。ボタンクリック後に `/api/organizations/.../usage` が捕捉できなかった場合（未ログイン・別ページ遷移・サーバ遅延など）。
4. **JSON パース失敗**（`handleCapturedAPIResponse`）: `applyFailure(reason: .jsonParseError)`。
5. **プラン判定不能**: `applyFailure(reason: .unknownPlan)`。
6. **JSON エンコード失敗**・**ファイル書き込み失敗**・**HTTP 非 200**・**通信エラー**も `applyFailure(reason:)` を呼ぶ。

### write と POST の独立実行

`handleCapturedAPIResponse` は取得成功後に以下を**独立して試行**する:

- `writeUsageFileIfNeeded(_:)` → `FileOutcome` を同期的に返す
- `postToAPIIfNeeded(_:completion:)` → 非同期コールバックで `PostOutcome` を返す

片方が失敗しても他方をブロックしない。両方の結果が揃ったら `applyCombinedOutcome(file:post:)` が呼ばれ、**1 tick あたり 1 回だけ** `applyFailure` / `applySuccess` のいずれかを発火する。これにより `consecutiveFailureCount` の二重加算を防ぐ。

集約ルール:
- `file` が `.failed` なら failure（ファイル失敗を優先してログ出力）
- `post` が `.failed` なら failure
- それ以外（両方 `.success` or `.skipped` の組み合わせ）は success

### カウンタとリロード
- `consecutiveFailureCount` が 3 以上 かつ `OAuthPopupController.active.isEmpty` で設定 URL にリロード
- リロード後は `consecutiveFailureCount = 0` にリセット
- 成功時も `consecutiveFailureCount = 0` にリセット
- `.notOnSettingsPage` / `.urlNotConfigured` は count 非加算なので、このパスでは 3 回リロードが発火しない

### OAuth ポップアップ中のリロード抑止
- ポップアップ表示中にリロードすると認証フローが壊れる
- `OAuthPopupController.active` 配列でポップアップ存在を確認

---

## 即時 fetch（起動直後・ログイン後）

`WebViewCoordinator.webView(_:didFinish:)` で設定 URL のページ読み込み完了を検出したら `AutomationManager.scheduleImmediateFetch()` を呼ぶ。

- `DispatchWorkItem` で 5 秒後に `tick()` を実行（click → API レスポンス待機 → パース）
- 既にスケジュール済みのものがあれば `cancel()` してから再設定
- タイマーループとは独立（タイマー間隔の途中でも実行される）

これにより、以下のタイミングで即座にデータが更新される:
- アプリ起動直後（WebView の初回ロード完了後）
- OAuth ログインからの復帰後
- セッションリセット＆リロード後
- 3 回連続失敗からの自動リロード後

---

## Timer ライフサイクル

View 非依存。`AutomationManager.init` 末尾で `DispatchQueue.main.async { [weak self] in self?.start() }` を呼ぶ。以降はアプリ終了までタイマーが走り続ける（明示的な `stop()` はプロセス終了時にも呼ばない方針）。

### Combine 購読による interval / url 変更反映

`AutomationManager.init(settings:logStore:)` で `cancellables` に 2 本 sink を登録:

- `settings.$intervalSeconds.removeDuplicates().dropFirst()` + sink → `DispatchQueue.main.async { self.start() }`
- `settings.$url.removeDuplicates().dropFirst()` + sink → `DispatchQueue.main.async { self.handleURLSettingChanged() }`

View 層から `.onChange` を消したため、ウィンドウが一度も開かれなくても設定変更が反映される。

`handleURLSettingChanged()` は以下を行う:

1. 変更前のページに対する pending fetch を `cancelAllInFlightFetches()` で全てキャンセル
2. URL 空なら `webView.load(URLRequest(url: about:blank))` で WebView を空にしつつ `.urlNotConfigured` に遷移
3. そうでなければ `.urlNotConfigured` で止まっていた status を `.notYetFetched` に戻し、新 URL をロード

タイマーと Combine の落とし穴については別セクション参照。

### 手動更新 (`runManualFetch`)

MenuBarExtra の「手動更新」から呼ばれる公開 API。`cancelAllInFlightFetches()` で pending をクリアしたうえで、設定 URL を `webView.load(URLRequest(url:))` で再ロードする。ロード完了後の `didFinish` → `scheduleImmediateFetch()` → `tick()` の連鎖で「使用制限を更新」ボタンクリック → API レスポンス受信が走る。タイマーのリセットは `tick()` 冒頭で `start()` が呼ばれるため `runManualFetch` 側では行わない（冗長な二重リセット回避）。

### 起動シーケンス

`AutomationManager.init` では初回 URL ロードを直接行わず、`DispatchQueue.main.asyncAfter(deadline: .now() + 5)` で `runManualFetch()` を 1 回だけ予約する。これにより初回ロードも「手動更新 → didFinish → scheduleImmediateFetch → tick」という通常フローに乗り、コードパスが一本化されて二重ロード・二重 `scheduleImmediateFetch` が発生しない。

---

## ログアーキテクチャ

### 目的

本番運用中の挙動追跡とトラブルシュートのため、主要イベントとデバッグ詳細をアプリ内で保持する。ログは `LogStore` 経由のアプリ内ログウィンドウに一本化している（標準出力 `print` は使わない）。

### LogStore 設計

- `@MainActor` 固定の `ObservableObject`。呼び出し側は actor 切替を意識しなくて済む
- `@Published private(set) var entries: [LogEntry]` を SwiftUI View が購読
- 最大 `maxEntries = 1000` の FIFO（`append` 後に `entries.count > maxEntries` なら `removeFirst(excess)`）
- `lineCounter` は起動以降の絶対行番号。`clear()` で 0 にリセット
- `minLevel: LogLevel` はハードコーディングの閾値。デフォルトは `.info`。詳細追跡が必要な際は `.debug` に書き換えて再ビルドする運用

### ディスパッチ方式

`AutomationManager` / `WebViewCoordinator` は非 isolated クラスだが、`LogStore` は `@MainActor`。呼び出し側は以下のヘルパで吸収する:

- `appLog(_:level:)` — 呼び出し元スレッドに関わらず常に `DispatchQueue.main.async` で `LogStore.log(_:level:)` を呼ぶ（`MainActor.assumeIsolated` は `_checkIsolated()` クラッシュのリスクがあるため使わない）
- `appLogDebug` / `appLogWarn` / `appLogError` — level 指定のショートハンド

これにより呼び出し側は `appLog("...")` を気楽に書ける。

### LogEntry.formatted の書式

`NNNNN  HH:mm:ss [LEVEL]  message`（行番号 5 桁ゼロ埋め、スペース 2 個、時刻、スペース 1 個、5 文字固定幅の LEVEL、スペース 2 個、メッセージ）。等幅フォントで揃える前提。`LogLevel.label` は `"INFO "` のようにスペース埋めされた 5 文字固定幅。

### LogView のレンダリング

- 全エントリを `.map(\.formatted).joined(separator: "\n")` で 1 本の `String` にまとめ、単一の `Text` に渡す
- `textSelection(.enabled)` で複数行選択・コピー可
- `ScrollViewReader` と末尾マーカー（`Color.clear` に `id("log-bottom")` を付けた 1px View）を使い、`onChange(of: entries.count)` と `onAppear` で `proxy.scrollTo(..., anchor: .bottom)` を呼んで自動末尾追従
- `withAnimation(.none)` でアニメーションを抑止（スクロール ジャンプを回避）
- 空状態は「ログはまだありません」を中央表示
- ヘッダに `N / 1000 行`、右端に「クリア」ボタン

### ログウィンドウの起動時挙動

`Window("ログ", id: "log")` は `.defaultLaunchBehavior(.suppressed)` + `.windowResizability(.contentMinSize)` を指定し、起動時には開かない。メニュー「ログ」クリックで `openWindow(id: "log")` + `NSApp.activate(ignoringOtherApps: true)` で明示表示する。

---

## タイマーと Combine の落とし穴

### sink 購読順序（`removeDuplicates` → `dropFirst`）

`settings.$intervalSeconds` / `settings.$url` を sink する際、**`removeDuplicates` を先・`dropFirst` を後**に置くのが正しい。理由:

- 初回 subscribe 時に `@Published` の初期値が `removeDuplicates` を通過し `dropFirst` で捨てられる
- 以降の同値再代入は `removeDuplicates` が「前回値と一致」として filter する

逆順（`dropFirst` → `removeDuplicates`）だと `dropFirst` が初回値を捨てたあと `removeDuplicates` の内部状態が「前回値なし」のまま、初回 SAVE で同値再代入が発火してしまう（= タイマー再貼付が無駄に走り、直後の `scheduleImmediateFetch` と競合する）。

### sink クロージャから `settings.xxx` を読まない

SwiftUI の `@Published` は `willSet` タイミング（= プロパティ書き込み**前**）で発火する。sink クロージャ内で `self.settings.intervalSeconds` のように property を読むと古い値が返る。

対応: sink 内では `DispatchQueue.main.async { self.start() }` で一旦 runloop を跨がせ、property 書き込み完了後の値を `start()` 側で `Double(settings.intervalSeconds)` として読む。

### `tick()` 冒頭の `start()`

tick 発火経路（自動 Timer / `scheduleImmediateFetch` / `runManualFetch` 経由）がどれであっても、`tick()` 冒頭で `start()` を呼んで Timer を次の `intervalSeconds` からリセットする。これにより「手動 fetch 完了直後にうっかり Timer が発火して 2 重取得」や「scheduleImmediateFetch で tick した直後に Timer が重ねて発火」のケースを防ぐ。`runManualFetch` 側では `start()` を呼ばない（tick 冒頭のリセットで十分）。

---

## fetch レース回避

reload（手動更新 / セッションクリア / 3 連続失敗自動リロード / URL 設定変更）が走ったとき、in-flight の処理が新ページに引き継がれて誤動作する race を防ぐため、in-flight の WorkItem と pending slot を目的別にキャンセルする仕組みを持つ。

### 対象となる in-flight 状態

| プロパティ | 発生タイミング |
|---|---|
| `immediateFetchWorkItem` | `didFinish` → `scheduleImmediateFetch()` で予約される「5 秒後に `tick()`」の `DispatchWorkItem` |
| `pendingAPIHandler` + `pendingAPITimeoutWorkItem` | `tick()` 内でボタンクリック直前にセットされる API レスポンス待機スロット（= 「使用制限を更新」押下後に届く `/api/organizations/.../usage` レスポンスを拾うためのハンドラと 10 秒 timeout） |

### キャンセルヘルパの責務分離

3 つのヘルパを目的別に呼び分ける。

| ヘルパ | 役割 | 呼び出し元 |
|---|---|---|
| `cancelImmediateFetch()` | 5 秒後 tick 予約のみ破棄 | （内部用） |
| `cancelPendingAPIWait()` | API 応答待機スロット（handler + timeout）を破棄 | `tick()` 冒頭、MessageHandler 内 |
| `cancelAllInFlightFetches()` | 上の両方を一括破棄 | `runManualFetch()` / `clearSessionAndReload()` / `handleURLSettingChanged()` / 3 連続失敗リロード直前 |

`tick()` 冒頭では `cancelPendingAPIWait()` のみを呼ぶ（次の tick が別のクリックを発火する前提なので immediate 予約は触らない）。

### pending slot 方式

「いつ届くか分からない API レスポンスを tick サイクル内でだけ拾う」ため、以下の pending slot 方式を使う:

- `pendingAPIHandler: ((Data) -> Void)?` … レスポンス本体を処理するクロージャ。`tick()` 開始時にセット、タイムアウト or handler 発火で nil へ戻す
- `pendingAPITimeoutWorkItem: DispatchWorkItem?` … 10 秒後に `applyFailure(reason: .apiResponseTimeout)` を発火するフォールバック
- MessageHandler は `pendingAPIHandler` がセット中のときだけ capture を採用し、それ以外は DEBUG ログだけ残して破棄する（tick 外で届いたレスポンスは `consecutiveFailureCount` に影響させない）

---

## API レスポンス傍受方式

claude.ai 内部の `/api/organizations/[^/]+/usage` レスポンスを WebView 内で傍受してデータを取得する。DOM スクレイプは使わない。

### 注入する JS ラッパ

`AutomationManager.interceptUsageJS` が `WKUserScript(injectionTime: .atDocumentStart, forMainFrameOnly: true)` として登録され、`window.fetch` と `window.XMLHttpRequest` をラップする。

- URL が `USAGE_RE = /\/api\/organizations\/[^/]+\/usage(\?|$)/` に一致したときだけ、`response.clone().text()` の結果を `window.webkit.messageHandlers.usageAPI.postMessage({ url, body, status })` で Swift に転送する
- **観測専用（read-only tap）**: 元 response は `clone()` してから読むため page 側の DOM 更新・データフローには干渉しない
- 例外は全て握りつぶす（ラッパが原因でページ挙動を壊さないことを最優先）
- `WKUserContentController` に登録しているため全 navigation で自動再注入される（ページリロード時も気にしなくてよい）
- OAuth ポップアップ側の WebView も `createWebViewWith` 経由で同じ `configuration` を継承するため、script handler が引き継がれる（副作用なし: OAuth ページは `/usage` を叩かない）

### MessageHandler とプラン判定

`AutomationManager` が `WKScriptMessageHandler` に準拠し、`"usageAPI"` 名で受信する。受信した JSON を `classifyPlan(json:)` で分類:

- `five_hour == nil && seven_day == nil && extra_usage.is_enabled == true` → `.enterprise`
- `five_hour != nil || seven_day != nil` → `.individual`
- 両方 null かつ extra_usage 無効 → nil（`.unknownPlan` 失敗）

Individual で片側が null の場合（例: `seven_day` だけ null）は該当フィールドを null として出力し、失敗扱いにしない。`resets_at: null` も `utilization: 0.0` 時などに発生し得るため optional 扱い。

### buildUsagePayload

`classifyPlan` の結果をもとに `UsageData`（JSON 出力）と `UsageSnapshot`（UI 用）を同時に構築する。

- Individual: `five_hour.utilization` → `sessionPct`、`seven_day.utilization` → `weeklyPct`、両方の `resets_at` を `parseISO8601` → `roundedToNearestHour()`
- Enterprise: `extra_usage.utilization` → `sessionPct`、`session_reset_at` は JST の来月 1 日 0:00（`nextMonthFirstAtJST`）、`weeklyPct` / `weeklyResetAt` は nil

### 出力 JSON フォーマット

`JSONEncoder` の `outputFormatting = [.prettyPrinted, .sortedKeys]` + `keyEncodingStrategy = .convertToSnakeCase` により、キー順は `datetime, plan, session_pct, session_reset_at, weekly_pct, weekly_reset_at` の snake_case。nil は必ず `null` として出力（フォーマット一貫性のため `UsageData.encode(to:)` を手書きし、`encode` のオプショナルオーバーロードを使って null 明示）。

### TimeZone 統一

出力 / 表示すべての `DateFormatter` が `Asia/Tokyo` に固定されている（`AutomationManager.dateFormatter` と `MenuContentView.sessionResetFormatter` / `weeklyResetFormatter`）。入力 ISO 8601 は UTC オフセット付きを受け付けるが、`Date` 化されれば絶対時刻の点なので出力側を JST 固定すれば端末 TZ に依存しない。

---

## UsagePlan と UI 分岐

`MenuContentView.summaryRows` が `UsagePlan` に応じてサマリ行の構成を切り替える。

- `.individual` → 4 行: `Session limits (5h): N% / Resets H:mm / Weekly limits: N% / Resets M/d (曜) H:mm`
- `.enterprise` → 2 行: `Monthly limits: N% / Resets M/d (曜) H:mm`（`weeklyResetFormatter` を流用して日付込みで表示）

`lastUsage == nil`（起動直後・失敗時）はプラン不明として `.individual` レイアウトを選び 4 行すべて `----` プレースホルダで埋める。Pro / Max の区別はしない（両方 `.individual`）。

---

## URL 未設定時の WebView リセット

設定画面で URL を空文字に変更した場合、`handleURLSettingChanged()` は WebView に `about:blank` をロードする（`cancelAllInFlightFetches()` を先行実行）。これにより古い `/settings/usage` のページが残って後続の URL 変更後に誤って傍受結果を拾う事故を防ぐ。status は `.urlNotConfigured` に遷移。

---

## API POST -1009 リトライ

起動直後の数秒間は URLSession がネットワーク可用性を把握しきれず、実際はオンラインでも `NSURLErrorNotConnectedToInternet` (-1009) を返すことがある。`postToAPIIfNeeded` / `performPOST` は再帰方式で以下を行う:

- 初回呼び出しは `allowRetry: true` で `performPOST` に委譲
- `dataTask` completion で `NSURLErrorDomain` + `-1009` を検知し、`allowRetry == true` なら 2 秒後に `allowRetry: false` で再呼び出し
- リトライ 1 回限り。2 回目も失敗 or 他のエラーコードは即 `.failed(.networkFailed)` で確定

これにより「起動 5 秒後の初回 `runManualFetch` → API POST が -1009 で失敗」の偽陽性を抑制する。

---

## 使用率警告と通知

メニューバーアイコンの Orange 化と macOS ユーザー通知を組み合わせ、使用率が閾値に近づいたことを知らせる機能。

### 閾値と判定ロジック

- 閾値は `AppSettings.warningThresholdPct`（Int、1〜100%、初期値 90%）。`UserDefaults` キー `warningThresholdPct` で永続化
- 判定は `AutomationManager.statusBarColor` computed プロパティで毎回行う（状態フラグを持たないため常に最新値を反映）
- 比較は `>=`（閾値ちょうどで Orange）。session / weekly のどちらか片方でも越えれば Orange

### アイコン色遷移ルール

`StatusBarColor` の 3 値は `status` と `lastUsage` から決定論的に計算される。`status` が優先され、`.red` の場合は必ず `.red`。成功系（`.green`）のときだけ使用率によって `.green` / `.orange` を切り替える。詳細は「状態モデル > 状態遷移ルール」の表を参照。

### 通知発火の制御

- `AutomationManager.init` 末尾で `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])` を 1 回だけ呼ぶ（初回起動時に macOS が許可ダイアログを出す）
- `applyStatus` の末尾で `notifyIfOrangeTransition()` を呼ぶ
- `previousStatusBarColor` に直前の `StatusBarColor` を保持。現在値が `.orange` で、かつ直前が `.orange` 以外なら 1 回だけ通知を送る。値の更新は `defer` で毎回行う（通知を送ったかどうかに関わらず）
- 通知 content:
  - title: `Claude Usage Warning`
  - body: `Session limits: N%, Weekly limits: M%`（`lastUsage == nil` の場合は `----`）
  - sound: `.default`
  - identifier は UUID 付与で毎回ユニーク化（同一 ID の上書き重複排除を**あえて無効化**し、遷移ごとに独立した通知として扱う）
- 連続発火の抑止: Orange に遷移したあと Green（閾値未満）に戻らない限り、再度 Orange 判定になっても `previousStatusBarColor == .orange` のため通知は出ない
- 通知許可が無くても `UNUserNotificationCenter.add` はエラーをコールバックで返すだけで、monitoring 自体は継続する（サイレント無視）

### ユーザー側の ON / OFF

アプリ内にトグルは設けない。macOS の「システム設定 → 通知 → ClaudeUsageMonitor」からオン／オフする運用とする（macOS の通知ポリシーを単一情報源にするため）。

---

## メニューバーアイコンのシルエット生成

### 素材生成フロー

`Assets.xcassets/StatusBarIcon.imageset/` には以下の 2 解像度 PNG を配置している:

| ファイル | 解像度 | 用途 |
|---|---|---|
| `StatusBarIcon.png` | 22px（1x） | メニューバー標準解像度 |
| `StatusBarIcon@2x.png` | 44px（2x） | Retina ディスプレイ |

生成手順:

1. AppIcon（`AppIcon.appiconset/icon_256.png`）をソースに使う
2. 各ピクセルの luminance を計算し、`threshold = 0.75` で二値化して黒いマスクを作る（暗い領域 = シルエット）
3. マスクの bounding box を算出し、bbox に 10% の margin を足してタイトクロップ（余白をほぼゼロに詰める）
4. 22px と 44px にリサイズして書き出す
5. 色は黒（RGBA: 0,0,0,α）。α はアンチエイリアスを保つためグレースケール→α 置換

### Contents.json

`template-rendering-intent: "template"` を指定して Xcode 側にも「テンプレート素材」であることを明示。

### レンダリング時の色処理

`ClaudeUsageMonitorApp.statusBarIcon(color:)` が `StatusBarColor` を受け取って NSImage を返す:

- `.green` → `NSImage(named: "StatusBarIcon")` を `copy()` してから `isTemplate = true`。macOS がメニューバーのアピアランスに合わせて自動で色（ダーク: 白基調、ライト: 黒基調）を付けるため、通常時はうるさくない見た目になる。コピーを返しているのは他の呼び出しパスで `isTemplate` を書き換えられるリスクを避けるため
- `.orange` / `.red` → base の CGImage を取得し、`NSImage(size:flipped:)` の中で CGContext に `draw(baseCG, in: rect)` → `setBlendMode(.sourceIn)` → `setFillColor(systemOrange / systemRed)` → `fill(rect)` の順で描画。これでシルエットの形状を保ったまま中身だけを任意色に置換できる。仕上げに `isTemplate = false` を設定して macOS のテンプレート処理を切る
- 素材が読み込めない場合のみ `fallbackDotIcon(color:)` で塗り丸（16x16、`insetBy(dx: 3, dy: 3)`、`systemGreen` / `systemOrange` / `systemRed`）に逃げる。存在チェックは `NSImage(named:)` の返り値 nil のみで判定

### SF Symbol を使わない理由

MenuBarExtra の label に SF Symbol を渡す方式では色を確実に反映できない（`Image(systemName:).foregroundStyle(.green)` / `.symbolRenderingMode(.multicolor)` などを試しても MenuBarExtra が template 化してモノクロ固定になる、`Circle().fill(.green)` に差し替えるとアイコン自体が載らなくなるなど）。そのため `NSImage(size:flipped:)` + CGContext の自前描画で状態色を焼き込み、`isTemplate = false` を設定したうえで `Image(nsImage:)` として渡す方式を採用している。

---

## ログイン時起動

設定画面のログイン時起動トグルは `ServiceManagement` フレームワークの `SMAppService.mainApp` を使ってログイン項目への登録/解除を制御する。

### SoT と state の関係
- **真の状態はシステム側（`SMAppService.mainApp.status`）**。アプリ内の `@State var launchAtLogin: Bool` は UI 表示同期用のキャッシュ
- 設定画面の `onAppear` で `SMAppService.mainApp.status == .enabled` を評価して `launchAtLogin` に反映する。システム設定「一般 → ログイン項目」から外部操作された場合も、次回設定画面を開いた時点で同期される
- ボタンのラベル切替（`ログイン時に起動する` / `ログイン時の起動を無効にする`）は `launchAtLogin` の現在値で決定

### register / unregister のフロー
- ボタン押下で `toggleLaunchAtLogin()` が呼ばれ、現在値の反転を内部で計算して `SMAppService.mainApp.register()` / `unregister()` を try する（呼び出し側は反転を気にしなくて済む）
- 成功: INFO ログ（`ログイン時起動: 有効化` / `ログイン時起動: 無効化`）を出し、`launchAtLogin` を要求値に更新
- **`.requiresApproval` 判定**: `register()` 直後に `service.status == .requiresApproval` だった場合は、`ログイン時起動: 承認待ち (システム設定で許可が必要)` を WARN ログし、`SMAppService.openSystemSettingsLoginItems()` でシステム設定を開いてユーザーに次のアクションを促す。UI 上は実態（承認待ち = まだ発動しない）に合わせて `launchAtLogin = false` を維持
- 失敗（catch）: WARN ログ（`ログイン時起動の有効化失敗: ...` / `ログイン時起動の無効化失敗: ...` と操作を区別）を出したうえで、`launchAtLogin` を `SMAppService.mainApp.status == .enabled` の実態に**再同期**する。UI と実態の乖離を残さないため、楽観的な state 更新ではなく必ずシステム側の status を読み直す
- Save/Cancel の対象外なので `commit()` / `loadDrafts()` からは切り離されている

### Ad-hoc 署名時のシステム承認挙動
- 現在の配布は Ad-hoc 署名のみ（`codesign --sign -`）のため、初回 `register()` 時に macOS が「このアプリを許可しますか」相当のシステム承認を要求することがある
- Developer ID 署名 + 公証が整うまでは、この挙動を回避する手段はない（初回だけユーザー操作が必要になる想定）
- `unregister()` 側は承認ダイアログを伴わない

---

## 過去にハマった問題と対応（将来の地雷回避）

現在の設計判断を正当化するために残している注意事項。

### 1. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` によるクラッシュ
- Xcode プロジェクトのビルド設定で `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` が有効だと全クラスが暗黙 `@MainActor` 扱いになり、OAuth 復帰時にバックグラウンドスレッドから `swiftRelease` が走るとクラッシュする
- pbxproj から `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` を Debug / Release 両方から削除した状態を維持する
- 復活させると OAuth 復帰時クラッシュが再発するので注意

### 2. `NSWindow.isReleasedWhenClosed` のデフォルト true 問題
- デフォルトで `true` のため、ウィンドウを閉じた瞬間に ObjC が追加 release を送り、Swift が参照を持っている間に解放される
- `window.isVisible` 参照時に `EXC_BAD_ACCESS`
- **対応**: メインウィンドウ（`AutomationManager.installMainWindow`）・OAuth ポップアップ（`OAuthPopupController.init`）のいずれも生成直後に `window.isReleasedWhenClosed = false` を設定する

### 3. `createWebViewWith` で nil を返すと画面フリーズ
- Apple の `SOAuthorizationCoordinator` は OAuth フローで必ずポップアップ WKWebView を要求する
- nil を返すと UI が固まる
- **対応**: `WebViewCoordinator.webView(_:createWebViewWith:...)` で `OAuthPopupController` を生成して WKWebView を返す

### 4. JSON 出力順が不安定
- `JSONEncoder` のデフォルトでは出力順が保証されない
- **対応**: `outputFormatting = [.prettyPrinted, .sortedKeys]` でキーをアルファベット順に固定

### 5. パストラバーサル脆弱性
- `monitoringFileName` を検証せずに `appendingPathComponent` に渡すと `../../etc/passwd` のような文字列で任意パス書き込みが可能
- **対応**: `(monitoringFileName as NSString).lastPathComponent` でファイル名部分のみに制限

### 6. SwiftUI `Window` Scene + `.defaultLaunchBehavior(.suppressed)` と WKWebView の組み合わせ禁忌（NSWindow 採用の根拠）
- SwiftUI `Window(id:)` + `.defaultLaunchBehavior(.suppressed)` に `NSViewRepresentable` 経由で `WKWebView` を attach する構成だと、ウィンドウが一度も具現化されない状態で WKWebView が NSView 階層に載らず、macOS がレンダリング / JS 実行を throttle する
- 症状: SPA の動的 DOM や fetch 応答が滞り、自動取得が連続失敗する
- `orderOut` / `miniaturize` / 画面外 origin `(-20000, 0)` への `setFrameOrigin` でも「不可視」扱いで throttle されたり、macOS の自動クランプで左下に戻される
- **対応**: `AutomationManager` が AppKit `NSWindow` を所有し、`contentView = webView` で attach したうえで、起動時に `alphaValue = 0` + `ignoresMouseEvents = true` + `orderFrontRegardless` を呼んで**「不可視だが on screen」**として保持する
  - 閉じる操作は `NSWindowDelegate.windowShouldClose` で `false` を返してインターセプトし、`hideMainWindow()`（= `alphaValue = 0` + `ignoresMouseEvents = true`）で代替
  - 「ウィンドウを表示」は `center()` + `alphaValue = 1` + `ignoresMouseEvents = false` + `makeKeyAndOrderFront` + `NSApp.activate` で画面中央へ前面表示
- 補足: `Window("ログ", id: "log")` は WKWebView を載せないため SwiftUI Scene のまま `.defaultLaunchBehavior(.suppressed)` で運用できる（WKWebView を載せた SwiftUI Window だけがダメ）

### 7. `MenuBarExtra` 採用の判断理由
- AppKit `NSStatusItem` + `AppDelegate` 構成は SwiftUI App ライフサイクルと噛み合わず、`@StateObject` を直接購読できない
- `MenuBarExtra` なら `@EnvironmentObject var automation: AutomationManager` で素直に状態バインディングでき、アイコン色・状態ラベルの動的更新が自然
- deployment target が macOS 15+ のため可用性に問題なし

### 8. `LSUIElement = YES` は Info.plist ファイルではなく pbxproj で設定
- `GENERATE_INFOPLIST_FILE = YES` のため独立した Info.plist ファイルは存在しない
- **対応**: pbxproj の `INFOPLIST_KEY_LSUIElement = YES` を Debug / Release 両方に追加する（ビルド時に自動生成される Info.plist に反映される）

### 9. Combine の `.dropFirst().removeDuplicates()` 順序バグ
- `settings.$intervalSeconds` を `dropFirst().removeDuplicates().sink` の順で繋ぐと、初回 SAVE で同値を再代入しても sink が発火する
- 原因: `dropFirst` が初回値を捨てた段階で `removeDuplicates` の内部「前回値」が空のまま。次に来る同値が「変更」と判定される
- **対応**: `.removeDuplicates().dropFirst()` の順に固定。これで初回値が `removeDuplicates` を通って内部状態として保持され、`dropFirst` でそれを捨ててから以降の差分検出が正しく働く

### 10. `@Published` willSet タイミングで property を読むと古い値
- sink のクロージャ内から `self.settings.intervalSeconds` を直接読むと、`@Published` が `willSet` で発火する関係で**更新前の値**が返る
- タイマーが古い interval で再貼付されるなど不整合の原因
- **対応**: sink 内では `DispatchQueue.main.async { self.start() }` のように一旦 runloop を跨がせる。`start()` 側で property を読めば書き込み後の値になる

### 11. tick と Timer の発火時刻バラつき → tick 冒頭で `start()` リセット
- `scheduleImmediateFetch` や `runManualFetch` 経由で tick を即時発火すると、既存の Timer は前回スケジュールのまま走り、2 重発火や微妙な周期ずれが起きる
- **対応**: `tick()` 冒頭で `start()` を呼んで Timer を毎回 `intervalSeconds` からリセット。`runManualFetch` 側では `start()` を呼ばない（冗長回避）
- これにより「手動 fetch 直後に Timer が発火」「scheduleImmediateFetch の直後に Timer が被る」ケースが消える

### 12. 起動直後の URLSession -1009 偽陽性
- アプリ起動 5 秒後の初回 `runManualFetch` → API POST が `NSURLErrorNotConnectedToInternet` (-1009) で失敗することがある
- 実際はオンラインだが URLSession のネットワーク把握が追いつかないタイミング
- **対応**: `performPOST` を再帰化し、`allowRetry: true` の初回呼び出しで -1009 を検出したら 2 秒後に 1 回だけ `allowRetry: false` で再実行。リトライ 1 回限り

### 13. SwiftUI Container 経由で UserDefaults が二重化される
- 非サンドボックス化されたアプリでも、SwiftUI の `Settings` Scene などを経由すると macOS が `~/Library/Containers/<bundle-id>/` を自動生成して別プロセス視点の UserDefaults を使い始めるケースがある
- 症状: `defaults write <bundle-id> key value` で書き換えても反映されない／`defaults delete` しても UI に残り続ける
- **対応**: クリア手順を両方実行する。`defaults delete <bundle-id>` と `rm -rf ~/Library/Containers/<bundle-id>` の両方を揃えないと UserDefaults が完全にはリセットされない
- 新しい永続化キーを追加したあとに挙動確認するときはこの手順で必ずクリーンな状態から検証する

---

## ビルド・コード品質の取り決め

### コードスタイル
- インデント: スペース 2 個（Xcode デフォルト）
- `static let` キャッシュ: `DateFormatter`、`JSONEncoder`、`NSRegularExpression` など
- `[weak self]`: クロージャで `self` を参照する場合、二重キャプチャはしない（内側のみで十分）
- `@MainActor`: 必要最小限。UI View に関連する処理のみ。Combine 購読で `settings.$url` / `settings.$intervalSeconds` を sink する箇所は、SwiftUI の `@Published` が MainActor 上で発行する契約に依存しており、sink クロージャ内で UI / `@Published status` を更新しても MainActor 保証が成立する

### セキュリティ
- API POST に認証ヘッダーなし（将来的に API キー項目を設定に追加予定なら拡張可能）
- `URLSession.shared` を使用（証明書ピンニングなし）
- `monitoringFileName` はパストラバーサル対策で `lastPathComponent` のみ使用

---

## デバッグ方法

### アプリ内ログ（推奨）
メニュー「ログ」で開くログウィンドウが一次情報源。主要イベント・status 遷移・失敗理由が絶対行番号付きで記録される。詳細は「ログアーキテクチャ」セクション参照。`LogStore.minLevel` を `.debug` にすると tick / Timer 発火や個別フィールド変更まで追える。

### 開発用フラグ

ソースコードに直接書かれた開発用フラグ。本番配布前にデフォルト値（`.info` / `false`）に戻すこと。

- `LogStore.minLevel: LogLevel`（`LogStore.swift`）— `.info` → `.debug` にするとタイマー発火・API 受信（URL / status / bytes）・JSON パース結果・プラン判定までログに残る。`usageAPI 受信 [pending|passive] status=... bytes=... url=...` が AJAX 傍受確認の一次情報
- `AutomationManager.enterpriseTestMode: Bool`（`AutomationManager.swift`）— 手元が Individual アカウントでも Enterprise UI / JSON 出力を検証するための一時フラグ。true にすると `extra_usage.is_enabled == true` のレスポンスを (`five_hour` / `seven_day` の有無に関係なく) Enterprise として分類する。動作中は DEBUG ログに `enterpriseTestMode=true: Individual データを Enterprise として強制分類` が出る。`extra_usage.is_enabled` は Pro/Max の設定画面でユーザーが切り替えられるオプションであることを前提にした判定ロジック

### Xcode での確認
- `Debug Navigator` → `View Memory Graph` でメモリリーク確認（`OAuthPopupController.active` の残留チェックなど）

### 手動テスト
- メニューの「手動更新」で任意タイミングで取得実行可能
- 設定画面の「セッションをクリアして再読み込み」ボタンで任意タイミングでセッションリセットをテスト可能
- URL を `https://claude.ai/settings/general` などに一時的に変えて URL 不一致時の `.notOnSettingsPage` 表示を確認可能（戻すのを忘れずに）
- メニュー「ログ」でログウィンドウを開き、tick / Save / fetch 成否のイベントが記録されることを確認

### 主要テスト観点

- ウィンドウを一度も開かずに起動したまま `intervalSeconds` だけ待ち、自動 tick で API レスポンス取得が成功する（アイコンが Green になる）ことを確認
- 「ウィンドウを表示」→ 閉じるボタンで非表示 → `intervalSeconds` 待ち → 依然として自動取得が走り成功することを確認（閉じるボタンは破棄ではなく不可視化）
- ウィンドウをリサイズして閉じ、再度「ウィンドウを表示」で開き直したときにサイズが保持されている（位置は中央に再配置）ことを確認
- 設定画面で URL / 間隔 / ファイル名等を変更したあと、Save を押下するまでモニタリング動作が変わらず、Save 後に即反映されることを確認
- URL を空文字に変更して Save → WebView が `about:blank` に切り替わりアイコンが Red（URL 未設定）になることを確認
- 設定で同じ interval 値を再 Save（変更なし Save）したとき、タイマーが再貼付されず Log に `intervalSeconds 変更を検知` が出ないことを確認（`.removeDuplicates()` の効き）
- Enterprise プラン相当のレスポンス検証には `enterpriseTestMode` フラグ（「開発用フラグ」セクション参照）を一時的に true にして確認

---

## 新機能追加時の注意点

### JSON 出力フィールド追加
1. `UsageData` 構造体にプロパティ追加
2. `UsageData.CodingKeys` と `encode(to:)` にも手書きで追記する（nil を null として出力するため synthesized Codable には戻せない）
3. `AutomationManager.buildUsagePayload(from:)` で API レスポンス JSON から値を取り出し、必要なら `UsageSnapshot` にも追加
4. `JSONEncoder.keyEncodingStrategy = .convertToSnakeCase` によりキーは自動で snake_case 化されるため、Swift 側はキャメルケースで統一
5. プラン（Individual / Enterprise）ごとに値の有無が変わる場合は `buildUsagePayload` の switch 各 case に分けて対応

### API レスポンス JSON キーの追加追跡
- `AutomationManager.buildUsagePayload(from:)` を更新。`json["..."] as? [String: Any]` / `as? Double` など辞書アクセスで追加キーを参照する
- 傍受対象 URL パターンを増やす場合は `interceptUsageJS` 内の `USAGE_RE` を更新
- JS 側の fetch / XHR ラッパが URL マッチに失敗すると Swift 側に何も届かないため、変更後は実機で DEBUG ログ（`usageAPI: pending 外の capture を破棄` や `fetch 成功`）を確認する

### 設定項目追加
1. `AppSettings` に `@Published` プロパティと `didSet` 追加
2. `AppSettings.Keys` enum にキー定数を追加
3. `init()` で `UserDefaults` から読み込み
4. `SettingsView` に対応するドラフト `@State`（編集バッファ）を追加し、`loadDrafts()` と `commit()` にも反映する
5. `SettingsView` の UI はバッファへ双方向バインドすること（直接 `$settings.xxx` で bind しない。SAVE/Cancel の対象外になり挙動が混在する）

### メニュー項目追加
1. `MenuContentView`（`ClaudeUsageMonitorApp.swift`）に `Button` / `SettingsLink` などを追加
2. 並び順は既存（状態ラベル → Divider → ウィンドウを表示 → 手動更新 → 設定… → ログ → Divider → 終了）に揃える
3. クリック不可のラベルが必要な場合は `Text(...).disabled(true)` を使う
4. アクションが `AutomationManager` のメソッドを呼ぶ場合は `@EnvironmentObject var automation` を使用
5. 破壊的操作（セッションクリア等）は原則メニューではなく**設定画面側**に置く方針（誤操作リスク低減）

### 新しい `RedReason` / `FailureReason` 追加
1. `AutomationManager.swift` 末尾の enum に case を追加
2. `AutomationStatus.text` の switch に対応する文言を追加（`RedReason` 追加時）
3. 判定ロジック追加:
   - 新しい Red 状態 → 専用の `applyXxx()` メソッドを追加し、`consecutiveFailureCount` に加算するかどうかを明示
   - 新しい失敗原因 → `applyFailure(reason: .xxx)` を呼ぶ箇所を追加
4. 「`consecutiveFailureCount` に加算するか」「3 回連続失敗リロードの対象にするか」を設計時に必ず決める（`.notOnSettingsPage` / `.urlNotConfigured` パターンは非加算）
5. 必要に応じて本ドキュメントの「状態遷移ルール」テーブルを更新

---

## アプリ配布

### クリーンビルド

```sh
xcodebuild clean build \
  -scheme ClaudeUsageMonitor \
  -configuration Release \
  -derivedDataPath /tmp/ClaudeUsageMonitor_build

cp -R /tmp/ClaudeUsageMonitor_build/Build/Products/Release/ClaudeUsageMonitor.app /path/to/destination/
rm -rf /tmp/ClaudeUsageMonitor_build
```

### コード署名・公証
- 現在は Ad-Hoc 署名のみ（`codesign --sign -`）
- 配布には Developer ID 署名 + Apple 公証 (`xcrun notarytool`) が必要

---

## 既知の制約

- **macOS 15+ 必須**（SwiftUI Scene の `.defaultLaunchBehavior(.suppressed)` を使用しているため）
- `URLSession.shared` 使用のため、証明書ピンニングなし（MITM 耐性なし）
- API POST に認証ヘッダー未対応（送信先は信頼できる環境に限定する想定）
- WKWebView プロセスのサンドボックス由来の警告ログ（`CFPasteboard`, `launchservicesd`, `networkd` 等）が多数出るが無害
- claude.ai の API / URL パターンに依存しているため、サイト側の変更で動作しなくなる可能性あり
- ユーザー通知の許可設定はアプリ内トグルではなく「システム設定 → 通知 → ClaudeUsageMonitor」で管理する方針。初回起動時のみ `UNUserNotificationCenter.requestAuthorization` でダイアログが出る。拒否されても monitoring は継続する（通知のみサイレント無視）
- ログイン時起動は `SMAppService.mainApp` 経由で macOS 13+ のログイン項目 API を使用する。現在は Ad-hoc 署名のみで配布しているため、初回 `register()` で macOS のシステム承認を要求されるケースがある。Developer ID 署名 + 公証が整うまでは回避手段がない
