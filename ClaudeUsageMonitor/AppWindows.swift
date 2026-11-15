import AppKit
import Combine

// 設定と About のウィンドウを持ち、外観を NSApp に当てる。
@MainActor
final class AppWindows: ObservableObject {
  private let settings: AppSettings
  private let automation: AutomationManager
  private lazy var settingsController = SettingsWindowController(settings: settings, automation: automation)
  private lazy var aboutController = AboutWindowController()
  private var cancellables = Set<AnyCancellable>()

  init(settings: AppSettings, automation: AutomationManager) {
    self.settings = settings
    self.automation = automation
    // 配信された値を使う (@Published は willSet で発火する)。アプリの起動の途中では当てない
    settings.$appearance
      .sink { choice in
        DispatchQueue.main.async { NSApplication.shared.appearance = choice.nsAppearance }
      }
      .store(in: &cancellables)
  }

  func showSettings() {
    settingsController.show()
  }

  func showAbout() {
    aboutController.show()
  }
}
