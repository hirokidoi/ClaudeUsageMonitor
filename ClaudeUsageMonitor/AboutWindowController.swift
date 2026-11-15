import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController {
  init() {
    let hosting = NSHostingController(rootView: AboutView())
    hosting.sizingOptions = [.preferredContentSize]
    let window = NSWindow(contentViewController: hosting)
    window.styleMask = [.titled, .closable]
    window.title = "\(Bundle.main.appName) について"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func show() {
    showWindow(nil)
    NSApp.activate()
    // activate() は他のアプリが使用中だと断られうるので、ウィンドウは必ず前に出す
    window?.orderFrontRegardless()
  }
}
