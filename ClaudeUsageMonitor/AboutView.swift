import AppKit
import SwiftUI

struct AboutView: View {
  // 設計値 (pt)。
  private static let width: CGFloat = 360
  private static let iconSide: CGFloat = 96
  private static let bodyFontSize: CGFloat = 12.5

  private static let license = """
    MIT License
    Copyright (c) 2026 Hiroki Doi
    """

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(spacing: 10) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: Self.iconSide, height: Self.iconSide)
        Text(Bundle.main.appName)
          .font(.system(size: 20, weight: .semibold))
        Text(verbatim: "Version \(version)")
          .font(.system(size: Self.bodyFontSize))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 26)
      Divider()
      VStack(alignment: .leading, spacing: 11) {
        Text("LICENSE")
          .font(.system(size: Self.bodyFontSize, weight: .semibold))
        Text(Self.license)
          .font(.system(size: Self.bodyFontSize))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 18)
    }
    .padding(.horizontal, 24)
    .frame(width: Self.width)
    .fixedSize(horizontal: false, vertical: true)
  }
}
