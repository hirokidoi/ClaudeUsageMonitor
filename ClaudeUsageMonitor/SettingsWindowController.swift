import AppKit
import SwiftUI

// NSTabViewController は却下: 中身の高さが変わるとビューの配置が実際のウィンドウとずれる (実測)。
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
  private static let frameName = "SettingsWindow"

  private enum Tab: String, CaseIterable {
    case general, claude, output

    var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }

    var title: String {
      switch self {
      case .general: "一般"
      case .claude: "Claude"
      case .output: "出力"
      }
    }

    var symbol: String {
      switch self {
      case .general: "gearshape"
      case .claude: "terminal"
      case .output: "square.and.arrow.up"
      }
    }

    @MainActor
    func content(settings: AppSettings, automation: AutomationManager) -> AnyView {
      switch self {
      case .general: AnyView(GeneralTab(settings: settings, automation: automation))
      case .claude: AnyView(ClaudeTab(settings: settings))
      case .output: AnyView(OutputTab(settings: settings, automation: automation))
      }
    }
  }

  private let settings: AppSettings
  private let automation: AutomationManager
  private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
  private var contentHeight: CGFloat?
  private var selectedTab = Tab.general

  init(settings: AppSettings, automation: AutomationManager) {
    self.settings = settings
    self.automation = automation
    hosting.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.width, height: 1),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = hosting
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    let toolbar = NSToolbar(identifier: "SettingsToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconAndLabel
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    if !window.setFrameUsingName(Self.frameName) { window.center() }
    window.setFrameAutosaveName(Self.frameName)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// 開くたびにタブの中身を作り直し、設定とシステムの今の状態に合わせる。
  func show() {
    if window?.isVisible != true { select(selectedTab) }
    fitToContent()
    showWindow(nil)
    window?.makeFirstResponder(nil)
    NSApp.activate()
    // activate() は他のアプリが使用中だと断られうるので、ウィンドウは必ず前に出す
    window?.orderFrontRegardless()
  }

  private func select(_ tab: Tab) {
    selectedTab = tab
    window?.title = tab.title
    window?.toolbar?.selectedItemIdentifier = tab.identifier
    contentHeight = nil
    hosting.rootView = AnyView(
      tab.content(settings: settings, automation: automation)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { [weak self] height in
          self?.contentHeight = height
          self?.fitToContent()
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    )
  }

  private func fitToContent() {
    guard let window, let contentHeight else { return }
    let chrome = window.frame.height - hosting.frame.height
    let height = contentHeight + chrome
    let frame = NSRect(
      x: window.frame.minX,
      y: window.frame.maxY - height,
      width: SettingsMetrics.width + window.frame.width - hosting.frame.width,
      height: height
    )
    if frame != window.frame { window.setFrame(frame, display: true) }
  }

  @objc private func selectTab(_ item: NSToolbarItem) {
    if let tab = Tab(rawValue: item.itemIdentifier.rawValue) { select(tab) }
  }

  // MARK: - NSWindowDelegate

  // 閉じたときはフォーカスの変化が届かないことがあるので、タブを外して入力中の値を確定させる。
  func windowWillClose(_ notification: Notification) {
    window?.makeFirstResponder(nil)
    hosting.rootView = AnyView(EmptyView())
  }

  // MARK: - NSToolbarDelegate

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Tab.allCases.map(\.identifier)
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Tab.allCases.map(\.identifier)
  }

  func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Tab.allCases.map(\.identifier)
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    guard let tab = Tab(rawValue: itemIdentifier.rawValue) else { return nil }
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = tab.title
    item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
    item.target = self
    item.action = #selector(selectTab(_:))
    return item
  }
}
