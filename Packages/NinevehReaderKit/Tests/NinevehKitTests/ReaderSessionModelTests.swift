import Foundation
import NinevehCore
import Testing

@testable import NinevehKit

@Test @MainActor func readerSessionTurnsToTheLastPageThenTheEndCard() async {
  let recorder = PositionRecorder()
  let model = session(pageCount: 4, page: 3, recorder: recorder)

  await model.load()
  model.move(1)
  #expect(model.page == 4)
  #expect(!model.completed)
  #expect(!model.isFinished)

  model.move(1)
  #expect(model.isFinished)
  #expect(model.completed)
  await model.flush()

  #expect(model.pageCount == 4)
  #expect(await recorder.latest?.publicationID == "volume-1")
  #expect(await recorder.latest?.page == 4)
  #expect(await recorder.latest?.completed == true)
  #expect(model.syncStatus == .saved)
  #expect(model.savedMessage == "Your progress has been saved.")
}

@Test @MainActor func readerSessionGoesBackFromTheEndCardWithoutUncompleting() async {
  let model = session(pageCount: 4, page: 4)
  await model.load()
  model.move(1)
  #expect(model.isFinished)

  // Forward from the end card goes nowhere; back returns to the last page.
  model.move(1)
  #expect(model.isFinished)
  model.move(-1)
  #expect(!model.isFinished)
  #expect(model.page == 4)
  #expect(model.completed)
}

@Test @MainActor func readerSessionUncompletesWhenLeavingTheLastPage() async {
  let recorder = PositionRecorder()
  let model = session(
    pageCount: 4, page: 4, completed: true, recorder: recorder)
  await model.load()
  #expect(model.completed)

  model.go(to: 2)
  await model.flush()

  #expect(!model.completed)
  #expect(await recorder.latest?.page == 2)
  #expect(await recorder.latest?.completed == false)
}

@Test @MainActor func readerSessionDropsACompletedFlagAwayFromTheEnd() async {
  let model = session(pageCount: 10, page: 3, completed: true)
  await model.load()
  #expect(model.page == 3)
  #expect(!model.completed)
}

@Test @MainActor func readerSessionReadsAgainFromPageOne() async {
  let recorder = PositionRecorder()
  let model = session(pageCount: 4, page: 4, completed: true, recorder: recorder)
  await model.load()
  model.showEndCard()
  model.readAgain()
  await model.flush()

  #expect(model.page == 1)
  #expect(!model.completed)
  #expect(!model.isFinished)
  #expect(await recorder.latest?.page == 1)
  #expect(await recorder.latest?.completed == false)
}

@Test @MainActor func readerSessionStartsAtTheBeginningWhenAsked() async {
  let model = session(pageCount: 8, page: 6, startsAtBeginning: true)
  await model.load()
  #expect(model.page == 1)
}

@Test @MainActor func readerSessionPairsSpreadsInTwoPageMode() async {
  let model = session(pageCount: 5, page: 3, mode: .double)
  await model.load()

  // The cover stands alone, then pages pair: [1] [2, 3] [4, 5].
  #expect(model.page == 2)
  #expect(model.visiblePages == [2, 3])
  #expect(model.pageLabel == "2–3 / 5")

  model.move(1)
  #expect(model.visiblePages == [4, 5])
  model.move(1)
  #expect(model.isFinished)
  #expect(model.completed)
  model.move(-1)
  model.move(-1)
  #expect(model.visiblePages == [2, 3])
  model.move(-1)
  #expect(model.visiblePages == [1])
  model.move(-1)
  #expect(model.page == 1)
}

@Test @MainActor func readerSessionTurnsTowardTheArrowForTheReadingDirection() async {
  let model = session(
    pageCount: 6, page: 3, defaultDirection: .rightToLeft, directionPreference: .automatic)
  await model.load()
  #expect(model.direction == .rightToLeft)

  // Right to left, the page on the right comes before.
  model.turn(pointingRight: true)
  #expect(model.page == 2)
  model.turn(pointingRight: false)
  #expect(model.page == 3)

  model.setDirection(.leftToRight)
  model.turn(pointingRight: true)
  #expect(model.page == 4)
}

@Test @MainActor func readerSessionRemembersModeAndDirectionChoices() async {
  let choices = ChoiceRecorder()
  let actions = ReaderActions(
    saveDirection: { await choices.record(direction: $0) },
    saveMode: { await choices.record(mode: $0) }
  )
  let model = session(pageCount: 6, page: 3, actions: actions)
  await model.load()

  model.setMode(.double)
  #expect(model.page == 2)
  model.cycleDirection()
  #expect(model.directionPreference == .leftToRight)
  await model.flush()
  try? await Task.sleep(for: .milliseconds(50))

  #expect(await choices.mode == .double)
  #expect(await choices.direction == .leftToRight)
}

@Test @MainActor func readerSessionCompletesFromContinuousScrolling() async {
  let recorder = PositionRecorder()
  let model = session(pageCount: 12, page: 1, mode: .scroll, recorder: recorder)
  await model.load()

  model.recordScrolledPage(7)
  #expect(model.page == 7)
  model.completeReading()
  #expect(model.page == 12)
  #expect(model.completed)
  await model.flush()
  #expect(await recorder.latest?.completed == true)

  model.go(to: 11)
  #expect(model.scrollRequest?.page == 11)
  #expect(!model.completed)
}

@Test @MainActor func readerSessionReportsProgressKeptOnThisDevice() async {
  let actions = ReaderActions(savePosition: { _ in .savedLocally(retryable: false) })
  let model = session(pageCount: 3, page: 1, actions: actions)
  await model.load()
  model.move(1)
  await model.flush()

  #expect(model.syncStatus == .savedLocally)
  #expect(model.savedMessage == "Your progress is saved on this device.")
}

@Test @MainActor func readerSessionReportsAnEmptyArchive() async {
  let model = session(pageCount: 0, page: 1)
  await model.load()
  #expect(model.errorMessage == ReaderError.emptyArchive.errorDescription)
  #expect(!model.isLoading)
}

@Test @MainActor func storeRoundTripsCachedCatalogAndProgress() throws {
  let store = try ReaderStore(inMemory: true)
  let publication = Publication(id: "p1", title: "First", category: .comics)
  try store.cache(publications: [publication], connectionID: "server")
  let position = ReadingPosition(
    publicationID: publication.id,
    page: 7,
    mode: .double,
    completed: false
  )
  try store.saveProgress(position, key: "server|p1", pendingSync: true)

  #expect(try store.cachedPublications(connectionID: "server") == [publication])
  #expect(try store.progress(key: "server|p1")?.page == 7)
  #expect(try store.progress(key: "server|p1")?.mode == .double)
}

// MARK: - Library

@Test @MainActor func libraryFindsSeriesByAlternateTitleAndCreator() {
  let model = ApplicationModel.preview()

  #expect(model.series(matching: "tsuki").map(\.title) == ["Moon Garden"])
  #expect(model.series(matching: "lantern").map(\.title) == ["Moon Garden", "Tin Lantern"])
  #expect(model.series(matching: "LANTERN", in: "Studio Shelf").map(\.title) == ["Tin Lantern"])
  #expect(model.series(matching: "ren ishida").map(\.title) == ["Moon Garden", "Paper Kingdom"])
  #expect(model.series(matching: "月の庭").map(\.title) == ["Moon Garden"])
}

@Test @MainActor func libraryShelvesWhatToReadNext() {
  let model = ApplicationModel.preview()

  #expect(model.continueReading.map(\.id) == ["ghost-circuit-3", "neon-harbor-2"])
  #expect(model.upNext.map(\.id) == ["moon-garden-2"])
}

@Test @MainActor func libraryDescribesSeriesProgressAndMetadata() throws {
  let model = ApplicationModel.preview()
  let moonGarden = try #require(model.seriesGroups.first { $0.title == "Moon Garden" })

  #expect(model.displayTitle(for: moonGarden) == "Moon Garden: Tales of the Lantern Road")
  #expect(model.progress(for: moonGarden).summary == "1 of 3 read")
  #expect(model.detail(for: moonGarden)?.metadata?.badges == ["Manga", "Releasing", "2019", "88/100"])
  #expect(model.progress(for: moonGarden.volumes[0]).label == "Completed")
  #expect(model.progress(for: moonGarden.volumes[1]).label == "Not started")
  #expect(model.categories(in: "Studio Shelf") == [.comics])
}

@Test @MainActor func libraryCountsASeriesDownloadedVolumes() throws {
  let model = ApplicationModel.preview()
  let moonGarden = try #require(model.seriesGroups.first { $0.title == "Moon Garden" })
  let tinLantern = try #require(model.seriesGroups.first { $0.title == "Tin Lantern" })

  #expect(model.downloadedCount(in: moonGarden) == 1)
  #expect(model.downloadedCount(in: tinLantern) == 0)
}

@Test @MainActor func libraryCreditsSeriesMetadataCreatorsToEachVolume() throws {
  let model = ApplicationModel.preview()
  let moonGarden = try #require(model.publications.first { $0.id == "moon-garden-2" })
  let neonHarbor = try #require(model.publications.first { $0.id == "neon-harbor-1" })

  #expect(model.creators(of: moonGarden) == ["Ren Ishida", "Sora Nakamura"])
  // Without series metadata, the volume's own authors.
  #expect(model.creators(of: neonHarbor) == ["Mara Voss"])
}

@Test @MainActor func libraryHidesALibraryEverywhereAndRemembersIt() async {
  let visibility = VisibilityRecorder()
  let model = ApplicationModel.preview(libraryVisibilityStore: visibility)

  model.setLibrary("Studio Shelf", shown: false)
  await model.visibilitySave?.value
  #expect(model.libraries.map(\.name) == ["Home Library"])
  #expect(model.allLibraries.map(\.name) == ["Home Library", "Studio Shelf"])
  #expect(!model.publications.contains { $0.library == "Studio Shelf" })
  #expect(model.seriesGroups(in: "Studio Shelf").isEmpty)
  #expect(model.series(matching: "lantern").map(\.title) == ["Moon Garden"])
  #expect(await visibility.saved == ["Studio Shelf"])

  model.setLibrary("Home Library", shown: false)
  #expect(model.publications.isEmpty)
  #expect(model.continueReading.isEmpty)
  #expect(model.shownDownloads.isEmpty)
  #expect(model.downloads.count == 1)

  model.setLibrary("Home Library", shown: true)
  model.setLibrary("Studio Shelf", shown: true)
  await model.visibilitySave?.value
  #expect(model.series(matching: "lantern").map(\.title) == ["Moon Garden", "Tin Lantern"])
  #expect(model.continueReading.map(\.id) == ["ghost-circuit-3", "neon-harbor-2"])
  #expect(await visibility.saved == [])
}

@Test func libraryVisibilityIsKeptPerServer() async throws {
  let suite = "nineveh-tests-\(UUID().uuidString)"
  defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
  let store = UserDefaultsLibraryVisibilityStore(
    defaults: try #require(UserDefaults(suiteName: suite)))

  await store.save(hiddenLibraries: ["Test Library"], for: "first")
  #expect(await store.hiddenLibraries(for: "first") == ["Test Library"])
  #expect(await store.hiddenLibraries(for: "second").isEmpty)
  await store.save(hiddenLibraries: [], for: "first")
  #expect(await store.hiddenLibraries(for: "first").isEmpty)
}

@Test @MainActor func libraryReturnsToASeriesAlreadyInThePath() throws {
  let model = ApplicationModel.preview()
  let series = try #require(model.seriesGroups.first)
  let volume = try #require(series.volumes.first)

  model.showSeries(series.key)
  #expect(model.libraryPath == [.series(series.key)])
  model.libraryPath.append(.publication(volume))
  model.showSeries(series.key)
  #expect(model.libraryPath == [.series(series.key)])
}

// MARK: - Helpers

@MainActor
private func session(
  pageCount: Int,
  page: Int,
  completed: Bool = false,
  mode: ReadingMode = .single,
  startsAtBeginning: Bool = false,
  defaultDirection: ReadingDirection = .leftToRight,
  directionPreference: ReadingDirectionPreference = .automatic,
  recorder: PositionRecorder? = nil,
  actions: ReaderActions? = nil
) -> ReaderSessionModel {
  let recorder = recorder ?? PositionRecorder()
  let destination = ReaderDestination(
    id: "server|volume-1",
    publicationID: "volume-1",
    title: "Volume One",
    source: StubPageSource(pageCount: pageCount),
    initialPosition: ReadingPosition(
      publicationID: "volume-1", page: page, mode: mode, completed: completed),
    startsAtBeginning: startsAtBeginning,
    initialMode: mode,
    defaultDirection: defaultDirection,
    directionPreference: directionPreference,
    actions: actions
      ?? ReaderActions(savePosition: { position in
        await recorder.record(position)
        return .saved
      })
  )
  return ReaderSessionModel(destination: destination)
}

private struct StubPageSource: PageProviding {
  let pageCount: Int

  func manifest() async throws -> PageManifest {
    PageManifest(publicationID: "volume-1", revision: "r1", totalPages: pageCount)
  }

  func page(number: Int, maximumPixelWidth: Int?) async throws -> Data {
    Data("page-\(number)".utf8)
  }
}

private actor PositionRecorder {
  private(set) var latest: ReadingPosition?

  func record(_ position: ReadingPosition) {
    latest = position
  }
}

private actor VisibilityRecorder: LibraryVisibilityStoring {
  private(set) var saved: Set<String>?

  func hiddenLibraries(for connectionID: String) -> Set<String> { saved ?? [] }
  func save(hiddenLibraries: Set<String>, for connectionID: String) { saved = hiddenLibraries }
}

private actor ChoiceRecorder {
  private(set) var mode: ReadingMode?
  private(set) var direction: ReadingDirectionPreference?

  func record(mode: ReadingMode) { self.mode = mode }
  func record(direction: ReadingDirectionPreference) { self.direction = direction }
}
