# DEVELOPMENT.md

設計判断・運用ポリシー・外部依存のリスクなどの記録。
クラス構成や個々のメソッドの詳細はソースコード（コメント含む）を参照すること。

---

## アーキテクチャ

### 全体の流れ

```
ClaudeUsageMonitorApp (@main)
  ├─ AppSettings         … UserDefaults 永続化
  ├─ LogStore            … アプリ内ログ（詳細は「ログアーキテクチャ」）
  └─ AutomationManager   … 共有 WKWebView / WebViewCoordinator / メインウィンドウ用 NSWindow を
                          強参照で所有する SoT。タイマー・fetch・状態管理を統括（詳細は各セクション）

Scene 構成 (3 つ):
  ├─ MenuBarExtra              … 常駐アイコン（NSImage 自前描画）+ MenuContentView
  ├─ Window(id: "log")         … LogView（.defaultLaunchBehavior(.suppressed) で起動時は開かない）
  └─ Settings                  … SettingsView

メイン WebView ウィンドウ（SwiftUI Scene ではない）:
  AutomationManager が AppKit NSWindow を直接生成・所有し、共有 WKWebView を attach する。
  SwiftUI Window Scene を使わない理由は「過去にハマった問題 #6」参照。

OAuth ポップアップ（navigationDelegate 経由で生成される別ウィンドウ）:
  OAuthPopupController（ContentView.swift に定義）が NSWindow + WKWebView を生成。
```

※ 正常状態（Normalアイコン時）= green, 警告状態（Orangeアイコン時）= orange, 異常状態（Redアイコン時）= red と表現する。

- `AutomationManager` が `WKWebView` / `WebViewCoordinator` / メインウィンドウ用 `NSWindow` / `LogStore` 参照を**強参照**で所有する（SoT）
- メインウィンドウの不可視化・再表示（閉じる操作のインターセプト、hide/show の実装）は「過去にハマった問題 #6」に理由と仕組みをまとめている
- `WebViewCoordinator` は `AppSettings` / `LogStore` の参照を持ち、ナビゲーション監視・ループ検出に加えて `appLog` 系ヘルパ（AutomationManager と同じディスパッチ方式）でログも記録する
- Timer のライフサイクルは View 非依存。詳細は「Timer ライフサイクル」セクション参照

### 各クラスの責務

各クラスのプロパティ・メソッドはソースコード（およびコメント）を参照。ここではクラス間の役割分担のみを一覧化する。

| クラス / 構造体 | 役割 |
|----------------|------|
| `ClaudeUsageMonitorApp` | SwiftUI エントリポイント。3 つの Scene を宣言し、状態色に応じたメニューバーアイコンを描画する（詳細は「メニューバーアイコンのシルエット生成」） |
| `MenuContentView` | MenuBarExtra の中身。プランに応じた使用率サマリと操作メニューを表示する（詳細は「UsagePlan と UI 分岐」） |
| `LogView` / `LogTextView` | ログウィンドウ UI（詳細は「ログアーキテクチャ」） |
| `LogStore` / `LogEntry` / `LogLevel` | アプリ内ログの保持とレベル定義（詳細は「ログアーキテクチャ」） |
| `OAuthPopupController` | OAuth ポップアップ用の `NSWindow` + `WKWebView`（`ContentView.swift` 内）。ウィンドウクローズをポーリングで検出し `onClose` を呼ぶ |
| `AutomationManager` | 共有 WebView・メインウィンドウ・タイマー・fetch・状態遷移を統括する中核クラス（SoT）。詳細は本ドキュメントの各セクション参照 |
| `WebViewCoordinator` | `WKNavigationDelegate` / `WKUIDelegate`。OAuth ポップアップ生成、即時 fetch のトリガー、ログイン/ログアウトのループ検出を担当 |
| `AppSettings` | `UserDefaults` 永続化。`url` は表示・ログイン用ページ URL（初回ロード / 手動更新 / 自動リロード / OAuth 復帰先）であり、usage データ取得自体はページに依存しない点に注意 |
| `SettingsView` | 設定画面 UI。編集バッファ方式を採用する（詳細は「設定画面の保存方式」） |

---

## 状態モデル

`AutomationManager.swift` 末尾に同居する enum 群。メニューバーアイコン色・状態ラベル・自動リロードのトリガー判定・使用率警告通知を一元化する。

### `AutomationStatus`
- `.green(lastSuccessAt: Date)` — 直近の tick が成功、かつ起動以降に少なくとも 1 回成功している
- `.red(RedReason)` — それ以外

`AutomationStatus.color` が `StatusColor`（`.green` / `.red`）を返し、自動リロード判定などの統計的な成否判定に使う。`AutomationStatus.text` が表示用文言を返す（計算プロパティ。`status` 以外に状態ソースを増やさないため）。`.green` 時の時刻表記は `HH:mm:ss`（`AutomationManager.statusTimeFormatter`）。

### `UsageSnapshot`
`handleUsageResponseBody` が成功したときに `AutomationManager.@Published var lastUsage: UsageSnapshot?` にセットされる UI 用スナップショット。`plan: UsagePlan` / `sessionPct: Int?` / `sessionResetAt: Date?` / `weeklyPct: Int?` / `weeklyResetAt: Date?` を保持し、View 側で好きな書式に整形できる。JSON 出力用の `UsageData`（文字列フィールドでフォーマット済み）とは別立てに分けている（責務分離: JSON シリアライゼーションと UI 表示で必要な型が異なるため、`buildUsagePayload(from:)` が両方を同時に構築して返す）。

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
- `.notYetFetched` — 起動直後で一度も成功していない
- `.urlNotConfigured` — 設定 URL が空
- `.notOnClaudePage` — WebView の現在ページが claude.ai origin でない
- `.loginRequired` — usage fetch の応答から未ログインを陽性検出（401/403、または HTTP 200 だが非 JSON）
- `.recentFailure(count: Int, lastReason: FailureReason)` — 直近 tick が失敗

ユーザー向けの表示文言は `AutomationStatus.text` が case ごとに持つ（README.md の「状態表示」セクションが正）。

### `UsageFetchStage`
2 段 fetch のどちらで失敗したかを表す enum（`.organizations` / `.usage`）。ログと `FailureReason.claudeApiHttpError` の関連付けに使う。

### `FailureReason`
tick サイクルの各失敗原因を enum で表現する。`.recentFailure` の `lastReason` に埋め込まれる。判定は `classifyAndApplyFetchFailure` の 1 箇所に集約する。

- `.javaScriptError` — `callAsyncJavaScript` の completion が失敗、または戻り値が想定外の形
- `.fetchTimeout` — JS 側 `AbortSignal.timeout` によるタイムアウト、または Swift 側 watchdog の発火
- `.fetchNetworkError` — JS fetch の TypeError 等（オフライン・DNS 失敗など）
- `.claudeApiHttpError(stage: UsageFetchStage, status: Int)` — claude.ai API の HTTP 非 200（未ログイン分類に該当しないもの）
- `.orgResolutionFailed` — organizations 応答の構造が想定外（JSON 破損・空配列・uuid 欠落等）
- `.jsonParseError` — usage レスポンス本体の JSON パース失敗
- `.jsonEncodeError` — `UsageData` エンコード失敗
- `.fileWriteFailed` — ファイル書き込み失敗
- `.postHttpFailed(Int)` — API POST（出力側）の HTTP 非 200 系
- `.postNetworkFailed` — API POST（出力側）の通信エラー
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
| `tick()` で claude.ai 以外を表示中 | `.red(.notOnClaudePage)` | `.red` | 変化なし |
| usage fetch が未ログインを検出（401/403 または 200+非JSON） | `.red(.loginRequired)` | `.red` | 変化なし |
| `applyCombinedOutcome` が success 判定、使用率 < 閾値 | `.green(lastSuccessAt: Date())` | `.green` | 0 にリセット |
| `applyCombinedOutcome` が success 判定、session% または weekly% ≥ 閾値 | `.green(lastSuccessAt: Date())` | `.orange`（前回 `.orange` 以外なら通知 1 回発火） | 0 にリセット |
| `applyCombinedOutcome` が failed 判定 | `.red(.recentFailure(count, lastReason))` | `.red` | +1。3 以上で自動リロード |
| `.skipped` のみ | `applyCombinedOutcome` 内で success 扱い | 使用率による | 0 にリセット |
| usage fetch JS の実行失敗・戻り値想定外 | `.red(.recentFailure(count, .javaScriptError))` | `.red` | +1。3 以上で自動リロード |
| JS 側 timeout または Swift 側 watchdog 発火 | `.red(.recentFailure(count, .fetchTimeout))` | `.red` | +1。3 以上で自動リロード |
| 届いた API JSON がプラン判定不能 | `.red(.recentFailure(count, .unknownPlan))` | `.red` | +1。3 以上で自動リロード |

**重要**: `.notOnClaudePage` と `.urlNotConfigured` と `.loginRequired` は `consecutiveFailureCount` に加算されず、3 回連続失敗リロードの対象外。未ログイン状態での無限リロードループを避けるため。

**StatusBarColor は status の派生**: 上表の `StatusBarColor` 列は `applyStatus` 完了後に `statusBarColor` computed プロパティで再計算される。`notifyIfOrangeTransition()` は `applyStatus` 末尾で呼ばれ、`previousStatusBarColor != .orange && current == .orange` の瞬間に限り通知を送る。

---

## 設定画面の保存方式

`SettingsView` は**編集バッファ方式**を採用する。

### 構造
- `@State` プロパティ（`urlDraft` / `intervalDraft` / `apiEndpointDraft` / `monitoringFileNameDraft` / `warningThresholdDraft`）を画面内に保持
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

以下の API パス・JSON 構造に依存しているため、claude.ai 側の変更で動作しなくなる可能性がある（DOM 要素には非依存）。

### API 直接呼び出し先（`AutomationManager.usageFetchJS` が same-origin fetch で呼ぶ）
- `GET /api/organizations` … org uuid 解決。レスポンスは org オブジェクトの配列で、先頭要素の `uuid` を採用する（`cachedOrgUuid` にキャッシュ）
- `GET /api/organizations/{uuid}/usage` … 使用量本体。レスポンス JSON の主要キー:
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

### ナビゲーションループ検出対象 URL（`WebViewCoordinator.decidePolicyFor`）
- URL 文字列に `/login` または `/logout` を含むもの

### セッションリセットに使う API
- `WKWebsiteDataStore.default().removeData(ofTypes: .allWebsiteDataTypes, modifiedSince: .distantPast)` で全クッキー・ストレージを削除

---

## リセット時刻の丸め

API レスポンスの `resets_at`（ISO 8601）を `Date.roundedToNearestTenMinutes()` で 10 分単位に四捨五入する:

- `+5 分` してから 10 分単位で切り捨て（分の 1 桁目を 0 に）することで、最も近い 10 分境界に丸める
- 秒は常に無視
- 例: `15:54` → `15:50`、`15:55` → `16:00`、`15:59` → `16:00`、`16:04` → `16:00`、`16:05` → `16:10`

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

### 失敗判定の一元化

tick サイクルで発生し得る失敗はすべて `classifyAndApplyFetchFailure`（またはページ不一致・URL 未設定・未ログイン用の専用パス `applyNotOnClaudePage` / `applyURLNotConfigured` / `applyLoginRequired`）に集約される。各失敗理由の意味は「状態モデル」の `FailureReason` 一覧を参照。新しい失敗パスを追加する際もこの集約ポイントに寄せること（分散させると「状態遷移ルール」表との整合が崩れる）。

### write と POST の独立実行

`handleUsageResponseBody` は取得成功後に以下を**独立して試行**する:

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
- `.notOnClaudePage` / `.urlNotConfigured` / `.loginRequired` は count 非加算なので、このパスでは 3 回リロードが発火しない

### OAuth ポップアップ中のリロード抑止
- ポップアップ表示中にリロードすると認証フローが壊れる
- `OAuthPopupController.active` 配列でポップアップ存在を確認

---

## 即時 fetch（起動直後・ログイン後）

`WebViewCoordinator.webView(_:didFinish:)` で claude.ai 到達（`AutomationManager.isClaudeAiPage`）を検出したら `AutomationManager.scheduleImmediateFetch()` を呼ぶ。

- `DispatchWorkItem` で `postLoadDelaySeconds` 秒後に `tick()` を実行（tick → 2 段 fetch → パース）
- 既にスケジュール済みのものがあれば `cancel()` してから再設定（ログイン直後の複数ナビゲーション等で didFinish が連発しても tick は 1 回に coalesce される）
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

MenuBarExtra の「手動更新」から呼ばれる公開 API。`cancelAllInFlightFetches()` で pending をクリアしたうえで、設定 URL を about:blank を挟む 2 ステップナビゲーションでフルリロードする（「fetch レース回避」節参照）。ロード完了後の `didFinish` → `scheduleImmediateFetch()` → `tick()` の連鎖で 2 段 fetch → パースが走る。タイマーのリセットは `tick()` 冒頭で `start()` が呼ばれるため `runManualFetch` 側では行わない（冗長な二重リセット回避）。usage データ取得自体はページ再描画に依存しないが、リロードには「未ログイン時に `/login` へのリダイレクトをナビゲーションレベルで露見させる」副次効果があり、`.loginRequired`（fetch 応答からの陽性検出）と併存して働く。

### 起動シーケンス

`AutomationManager.init` では初回 URL ロードを直接行わず、`DispatchQueue.main.asyncAfter(deadline: .now() + 5)` で `runManualFetch()` を 1 回だけ予約する。ログイン項目起動直後はネットワークが未確立のことがあり、初回ページロードの成功率を上げるための猶予として機能する。これにより初回ロードも「手動更新 → didFinish → scheduleImmediateFetch → tick」という通常フローに乗り、コードパスが一本化されて二重ロード・二重 `scheduleImmediateFetch` が発生しない。

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

ログ本文は `LogTextView`（`NSViewRepresentable` で `NSTextView` をラップ）で描画する。SwiftUI `Text` + `.textSelection(.enabled)` を使わない理由は「過去にハマった問題 #14」参照（1000 行規模で CPU 100% になった実績があるため、この選択は意図的な制約であり Text へ戻すべきではない）。

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

reload（手動更新 / セッションクリア / 3 連続失敗自動リロード / URL 設定変更）が走ったとき、in-flight の処理が新ページに引き継がれて誤動作する race を防ぐため、in-flight の WorkItem と usage fetch を目的別にキャンセルする仕組みを持つ。

### 対象となる in-flight 状態

| プロパティ | 発生タイミング |
|---|---|
| `immediateFetchWorkItem` | `didFinish` → `scheduleImmediateFetch()` で予約される「postLoadDelaySeconds 秒後に `tick()`」の `DispatchWorkItem` |
| `usageFetchGeneration` + `usageFetchWatchdogWorkItem` | `beginUsageFetch()` で発行する 2 段 fetch (organizations → usage) の世代番号と、その watchdog `DispatchWorkItem` |

### キャンセルヘルパの責務分離

3 つのヘルパを目的別に呼び分ける。

| ヘルパ | 役割 | 呼び出し元 |
|---|---|---|
| `cancelImmediateFetch()` | postLoadDelaySeconds 秒後 tick 予約のみ破棄 | （内部用） |
| `invalidateInFlightFetch()` | in-flight の usage fetch を無効化する（世代番号を進め、watchdog をキャンセル） | `beginUsageFetch()` 冒頭、completion / watchdog 反映前 |
| `cancelAllInFlightFetches()` | 上の両方 + `pendingLoadURL` を一括破棄 | `runManualFetch()` / `clearSessionAndReload()` / `handleURLSettingChanged()` / 3 連続失敗リロード直前 |

### 世代番号方式

「in-flight の usage fetch の結果を 1 tick あたり 1 回だけ反映し、reload/キャンセル後に届いた古い結果を無効化する」ため、`usageFetchGeneration`（Int）を使う:

- `beginUsageFetch()` が `invalidateInFlightFetch()` で世代を進めてから発行時点の世代を記録する
- `callAsyncJavaScript` の completion と watchdog はどちらも、反映前に記録した世代と現在の `usageFetchGeneration` が一致するかを確認する。不一致なら何もせず破棄する
- 先着した側（completion または watchdog）が `invalidateInFlightFetch()` を呼んで世代をさらに進めるため、後から届いた側は不一致になり反映されない
- reload 系操作は `cancelAllInFlightFetches()` 経由で世代を進めるため、reload 前に発行された in-flight の fetch は完了しても状態に反映されない

---

## API 直接呼び出し方式

claude.ai の使用量 API を WebView 内の JS で直接呼び出してデータを取得する。DOM スクレイプは使わない。

### usageFetchJS（2 段 fetch）

`AutomationManager.usageFetchJS` を `webView.callAsyncJavaScript` の async function body として実行する（`contentWorld: .defaultClient`）。

- `orgUuid`（未解決時は空文字）/ `timeoutMs` / `previewLength` を `arguments` で注入する
- `orgUuid` が空なら `GET /api/organizations` で org 一覧を取得し、先頭要素の `uuid` を採用する（org 選択ポリシーは JS 内 1 箇所に閉じ込め、複数 org 対応時はここを設定値参照に差し替える）
- 続けて `GET /api/organizations/{uuid}/usage` を実行する
- JS は **reject せず**、常に plist 互換の flat な辞書を resolve で返す（`{ ok, stage, kind, status, contentType, redirected, bodyHead, body, ... }`）。JS は「機構と生の事実」だけを返し、失敗の意味づけ（未ログイン判定・カウント加算）は Swift 側の `classifyAndApplyFetchFailure` に集約する
- 各 fetch には `AbortSignal.timeout(timeoutMs)` を指定し、タイムアウト時は `kind: "timeout"` で resolve する
- fetch はドキュメント相対パスで発行する（same-origin が自動成立し、ホスト名を JS 内へハードコードしない）

### 世代管理と watchdog

`beginUsageFetch()` が世代番号を進めてから fetch を発行し、`callAsyncJavaScript` の completion は main thread で世代一致を確認してから 1 回だけ結果を反映する（詳細は「fetch レース回避」節）。`fetchWatchdogSeconds`（`fetchTimeoutSeconds * 2 + 5` から導出）は completion が呼ばれないケース（WebContent プロセス不調等）に備えた Swift 側の最終上限で、発火時は世代を無効化してから `applyFailure(reason: .fetchTimeout)` する。

### org uuid キャッシュ

`cachedOrgUuid` に解決済みの org uuid を保持し、以降の tick では organizations 段をスキップする。無効化するのは次の 3 箇所:

1. `clearSessionAndReload()`（セッションが変われば org も変わり得るため。`removeData` 完了ハンドラ内でも再度破棄し、クリア中に走った tick による再キャッシュを防ぐ）
2. `applyLoginRequired()`（再ログイン後は別アカウントの可能性があるため）
3. usage fetch の HTTP 404（org 消滅・権限喪失。次 tick で再解決させる）

### handleUsageFetchResult とプラン判定

`beginUsageFetch()` の completion が受け取った辞書を `handleUsageFetchResult(_:)` が解釈する。`ok == true` かつ `contentType` が JSON なら usage の body（文字列）を `Data` 化して `handleUsageResponseBody(_:)` に渡し、`classifyPlan(json:)` で分類する。判定条件は「外部依存箇所」セクションのプラン判定を参照。

Individual で片側が null の場合（例: `seven_day` だけ null）は該当フィールドを null として出力し、失敗扱いにしない。`resets_at: null` も `utilization: 0.0` 時などに発生し得るため optional 扱い。`ok == true` でも `contentType` が非 JSON（ログイン HTML へのリダイレクト等）なら未ログイン扱い（`applyLoginRequired()`）とする。

### buildUsagePayload

`classifyPlan` の結果をもとに `UsageData`（JSON 出力）と `UsageSnapshot`（UI 用）を同時に構築する。

- Individual: `five_hour.utilization` → `sessionPct`、`seven_day.utilization` → `weeklyPct`、両方の `resets_at` を `parseISO8601` → `roundedToNearestTenMinutes()`
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

設定画面で URL を空文字に変更した場合、`handleURLSettingChanged()` は WebView に `about:blank` をロードする（`cancelAllInFlightFetches()` を先行実行）。`about:blank` は claude.ai origin ではないため、この間に tick が走っても `isClaudeAiPage` ガードで skip される。status は `.urlNotConfigured` に遷移。

---

## 使用率警告と通知

メニューバーアイコンの Orange 化と macOS ユーザー通知を組み合わせ、使用率が閾値に近づいたことを知らせる機能。

### 閾値と判定ロジック

- 閾値は `AppSettings.warningThresholdPct`（1〜100% の範囲で `UserDefaults` に永続化。初期値は同プロパティの宣言を参照）
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

`ClaudeUsageMonitorApp.statusBarIcon(color:)` が状態色に応じて NSImage を返す。green は `isTemplate = true` で macOS 標準のテンプレート処理（ダーク/ライトに応じた自動配色）に委ね、orange / red は CGContext の `.sourceIn` ブレンドでシルエット形状を保ったまま塗り色だけ差し替える（`isTemplate = false` で固定色化）。素材が読み込めない場合のみ塗り丸へフォールバックする。実装の詳細はソースコードのコメントを参照。

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

### 14. SwiftUI `Text` + `.textSelection` の大量テキストで CPU 100%
- ログ全行を結合した巨大文字列を `Text` + `.textSelection(.enabled)` に渡す構成にすると、マウスホバー・スクロールのたびに全行ヒットテスト＋グリフジオメトリ計算が走り、1000 行規模で CPU 100% に張り付く
- **対応**: `LogTextView`（`NSViewRepresentable` で `NSTextView` をラップ）に置き換える。`NSTextView` はネイティブのテキストエンジンを使うため大量テキストでも選択・スクロールが軽量
- ログ表示に限らず、大量テキストを選択可能な形で表示する UI を今後追加する場合はこの地雷を踏まないよう `Text` + `.textSelection` を避ける

---

## ビルド・コード品質の取り決め

### コードスタイル
- インデント: スペース 2 個（Xcode デフォルト）
- `static let` キャッシュ: `DateFormatter`、`JSONEncoder`、`ISO8601DateFormatter` など、生成コストのあるオブジェクトは使い回す
- `[weak self]`: クロージャで `self` を参照する場合、二重キャプチャはしない（内側のみで十分）
- `@MainActor`: 必要最小限。UI View に関連する処理のみ。Combine 購読で `settings.$url` / `settings.$intervalSeconds` を sink する箇所は、SwiftUI の `@Published` が MainActor 上で発行する契約に依存しており、sink クロージャ内で UI / `@Published status` を更新しても MainActor 保証が成立する

セキュリティ上の既知の非対応事項（認証ヘッダー・証明書ピンニング等）は「既知の制約」セクション参照。

---

## デバッグ方法

### アプリ内ログ（推奨）
メニュー「ログ」で開くログウィンドウが一次情報源。主要イベント・status 遷移・失敗理由が絶対行番号付きで記録される。詳細は「ログアーキテクチャ」セクション参照。`LogStore.minLevel` を `.debug` にすると tick / Timer 発火や個別フィールド変更まで追える。

### 開発用フラグ

ソースコードに直接書かれた開発用フラグ。本番配布前にデフォルト値（`.info` / `false`）に戻すこと。

- `LogStore.minLevel: LogLevel`（`LogStore.swift`）— `.info` → `.debug` にするとタイマー発火・usage fetch 開始・org uuid 解決・JSON パース結果・プラン判定までログに残る。`usage fetch 失敗詳細: stage=... kind=... status=... contentType=... redirected=... bodyHead=...` が fetch 失敗の切り分けの一次情報
- `AutomationManager.enterpriseTestMode: Bool`（`AutomationManager.swift`）— 手元が Individual アカウントでも Enterprise UI / JSON 出力を検証するための一時フラグ。true にすると `extra_usage.is_enabled == true` のレスポンスを (`five_hour` / `seven_day` の有無に関係なく) Enterprise として分類する。動作中は DEBUG ログに `enterpriseTestMode=true: Individual データを Enterprise として強制分類` が出る。`extra_usage.is_enabled` は Pro/Max の設定画面でユーザーが切り替えられるオプションであることを前提にした判定ロジック

### Xcode での確認
- `Debug Navigator` → `View Memory Graph` でメモリリーク確認（`OAuthPopupController.active` の残留チェックなど）

### 手動テスト
- メニューの「手動更新」で任意タイミングで取得実行可能
- 設定画面の「セッションをクリアして再読み込み」ボタンで任意タイミングでセッションリセットをテスト可能
- URL を `https://example.com` などクラウド外に一時的に変えて `.notOnClaudePage` 表示を確認可能（戻すのを忘れずに）
- メニュー「ログ」でログウィンドウを開き、tick / Save / fetch 成否のイベントが記録されることを確認

### 主要テスト観点

- ウィンドウを一度も開かずに起動したまま `intervalSeconds` だけ待ち、自動 tick で usage fetch が成功する（アイコンが Green になる。2 tick 目以降は `usage fetch 開始 (org=<uuid>)` の DEBUG ログで org uuid キャッシュが効いていることを確認できる）ことを確認
- 「ウィンドウを表示」→ 閉じるボタンで非表示 → `intervalSeconds` 待ち → 依然として自動取得が走り成功することを確認（閉じるボタンは破棄ではなく不可視化）
- ウィンドウをリサイズして閉じ、再度「ウィンドウを表示」で開き直したときにサイズが保持されている（位置は中央に再配置）ことを確認
- 手動更新: about:blank → 設定 URL の 2 段ナビでフルリロードされ、didFinish → 即時 fetch で取得成功すること
- セッションクリア → org uuid キャッシュ破棄（次回 fetch で `org uuid 解決` が再度出る）→ ログイン画面 → `.loginRequired` になることを確認
- `.loginRequired` 中は `consecutiveFailureCount` が増えず自動リロードも走らないこと。ログイン完了後は didFinish → 自動復帰すること
- 設定画面で URL / 間隔 / ファイル名等を変更したあと、Save を押下するまでモニタリング動作が変わらず、Save 後に即反映されることを確認
- URL を空文字に変更して Save → WebView が `about:blank` に切り替わりアイコンが Red（URL 未設定）になることを確認
- 設定で同じ interval 値を再 Save（変更なし Save）したとき、タイマーが再貼付されず Log に `intervalSeconds 変更を検知` が出ないことを確認（`.removeDuplicates()` の効き）
- 3 連続失敗の自動リロード: ネットワーク切断等で `.fetchNetworkError` または `.fetchTimeout` が 3 回続きリロードが走ることを確認
- reload 系操作（手動更新 / セッションクリア / URL 変更）直後に古い fetch 結果が反映されないこと（世代管理）を確認
- OAuth ポップアップの生成・閉じ → settings.url ロード → 即時 fetch の連鎖を確認
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
- `usageFetchJS` の呼び出し先パス（organizations / usage）を変更する場合は `AutomationManager.usageFetchJS` を直接更新する
- 変更後は実機で DEBUG ログ（`usage fetch 開始` / `org uuid 解決` / `usage JSON パース成功 keys:` / `fetch 成功`）を確認する

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
4. 「`consecutiveFailureCount` に加算するか」「3 回連続失敗リロードの対象にするか」を設計時に必ず決める（`.notOnClaudePage` / `.urlNotConfigured` / `.loginRequired` パターンは非加算）
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
- claude.ai の API パスとレスポンス JSON 構造に依存しているため、サイト側の変更で動作しなくなる可能性あり（DOM 要素には非依存）
- ユーザー通知の許可設定はアプリ内トグルではなく「システム設定 → 通知 → ClaudeUsageMonitor」で管理する方針。初回起動時のみ `UNUserNotificationCenter.requestAuthorization` でダイアログが出る。拒否されても monitoring は継続する（通知のみサイレント無視）
- ログイン時起動は `SMAppService.mainApp` 経由で macOS 13+ のログイン項目 API を使用する。現在は Ad-hoc 署名のみで配布しているため、初回 `register()` で macOS のシステム承認を要求されるケースがある。Developer ID 署名 + 公証が整うまでは回避手段がない
