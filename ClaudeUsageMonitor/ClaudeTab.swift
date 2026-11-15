import AppKit
import ClaudeUsageMonitorCore
import SwiftUI

struct ClaudeTab: View {
  private static let versionDebounce: Duration = .milliseconds(400)

  private enum VersionState: Equatable {
    case loading
    case missing
    case value(String)
    case failed(String)
  }

  private struct VersionRequest: Equatable {
    var executable: URL?
    var count: Int
  }

  private enum TestState: Equatable {
    case idle
    case running
    case finished(String)
  }

  @ObservedObject var settings: AppSettings
  @State private var pathDraft: String
  @State private var configDraft: String
  @State private var version: VersionState = .loading
  @State private var versionRequest = 0
  @State private var test: TestState = .idle
  @State private var testRun = 0

  init(settings: AppSettings) {
    self.settings = settings
    _pathDraft = State(initialValue: settings.claudePath)
    _configDraft = State(initialValue: settings.claudeConfigDirectory)
  }

  private var executable: URL? { settings.resolvedClaudeExecutable }

  private var isConfigInvalid: Bool {
    if case .invalid = settings.configFolderInput { return true }
    return false
  }

  private var isConfigFolderMissing: Bool {
    guard let folder = settings.configFolderInput.folderPath else { return false }
    return !ClaudeConfigFolder.folderExists(folder)
  }

  private var isCacheFileMissing: Bool {
    guard settings.configFolderInput.folderPath != nil, !isConfigFolderMissing, let file = settings.cacheFileURL else { return false }
    return !FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
  }

  private var pathNote: (text: String, isWarning: Bool)? {
    switch settings.claudeExecutable {
    case let .found(url):
      guard settings.claudePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return ("使うパス: \(Self.display(url.path(percentEncoded: false)))", false)
    case .notFound: return ("よくあるインストール先に見つかりません", true)
    case .invalid: return ("無効なパスです", true)
    }
  }

  var body: some View {
    Form {
      SettingsRow("Claude Code CLI のパス：") {
        HStack(spacing: 7) {
          CommittingTextField(draft: $pathDraft, value: settings.claudePath, prompt: "空ならよくあるインストール先から探す") { commitClaudePath($0) }
          Button("選ぶ…") { chooseClaude() }
        }
      }
      SettingsNote(text: pathNote?.text ?? "", isWarning: pathNote?.isWarning ?? false, isSelectable: true)
        .reservingSpace(isShown: pathNote != nil)
      versionBox
      SettingsNote(text: "更新はターミナルで claude update を実行する。")
        .reservingSpace(isShown: executable != nil)

      SettingsRow("CLAUDE_CONFIG_DIR：") {
        CommittingTextField(draft: $configDraft, value: settings.claudeConfigDirectory, prompt: "空なら渡さない") { commitConfigDirectory($0) }
      }
      .settingsRowSpacing()
      // 出し分けても行の高さを変えない。
      ZStack(alignment: .leading) {
        SettingsNote(text: "無効なパスです", isWarning: true)
          .reservingSpace(isShown: isConfigInvalid)
        SettingsNote(text: "このフォルダは存在しません", isWarning: true)
          .reservingSpace(isShown: isConfigFolderMissing)
        SettingsNote(text: "このフォルダに Claude Code の設定が見つかりません", isWarning: true)
          .reservingSpace(isShown: isCacheFileMissing)
      }
      SettingsNote(text: "claude の設定フォルダを既定の場所から変えているときに入れる。")

      SettingsRow("接続テスト：") {
        HStack(spacing: 7) {
          Button("テスト") { runTest() }
            .disabled(test == .running)
          switch test {
          case .idle: EmptyView()
          case .running: ProgressView().controlSize(.small)
          case let .finished(message): Text(message).lineLimit(1).truncationMode(.tail).help(message).textSelection(.enabled)
          }
        }
      }
      .settingsRowSpacing()
      SettingsNote(text: "claude が正常に使える状態かを確かめる。")
        .settingsRowSpacing()
    }
    .settingsFormFrame()
    .task(id: VersionRequest(executable: executable, count: versionRequest)) { await loadVersion() }
  }

  // MARK: - バージョン

  private var versionBox: some View {
    HStack(spacing: 0) {
      Text("バージョン：").foregroundStyle(.secondary)
      switch version {
      case .loading: ProgressView().controlSize(.small)
      case .missing: Text("claude が見つかりません").foregroundStyle(.orange)
      case let .value(text): Text(text)
      case let .failed(detail): Text(detail).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail).help(detail)
      }
      Spacer(minLength: 0)
    }
    .textSelection(.enabled)
    .font(.system(size: 12))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5) }
  }

  private func loadVersion() async {
    guard let executable else {
      version = .missing
      return
    }
    version = .loading
    try? await Task.sleep(for: Self.versionDebounce)
    guard !Task.isCancelled else { return }
    let result = await Task.detached { ClaudeVersion.fetch(executable: executable) }.value
    guard !Task.isCancelled else { return }
    switch result {
    case let .success(text): version = .value(text)
    case let .failure(failure): version = .failed(failure.message)
    }
  }

  // MARK: - 入力

  // 結果はここで消す。値の変化を後から見張って消すと、確定の直後に始めたテストの結果まで消える
  private func commitClaudePath(_ text: String) -> String {
    if text != settings.claudePath {
      settings.claudePath = text
      resetTest()
    }
    return text
  }

  private func commitConfigDirectory(_ text: String) -> String {
    if text != settings.claudeConfigDirectory {
      settings.claudeConfigDirectory = text
      resetTest()
    }
    return text
  }

  private func chooseClaude() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = true
    panel.showsHiddenFiles = true
    if let executable { panel.directoryURL = executable.deletingLastPathComponent() }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let path = url.path(percentEncoded: false)
    _ = commitClaudePath(path)
    // 欄にフォーカスが残っていても、古い下書きが後で確定して選んだ値を戻さないようにする。
    pathDraft = path
  }

  private static func display(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  // MARK: - 接続テスト

  private func resetTest() {
    testRun += 1
    test = .idle
  }

  // ボタンはフォーカスを奪わないので、入力中の値を先に確定する
  private func runTest() {
    _ = commitClaudePath(pathDraft)
    _ = commitConfigDirectory(configDraft)
    versionRequest += 1
    testRun += 1
    let run = testRun
    test = .running
    let executable = settings.claudeExecutable
    let customFolder = settings.configFolderInput
    Task {
      let message = await Task.detached { ClaudeConnection.test(executable: executable, customFolder: customFolder) }.value
      if run == testRun { test = .finished(message) }
    }
  }
}
