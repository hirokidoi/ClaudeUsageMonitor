import SwiftUI
import WebKit

// メイン WebView のウィンドウは AutomationManager が AppKit NSWindow として直接保持・配置する。
// SwiftUI Window Scene は hide 時に WebView のレンダリング/JS 実行が throttle される症状が
// あったため廃止した。ここでは OAuth ポップアップ用コントローラのみ残す。

final class OAuthPopupController {
  static var active: [OAuthPopupController] = []

  let window: NSWindow
  let webView: WKWebView
  private let onClose: () -> Void

  init(configuration: WKWebViewConfiguration, onClose: @escaping () -> Void) {
    self.onClose = onClose
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    webView = WKWebView(frame: .zero, configuration: configuration)
    window.contentView = webView
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    OAuthPopupController.active.append(self)
    watchClose()
  }

  private func watchClose() {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self else { return }
      if !self.window.isVisible {
        self.onClose()
        OAuthPopupController.active.removeAll { $0 === self }
      } else {
        self.watchClose()
      }
    }
  }
}
