import SwiftUI

enum ReaderTheme {
  static let coverRadius: CGFloat = 10
  static let cardSpacing: CGFloat = 20
  static let contentPadding: CGFloat = 28
  static let coverRatio: CGFloat = 0.67
}

extension View {
  /// Runs a horizontal shelf out through the `contentPadding` around it while
  /// its first card stays in line with the page. Cards scroll under the
  /// margin, and the first one's shadow and hover growth aren't cut off there.
  func shelfBleed() -> some View {
    contentMargins(.horizontal, ReaderTheme.contentPadding, for: .scrollContent)
      .padding(.horizontal, -ReaderTheme.contentPadding)
  }
}

struct QuietBackground: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      baseColor
      LinearGradient(
        colors: [Color.accentColor.opacity(0.09), baseColor],
        startPoint: .topLeading,
        endPoint: .center
      )
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  private var baseColor: Color {
    colorScheme == .dark
      ? Color(red: 0.055, green: 0.06, blue: 0.07)
      : Color(red: 0.965, green: 0.965, blue: 0.975)
  }
}
