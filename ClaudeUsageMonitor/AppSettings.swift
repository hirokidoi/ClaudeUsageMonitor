import Foundation
import Combine
import AppKit
import ClaudeUsageMonitorCore

extension Bundle {
  // "1.0 (1)" 形式。起動ログなどで共通利用
  var appVersionLabel: String {
    let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(short) (\(build))"
  }

  var appName: String {
    object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ClaudeUsageMonitor"
  }
}

enum OutputDirectoryMode: String {
  case tmp
  case custom
}

enum AppearanceChoice: String, CaseIterable {
  case system
  case light
  case dark

  var title: String {
    switch self {
    case .system: return "自動"
    case .light: return "ライト"
    case .dark: return "ダーク"
    }
  }

  // nil = OS の外観に従う
  var nsAppearance: NSAppearance? {
    switch self {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }
}

class AppSettings: ObservableObject {
  // 既定と範囲。0 は自動更新しない
  static let defaultIntervalMinutes = 5
  static let intervalMinutesRange = 0...300
  static let defaultWarningThresholdPct = 90
  static let warningThresholdRange = 1...100
  static let defaultFailureTolerance = 3
  static let failureToleranceRange = 1...10

  private enum Keys {
    static let intervalMinutes = "intervalMinutes"
    static let autoRefreshEnabled = "autoRefreshEnabled"
    static let warningThresholdPct = "warningThresholdPct"
    static let failureTolerance = "failureTolerance"
    static let appearance = "appearance"
    static let claudePath = "claudePath"
    static let claudeConfigDirectory = "claudeConfigDirectory"
    static let apiEndpointUrl = "apiEndpointUrl"
    static let monitoringFileName = "monitoringFileName"
    static let outputDirectoryMode = "outputDirectoryMode"
    static let customOutputDirectory = "customOutputDirectory"
  }

  @Published var intervalMinutes: Int = AppSettings.defaultIntervalMinutes {
    didSet { UserDefaults.standard.set(intervalMinutes, forKey: Keys.intervalMinutes) }
  }
  @Published var autoRefreshEnabled = true {
    didSet { UserDefaults.standard.set(autoRefreshEnabled, forKey: Keys.autoRefreshEnabled) }
  }
  var isAutoRefreshActive: Bool { autoRefreshEnabled && intervalMinutes > 0 }
  // この値以上の使用率になったらアイコンをオレンジにして警告する閾値 (% 整数)
  @Published var warningThresholdPct: Int = AppSettings.defaultWarningThresholdPct {
    didSet { UserDefaults.standard.set(warningThresholdPct, forKey: Keys.warningThresholdPct) }
  }
  @Published var failureTolerance: Int = AppSettings.defaultFailureTolerance {
    didSet { UserDefaults.standard.set(failureTolerance, forKey: Keys.failureTolerance) }
  }
  @Published var appearance: AppearanceChoice = .system {
    didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
  }
  @Published var claudePath: String = "" {
    didSet { UserDefaults.standard.set(claudePath, forKey: Keys.claudePath) }
  }
  @Published var claudeConfigDirectory: String = "" {
    didSet { UserDefaults.standard.set(claudeConfigDirectory, forKey: Keys.claudeConfigDirectory) }
  }
  @Published var apiEndpointUrl: String = "" {
    didSet { UserDefaults.standard.set(apiEndpointUrl, forKey: Keys.apiEndpointUrl) }
  }
  @Published var monitoringFileName: String = "" {
    didSet { UserDefaults.standard.set(monitoringFileName, forKey: Keys.monitoringFileName) }
  }
  @Published var outputDirectoryMode: OutputDirectoryMode = .tmp {
    didSet { UserDefaults.standard.set(outputDirectoryMode.rawValue, forKey: Keys.outputDirectoryMode) }
  }
  @Published var customOutputDirectory: String = "" {
    didSet { UserDefaults.standard.set(customOutputDirectory, forKey: Keys.customOutputDirectory) }
  }

  init() {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: Keys.intervalMinutes) != nil {
      intervalMinutes = Self.clamped(defaults.integer(forKey: Keys.intervalMinutes), Self.intervalMinutesRange)
    }
    if defaults.object(forKey: Keys.autoRefreshEnabled) != nil {
      autoRefreshEnabled = defaults.bool(forKey: Keys.autoRefreshEnabled)
    }
    if defaults.object(forKey: Keys.warningThresholdPct) != nil {
      warningThresholdPct = Self.clamped(defaults.integer(forKey: Keys.warningThresholdPct), Self.warningThresholdRange)
    }
    if defaults.object(forKey: Keys.failureTolerance) != nil {
      failureTolerance = Self.clamped(defaults.integer(forKey: Keys.failureTolerance), Self.failureToleranceRange)
    }
    if let saved = defaults.string(forKey: Keys.appearance), let choice = AppearanceChoice(rawValue: saved) {
      appearance = choice
    }
    if let saved = defaults.string(forKey: Keys.claudePath) {
      claudePath = saved
    }
    if let saved = defaults.string(forKey: Keys.claudeConfigDirectory) {
      claudeConfigDirectory = saved
    }
    if let saved = defaults.string(forKey: Keys.apiEndpointUrl) {
      apiEndpointUrl = saved
    }
    if let saved = defaults.string(forKey: Keys.monitoringFileName) {
      monitoringFileName = saved
    }
    if let saved = defaults.string(forKey: Keys.outputDirectoryMode), let mode = OutputDirectoryMode(rawValue: saved) {
      outputDirectoryMode = mode
    }
    if let saved = defaults.string(forKey: Keys.customOutputDirectory) {
      customOutputDirectory = saved
    }
  }

  static func clamped(_ value: Int, _ range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
  }

  // パストラバーサル対策でファイル名部分のみに制限する
  var safeMonitoringFileName: String {
    (monitoringFileName as NSString).lastPathComponent
  }

  var outputDirectoryURL: URL? {
    switch outputDirectoryMode {
    case .tmp:
      return FileManager.default.temporaryDirectory
    case .custom:
      return customOutputDirectory.isEmpty ? nil : URL(fileURLWithPath: customOutputDirectory, isDirectory: true)
    }
  }

  var resolvedClaudeExecutable: URL? {
    ClaudeLocator.resolve(configured: claudePath, home: .homeDirectory) {
      FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false))
    }
  }

  var customConfigFolder: String? {
    ClaudeConfigFolder.customFolderPath(claudeConfigDirectory, home: .homeDirectory)
  }

  var cacheFileURL: URL {
    ClaudeConfigFolder.cacheFile(customFolder: customConfigFolder, home: .homeDirectory)
  }
}
