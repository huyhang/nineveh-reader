import Testing

@testable import NinevehCore

// The same cases the server runs against the web reader's `reader-model.js`,
// so both readers pair a volume the same way.

private func page(_ number: Int, wide: Bool = false, spread: Bool = false) -> ManifestPage {
  // Matches the archives in `example-data`: a printed double spread is stored
  // as one image twice as wide as the pages around it.
  ManifestPage(number: number, width: wide ? 3000 : 1500, height: 2250, spread: spread)
}

private func volume(_ count: Int, wide: Set<Int> = []) -> [ManifestPage] {
  (0..<count).map { page($0 + 1, wide: wide.contains($0 + 1)) }
}

private func grouped(_ pages: [ManifestPage], anchor: Int? = nil) -> [[Int]] {
  PageLayout(pages: pages, totalPages: pages.count, pairingAnchor: anchor).groups
}

@Test func withoutAnAnchorTheCoverStandsAloneAndTheRestPair() {
  #expect(grouped(volume(7)) == [[1], [2, 3], [4, 5], [6, 7]])
}

@Test func aStitchedPageStandsAloneAndRepairsThePagesAfterIt() {
  #expect(grouped(volume(7, wide: [4])) == [[1], [2, 3], [4], [5, 6], [7]])
  let marked = volume(7).map { $0.number == 4 ? page(4, spread: true) : $0 }
  #expect(grouped(marked) == [[1], [2, 3], [4], [5, 6], [7]])
}

@Test(arguments: [nil, 0, 1, 2, -4] as [Int?])
func aMeaninglessAnchorLeavesPairingAtTheCover(anchor: Int?) {
  #expect(grouped(volume(7), anchor: anchor) == grouped(volume(7)))
}

@Test func anAnchorShiftsTheParityRatherThanUnpairingWhatPrecedesIt() {
  #expect(grouped(volume(8), anchor: 3) == [[1], [2], [3, 4], [5, 6], [7, 8]])
  #expect(grouped(volume(8), anchor: 4) == [[1], [2, 3], [4, 5], [6, 7], [8]])
  #expect(grouped(volume(9), anchor: 5) == [[1], [2], [3, 4], [5, 6], [7, 8], [9]])
}

@Test func aLateAnchorLeavesOneSinglePageNotAWallOfThem() {
  let groups = grouped(volume(40, wide: [33]), anchor: 33)
  #expect(Array(groups.prefix(4)) == [[1], [2], [3, 4], [5, 6]])
  let spread = try! #require(groups.firstIndex(of: [33]))
  #expect(groups[spread - 1] == [31, 32])
  #expect(groups[..<spread].filter { $0.count == 1 } == [[1], [2]])
}

@Test func theCoverNeverPairsHoweverTheAnchorFalls() {
  for count in 2...12 {
    for wide: Set<Int> in [[], [3], [5], [2, 7]] {
      for anchor in 2...count {
        #expect(grouped(volume(count, wide: wide), anchor: anchor).first == [1])
      }
    }
  }
}

@Test func anAnchorPastTheLastPageStillPairsWhatItHas() {
  #expect(grouped(volume(5), anchor: 9) == [[1], [2, 3], [4, 5]])
  #expect(grouped(volume(6), anchor: 9) == [[1], [2], [3, 4], [5, 6]])
}

@Test func stitchedPagesStandAloneOnEitherSideOfAnAnchor() {
  #expect(grouped(volume(8, wide: [5]), anchor: 3) == [[1], [2], [3, 4], [5], [6, 7], [8]])
  #expect(grouped(volume(9, wide: [3]), anchor: 6) == [[1], [2], [3], [4, 5], [6, 7], [8, 9]])
}

@Test func pagesArriveInAnyOrderAndArePairedByNumber() {
  #expect(grouped(volume(6).reversed(), anchor: 3) == [[1], [2], [3, 4], [5, 6]])
}

@Test func anEmptyVolumeHasNoGroups() {
  #expect(grouped([]).isEmpty)
}

@Test func everyPageBelongsToExactlyOneGroup() {
  for anchor in [nil, 2, 3, 4, 7] as [Int?] {
    for pages in [volume(9), volume(9, wide: [3, 8]), volume(10, wide: [2])] {
      #expect(grouped(pages, anchor: anchor).flatMap { $0 } == pages.map(\.number))
    }
  }
}

@Test func visiblePagesFollowTheAnchorInTwoPageModeOnly() {
  let layout = PageLayout(pages: volume(8), totalPages: 8, pairingAnchor: 3)
  #expect(layout.visiblePages(for: 4, mode: .double) == [3, 4])
  #expect(layout.visiblePages(for: 4, mode: .single) == [4])
  #expect(layout.normalized(4, mode: .double) == 3)
  #expect(layout.label(for: 4, mode: .double) == "3–4 / 8")
  #expect(layout.label(for: 2, mode: .double) == "2 / 8")
  #expect(layout.reachesEnd(7, mode: .double))
  #expect(!layout.reachesEnd(7, mode: .single))
}

@Test func turningAPageInTwoPageModeStepsWholeSpreads() {
  let layout = PageLayout(pages: volume(8), totalPages: 8, pairingAnchor: 3)
  #expect(layout.adjacentPage(to: 1, mode: .double, step: 1) == 2)
  #expect(layout.adjacentPage(to: 2, mode: .double, step: 1) == 3)
  #expect(layout.adjacentPage(to: 3, mode: .double, step: 1) == 5)
  #expect(layout.adjacentPage(to: 5, mode: .double, step: -1) == 3)
  #expect(layout.adjacentPage(to: 1, mode: .double, step: -1) == nil)
  #expect(layout.adjacentPage(to: 7, mode: .double, step: 1) == nil)
  #expect(layout.adjacentPage(to: 7, mode: .single, step: 1) == 8)
  #expect(layout.adjacentPage(to: 8, mode: .scroll, step: 1) == nil)
}

@Test func anUnmeasuredVolumeStillPairsAfterTheCover() {
  let manifest = PageManifest(publicationID: "p", revision: "r", totalPages: 5)
  let layout = PageLayout(manifest: manifest)
  #expect(layout.groups == [[1], [2, 3], [4, 5]])
  #expect(layout.aspectRatio(of: 2) == nil)
}

@Test func theContinuousWindowTracksTheReaderAndStaysInsideTheVolume() {
  let layout = PageLayout(pages: volume(200), totalPages: 200)
  #expect(layout.activeWindow(around: 10) == 8...13)
  #expect(layout.activeWindow(around: 1) == 1...4)
  #expect(layout.activeWindow(around: 200) == 198...200)
  #expect(layout.activeWindow(around: 10_000) == 198...200)
  #expect(PageLayout(pages: volume(1), totalPages: 1).activeWindow(around: 1) == 1...1)
}

@Test func arrowsFollowTheReadingDirection() {
  #expect(ReadingDirection.leftToRight.step(forArrowPointingRight: true) == 1)
  #expect(ReadingDirection.rightToLeft.step(forArrowPointingRight: true) == -1)
  #expect(ReadingDirection.rightToLeft.step(forArrowPointingRight: false) == 1)
}

@Test func directionPreferencesCycleAndResolve() {
  #expect(ReadingDirectionPreference.automatic.resolved(default: .rightToLeft) == .rightToLeft)
  #expect(ReadingDirectionPreference.leftToRight.resolved(default: .rightToLeft) == .leftToRight)
  #expect(ReadingDirectionPreference.automatic.next.next.next == .automatic)
}

@Test func seriesMetadataReadsTheWayTheWebClientShowsIt() {
  let metadata = SeriesMetadata(
    editedFields: ["total_chapters"], publishedStart: "2019-04-01", status: "on_hiatus",
    mediaType: "manga", rating: 90.6)
  #expect(metadata.badges == ["Manga", "On Hiatus", "2019", "91/100"])
  #expect(metadata.publishedRange == "2019-04-01")
  #expect(metadata.providerName == "MangaBaka")
  #expect(metadata.isEditedLocally)
  #expect(SeriesMetadata(publishedEnd: "2023").publishedRange == "Unknown – 2023")
  #expect(SeriesMetadata().publishedRange == nil)
}
