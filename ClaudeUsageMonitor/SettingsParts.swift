import SwiftUI

enum SettingsMetrics {
  // 設計値 (pt)。
  static let width: CGFloat = 760
  static let rowSpacing: CGFloat = 18
  // 実機で見て決めた値 (pt)。
  static let formBottomPadding: CGFloat = 32
  // モックの値 (pt)。
  static let labelWidth: CGFloat = 176
  static let headingGap: CGFloat = 12
  static let formHorizontalPadding: CGFloat = 24
  static let formTopPadding: CGFloat = 18
  static let noteFontSize: CGFloat = 11.5
  // 設計値 (pt)。3 桁が入る幅。
  static let numberWidth: CGFloat = 60
}

extension View {
  func settingsRowSpacing() -> some View {
    padding(.top, SettingsMetrics.rowSpacing)
  }

  /// 消しても場所は残す。入力のたびにウィンドウの高さを変えない。
  func reservingSpace(isShown: Bool) -> some View {
    opacity(isShown ? 1 : 0).allowsHitTesting(isShown)
  }

  /// 右寄せラベルの `Form` の外枠。
  func settingsFormFrame() -> some View {
    self
      .formStyle(.columns)
      .padding(.horizontal, SettingsMetrics.formHorizontalPadding)
      .padding(.top, SettingsMetrics.formTopPadding)
      .padding(.bottom, SettingsMetrics.formBottomPadding)
      .frame(width: SettingsMetrics.width, alignment: .topLeading)
  }
}

/// ラベルの列の幅をタブをまたいで揃える行。
struct SettingsRow<Content: View>: View {
  let title: String
  let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    LabeledContent {
      content
    } label: {
      Text(title).frame(width: SettingsMetrics.labelWidth, alignment: .trailing)
    }
  }
}

struct SettingsNote: View {
  let text: String
  var isWarning = false
  var isSelectable = false

  var body: some View {
    label
      .font(.system(size: SettingsMetrics.noteFontSize))
      .foregroundStyle(isWarning ? Color.orange : Color.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var label: some View {
    if isSelectable {
      Text(text).textSelection(.enabled)
    } else {
      Text(text)
    }
  }
}

struct NumberField: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  let unit: String

  @State private var draft: String

  init(value: Binding<Int>, range: ClosedRange<Int>, unit: String) {
    _value = value
    self.range = range
    self.unit = unit
    _draft = State(initialValue: String(value.wrappedValue))
  }

  var body: some View {
    HStack(spacing: 5) {
      CommittingTextField(draft: $draft, value: String(value)) { commit($0) }
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: SettingsMetrics.numberWidth)
      Stepper("", value: $value, in: range)
        .labelsHidden()
      Text(unit)
    }
  }

  // 整数に読み、範囲に収める。読めなければ元の値に戻す
  private func commit(_ text: String) -> String {
    if let number = Int(text.trimmingCharacters(in: .whitespaces)) {
      value = AppSettings.clamped(number, range)
    }
    return String(value)
  }
}

/// 入力中は下書きに持ち、Enter・フォーカスが外れたとき・ビューが消えるときにだけ確定する文字列の欄。
/// `commit` は確定した値の表示を返し、下書きがそれに揃う。
struct CommittingTextField: View {
  @Binding var draft: String
  /// 設定側の今の値。
  let value: String
  var prompt = ""
  let commit: (String) -> String

  @State private var committed: String
  @FocusState private var isFocused: Bool

  init(draft: Binding<String>, value: String, prompt: String = "", commit: @escaping (String) -> String) {
    _draft = draft
    self.value = value
    self.prompt = prompt
    self.commit = commit
    _committed = State(initialValue: value)
  }

  var body: some View {
    TextField("", text: $draft, prompt: Text(prompt))
      .labelsHidden()
      .focused($isFocused)
      .onSubmit { commitDraft() }
      .onChange(of: isFocused) { _, focused in
        if !focused { commitDraft() }
      }
      .onChange(of: value) { _, new in
        if !isFocused || draft == committed { draft = new }
        committed = new
      }
      .onDisappear { commitDraft() }
  }

  private func commitDraft() {
    guard draft != committed else { return }
    let result = commit(draft)
    committed = result
    draft = result
  }
}
