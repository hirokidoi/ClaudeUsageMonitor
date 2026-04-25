import Foundation
import Combine

extension Bundle {
  // "1.0 (1)" 形式。起動ログ / 設定画面フッター などで共通利用
  var appVersionLabel: String {
    let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(short) (\(build))"
  }
}

class AppSettings: ObservableObject {
  static let defaultUrl = "https://claude.ai/settings/usage"

  private enum Keys {
    static let url = "url"
    static let intervalSeconds = "intervalSeconds"
    static let apiEndpointUrl = "apiEndpointUrl"
    static let monitoringFileName = "monitoringFileName"
    static let warningThresholdPct = "warningThresholdPct"
  }

  @Published var url: String = AppSettings.defaultUrl {
    didSet { UserDefaults.standard.set(url, forKey: Keys.url) }
  }
  @Published var intervalSeconds: Int = 300 {
    didSet { UserDefaults.standard.set(intervalSeconds, forKey: Keys.intervalSeconds) }
  }
  @Published var apiEndpointUrl: String = "" {
    didSet { UserDefaults.standard.set(apiEndpointUrl, forKey: Keys.apiEndpointUrl) }
  }
  @Published var monitoringFileName: String = "" {
    didSet { UserDefaults.standard.set(monitoringFileName, forKey: Keys.monitoringFileName) }
  }
  // この値以上の使用率になったらアイコンをオレンジにして警告する閾値 (% 整数)
  @Published var warningThresholdPct: Int = 90 {
    didSet { UserDefaults.standard.set(warningThresholdPct, forKey: Keys.warningThresholdPct) }
  }

  init() {
    let defaults = UserDefaults.standard
    if let saved = defaults.string(forKey: Keys.url) {
      url = saved
    }
    if defaults.object(forKey: Keys.intervalSeconds) != nil {
      intervalSeconds = defaults.integer(forKey: Keys.intervalSeconds)
    }
    if let saved = defaults.string(forKey: Keys.apiEndpointUrl) {
      apiEndpointUrl = saved
    }
    if let saved = defaults.string(forKey: Keys.monitoringFileName) {
      monitoringFileName = saved
    }
    if defaults.object(forKey: Keys.warningThresholdPct) != nil {
      warningThresholdPct = defaults.integer(forKey: Keys.warningThresholdPct)
    }
  }

  func matches(url other: URL?) -> Bool {
    // 設定 URL 未設定時は常に不一致扱い (呼び出し側の isEmpty ガード不要化)
    guard !url.isEmpty, let other, let settingsURL = URL(string: url) else { return false }
    return other.host == settingsURL.host && other.path == settingsURL.path
  }
}
