import SwiftUI
import ServiceManagement

struct GeneralTab: View {
  @ObservedObject var settings: AppSettings
  let automation: AutomationManager

  // SMAppService がシステム側の真実の状態を持つので、開くたび・操作のたびに読み直す
  @State private var launchAtLogin = false

  init(settings: AppSettings, automation: AutomationManager) {
    self.settings = settings
    self.automation = automation
  }

  var body: some View {
    Form {
      SettingsRow("更新間隔：") {
        NumberField(value: $settings.intervalMinutes, range: AppSettings.intervalMinutesRange, unit: "分")
      }
      SettingsNote(text: "0 にすると自動更新しない (手動更新のみ。メニューの「自動更新」も表示されない)。")

      SettingsRow("警告閾値：") {
        NumberField(value: $settings.warningThresholdPct, range: AppSettings.warningThresholdRange, unit: "%")
      }
      .settingsRowSpacing()
      SettingsNote(text: "session / weekly (Enterprise は monthly) のいずれかがこの値以上でアイコンが Orange になる。")

      SettingsRow("取得失敗の許容回数：") {
        NumberField(value: $settings.failureTolerance, range: AppSettings.failureToleranceRange, unit: "回")
      }
      .settingsRowSpacing()
      SettingsNote(text: "取得失敗がこの回数続くとアイコンを Red にして通知する。更新間隔が短すぎると CLI が取り直さず失敗に数えられるので、そのときは更新間隔かこの回数を調整する。")

      SettingsRow("外観：") {
        Picker("", selection: $settings.appearance) {
          ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      .settingsRowSpacing()

      SettingsRow("ログイン時に起動：") {
        Toggle("", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
          .labelsHidden()
      }
      .settingsRowSpacing()
    }
    .settingsFormFrame()
    .onAppear {
      automation.appLogDebug("設定画面 表示")
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }

  private func setLaunchAtLogin(_ target: Bool) {
    let service = SMAppService.mainApp
    do {
      if target {
        try service.register()
        // 初回 register 直後は .requiresApproval になり、ユーザーがシステム設定で承認するまで
        // 実際のログイン時起動は発動しない。表示はオフのままにして承認を促す
        if service.status == .requiresApproval {
          automation.appLogWarn("ログイン時起動: 承認待ち (システム設定で許可が必要)")
          SMAppService.openSystemSettingsLoginItems()
        } else {
          automation.appLog("ログイン時起動: 有効化")
        }
      } else {
        try service.unregister()
        automation.appLog("ログイン時起動: 無効化")
      }
    } catch {
      automation.appLogWarn("ログイン時起動の\(target ? "有効化" : "無効化")失敗: \(error)")
    }
    launchAtLogin = service.status == .enabled
  }
}
