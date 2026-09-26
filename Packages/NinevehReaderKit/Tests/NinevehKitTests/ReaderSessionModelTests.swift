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
  let position = ReadingPosition(publicationID: publication.id, page: 7, completed: false)
  try store.saveProgress(position, key: "server|p1", pendingSync: true)

  #expect(try store.cachedPublications(connectionID: "server") == [publication])
  #expect(try store.progress(key: "server|p1")?.page == 7)
}

@Test @MainActor func storeKeepsWhetherACachedPublicationIsPrivate() throws {
  let store = try ReaderStore(inMemory: true)
  let hidden = Publication(id: "p2", title: "Second", library: "Home", isPrivate: true)
  try store.cache(
    publications: [Publication(id: "p1", title: "First"), hidden], connectionID: "server")

  let cached = try store.cachedPublications(connectionID: "server")
  #expect(Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0.isPrivate) }) == ["p1": false, "p2": true])
}

@Test func readingModesAreRememberedPerSeries() async throws {
  let suite = "nineveh-tests-\(UUID().uuidString)"
  defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
  let store = UserDefaultsReadingPreferenceStore(
    defaults: try #require(UserDefaults(suiteName: suite)))

  #expect(await store.mode(for: "series|one") == nil)
  await store.save(mode: .double, for: "series|one")
  await store.save(mode: .scroll, for: "series|two")
  #expect(await store.mode(for: "series|one") == .double)
  #expect(await store.mode(for: "series|two") == .scroll)
  #expect(await store.mode(for: "series|three") == nil)
}

@Test func aSeriesWithoutAModeOpensInTheOneEarlierVersionsKeptForAll() async throws {
  let suite = "nineveh-tests-\(UUID().uuidString)"
  defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
  try #require(UserDefaults(suiteName: suite)).set("double", forKey: "readingMode")
  let store = UserDefaultsReadingPreferenceStore(
    defaults: try #require(UserDefaults(suiteName: suite)))

  #expect(await store.mode(for: "series|one") == .double)
  await store.save(mode: .scroll, for: "series|one")
  #expect(await store.mode(for: "series|one") == .scroll)
  // Choosing for one series leaves the others as they were.
  #expect(await store.mode(for: "series|two") == .double)
  #expect(UserDefaults(suiteName: suite)?.string(forKey: "readingMode") == "double")
}

@Test @MainActor func eachSeriesOpensInTheModeLastChosenForIt() async throws {
  let suite = "nineveh-tests-\(UUID().uuidString)"
  defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
  let model = ApplicationModel.preview(preferenceStore: try #require(preferences(suite: suite)))
  let connection = try #require(model.connection)
  model.activate(
    connection: connection,
    client: NinevehClient(
      connection: connection,
      credentials: Credentials(username: "reader", password: "secret"),
      transport: OfflineTransport()))
  let moonGarden = try #require(model.seriesGroups.first { $0.title == "Moon Garden" })
  let tinLantern = try #require(model.seriesGroups.first { $0.title == "Tin Lantern" })

  await model.beginReading(moonGarden.volumes[0])
  let first = try #require(model.presentedReader)
  #expect(first.initialMode == .single)
  await first.actions.saveMode(.double)

  await model.beginReading(tinLantern.volumes[0])
  #expect(model.presentedReader?.initialMode == .single)
  await model.beginReading(try #require(moonGarden.volumes.last))
  #expect(model.presentedReader?.initialMode == .double)
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

@Test @MainActor func libraryListsPrivateSeriesOnlyInThePrivateCollection() throws {
  let model = ApplicationModel.preview()

  #expect(model.privateSeriesGroups.map(\.title) == ["Quiet Hours", "Red Ledger"])
  #expect(model.privateLibraries == ["Home Library", "Studio Shelf"])
  // Not on Home, in a library, or in their searches.
  #expect(!model.seriesGroups.contains { $0.isPrivate })
  #expect(!model.publications.contains { $0.isPrivate })
  #expect(model.seriesGroups(in: "Home Library").allSatisfy { !$0.isPrivate })
  #expect(model.series(matching: "quiet").isEmpty)
  #expect(!model.continueReading.contains { $0.id == "quiet-hours-1" })
  // The collection has its own.
  #expect(model.series(matching: "quiet", privateCollection: true).map(\.title) == ["Quiet Hours"])
  #expect(
    model.seriesGroups(in: "Studio Shelf", privateCollection: true).map(\.title) == ["Red Ledger"])
  #expect(model.categories(in: nil, privateCollection: true) == [.comics, .manga])
  // Its series still open like any other.
  let quietHours = try #require(model.privateSeriesGroups.first)
  #expect(model.series(for: quietHours.key)?.title == "Quiet Hours")
  #expect(model.series(containing: quietHours.volumes[0])?.key == quietHours.key)
  #expect(model.detail(for: quietHours)?.isPrivate == true)
  #expect(model.progress(for: quietHours).fraction > 0)
}

@Test @MainActor func anAdministratorMovesASeriesIntoThePrivateCollectionAndBack() async throws {
  let model = ApplicationModel.preview()
  let server = ServerStub()
  try connect(model, to: server)
  let moonGarden = try #require(model.seriesGroups.first { $0.title == "Moon Garden" })
  #expect(model.isAdministrator)

  await model.setPrivate(true, for: moonGarden)

  // Filed where Nineveh now lists it: only in the collection, page and all.
  #expect(!model.seriesGroups.contains { $0.key == moonGarden.key })
  #expect(!model.publications.contains { $0.series?.serverID == "moon-garden" })
  #expect(model.series(matching: "moon").isEmpty)
  #expect(model.series(matching: "moon", privateCollection: true).map(\.title) == ["Moon Garden"])
  #expect(model.series(for: moonGarden.key)?.isPrivate == true)
  #expect(model.detail(for: moonGarden)?.isPrivate == true)

  await model.setPrivate(false, for: try #require(model.series(for: moonGarden.key)))

  #expect(model.series(matching: "moon").map(\.title) == ["Moon Garden"])
  #expect(model.series(for: moonGarden.key)?.isPrivate == false)
  #expect(model.detail(for: moonGarden)?.isPrivate == false)
  #expect(model.seriesBeingMoved.isEmpty)
  let sent = await server.requests
  #expect(sent.map(\.httpMethod) == ["PUT", "PUT"])
  #expect(sent.allSatisfy { $0.url?.path == "/api/v1/series/moon-garden/privacy" })
  let bodies = sent.map { request in
    request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Bool] }
  }
  #expect(bodies == [["private": true], ["private": false]])
}

@Test @MainActor func stopsOfferingThePrivateCollectionOnceNinevehRefuses() async throws {
  let model = ApplicationModel.preview()
  try connect(model, to: ServerStub(refusesPrivacy: true))
  let moonGarden = try #require(model.seriesGroups.first { $0.title == "Moon Garden" })

  await model.setPrivate(true, for: moonGarden)

  #expect(model.series(for: moonGarden.key)?.isPrivate == false)
  #expect(model.alertMessage == "Administrator access required")
  // No longer an administrator, so the series page no longer offers the move.
  #expect(!model.isAdministrator)
}

@Test @MainActor func learnsTheAccountOnceNinevehAnswers() async throws {
  // As after a launch with Nineveh unreachable: connected, account unknown.
  let model = ApplicationModel(store: try ReaderStore(inMemory: true))
  let server = ServerStub()
  let connection = try ServerConnection.validated(
    urlText: "https://library.example", username: "reader")
  model.activate(
    connection: connection,
    client: NinevehClient(
      connection: connection, credentials: Credentials(username: "reader", password: "secret"),
      transport: server))
  #expect(model.account == nil)

  await model.refresh()
  await model.refresh()

  #expect(model.isAdministrator)
  let asked = await server.requests.filter { $0.url?.path == "/api/v1/auth/me" }
  #expect(asked.count == 1)
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
  #expect(model.privateSeriesGroups.map(\.title) == ["Quiet Hours"])
  #expect(await visibility.saved == ["Studio Shelf"])

  model.setLibrary("Home Library", shown: false)
  #expect(model.publications.isEmpty)
  #expect(model.privatePublications.isEmpty)
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
    initialPosition: ReadingPosition(publicationID: "volume-1", page: page, completed: completed),
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

/// Reading preferences kept in a suite of their own.
private func preferences(suite: String) -> UserDefaultsReadingPreferenceStore? {
  guard let defaults = UserDefaults(suiteName: suite) else { return nil }
  return UserDefaultsReadingPreferenceStore(defaults: defaults)
}

/// A server that never answers, so a volume opens from what the device has.
private struct OfflineTransport: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    throw URLError(.notConnectedToInternet)
  }

  func download(for request: URLRequest) async throws -> (URL, URLResponse) {
    throw URLError(.notConnectedToInternet)
  }
}

/// Connects a preview library to `transport`, as signing in would.
@MainActor private func connect(_ model: ApplicationModel, to transport: some HTTPTransport) throws {
  let connection = try #require(model.connection)
  model.activate(
    connection: connection,
    client: NinevehClient(
      connection: connection, credentials: Credentials(username: "reader", password: "secret"),
      transport: transport))
}

/// Answers as Nineveh does for an administrator with an empty catalog, or
/// refuses a series' move as it does for any other account.
private actor ServerStub: HTTPTransport {
  let refusesPrivacy: Bool
  private(set) var requests: [URLRequest] = []

  init(refusesPrivacy: Bool = false) {
    self.refusesPrivacy = refusesPrivacy
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard let url = request.url else { throw URLError(.badURL) }
    var status = 200
    let body: String
    switch url.path {
    case "/api/v1/auth/me":
      body = #"{"id": "1", "username": "reader", "isAdmin": true, "enabled": true}"#
    case "/opds/v2/catalog.json":
      body = #"{"metadata": {"title": "Nineveh"}, "links": [], "navigation": []}"#
    case "/opds/v2/publications.json":
      body = #"{"metadata": {"title": "Publications"}, "publications": [], "links": []}"#
    case let path where path.hasSuffix("/privacy") && refusesPrivacy:
      status = 403
      body = #"{"detail": "Administrator access required"}"#
    case let path where path.hasSuffix("/privacy"):
      let id = url.deletingLastPathComponent().lastPathComponent
      let sent = request.httpBody.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Bool]
      }
      body = #"""
        {"id": "\#(id)", "library": "Home Library", "category": "manga",
         "localName": "\#(id)", "title": "\#(id)", "publicationCount": 3,
         "metadata": null, "isPrivate": \#(sent?["private"] == true)}
        """#
    default:
      status = 404
      body = #"{"detail": "Not Found"}"#
    }
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
    return (Data(body.utf8), response ?? URLResponse())
  }

  func download(for request: URLRequest) async throws -> (URL, URLResponse) {
    throw URLError(.unsupportedURL)
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
