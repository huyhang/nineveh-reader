import SwiftUI

/// The library's look, after the Plex app: warm charcoal, flat panels, square
/// posters, and gold where something is chosen or can be acted on.
enum ReaderTheme {
  static let coverRadius: CGFloat = 3
  static let cardSpacing: CGFloat = 20
  static let contentPadding: CGFloat = 36
  static let coverRatio: CGFloat = 0.67

  /// Plex's gold.
  static let accent = Color(red: 0.898, green: 0.627, blue: 0.051)
  /// The top bar and the sidebar.
  static let chrome = Color(red: 0.098, green: 0.094, blue: 0.09)
  /// A field or a row the pointer is over.
  static let raised = Color.white.opacity(0.08)
  static let sidebarWidth: CGFloat = 236
  #if os(macOS)
    /// The top bar's round buttons, sized for a pointer.
    static let topBarIconSize: CGFloat = 32
    static let sidebarRowHeight: CGFloat = 40
  #else
    /// The top bar's round buttons, big enough for a finger.
    static let topBarIconSize: CGFloat = 40
    static let sidebarRowHeight: CGFloat = 44
  #endif

  static let secondaryText = Color.white.opacity(0.6)
  static let tertiaryText = Color.white.opacity(0.38)
}

extension View {
  /// Runs a horizontal shelf out through the `contentPadding` around it while
  /// its first card stays in line with the page. Cards scroll under the
  /// margin, and the first one's hover growth isn't cut off there.
  func shelfBleed() -> some View {
    modifier(ShelfBleed())
  }

  /// A page's heading, Plex's size: large, bold, and plain white.
  func pageTitleStyle() -> some View {
    font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
  }

  /// A button that reads as a link: the Mac's link style, or on an iPad,
  /// which has none, plain text in the tint.
  @ViewBuilder
  func linkButtonStyle() -> some View {
    #if os(macOS)
      buttonStyle(.link)
    #else
      buttonStyle(.plain).foregroundStyle(.tint)
    #endif
  }
}

private struct ShelfBleed: ViewModifier {
  @Environment(\.contentPadding) private var contentPadding

  func body(content: Content) -> some View {
    content
      .contentMargins(.horizontal, contentPadding, for: .scrollContent)
      .padding(.horizontal, -contentPadding)
  }
}

/// A warm charcoal that browns toward the bottom, as Plex's pages do.
struct QuietBackground: View {
  var body: some View {
    LinearGradient(
      stops: [
        .init(color: Color(red: 0.15, green: 0.145, blue: 0.14), location: 0),
        .init(color: Color(red: 0.12, green: 0.11, blue: 0.1), location: 0.45),
        .init(color: Color(red: 0.16, green: 0.12, blue: 0.08), location: 1),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }
}

/// A section heading in Plex's manner: bold capitals, with where it comes
/// from after a dash in grey. "CONTINUE READING — Home Library".
struct SectionHeading: View {
  let title: String
  var detail: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(title.uppercased())
        .font(.system(size: 15, weight: .heavy))
        .tracking(0.6)
        .foregroundStyle(.white)
      if let detail {
        Text("  —  \(detail)")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(ReaderTheme.secondaryText)
      }
    }
    .lineLimit(1)
  }
}

/// Plex's call to action: a gold slab with dark text.
struct AccentButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .bold))
      .foregroundStyle(.black.opacity(0.88))
      .padding(.horizontal, 16)
      .frame(minHeight: 30)
      .background(
        ReaderTheme.accent.opacity(configuration.isPressed ? 0.8 : 1),
        in: RoundedRectangle(cornerRadius: 4))
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(Rectangle())
  }
}

/// A quieter button beside the gold one: grey, with white text.
struct ChromeButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .frame(minHeight: 30)
      .background(
        Color.white.opacity(configuration.isPressed ? 0.22 : 0.12),
        in: RoundedRectangle(cornerRadius: 4))
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(Rectangle())
  }
}

/// A round icon button for the top bar and shelf headers, lit on hover.
struct ChromeIconButtonStyle: ButtonStyle {
  var size: CGFloat = 30
  @State private var hovering = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: size * 0.46, weight: .semibold))
      .foregroundStyle(.white.opacity(isEnabled ? (hovering ? 1 : 0.8) : 0.25))
      .frame(width: size, height: size)
      .background(
        Circle().fill(.white.opacity(configuration.isPressed ? 0.2 : hovering && isEnabled ? 0.1 : 0))
      )
      .contentShape(Circle())
      .onHover { hovering = $0 }
  }
}

extension ButtonStyle where Self == AccentButtonStyle {
  static var accent: AccentButtonStyle { AccentButtonStyle() }
}

extension ButtonStyle where Self == ChromeButtonStyle {
  static var chrome: ChromeButtonStyle { ChromeButtonStyle() }
}

extension ButtonStyle where Self == ChromeIconButtonStyle {
  static var chromeIcon: ChromeIconButtonStyle { ChromeIconButtonStyle() }
  static func chromeIcon(size: CGFloat) -> ChromeIconButtonStyle {
    ChromeIconButtonStyle(size: size)
  }
}
