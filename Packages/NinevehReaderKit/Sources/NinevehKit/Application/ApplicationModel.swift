import Combine
import Foundation
import NinevehCore

/// A page the library's navigation stack can show.
public enum LibraryRoute: Hashable, Sendable {
  case series(SeriesKey)
  case publication(Publication)
  case collection(PublicationCollection)
}

@MainActor
public final class ApplicationModel: ObservableObject {
  public enum Phase: Equatable {
    case restoring
    case signedOut
    case ready
  }

  @Published public private(set) var phase: Phase = .restoring
  /// The public publications in libraries that are shown.
  @Published public private(set) var publications: [Publication] = []
  @Published public private(set) var seriesGroups: [SeriesGroup] = []
  /// The Private Collection's publications in libraries that are shown. Like
  /// the web's, they are listed only in the collection: not on Home, in the
  /// libraries, or in their searches.
  @Published public private(set) var privatePublications: [Publication] = []
  @Published public private(set) var privateSeriesGroups: [SeriesGroup] = []
  /// The libraries that are shown.
  @Published public private(set) var libraries: [LibrarySummary] = []
  /// Every library on the server, hidden or not.
  @Published public private(set) var allLibraries: [LibrarySummary] = []
  @Published public private(set) var hiddenLibraries: Set<String> = []
  /// Keyed by series id.
  @Published public private(set) var seriesDetails: [String: SeriesDetail] = [:]
  @Published public private(set) var downloads: [DownloadRecord] = []
  @Published public private(set) var localBooks: [LocalBook] = []
  @Published public private(set) var positions: [String: ReadingPosition] = [:]
  @Published public private(set) var connection: ServerConnection?
  /// The signed-in account as Nineveh last described it; `nil` until it has
  /// answered since launch.
  @Published public private(set) var account: Account?
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var isRefreshingMetadata = false
  /// Series being moved into or out of the Private Collection, by server id.
  @Published public private(set) var seriesBeingMoved: Set<String> = []
  /// Changes when series covers are fetched again, so views showing one reload it.
  @Published public private(set) var coverGeneration = 0
  @Published public var presentedReader: ReaderDestination?
  @Published public var libraryPath: [LibraryRoute] = []
  @Published public var alertMessage: String?

  private let credentialStore: any CredentialStoring
  private let connectionStore: any ConnectionStoring
  private let preferenceStore: any ReadingPreferenceStoring
  private let visibilityStore: any LibraryVisibilityStoring
  private let store: ReaderStore
  private let localLibrary: LocalLibraryService
  private var client: NinevehClient?
  private var downloadService: DownloadService?
  private var pageSourceResolver: PageSourceResolver?
  private var downloadTask: Task<Void, Never>?
  private var detailTask: Task<Void, Never>?
  private var positionTask: Task<Void, Never>?
  private var downloadQueue: [Publication] = []
  private var activeDownloadID: String?
  /// Every publication on the server, public or private, including those in
  /// hidden libraries.
  private var catalog: [Publication] = []
  /// The latest write of `hiddenLibraries`, which the next one waits for.
  private(set) var visibilitySave: Task<Void, Never>?
  private var knownPublications: [String: Publication] = [:]
  private var seriesByKey: [SeriesKey: SeriesGroup] = [:]
  private var seriesKeyByPublication: [String: SeriesKey] = [:]
  /// When this device last changed each position, so a server answer that
  /// left before the change cannot undo it.
  private var localWrites: [String: Date] = [:]
  private let imageCache = ImageDataCache()

  public init(
    store: ReaderStore,
    credentialStore: any CredentialStoring = KeychainCredentialStore(),
    connectionStore: any ConnectionStoring = UserDefaultsConnectionStore(),
    preferenceStore: any ReadingPreferenceStoring = UserDefaultsReadingPreferenceStore(),
    libraryVisibilityStore: any LibraryVisibilityStoring = UserDefaultsLibraryVisibilityStore()
  ) {
    self.store = store
    self.credentialStore = credentialStore
    self.connectionStore = connectionStore
    self.preferenceStore = preferenceStore
    self.visibilityStore = libraryVisibilityStore
    self.localLibrary = LocalLibraryService(store: store)
  }

  public static func live() -> ApplicationModel {
    do {
      return ApplicationModel(store: try ReaderStore())
    } catch {
      do {
        let model = ApplicationModel(store: try ReaderStore(inMemory: true))
        model.alertMessage =
          "Local storage is unavailable. Changes will not persist after quitting."
        return model
      } catch {
        preconditionFailure("Unable to initialize Nineveh Reader storage: \(error)")
      }
    }
  }

  public static func preview(
    preferenceStore: any ReadingPreferenceStoring = UserDefaultsReadingPreferenceStore(),
    libraryVisibilityStore: any LibraryVisibilityStoring = UserDefaultsLibraryVisibilityStore()
  ) -> ApplicationModel {
    guard let url = URL(string: "https://library.example") else {
      preconditionFailure("Invalid preview URL")
    }
    do {
      let model = ApplicationModel(
        store: try ReaderStore(inMemory: true), preferenceStore: preferenceStore,
        libraryVisibilityStore: libraryVisibilityStore)
      let connection = ServerConnection(baseURL: url, username: "reader")
      let publications = PreviewCatalog.publications
      model.connection = connection
      // An administrator, so the series pages show every action.
      model.account = Account(username: connection.username, isAdministrator: true)
      model.catalog = publications
      model.allLibraries = PreviewCatalog.libraries
      model.applyVisibility()
      model.seriesDetails = PreviewCatalog.seriesDetails
      model.knownPublications = Dictionary(uniqueKeysWithValues: publications.map { ($0.id, $0) })
      model.downloads = [
        DownloadRecord(
          id: "demo|moon-garden-1",
          publicationID: "moon-garden-1",
          title: "Moon Garden",
          seriesTitle: "Moon Garden",
          state: .completed,
          progress: 1,
          localFilename: "moon-garden-1.cbz",
          byteCount: 184_000_000
        )
      ]
      for (id, page, completed) in PreviewCatalog.positions {
        model.positions["\(connection.identity)|\(id)"] = ReadingPosition(
          publicationID: id,
          page: page,
          completed: completed,
          updatedAt: .now.addingTimeInterval(-Double(page) * 60)
        )
      }
      model.phase = .ready
      return model
    } catch {
      preconditionFailure("Unable to initialize preview storage: \(error)")
    }
  }

  // MARK: - Session

  public func restore() async {
    do {
      try reloadLocalBooks()
      guard let savedConnection = try await connectionStore.load(),
        let password = try await credentialStore.password(for: savedConnection)
      else {
        phase = .signedOut
        return
      }
      do {
        try await establish(connection: savedConnection, password: password, persist: false)
      } catch {
        activate(connection: savedConnection, password: password)
        await loadHiddenLibraries()
        loadOfflineLibrary()
        phase = .ready
        alertMessage = "Nineveh is unavailable. Showing your offline library."
      }
    } catch {
      phase = .signedOut
      alertMessage = error.localizedDescription
    }
  }

  public func signIn(server: String, username: String, password: String) async {
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      guard !password.isEmpty else { throw ReaderError.missingCredentials }
      let connection = try ServerConnection.validated(urlText: server, username: username)
      try await establish(connection: connection, password: password, persist: true)
    } catch {
      phase = .signedOut
      alertMessage = error.localizedDescription
    }
  }

  public func signOut() async {
    downloadTask?.cancel()
    downloadTask = nil
    detailTask?.cancel()
    positionTask?.cancel()
    downloadQueue.removeAll()
    activeDownloadID = nil
    if let connection {
      try? await credentialStore.removePassword(for: connection)
    }
    try? await connectionStore.remove()
    client = nil
    downloadService = nil
    pageSourceResolver = nil
    presentedReader = nil
    libraryPath = []
    catalog = []
    publications = []
    privatePublications = []
    reindexSeries()
    allLibraries = []
    libraries = []
    hiddenLibraries = []
    seriesDetails = [:]
    downloads = []
    positions = [:]
    connection = nil
    account = nil
    phase = .signedOut
  }

  public func continueOffline() {
    phase = .ready
  }

  public func showSignIn() {
    phase = .signedOut
  }

  public func refresh() async {
    guard let client, let connection else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let snapshot = try await client.catalog()
      catalog = snapshot.publications
      allLibraries = snapshot.libraries.isEmpty ? librariesInCatalog() : snapshot.libraries
      applyVisibility()
      for publication in catalog { knownPublications[publication.id] = publication }
      try store.replaceCachedPublications(catalog, connectionID: connection.identity)
      loadCachedPositions()
      saveCatalogExtras()
      prefetchSeriesDetails()
      startPositionSync()
      // Unknown when Nineveh was unreachable at launch.
      if account == nil { account = try? await client.account() }
    } catch {
      if catalog.isEmpty { loadOfflineLibrary() }
      alertMessage = error.localizedDescription
    }
  }

  /// Fetches series details and covers again, for metadata changed on Nineveh
  /// since they were loaded, along with the page geometry kept with
  /// downloaded volumes. Without a series, refreshes every one shown.
  public func refreshMetadata(for series: SeriesGroup? = nil) async {
    guard let client, let connection, !isRefreshingMetadata else { return }
    let ids = series.map { $0.serverID.map { [$0] } ?? [] }
      ?? Array(Set((seriesGroups + privateSeriesGroups).compactMap(\.serverID)))
    guard !ids.isEmpty else { return }
    isRefreshingMetadata = true
    defer { isRefreshingMetadata = false }
    if series == nil { detailTask?.cancel() }
    let fetched = await gather(ids, limit: 6) { id in try? await client.seriesDetail(id: id) }
    guard !fetched.isEmpty else {
      alertMessage = "Nineveh did not send series metadata. Try again once it is reachable."
      return
    }
    seriesDetails.merge(fetched) { _, new in new }
    for id in fetched.keys {
      await imageCache.removeValue(for: seriesCoverKey(id, connection: connection))
    }
    coverGeneration += 1
    saveCatalogExtras()
    await refreshDownloadGeometry(in: series)
  }

  /// Brings the page geometry kept with downloads up to date, so their spreads
  /// pair as Nineveh now pairs them the next time they open.
  private func refreshDownloadGeometry(in series: SeriesGroup?) async {
    guard let resolver = pageSourceResolver else { return }
    let volumes = series.map { Set($0.volumes.map(\.id)) }
    let ids = downloads
      .filter { $0.state == .completed && volumes?.contains($0.publicationID) != false }
      .map(\.publicationID)
    guard !ids.isEmpty else { return }
    _ = await gather(ids, limit: 4) { id in
      await resolver.refreshGeometry(publicationID: id) ? true : nil
    }
  }

  // MARK: - Library visibility

  /// Shows or hides a library everywhere: the sidebar, Home, search, and every
  /// list of series, volumes, and downloads. Remembered for this server.
  public func setLibrary(_ name: String, shown: Bool) {
    guard hiddenLibraries.contains(name) == shown else { return }
    if shown { hiddenLibraries.remove(name) } else { hiddenLibraries.insert(name) }
    applyVisibility()
    if shown {
      // Its series were not looked up while it was hidden.
      prefetchSeriesDetails()
      startPositionSync()
    }
    guard let connection else { return }
    let visibilityStore = self.visibilityStore
    let hidden = hiddenLibraries
    let previous = visibilitySave
    visibilitySave = Task {
      await previous?.value
      await visibilityStore.save(hiddenLibraries: hidden, for: connection.identity)
    }
  }

  /// Downloads, leaving out volumes in hidden libraries.
  public var shownDownloads: [DownloadRecord] {
    guard !hiddenLibraries.isEmpty else { return downloads }
    return downloads.filter { record in
      knownPublications[record.publicationID]?.library.map { !hiddenLibraries.contains($0) }
        ?? true
    }
  }

  // MARK: - Series

  public func series(for key: SeriesKey) -> SeriesGroup? {
    seriesByKey[key]
  }

  public func series(containing publication: Publication) -> SeriesGroup? {
    seriesKeyByPublication[publication.id].flatMap { seriesByKey[$0] }
  }

  public func detail(for series: SeriesGroup) -> SeriesDetail? {
    series.serverID.flatMap { seriesDetails[$0] }
  }

  /// The metadata title when the server has one, otherwise the folder name.
  public func displayTitle(for series: SeriesGroup) -> String {
    detail(for: series)?.title ?? series.title
  }

  /// Who made a volume: its series' writers and artists when Nineveh has
  /// metadata for it, else the names the volume itself carries.
  public func creators(of publication: Publication) -> [String] {
    if let metadata = series(containing: publication).flatMap(detail(for:))?.metadata {
      var seen = Set<String>()
      let names = (metadata.authors + metadata.artists).filter { seen.insert($0).inserted }
      if !names.isEmpty { return names }
    }
    return publication.authors
  }

  /// Public series, or with `privateCollection` the Private Collection's.
  public func seriesGroups(
    in library: String?, category: PublicationCategory? = nil, privateCollection: Bool = false
  ) -> [SeriesGroup] {
    (privateCollection ? privateSeriesGroups : seriesGroups).filter { group in
      (library == nil || group.library == library)
        && (category == nil || group.category == category)
    }
  }

  public func categories(in library: String?, privateCollection: Bool = false)
    -> [PublicationCategory]
  {
    let present = Set(
      seriesGroups(in: library, privateCollection: privateCollection).map(\.category))
    return PublicationCategory.allCases.filter(present.contains)
  }

  /// The libraries the Private Collection has series in, as the server
  /// names them, leaving out hidden ones.
  public var privateLibraries: [String] {
    Set(privateSeriesGroups.compactMap(\.library))
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  /// Series whose titles, alternative titles, or creators contain every word
  /// of `query`, ignoring case and accents.
  public func series(
    matching query: String, in library: String? = nil, privateCollection: Bool = false
  ) -> [SeriesGroup] {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    let candidates = seriesGroups(in: library, privateCollection: privateCollection)
    guard !words.isEmpty else { return candidates }
    return candidates.filter { group in
      let haystack = searchText(for: group)
      return words.allSatisfy {
        haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
    }
  }

  /// Refetches what the series page shows: its details and every volume's position.
  public func refreshSeries(_ series: SeriesGroup) async {
    guard let client else { return }
    if let serverID = series.serverID,
      let detail = try? await client.seriesDetail(id: serverID)
    {
      seriesDetails[serverID] = detail
      saveCatalogExtras()
    }
    await syncPositions(for: series.volumes)
  }

  /// Whether the account may move series into or out of the Private Collection.
  public var isAdministrator: Bool {
    account?.isAdministrator == true
  }

  /// Moves a series into or out of the Private Collection, as the series page
  /// on the web does, and files its volumes where Nineveh now lists them.
  public func setPrivate(_ isPrivate: Bool, for series: SeriesGroup) async {
    guard let client, let connection, let id = series.serverID,
      seriesBeingMoved.insert(id).inserted
    else { return }
    defer { seriesBeingMoved.remove(id) }
    do {
      let detail = try await client.setPrivate(isPrivate, seriesID: id)
      seriesDetails[id] = detail
      catalog = catalog.map { publication in
        guard publication.series?.serverID == id else { return publication }
        let moved = publication.filed(
          in: publication.category, library: publication.library, isPrivate: detail.isPrivate)
        knownPublications[moved.id] = moved
        return moved
      }
      applyVisibility()
      try? store.replaceCachedPublications(catalog, connectionID: connection.identity)
      saveCatalogExtras()
    } catch {
      if case ReaderError.server(403, _) = error {
        // No longer an administrator: stop offering what Nineveh refuses.
        account = account.map { Account(username: $0.username) }
      }
      alertMessage = error.localizedDescription
    }
  }

  public func progress(for publication: Publication) -> VolumeProgress {
    VolumeProgress(position: position(for: publication), pageCount: publication.pageCount)
  }

  public func progress(for series: SeriesGroup) -> SeriesProgress {
    SeriesProgress(series.volumes.map(progress(for:)))
  }

  /// Volumes part-way through, most recently read first.
  public var continueReading: [Publication] {
    publications
      .compactMap { publication -> (Publication, Date)? in
        guard let position = position(for: publication), !position.completed else { return nil }
        return (publication, position.updatedAt)
      }
      .sorted { $0.1 > $1.1 }
      .map(\.0)
  }

  /// The unopened volume after the last one finished in each series, most
  /// recently finished first.
  public var upNext: [Publication] {
    seriesGroups
      .compactMap { group -> (Publication, Date)? in
        let read = group.volumes.compactMap { volume in
          position(for: volume).map { (volume, $0) }
        }
        guard let (latest, position) = read.max(by: { $0.1.updatedAt < $1.1.updatedAt }),
          position.completed,
          let next = group.volume(after: latest),
          self.position(for: next) == nil
        else { return nil }
        return (next, position.updatedAt)
      }
      .sorted { $0.1 > $1.1 }
      .map(\.0)
  }

  public func showSeries(_ key: SeriesKey) {
    presentedReader = nil
    let route = LibraryRoute.series(key)
    if let index = libraryPath.lastIndex(of: route) {
      libraryPath = Array(libraryPath[...index])
    } else {
      libraryPath.append(route)
    }
  }

  // MARK: - Covers

  public func coverData(for publication: Publication) async -> Data? {
    let key = "\(connection?.identity ?? "offline")|\(publication.id)"
    if let cached = await imageCache.value(for: key) { return cached }
    if let connection,
      let localURL = try? store.downloadedURL(
        publicationID: publication.id,
        connectionID: connection.identity
      ),
      let localData = try? await CBZArchiveSource(url: localURL).page(
        number: 1,
        maximumPixelWidth: 480
      )
    {
      await imageCache.insert(localData, for: key)
      return localData
    }
    guard let client else { return nil }
    let data = try? await client.cover(for: publication)
    if let data { await imageCache.insert(data, for: key) }
    return data
  }

  public func coverData(forPublicationID id: String) async -> Data? {
    guard let publication = knownPublications[id] else { return nil }
    return await coverData(for: publication)
  }

  /// The cover chosen for the series on the server, else its first volume's.
  public func seriesCoverData(for series: SeriesGroup) async -> Data? {
    if let serverID = series.serverID, let client, let connection {
      let key = seriesCoverKey(serverID, connection: connection)
      if let cached = await imageCache.value(for: key) { return cached }
      if let data = try? await client.seriesCover(id: serverID) {
        await imageCache.insert(data, for: key)
        return data
      }
    }
    guard let first = series.volumes.first else { return nil }
    return await coverData(for: first)
  }

  public func localCoverData(for book: LocalBook) async -> Data? {
    let key = "local|\(book.id)"
    if let cached = await imageCache.value(for: key) { return cached }
    guard let source = try? await localLibrary.source(for: book),
      let data = try? await source.page(number: 1, maximumPixelWidth: 480)
    else { return nil }
    await imageCache.insert(data, for: key)
    return data
  }

  // MARK: - Reading

  public func beginReading(_ publication: Publication, fromStart: Bool = false) async {
    guard let resolver = pageSourceResolver, let connection, let client else { return }
    do {
      let source = try await resolver.source(for: publication)
      let key = progressKey(publication.id, connection: connection)
      let publicationID = publication.id
      let startedAt = Date.now
      // Another device may have read further; offline, what is saved here is enough.
      if let remote = await firstResult(
        within: 2.5, { await RemotePosition.fetch(publicationID, from: client) })
      {
        reconcile(publicationID: publicationID, remote: remote.value, requestedAt: startedAt)
      }
      let initial = try store.progress(key: key)
      positions[key] = initial

      let series = self.series(containing: publication)
      let directionKey = series.map(directionKey(for:)) ?? key
      var preference = await preferenceStore.direction(for: directionKey)
      if preference == nil { preference = await preferenceStore.direction(for: key) }
      // Each series opens as it was last read on this device, as on the web.
      let mode = await preferenceStore.mode(for: directionKey) ?? .single
      let volumes = series?.volumes ?? [publication]
      let preferenceStore = self.preferenceStore
      let seriesTitle: String? = series.map { displayTitle(for: $0) }

      var actions = ReaderActions(
        savePosition: { [weak self] position in
          guard let self else { return .savedLocally(retryable: false) }
          return await self.save(position: position, key: key, syncRemote: true)
        },
        saveDirection: { await preferenceStore.save(direction: $0, for: directionKey) },
        saveMode: { await preferenceStore.save(mode: $0, for: directionKey) },
        cover: { [weak self] id in await self?.coverData(forPublicationID: id) }
      )
      if volumes.count > 1 {
        actions.openVolume = { [weak self] id in await self?.openVolume(id) }
      }
      if let seriesKey = series?.key {
        actions.showSeries = { [weak self] in await self?.showSeries(seriesKey) }
      }
      let context = ReaderContext(
        seriesTitle: seriesTitle,
        volumes: volumes.map { ReaderVolume($0) },
        currentIndex: volumes.firstIndex { $0.id == publicationID }
      )

      presentedReader = ReaderDestination(
        id: key,
        publicationID: publicationID,
        title: publication.title,
        subtitle: seriesTitle ?? publication.series?.title,
        source: source,
        initialPosition: initial,
        startsAtBeginning: fromStart,
        initialMode: mode,
        defaultDirection: publication.category.defaultDirection,
        directionPreference: preference ?? .automatic,
        context: context,
        actions: actions
      )
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  public func beginReading(_ book: LocalBook) async {
    do {
      let source = try await localLibrary.source(for: book)
      let key = "local|\(book.id)"
      let initial = try store.progress(key: key)
      let preference = await preferenceStore.direction(for: key) ?? .automatic
      let mode = await preferenceStore.mode(for: key) ?? .single
      let preferenceStore = self.preferenceStore
      presentedReader = ReaderDestination(
        id: key,
        publicationID: book.id,
        title: book.title,
        source: source,
        initialPosition: initial,
        initialMode: mode,
        directionPreference: preference,
        actions: ReaderActions(
          savePosition: { [weak self] position in
            await self?.save(position: position, key: key, syncRemote: false) ?? .saved
          },
          saveDirection: { await preferenceStore.save(direction: $0, for: key) },
          saveMode: { await preferenceStore.save(mode: $0, for: key) }
        )
      )
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  public func markRead(_ publication: Publication) async {
    guard let connection else { return }
    var pageCount = publication.pageCount
    if pageCount == nil, let client {
      pageCount = try? await client.manifest(for: publication.id).totalPages
    }
    guard let pageCount, pageCount > 0 else {
      alertMessage = "“\(publication.title)” cannot be marked as read while Nineveh is unavailable."
      return
    }
    let position = ReadingPosition(publicationID: publication.id, page: pageCount, completed: true)
    let result = await save(
      position: position, key: progressKey(publication.id, connection: connection),
      syncRemote: true)
    if result == .savedLocally(retryable: false) {
      alertMessage = "Nineveh did not accept “\(publication.title)” as read."
    }
  }

  public func markUnread(_ publication: Publication) async {
    guard let connection else { return }
    let key = progressKey(publication.id, connection: connection)
    do {
      guard let client else { throw ReaderError.invalidResponse }
      try await client.clearPosition(for: publication.id)
      try store.removeProgress(key: key)
      localWrites[key] = .now
      positions[key] = nil
    } catch {
      alertMessage = "“\(publication.title)” could not be marked as unread. \(error.localizedDescription)"
    }
  }

  // MARK: - Downloads and local files

  public func download(_ publication: Publication) async {
    guard downloadService != nil else { return }
    do {
      try await enqueueDownloads([publication])
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  public func downloadSeries(containing publication: Publication) async {
    guard let series = publication.series, downloadService != nil else {
      await download(publication)
      return
    }
    do {
      var volumes = self.series(containing: publication)?.volumes ?? []
      if volumes.isEmpty, let client {
        volumes = try await client.publications(
          in: series, library: publication.library, isPrivate: publication.isPrivate)
      }
      let needed = volumes.filter { !isDownloaded($0) || updateAvailable(for: $0) }
      try await enqueueDownloads(needed)
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  public func downloadSeries(_ series: SeriesGroup) async {
    guard downloadService != nil else { return }
    do {
      try await enqueueDownloads(
        series.volumes.filter { !isDownloaded($0) || updateAvailable(for: $0) })
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  public func removeDownload(_ record: DownloadRecord) async {
    do {
      try await downloadService?.remove(record)
      try reloadDownloads()
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  public func retryDownload(_ record: DownloadRecord) async {
    guard let publication = knownPublications[record.publicationID] else {
      alertMessage = "This publication is not in the current catalog."
      return
    }
    await download(publication)
  }

  public func addLocalFiles(_ urls: [URL], kind: LocalBookKind) async {
    for url in urls {
      do {
        _ = try await localLibrary.add(url: url, kind: kind)
      } catch {
        alertMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
      }
    }
    try? reloadLocalBooks()
  }

  public func removeLocalBook(_ book: LocalBook) async {
    do {
      try store.removeLocalBook(id: book.id)
      try reloadLocalBooks()
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  public func isDownloaded(_ publication: Publication) -> Bool {
    downloads.contains { $0.publicationID == publication.id && $0.localFilename != nil }
  }

  public func updateAvailable(for publication: Publication) -> Bool {
    guard let record = downloadRecord(for: publication), record.localFilename != nil else {
      return false
    }
    return publication.revision != nil && publication.revision != record.revision
  }

  public func downloadRecord(for publication: Publication) -> DownloadRecord? {
    downloads.first { $0.publicationID == publication.id }
  }

  /// How many of the series' volumes are downloaded.
  public func downloadedCount(in series: SeriesGroup) -> Int {
    let downloaded = Set(downloads.lazy.filter { $0.localFilename != nil }.map(\.publicationID))
    return series.volumes.count { downloaded.contains($0.id) }
  }

  /// Where a finished download's file is, if it is still there.
  public func downloadedFileURL(for record: DownloadRecord) -> URL? {
    guard let filename = record.localFilename else { return nil }
    let url = store.downloadsDirectory.appending(path: filename)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  public func position(for publication: Publication) -> ReadingPosition? {
    guard let connection else { return nil }
    return positions[progressKey(publication.id, connection: connection)]
  }

  // MARK: - Private

  private func establish(connection: ServerConnection, password: String, persist: Bool) async throws
  {
    let credentials = Credentials(username: connection.username, password: password)
    let client = NinevehClient(connection: connection, credentials: credentials)
    let account = try await client.authenticate()
    if persist {
      try await credentialStore.save(password: password, for: connection)
      try await connectionStore.save(connection)
    }
    activate(connection: connection, client: client)
    self.account = account
    await loadHiddenLibraries()
    loadOfflineLibrary()
    phase = .ready
    await syncPendingProgress()
    await refresh()
    await resumePendingDownloads()
  }

  private func activate(connection: ServerConnection, password: String) {
    let client = NinevehClient(
      connection: connection,
      credentials: Credentials(username: connection.username, password: password)
    )
    activate(connection: connection, client: client)
  }

  func activate(connection: ServerConnection, client: NinevehClient) {
    self.connection = connection
    self.client = client
    downloadService = DownloadService(
      client: client, store: store, connectionID: connection.identity)
    pageSourceResolver = PageSourceResolver(
      client: client, store: store, connectionID: connection.identity)
  }

  private func loadOfflineLibrary() {
    guard let connection else { return }
    catalog = (try? store.cachedPublications(connectionID: connection.identity)) ?? []
    knownPublications = Dictionary(
      catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let extras = store.catalogExtras(connectionID: connection.identity)
    allLibraries =
      extras?.libraries.isEmpty == false ? extras?.libraries ?? [] : librariesInCatalog()
    applyVisibility()
    seriesDetails = extras?.seriesDetails ?? [:]
    try? reloadDownloads()
    loadCachedPositions()
  }

  private func loadHiddenLibraries() async {
    guard let connection else { return }
    hiddenLibraries = await visibilityStore.hiddenLibraries(for: connection.identity)
  }

  /// Shows what of the catalog is not in a hidden library.
  private func applyVisibility() {
    let hidden = hiddenLibraries
    let shown = catalog.filter { $0.library.map { !hidden.contains($0) } ?? true }
    publications = shown.filter { !$0.isPrivate }
    privatePublications = shown.filter(\.isPrivate)
    libraries = allLibraries.filter { !hidden.contains($0.name) }
    reindexSeries()
  }

  private func reindexSeries() {
    seriesGroups = CatalogOrganizer.series(from: publications)
    privateSeriesGroups = CatalogOrganizer.series(from: privatePublications)
    let groups = seriesGroups + privateSeriesGroups
    seriesByKey = Dictionary(groups.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    seriesKeyByPublication = [:]
    for group in groups {
      for volume in group.volumes { seriesKeyByPublication[volume.id] = group.key }
    }
  }

  /// The libraries public series are in, for a server that does not list its libraries.
  private func librariesInCatalog() -> [LibrarySummary] {
    Set(catalog.filter { !$0.isPrivate }.compactMap(\.library))
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .map { LibrarySummary(name: $0) }
  }

  private func searchText(for group: SeriesGroup) -> String {
    var fields = [group.title, group.library ?? ""]
    if let detail = detail(for: group) {
      fields.append(detail.title)
      fields.append(detail.localName)
      if let metadata = detail.metadata {
        fields += metadata.alternativeTitles + metadata.authors + metadata.artists
      }
    }
    for volume in group.volumes {
      fields.append(volume.title)
      fields += volume.authors
    }
    return fields.joined(separator: "\n")
  }

  private func saveCatalogExtras() {
    guard let connection else { return }
    store.save(
      catalogExtras: CatalogExtras(libraries: allLibraries, seriesDetails: seriesDetails),
      connectionID: connection.identity)
  }

  private func prefetchSeriesDetails() {
    detailTask?.cancel()
    guard let client else { return }
    let ids = Array(Set((seriesGroups + privateSeriesGroups).compactMap(\.serverID)))
    guard !ids.isEmpty else { return }
    detailTask = Task { [weak self] in
      let fetched = await gather(ids, limit: 6) { id in try? await client.seriesDetail(id: id) }
      guard !Task.isCancelled, let self else { return }
      // Keep what was known for series that did not answer this time, and
      // for those in hidden libraries.
      let current = Set(catalog.compactMap { $0.series?.serverID })
      seriesDetails = seriesDetails.filter { current.contains($0.key) }
        .merging(fetched) { _, new in new }
      saveCatalogExtras()
    }
  }

  private func startPositionSync() {
    positionTask?.cancel()
    guard let connection else { return }
    // Positions come one volume at a time; a very large catalog only checks
    // what has been read here, and each series catches up when it is opened.
    let shown = publications + privatePublications
    let candidates =
      shown.count <= 400
      ? shown
      : shown.filter { positions[progressKey($0.id, connection: connection)] != nil }
    positionTask = Task { [weak self] in await self?.syncPositions(for: candidates) }
  }

  private func syncPositions(for volumes: [Publication]) async {
    guard let client, !volumes.isEmpty else { return }
    let startedAt = Date.now
    let fetched = await gather(volumes.map(\.id), limit: 6) { id in
      await RemotePosition.fetch(id, from: client)
    }
    guard !Task.isCancelled else { return }
    for (id, remote) in fetched {
      reconcile(publicationID: id, remote: remote.value, requestedAt: startedAt)
    }
  }

  /// Takes the server's position when it is newer, and forgets one the server
  /// no longer has unless it is still waiting to be uploaded.
  private func reconcile(publicationID: String, remote: ReadingPosition?, requestedAt: Date) {
    guard let connection else { return }
    let key = progressKey(publicationID, connection: connection)
    if let written = localWrites[key], written >= requestedAt { return }
    let local = try? store.progress(key: key)
    switch (local, remote) {
    case (nil, let remote?):
      adopt(remote, key: key)
    case (let local?, let remote?) where remote.updatedAt > local.updatedAt:
      adopt(remote, key: key)
    case (.some, nil) where (try? store.isPendingSync(key: key)) != true:
      try? store.removeProgress(key: key)
      positions[key] = nil
    default:
      break
    }
  }

  private func adopt(_ position: ReadingPosition, key: String) {
    try? store.saveProgress(position, key: key, pendingSync: false)
    positions[key] = position
  }

  private func openVolume(_ id: String) async {
    guard let publication = knownPublications[id] else { return }
    // A finished volume opens at its start, as the series page's primary action does.
    await beginReading(publication, fromStart: progress(for: publication).isCompleted)
  }

  private func directionKey(for series: SeriesGroup) -> String {
    series.serverID.map { "series|\($0)" } ?? "series|\(series.library ?? "")|\(series.key.id)"
  }

  private func progressKey(_ publicationID: String, connection: ServerConnection) -> String {
    "\(connection.identity)|\(publicationID)"
  }

  private func seriesCoverKey(_ seriesID: String, connection: ServerConnection) -> String {
    "\(connection.identity)|series|\(seriesID)"
  }

  @discardableResult
  private func save(position: ReadingPosition, key: String, syncRemote: Bool) async
    -> ProgressSaveResult
  {
    positions[key] = position
    localWrites[key] = .now
    try? store.saveProgress(position, key: key, pendingSync: syncRemote)
    guard syncRemote else { return .saved }
    guard let client else { return .savedLocally(retryable: false) }
    do {
      let saved = try await client.save(position)
      // A later save may have landed while this one was in flight.
      if positions[key] == position {
        try? store.saveProgress(saved, key: key, pendingSync: false)
        positions[key] = saved
      }
      return .saved
    } catch ReaderError.authenticationFailed {
      // Kept for upload once the account is signed in again.
      return .savedLocally(retryable: false)
    } catch ReaderError.server(let statusCode, _) where (400..<500).contains(statusCode) {
      // The server refused this position; offering it again would not change that.
      try? store.saveProgress(position, key: key, pendingSync: false)
      return .savedLocally(retryable: false)
    } catch {
      return .savedLocally(retryable: true)
    }
  }

  private func reloadDownloads() throws {
    guard let connection else {
      downloads = []
      return
    }
    downloads = try store.downloads(connectionID: connection.identity)
  }

  private func reloadDownloadsIgnoringErrors() {
    try? reloadDownloads()
  }

  private func enqueueDownloads(_ publications: [Publication]) async throws {
    guard let service = downloadService else { return }
    var queuedIDs = Set(downloadQueue.map(\.id))
    if let activeDownloadID { queuedIDs.insert(activeDownloadID) }
    let additions = publications.filter { !queuedIDs.contains($0.id) }
    for publication in additions { _ = try await service.enqueue(publication) }
    downloadQueue.append(contentsOf: additions)
    try reloadDownloads()
    startDownloadWorkerIfNeeded()
  }

  private func startDownloadWorkerIfNeeded() {
    guard downloadTask == nil, let service = downloadService else { return }
    downloadTask = Task { [weak self] in
      guard let self else { return }
      while !downloadQueue.isEmpty, !Task.isCancelled {
        let publication = downloadQueue.removeFirst()
        activeDownloadID = publication.id
        await service.download(publication) { [weak self] _ in
          await self?.reloadDownloadsIgnoringErrors()
        }
        activeDownloadID = nil
      }
      downloadTask = nil
    }
  }

  private func resumePendingDownloads() async {
    let pendingIDs = Set(
      downloads
        .filter { $0.state == .queued || $0.state == .downloading }
        .map(\.publicationID)
    )
    let pending = catalog.filter { pendingIDs.contains($0.id) }
    guard !pending.isEmpty else { return }
    try? await enqueueDownloads(pending)
  }

  private func syncPendingProgress() async {
    guard let client, let connection,
      let pending = try? store.pendingProgress(connectionID: connection.identity)
    else { return }
    for item in pending {
      do {
        try await client.save(item.position)
        try store.saveProgress(item.position, key: item.key, pendingSync: false)
      } catch ReaderError.server(let statusCode, _) where (400..<500).contains(statusCode) {
        try? store.saveProgress(item.position, key: item.key, pendingSync: false)
      } catch {
        return
      }
    }
  }

  private func reloadLocalBooks() throws {
    localBooks = try store.localBooks()
  }

  private func loadCachedPositions() {
    guard let connection else { return }
    for publication in catalog {
      let key = progressKey(publication.id, connection: connection)
      positions[key] = try? store.progress(key: key)
    }
  }
}

/// What the server said about a position, including that it has none.
private struct RemotePosition: Sendable {
  let value: ReadingPosition?

  /// `nil` when the server could not be asked.
  static func fetch(_ publicationID: String, from client: NinevehClient) async -> RemotePosition? {
    do {
      return RemotePosition(value: try await client.position(for: publicationID))
    } catch {
      return nil
    }
  }
}

actor ImageDataCache {
  private var values: [String: Data] = [:]
  private var order: [String] = []
  private var byteCount = 0
  private let byteLimit: Int

  init(byteLimit: Int = 128 * 1_024 * 1_024) {
    self.byteLimit = byteLimit
  }

  func value(for key: String) -> Data? {
    guard let value = values[key] else { return nil }
    order.removeAll { $0 == key }
    order.append(key)
    return value
  }

  func insert(_ data: Data, for key: String) {
    if let existing = values[key] { byteCount -= existing.count }
    values[key] = data
    byteCount += data.count
    order.removeAll { $0 == key }
    order.append(key)

    while byteCount > byteLimit, let oldest = order.first {
      order.removeFirst()
      if let removed = values.removeValue(forKey: oldest) { byteCount -= removed.count }
    }
  }

  func removeValue(for key: String) {
    guard let removed = values.removeValue(forKey: key) else { return }
    byteCount -= removed.count
    order.removeAll { $0 == key }
  }
}

private enum PreviewCatalog {
  static let libraries = [
    LibrarySummary(name: "Home Library", publicationCount: 14),
    LibrarySummary(name: "Studio Shelf", publicationCount: 3),
  ]

  static let publications: [Publication] = [
    book("neon-harbor-1", "Neon Harbor", "Low Tide", "Mara Voss", "1", .comics),
    book("neon-harbor-2", "Neon Harbor", "The Glass Horizon", "Mara Voss", "2", .comics),
    book("moon-garden-1", "Moon Garden", "Where the Lanterns Sleep", "Ren Ishida", "1", .manga),
    book("moon-garden-2", "Moon Garden", "A Path of Paper Cranes", "Ren Ishida", "2", .manga),
    book("moon-garden-3", "Moon Garden", "The Night Market", "Ren Ishida", "3", .manga),
    book("last-astronomer", "The Last Astronomer", nil, "Elian Cross", nil, .comics),
    book("ghost-circuit-3", "Ghost Circuit", "Signal / Noise", "Aiko Mori", "3", .manga),
    book("ash-ivory-1", "Ash & Ivory", "A Crown in Winter", "Mara Voss", "1", .comics),
    book("paper-kingdom-4", "Paper Kingdom", "The Folded City", "Ren Ishida", "4", .manga),
    book("northstar-1", "Northstar", "Cold Light", "June Hale", "1", .comics),
    book("silent-orchard-2", "Silent Orchard", "Summer Rain", "Emi Tanaka", "2", .manga),
    book("atlas-below-1", "Atlas Below", "The Sunken Map", "Noah Vale", "1", .comics),
    book("blue-hour-5", "Blue Hour", "After Midnight", "Aiko Mori", "5", .manga),
    book("velvet-engine-1", "Velvet Engine", "First Ignition", "June Hale", "1", .comics),
    book("small-gods-2", "Small Gods", "A Borrowed Name", "Emi Tanaka", "2", .manga),
    book(
      "tin-lantern-1", "Tin Lantern", "Sketchbook", "Noah Vale", "1", .comics,
      library: "Studio Shelf"),
    book(
      "tin-lantern-2", "Tin Lantern", "Inks", "Noah Vale", "2", .comics, library: "Studio Shelf"),
    book("quiet-hours-1", "Quiet Hours", "Room 204", "Lena Park", "1", .manga, isPrivate: true),
    book("quiet-hours-2", "Quiet Hours", "The Late Shift", "Lena Park", "2", .manga, isPrivate: true),
    book(
      "red-ledger-1", "Red Ledger", "Old Debts", "Tomas Reyes", "1", .comics,
      library: "Studio Shelf", isPrivate: true),
  ]

  static let seriesDetails: [String: SeriesDetail] = [
    "moon-garden": SeriesDetail(
      id: "moon-garden",
      library: "Home Library",
      category: .manga,
      localName: "Moon Garden",
      title: "Moon Garden: Tales of the Lantern Road",
      publicationCount: 3,
      metadata: SeriesMetadata(
        sourceURL: URL(string: "https://mangabaka.org/1"),
        title: "Moon Garden: Tales of the Lantern Road",
        alternativeTitles: ["月の庭", "Tsuki no Niwa"],
        authors: ["Ren Ishida"],
        artists: ["Ren Ishida", "Sora Nakamura"],
        publishers: ["Lantern Press"],
        tags: ["Fantasy", "Slice of Life", "Iyashikei", "Travel"],
        description:
          "A lantern maker's apprentice walks the old road between moonlit villages, "
          + "mending lights and collecting the stories people leave behind.",
        publishedStart: "2019-04-01",
        status: "releasing",
        mediaType: "manga",
        rating: 88.4
      )
    ),
    "quiet-hours": SeriesDetail(
      id: "quiet-hours",
      library: "Home Library",
      category: .manga,
      localName: "Quiet Hours",
      title: "Quiet Hours",
      publicationCount: 2,
      metadata: nil,
      isPrivate: true
    ),
  ]

  static let positions: [(String, Int, Bool)] = [
    ("neon-harbor-2", 73, false),
    ("moon-garden-1", 192, true),
    ("ghost-circuit-3", 41, false),
    ("quiet-hours-1", 55, false),
  ]

  private static func book(
    _ id: String,
    _ series: String,
    _ subtitle: String?,
    _ author: String,
    _ volume: String?,
    _ category: PublicationCategory,
    library: String = "Home Library",
    isPrivate: Bool = false
  ) -> Publication {
    let slug = series.lowercased().replacingOccurrences(of: " ", with: "-")
    return Publication(
      id: id,
      title: subtitle ?? series,
      subtitle: subtitle,
      authors: [author],
      series: subtitle == nil ? nil : SeriesReference(id: slug, title: series, serverID: slug),
      volume: volume,
      category: category,
      pageCount: 180 + id.count * 3,
      revision: "preview-1",
      library: library,
      isPrivate: isPrivate
    )
  }
}
