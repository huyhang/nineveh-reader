import Foundation
import NinevehCore
import SwiftData

@Model
final class DownloadEntity {
  @Attribute(.unique) var key: String
  var connectionID: String
  var publicationID: String
  var title: String
  var seriesTitle: String?
  var stateRawValue: String
  var progress: Double
  var localFilename: String?
  var revision: String?
  var byteCount: Int64
  var errorMessage: String?

  init(key: String, connectionID: String, publication: Publication) {
    self.key = key
    self.connectionID = connectionID
    self.publicationID = publication.id
    self.title = publication.title
    self.seriesTitle = publication.series?.title
    self.stateRawValue = DownloadState.queued.rawValue
    self.progress = 0
    self.revision = publication.revision
    self.byteCount = 0
  }

  var record: DownloadRecord {
    DownloadRecord(
      id: key,
      publicationID: publicationID,
      title: title,
      seriesTitle: seriesTitle,
      state: DownloadState(rawValue: stateRawValue) ?? .failed,
      progress: progress,
      localFilename: localFilename,
      revision: revision,
      byteCount: byteCount,
      errorMessage: errorMessage
    )
  }
}

@Model
final class LocalBookEntity {
  @Attribute(.unique) var id: String
  var title: String
  var kindRawValue: String
  var pageCount: Int
  var createdAt: Date
  var localFilename: String?
  var bookmark: Data?

  init(
    id: String,
    title: String,
    kind: LocalBookKind,
    pageCount: Int,
    localFilename: String?,
    bookmark: Data?
  ) {
    self.id = id
    self.title = title
    self.kindRawValue = kind.rawValue
    self.pageCount = pageCount
    self.createdAt = .now
    self.localFilename = localFilename
    self.bookmark = bookmark
  }

  var record: LocalBook {
    LocalBook(
      id: id,
      title: title,
      kind: LocalBookKind(rawValue: kindRawValue) ?? .imported,
      pageCount: pageCount,
      createdAt: createdAt
    )
  }
}

@Model
final class CachedPublicationEntity {
  @Attribute(.unique) var key: String
  var connectionID: String
  var payload: Data
  var updatedAt: Date

  init(key: String, connectionID: String, payload: Data) {
    self.key = key
    self.connectionID = connectionID
    self.payload = payload
    self.updatedAt = .now
  }
}

@Model
final class ProgressEntity {
  @Attribute(.unique) var key: String
  var publicationID: String
  var page: Int
  var modeRawValue: String
  var completed: Bool
  var updatedAt: Date
  var pendingSync: Bool

  init(key: String, position: ReadingPosition, pendingSync: Bool) {
    self.key = key
    self.publicationID = position.publicationID
    self.page = position.page
    self.modeRawValue = position.mode.rawValue
    self.completed = position.completed
    self.updatedAt = position.updatedAt
    self.pendingSync = pendingSync
  }

  var position: ReadingPosition {
    ReadingPosition(
      publicationID: publicationID,
      page: page,
      mode: ReadingMode(rawValue: modeRawValue) ?? .single,
      completed: completed,
      updatedAt: updatedAt
    )
  }
}

enum NinevehReaderSchemaV1: VersionedSchema {
  static let versionIdentifier = Schema.Version(1, 0, 0)
  static var models: [any PersistentModel.Type] {
    [
      DownloadEntity.self,
      LocalBookEntity.self,
      CachedPublicationEntity.self,
      ProgressEntity.self,
    ]
  }
}

enum NinevehReaderMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [NinevehReaderSchemaV1.self] }
  static var stages: [MigrationStage] { [] }
}

public struct CatalogExtras: Codable, Sendable {
  public var libraries: [LibrarySummary]
  /// Keyed by series id.
  public var seriesDetails: [String: SeriesDetail]

  public init(libraries: [LibrarySummary] = [], seriesDetails: [String: SeriesDetail] = [:]) {
    self.libraries = libraries
    self.seriesDetails = seriesDetails
  }
}

@MainActor
public final class ReaderStore {
  private let container: ModelContainer
  private let context: ModelContext
  public let applicationSupportURL: URL
  private let isInMemory: Bool

  public init(inMemory: Bool = false) throws {
    isInMemory = inMemory
    let schema = Schema(NinevehReaderSchemaV1.models)
    let configuration = ModelConfiguration(
      "NinevehReader", schema: schema, isStoredInMemoryOnly: inMemory)
    container = try ModelContainer(
      for: schema,
      migrationPlan: NinevehReaderMigrationPlan.self,
      configurations: [configuration]
    )
    context = ModelContext(container)

    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appending(path: "Nineveh Reader", directoryHint: .isDirectory)
    applicationSupportURL = root
    if !inMemory {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableRoot = root
      try? mutableRoot.setResourceValues(values)
    }
  }

  public func cache(publications: [Publication], connectionID: String) throws {
    let encoder = JSONEncoder()
    for publication in publications {
      let key = "\(connectionID)|\(publication.id)"
      let descriptor = FetchDescriptor<CachedPublicationEntity>(
        predicate: #Predicate { $0.key == key })
      let payload = try encoder.encode(publication)
      if let entity = try context.fetch(descriptor).first {
        entity.payload = payload
        entity.updatedAt = .now
      } else {
        context.insert(
          CachedPublicationEntity(key: key, connectionID: connectionID, payload: payload))
      }
    }
    try context.save()
  }

  public func replaceCachedPublications(
    _ publications: [Publication],
    connectionID: String
  ) throws {
    let descriptor = FetchDescriptor<CachedPublicationEntity>(
      predicate: #Predicate { $0.connectionID == connectionID }
    )
    for entity in try context.fetch(descriptor) { context.delete(entity) }
    try context.save()
    try cache(publications: publications, connectionID: connectionID)
  }

  public func cachedPublications(connectionID: String) throws -> [Publication] {
    let descriptor = FetchDescriptor<CachedPublicationEntity>(
      predicate: #Predicate { $0.connectionID == connectionID },
      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
    )
    let decoder = JSONDecoder()
    return try context.fetch(descriptor).compactMap {
      try? decoder.decode(Publication.self, from: $0.payload)
    }
  }

  public func prepareDownload(_ publication: Publication, connectionID: String) throws
    -> DownloadRecord
  {
    let key = "\(connectionID)|\(publication.id)"
    let descriptor = FetchDescriptor<DownloadEntity>(predicate: #Predicate { $0.key == key })
    let entity =
      try context.fetch(descriptor).first
      ?? DownloadEntity(
        key: key,
        connectionID: connectionID,
        publication: publication
      )
    if entity.modelContext == nil { context.insert(entity) }
    entity.title = publication.title
    entity.seriesTitle = publication.series?.title
    if entity.localFilename == nil { entity.revision = publication.revision }
    entity.stateRawValue = DownloadState.queued.rawValue
    entity.progress = 0
    entity.errorMessage = nil
    try context.save()
    return entity.record
  }

  public func updateDownload(
    key: String,
    state: DownloadState,
    progress: Double,
    localFilename: String? = nil,
    revision: String? = nil,
    byteCount: Int64? = nil,
    errorMessage: String? = nil
  ) throws {
    let descriptor = FetchDescriptor<DownloadEntity>(predicate: #Predicate { $0.key == key })
    guard let entity = try context.fetch(descriptor).first else { return }
    entity.stateRawValue = state.rawValue
    entity.progress = progress
    if let localFilename { entity.localFilename = localFilename }
    if let revision { entity.revision = revision }
    if let byteCount { entity.byteCount = byteCount }
    entity.errorMessage = errorMessage
    try context.save()
  }

  public func downloads(connectionID: String) throws -> [DownloadRecord] {
    let descriptor = FetchDescriptor<DownloadEntity>(
      predicate: #Predicate { $0.connectionID == connectionID },
      sortBy: [SortDescriptor(\.title)]
    )
    return try context.fetch(descriptor).map(\.record)
  }

  public func download(key: String) throws -> DownloadRecord? {
    let descriptor = FetchDescriptor<DownloadEntity>(predicate: #Predicate { $0.key == key })
    return try context.fetch(descriptor).first?.record
  }

  public func downloadedURL(publicationID: String, connectionID: String) throws -> URL? {
    let key = "\(connectionID)|\(publicationID)"
    let descriptor = FetchDescriptor<DownloadEntity>(predicate: #Predicate { $0.key == key })
    guard let entity = try context.fetch(descriptor).first,
      let filename = entity.localFilename
    else { return nil }
    let url = downloadsDirectory.appending(path: filename)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  public func removeDownload(key: String) throws {
    let descriptor = FetchDescriptor<DownloadEntity>(predicate: #Predicate { $0.key == key })
    guard let entity = try context.fetch(descriptor).first else { return }
    if let filename = entity.localFilename {
      Self.removeDownloadFiles(at: downloadsDirectory.appending(path: filename))
    }
    context.delete(entity)
    try context.save()
  }

  /// The page manifest saved beside a downloaded archive.
  nonisolated static func geometry(forDownloadAt url: URL) -> PageManifest? {
    guard
      let data = (try? Data(contentsOf: geometryURL(forDownloadAt: url)))
        ?? (try? Data(contentsOf: legacyGeometryURL(forDownloadAt: url)))
    else { return nil }
    return try? JSONDecoder().decode(PageManifest.self, from: data)
  }

  nonisolated static func save(geometry: PageManifest, forDownloadAt url: URL) {
    guard let data = try? JSONEncoder().encode(geometry) else { return }
    try? data.write(to: geometryURL(forDownloadAt: url), options: .atomic)
  }

  nonisolated static func removeGeometry(forDownloadAt url: URL) {
    try? FileManager.default.removeItem(at: geometryURL(forDownloadAt: url))
    try? FileManager.default.removeItem(at: legacyGeometryURL(forDownloadAt: url))
  }

  nonisolated static func removeDownloadFiles(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    removeGeometry(forDownloadAt: url)
  }

  /// Hidden, so that Finder shows the downloaded books alone.
  private nonisolated static func geometryURL(forDownloadAt url: URL) -> URL {
    url.deletingLastPathComponent()
      .appending(path: ".\(url.deletingPathExtension().lastPathComponent).manifest.json")
  }

  /// Where it was kept in plain sight, when downloads were named by UUID.
  private nonisolated static func legacyGeometryURL(forDownloadAt url: URL) -> URL {
    url.deletingPathExtension().appendingPathExtension("manifest.json")
  }

  /// Puts a file into `directory` as `name` with `place`, a move or a copy,
  /// numbering the name ("Title 2.cbz") while another file has it. Returns
  /// the name used.
  nonisolated static func placeFile(
    named name: String,
    in directory: URL,
    using place: (URL) throws -> Void
  ) throws -> String {
    let stem = (name as NSString).deletingPathExtension
    let pathExtension = (name as NSString).pathExtension
    var number = 1
    while true {
      let candidate = number == 1 ? name : "\(stem) \(number).\(pathExtension)"
      do {
        try place(directory.appending(path: candidate))
        return candidate
      } catch CocoaError.fileWriteFileExists {
        number += 1
      }
    }
  }

  public func saveLocalBook(
    title: String,
    kind: LocalBookKind,
    pageCount: Int,
    localFilename: String?,
    bookmark: Data?
  ) throws -> LocalBook {
    let entity = LocalBookEntity(
      id: UUID().uuidString,
      title: title,
      kind: kind,
      pageCount: pageCount,
      localFilename: localFilename,
      bookmark: bookmark
    )
    context.insert(entity)
    try context.save()
    return entity.record
  }

  public func localBooks() throws -> [LocalBook] {
    let descriptor = FetchDescriptor<LocalBookEntity>(sortBy: [
      SortDescriptor(\.createdAt, order: .reverse)
    ])
    return try context.fetch(descriptor).map(\.record)
  }

  public func localBookLocation(id: String) throws -> (url: URL, bookmark: Data?) {
    let descriptor = FetchDescriptor<LocalBookEntity>(predicate: #Predicate { $0.id == id })
    guard let entity = try context.fetch(descriptor).first else {
      throw ReaderError.fileUnavailable
    }
    if let filename = entity.localFilename {
      return (importsDirectory.appending(path: filename), nil)
    }
    guard let bookmark = entity.bookmark else { throw ReaderError.fileUnavailable }
    var stale = false
    #if os(macOS)
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
    #else
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
    #endif
    if stale {
      // A stale bookmark still opens the file; renewing it is only a courtesy.
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      #if os(macOS)
        let renewed = try? url.bookmarkData(options: Self.externalBookmarkOptions)
      #else
        let renewed = try? url.bookmarkData()
      #endif
      if let renewed {
        entity.bookmark = renewed
        try context.save()
      }
    }
    return (url, entity.bookmark)
  }

  #if os(macOS)
    /// Bookmarks to CBZ files kept where they are. The app only reads them,
    /// which is all its sandbox lets it ask for.
    nonisolated static let externalBookmarkOptions: URL.BookmarkCreationOptions = [
      .withSecurityScope, .securityScopeAllowOnlyReadAccess,
    ]
  #endif

  public func removeLocalBook(id: String) throws {
    let descriptor = FetchDescriptor<LocalBookEntity>(predicate: #Predicate { $0.id == id })
    guard let entity = try context.fetch(descriptor).first else { return }
    if let filename = entity.localFilename {
      try? FileManager.default.removeItem(at: importsDirectory.appending(path: filename))
    }
    context.delete(entity)
    try context.save()
  }

  public func saveProgress(_ position: ReadingPosition, key: String, pendingSync: Bool) throws {
    let descriptor = FetchDescriptor<ProgressEntity>(predicate: #Predicate { $0.key == key })
    let entity =
      try context.fetch(descriptor).first
      ?? ProgressEntity(
        key: key,
        position: position,
        pendingSync: pendingSync
      )
    if entity.modelContext == nil { context.insert(entity) }
    entity.page = position.page
    entity.modeRawValue = position.mode.rawValue
    entity.completed = position.completed
    entity.updatedAt = position.updatedAt
    entity.pendingSync = pendingSync
    try context.save()
  }

  public func removeProgress(key: String) throws {
    let descriptor = FetchDescriptor<ProgressEntity>(predicate: #Predicate { $0.key == key })
    for entity in try context.fetch(descriptor) { context.delete(entity) }
    try context.save()
  }

  public func progress(key: String) throws -> ReadingPosition? {
    let descriptor = FetchDescriptor<ProgressEntity>(predicate: #Predicate { $0.key == key })
    return try context.fetch(descriptor).first?.position
  }

  /// Whether the position saved under `key` has yet to reach the server.
  public func isPendingSync(key: String) throws -> Bool {
    let descriptor = FetchDescriptor<ProgressEntity>(predicate: #Predicate { $0.key == key })
    return try context.fetch(descriptor).first?.pendingSync ?? false
  }

  /// Libraries and series details from the last refresh, for browsing offline.
  public func catalogExtras(connectionID: String) -> CatalogExtras? {
    guard let url = catalogExtrasURL(connectionID: connectionID),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(CatalogExtras.self, from: data)
  }

  public func save(catalogExtras: CatalogExtras, connectionID: String) {
    guard let url = catalogExtrasURL(connectionID: connectionID),
      let data = try? JSONEncoder().encode(catalogExtras)
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  private func catalogExtrasURL(connectionID: String) -> URL? {
    guard !isInMemory else { return nil }
    // The identity holds a URL; hex keeps it a single, portable file name.
    let name = Data(connectionID.utf8).map { String(format: "%02x", $0) }.joined()
    return directory(named: "Catalog").appending(path: "\(name.prefix(200)).json")
  }

  public func pendingProgress(connectionID: String) throws -> [(
    key: String, position: ReadingPosition
  )] {
    let descriptor = FetchDescriptor<ProgressEntity>(predicate: #Predicate { $0.pendingSync })
    return try context.fetch(descriptor)
      .filter { $0.key.hasPrefix("\(connectionID)|") }
      .map { (key: $0.key, position: $0.position) }
  }

  public var downloadsDirectory: URL {
    directory(named: "Downloads")
  }

  public var importsDirectory: URL {
    directory(named: "Imports")
  }

  private func directory(named name: String) -> URL {
    let url = applicationSupportURL.appending(path: name, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
