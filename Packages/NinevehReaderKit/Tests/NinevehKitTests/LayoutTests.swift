#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import Testing

  @testable import NinevehKit

  /// A window squeezed narrower than a page's buttons wraps them onto more
  /// lines, each keeping its label, and a button wider than a whole line gets
  /// the line's width rather than running off the page.
  @Test @MainActor func buttonsWrapInsideANarrowWindow() {
    let row = NSHostingController(
      rootView: ActionRow {
        Button(String(repeating: "Continue ", count: 12)) {}
        Button("Download") {}
      })

    let narrow = row.sizeThatFits(in: CGSize(width: 150, height: 10_000))
    let wide = row.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))

    #expect(narrow.width <= 150)
    #expect(narrow.height > wide.height)
  }

  /// A series' secondary actions are each as wide as the widest of them, so
  /// the row is that width for every one, plus the gaps between them.
  @Test @MainActor func actionsInARowShareTheWidestWidth() {
    let row = NSHostingController(
      rootView: EqualWidthRow(spacing: 10) {
        Color.clear.frame(width: 40, height: 10)
        Color.clear.frame(width: 100, height: 20)
        Color.clear.frame(width: 70, height: 15)
      })

    let size = row.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))

    #expect(size == CGSize(width: 3 * 100 + 2 * 10, height: 20))
  }
#endif
