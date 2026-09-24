import SwiftUI

/// The device the library lives on, as its pages speak of it: "On My Mac",
/// "On My iPad".
enum Device {
  #if os(macOS)
    static let name = "Mac"
    static let symbol = "macbook"
  #else
    static let name = "iPad"
    static let symbol = "ipad"
  #endif
}

extension EnvironmentValues {
  /// A window too narrow for the library laid out in full: an iPad app
  /// sharing the screen, or in a small window. A Mac window never is.
  var isNarrow: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  /// The margin around a page, tighter in a narrow window.
  var contentPadding: CGFloat { isNarrow ? 20 : ReaderTheme.contentPadding }
}

/// A row of buttons. On the Mac it is one line, as it always was; an iPad
/// window can be narrower than its buttons, so there they wrap.
struct ActionRow<Content: View>: View {
  var spacing: CGFloat = 10
  @ViewBuilder var content: Content

  var body: some View {
    #if os(macOS)
      HStack(spacing: spacing) { content }
    #else
      FlowLayout(spacing: spacing) { content }
    #endif
  }
}

extension View {
  /// Keeps a bar's leading end clear of an iPad window's controls, which sit
  /// in its top leading corner while the app runs in a window. Nothing
  /// changes on the Mac, where the window's buttons have a title bar.
  func clearsWindowControls() -> some View {
    modifier(WindowControlsClearance())
  }
}

private struct WindowControlsClearance: ViewModifier {
  @State private var inset: CGFloat = 0

  func body(content: Content) -> some View {
    #if os(iOS)
      content
        .padding(.leading, inset)
        // Measured outside the padding, so the padding can't feed back into it.
        .onGeometryChange(for: CGFloat.self) { proxy in
          if #available(iOS 26, *) {
            proxy.containerCornerInsets.topLeading.width
          } else {
            0
          }
        } action: {
          inset = $0
        }
    #else
      content
    #endif
  }
}
