import SwiftUI
import AppKit

struct OutputTab: View {
  @ObservedObject var settings: AppSettings
  let automation: AutomationManager

  @State private var fileNameDraft: String
  @State private var endpointDraft: String

  init(settings: AppSettings, automation: AutomationManager) {
    self.settings = settings
    self.automation = automation
    _fileNameDraft = State(initialValue: settings.monitoringFileName)
    _endpointDraft = State(initialValue: settings.apiEndpointUrl)
  }

  var body: some View {
    Form {
      SettingsRow("JSON の保存先：") {
        VStack(alignment: .leading, spacing: 6) {
          Picker("", selection: $settings.outputDirectoryMode) {
            Text("$TMPDIR").tag(OutputDirectoryMode.tmp)
            Text("任意のフォルダ").tag(OutputDirectoryMode.custom)
          }
          .pickerStyle(.radioGroup)
          .labelsHidden()
          HStack(spacing: 7) {
            Button("選ぶ…") { chooseOutputDirectory() }
            Text(settings.customOutputDirectory)
              .font(.system(size: SettingsMetrics.noteFontSize))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
              .help(settings.customOutputDirectory)
          }
          .padding(.leading, 20)
          .disabled(settings.outputDirectoryMode != .custom)
        }
      }
      SettingsNote(text: "フォルダが選ばれていません", isWarning: true)
        .reservingSpace(isShown: settings.outputDirectoryMode == .custom && settings.customOutputDirectory.isEmpty)

      SettingsRow("JSON のファイル名：") {
        CommittingTextField(draft: $fileNameDraft, value: settings.monitoringFileName, prompt: "claude_usage.json") { commitFileName($0) }
      }
      .settingsRowSpacing()
      SettingsNote(text: "空なら保存しない。")

      SettingsRow("API エンドポイント URL：") {
        CommittingTextField(draft: $endpointDraft, value: settings.apiEndpointUrl, prompt: "https://...") { commitEndpoint($0) }
      }
      .settingsRowSpacing()
      SettingsNote(text: "空なら送らない。")
    }
    .settingsFormFrame()
    .onChange(of: settings.outputDirectoryMode) {
      automation.probeOutputDirectory()
    }
  }

  private func commitFileName(_ text: String) -> String {
    settings.monitoringFileName = text
    automation.probeOutputDirectory()
    return text
  }

  private func commitEndpoint(_ text: String) -> String {
    settings.apiEndpointUrl = text
    return text
  }

  private func chooseOutputDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if !settings.customOutputDirectory.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: settings.customOutputDirectory, isDirectory: true)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    settings.customOutputDirectory = url.path
    automation.probeOutputDirectory()
  }
}
