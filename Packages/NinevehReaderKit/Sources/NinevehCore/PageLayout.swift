import Foundation

/// How a publication's pages fall onto the screen: which pages share a
/// two-page spread, where a page turn lands, and what the reader is told.
///
/// This mirrors the web reader's `reader-model.js`, so a volume pairs the same
/// way in the app as it does in a browser.
public struct PageLayout: Hashable, Sendable {
  public let totalPages: Int
  /// One entry per page, in page order.
  public let pages: [ManifestPage]
  /// Two-page spreads, each one or two page numbers.
  public let groups: [[Int]]
  private let groupIndex: [Int: Int]

  public init(manifest: PageManifest) {
    self.init(
      pages: manifest.layoutPages, totalPages: manifest.totalPages,
      pairingAnchor: manifest.pairingAnchor)
  }

  public init(pages: [ManifestPage], totalPages: Int, pairingAnchor: Int? = nil) {
    self.totalPages = max(totalPages, 0)
    self.pages = pages.sorted { $0.number < $1.number }
    groups = Self.pageGroups(self.pages, pairingAnchor: pairingAnchor)
    var index: [Int: Int] = [:]
    for (position, group) in groups.enumerated() {
      for page in group { index[page] = position }
    }
    groupIndex = index
  }

  /// A page the server marked as a spread, or one wide enough to be two
  /// pages scanned as one, always stands alone.
  public static func isStitched(_ page: ManifestPage) -> Bool {
    if page.spread { return true }
    guard let ratio = page.aspectRatio else { return false }
    return ratio >= 1.25
  }

  public func isStitched(_ number: Int) -> Bool {
    page(number).map(Self.isStitched) ?? false
  }

  public func page(_ number: Int) -> ManifestPage? {
    guard number >= 1, number <= pages.count, pages[number - 1].number == number else {
      return pages.first { $0.number == number }
    }
    return pages[number - 1]
  }

  public func aspectRatio(of number: Int) -> Double? {
    page(number)?.aspectRatio
  }

  public func clamp(_ number: Int) -> Int {
    min(max(number, 1), max(totalPages, 1))
  }

  /// The pages on screen when `number` is the current page.
  public func visiblePages(for number: Int, mode: ReadingMode) -> [Int] {
    let current = clamp(number)
    guard mode == .double, let index = groupIndex[current] else { return [current] }
    return groups[index]
  }

  /// The page a turn lands on, or `nil` past either end of the volume.
  public func adjacentPage(to number: Int, mode: ReadingMode, step: Int) -> Int? {
    guard totalPages > 0 else { return nil }
    guard mode == .double, let index = groupIndex[clamp(number)] else {
      let target = number + step
      return target < 1 || target > totalPages ? nil : target
    }
    let target = index + step
    return groups.indices.contains(target) ? groups[target][0] : nil
  }

  /// In two-page mode a spread is named by its first page.
  public func normalized(_ number: Int, mode: ReadingMode) -> Int {
    visiblePages(for: number, mode: mode).first ?? clamp(number)
  }

  /// Whether `number` shows the volume's last page.
  public func reachesEnd(_ number: Int, mode: ReadingMode) -> Bool {
    visiblePages(for: number, mode: mode).contains(totalPages)
  }

  /// The pages worth keeping decoded around the current one while scrolling.
  public func activeWindow(around number: Int, before: Int = 2, after: Int = 3) -> ClosedRange<Int>
  {
    guard totalPages > 0 else { return 1...1 }
    let current = clamp(number)
    return max(1, current - before)...min(totalPages, current + after)
  }

  /// "12 / 246" for one page, "12–13 / 246" for a spread.
  public func label(for number: Int, mode: ReadingMode) -> String {
    let visible = visiblePages(for: number, mode: mode)
    let first = visible.first ?? clamp(number)
    let range = visible.count > 1 ? "\(first)–\(visible[visible.count - 1])" : "\(first)"
    return "\(range) / \(totalPages)"
  }

  // Anchors arrive from a manifest, so anything unusable has to fall back to
  // pairing straight after the cover rather than shifting the whole volume.
  private static func pairingStart(_ anchor: Int?) -> Int {
    guard let anchor, anchor > 2 else { return 2 }
    return anchor
  }

  // Pages between the cover and the anchor, paired from the anchor backwards so
  // the run finishes flush against it. Any page left over lands at the front,
  // which is where a colour insert or a frontispiece actually sits.
  private static func leadingGroups(_ pages: ArraySlice<ManifestPage>) -> [[Int]] {
    let pages = Array(pages)
    var groups: [[Int]] = []
    var index = pages.count - 1
    while index >= 0 {
      let page = pages[index]
      let previous = index > 0 ? pages[index - 1] : nil
      if let previous, !isStitched(page), !isStitched(previous) {
        groups.append([previous.number, page.number])
        index -= 2
      } else {
        groups.append([page.number])
        index -= 1
      }
    }
    return groups.reversed()
  }

  private static func pageGroups(_ ordered: [ManifestPage], pairingAnchor: Int?) -> [[Int]] {
    guard let cover = ordered.first else { return [] }
    let anchor = pairingStart(pairingAnchor)
    var index = 1
    while index < ordered.count, ordered[index].number < anchor { index += 1 }
    // The cover always stands alone. The anchor only sets the parity of what
    // follows: pages before it still pair, they just align backwards from it,
    // so one stray page early on does not desynchronise every later spread.
    var groups = [[cover.number]] + leadingGroups(ordered[1..<index])
    while index < ordered.count {
      let page = ordered[index]
      let next = index + 1 < ordered.count ? ordered[index + 1] : nil
      if let next, !isStitched(page), !isStitched(next) {
        groups.append([page.number, next.number])
        index += 2
      } else {
        groups.append([page.number])
        index += 1
      }
    }
    return groups
  }
}

extension ReadingDirection {
  /// The page step for a horizontal arrow, key or on-screen: forward when it
  /// points the way the pages are read.
  public func step(forArrowPointingRight pointsRight: Bool) -> Int {
    (pointsRight == (self == .leftToRight)) ? 1 : -1
  }
}
