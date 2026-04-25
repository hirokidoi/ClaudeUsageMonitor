import SwiftUI
import ServiceManagement

struct SettingsView: View {
  @EnvironmentObject var settings: AppSettings
  @EnvironmentObject var automation: AutomationManager
  @Environment(\.dismiss) private var dismiss

  // 編集バッファ。SAVE で一括書き戻す / Cancel で破棄することで
  // 入力途中での UserDefaults への即時コミットを避ける
  @State private var urlDraft: String = AppSettings.defaultUrl
  @State private var intervalDraft: Int = 300
  @State private var apiEndpointDraft: String = ""
  @State private var monitoringFileNameDraft: String = ""
  @State private var warningThresholdDraft: Int = 90

  // ログイン時起動は Save/Cancel の対象外。SMAppService がシステム側の真実の状態を
  // 持つため onAppear で同期し、Button クリック時に即時 register / unregister を呼ぶ
  @State private var launchAtLogin: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      field(label: "URL", placeholder: AppSettings.defaultUrl, text: $urlDraft)

      VStack(alignment: .leading, spacing: 4) {
        Text("実行間隔").font(.caption).foregroundStyle(.secondary)
        Stepper("\(intervalDraft)秒", value: $intervalDraft, in: 10...86400, step: 10)
      }

      field(label: "APIエンドポイントURL", placeholder: "https://...", text: $apiEndpointDraft)

      VStack(alignment: .leading, spacing: 4) {
        Text("モニタリング用JSONファイル名").font(.caption).foregroundStyle(.secondary)
        TextField("claude_usage.json", text: $monitoringFileNameDraft)
          .textFieldStyle(.roundedBorder)
        Text("保存先: $TMPDIR").font(.caption2).foregroundStyle(.tertiary)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("警告閾値").font(.caption).foregroundStyle(.secondary)
        Stepper("\(warningThresholdDraft)%", value: $warningThresholdDraft, in: 1...100, step: 1)
        Text("session / weekly のいずれかがこの値以上でアイコンがオレンジ").font(.caption2).foregroundStyle(.tertiary)
      }

      // Save/Cancel はバッファ方式のフィールド (上記) に対する確定操作。
      // 下段の即時動作項目より上に置いて責務を視覚的に分離する
      HStack {
        Spacer()
        Button("Cancel") {
          automation.appLogDebug("設定画面: Cancel")
          // 次回オープン時に stale な draft を残さないよう settings に戻しておく
          loadDrafts()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Save") {
          automation.appLogDebug("設定画面: Save")
          commit()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }

      Divider()

      // ここから下は Save/Cancel の対象外 (即時反映される操作)
      Button(launchAtLogin ? "ログイン時の起動を無効にする" : "ログイン時に起動する") {
        toggleLaunchAtLogin()
      }

      Divider()

      Button("セッションをクリアして再読み込み", role: .destructive) {
        automation.clearSessionAndReload()
      }
      Text("ログインできない場合にクッキーをリセットします").font(.caption2).foregroundStyle(.tertiary)

      HStack {
        Spacer()
        Text("version \(Bundle.main.appVersionLabel)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(20)
    .frame(width: 400)
    .onAppear {
      automation.appLogDebug("設定画面 表示")
      loadDrafts()
      // SMAppService の現在状態を反映 (SoT はシステム側)
      launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
  }

  // launchAtLogin の反転と SMAppService 呼び出しを 1 回で完結させる (呼び出し側は反転を気にしない)
  private func toggleLaunchAtLogin() {
    let service = SMAppService.mainApp
    let target = !launchAtLogin
    do {
      if target {
        try service.register()
        // 初回 register 直後は .requiresApproval になり、ユーザーがシステム設定で承認するまで
        // 実際のログイン時起動は発動しない。UI 上は「無効」のままにして承認を促す
        if service.status == .requiresApproval {
          automation.appLogWarn("ログイン時起動: 承認待ち (システム設定で許可が必要)")
          SMAppService.openSystemSettingsLoginItems()
          launchAtLogin = false
        } else {
          automation.appLog("ログイン時起動: 有効化")
          launchAtLogin = true
        }
      } else {
        try service.unregister()
        automation.appLog("ログイン時起動: 無効化")
        launchAtLogin = false
      }
    } catch {
      automation.appLogWarn("ログイン時起動の\(target ? "有効化" : "無効化")失敗: \(error)")
      // 失敗時は実態に再同期
      launchAtLogin = (service.status == .enabled)
    }
  }

  private func loadDrafts() {
    urlDraft = settings.url
    intervalDraft = settings.intervalSeconds
    apiEndpointDraft = settings.apiEndpointUrl
    monitoringFileNameDraft = settings.monitoringFileName
    warningThresholdDraft = settings.warningThresholdPct
  }

  private func commit() {
    if settings.url != urlDraft { automation.appLog("設定変更: url \(settings.url) → \(urlDraft)") }
    if settings.intervalSeconds != intervalDraft { automation.appLog("設定変更: intervalSeconds \(settings.intervalSeconds) → \(intervalDraft)") }
    if settings.apiEndpointUrl != apiEndpointDraft { automation.appLog("設定変更: apiEndpointUrl \(settings.apiEndpointUrl) → \(apiEndpointDraft)") }
    if settings.monitoringFileName != monitoringFileNameDraft { automation.appLog("設定変更: monitoringFileName \(settings.monitoringFileName) → \(monitoringFileNameDraft)") }
    if settings.warningThresholdPct != warningThresholdDraft { automation.appLog("設定変更: warningThresholdPct \(settings.warningThresholdPct) → \(warningThresholdDraft)") }
    settings.url = urlDraft
    settings.intervalSeconds = intervalDraft
    settings.apiEndpointUrl = apiEndpointDraft
    settings.monitoringFileName = monitoringFileNameDraft
    settings.warningThresholdPct = warningThresholdDraft
  }

  @ViewBuilder
  private func field(label: String, placeholder: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      TextField(placeholder, text: text)
        .textFieldStyle(.roundedBorder)
    }
  }
}
