import Foundation
import NinevehCore

/// Everything the reader needs to open one publication, and the way back to
/// the rest of the app.
public struct ReaderDestination: Identifiable, Sendable {
  public let id: String
  public let publicationID: String
  public let title: String
  /// The series the publication belongs to, shown under its title.
  public let subtitle: String?
  public let source: any PageProviding
  public let initialPosition: ReadingPosition?
  /// Opens at page one whatever was saved, as "Read from start" does.
  public let startsAtBeginning: Bool
  public let initialMode: ReadingMode
  /// The direction `automatic` resolves to: right to left for manga.
  public let defaultDirection: ReadingDirection
  public let directionPreference: ReadingDirectionPreference
  public let context: ReaderContext
  public let actions: ReaderActions

  public init(
    id: String,
    publicationID: String,
    title: String,
    subtitle: String? = nil,
    source: any PageProviding,
    initialPosition: ReadingPosition? = nil,
    startsAtBeginning: Bool = false,
    initialMode: ReadingMode = .single,
    defaultDirection: ReadingDirection = .leftToRight,
    directionPreference: ReadingDirectionPreference = .automatic,
    context: ReaderContext = ReaderContext(),
    actions: ReaderActions
  ) {
    self.id = id
    self.publicationID = publicationID
    self.title = title
    self.subtitle = subtitle
    self.source = source
    self.initialPosition = initialPosition
    self.startsAtBeginning = startsAtBeginning
    self.initialMode = initialMode
    self.defaultDirection = defaultDirection
    self.directionPreference = directionPreference
    self.context = context
    self.actions = actions
  }
}

/// A volume the reader can switch to without going back to the library.
public struct ReaderVolume: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let volume: String?
  public let pageCount: Int?

  public init(id: String, title: String, volume: String? = nil, pageCount: Int? = nil) {
    self.id = id
    self.title = title
    self.volume = volume
    self.pageCount = pageCount
  }

  init(_ publication: Publication) {
    self.init(
      id: publication.id, title: publication.title, volume: publication.volume,
      pageCount: publication.pageCount)
  }

  /// "2 · Ragna Crimson v02", as the web reader's publication picker has it.
  public var menuTitle: String {
    volume.map { "\($0) · \(title)" } ?? title
  }
}

/// Where the publication sits in its series.
public struct ReaderContext: Sendable {
  public let seriesTitle: String?
  public let volumes: [ReaderVolume]
  public let currentIndex: Int?

  public init(seriesTitle: String? = nil, volumes: [ReaderVolume] = [], currentIndex: Int? = nil) {
    self.seriesTitle = seriesTitle
    self.volumes = volumes
    self.currentIndex = currentIndex
  }

  public var previous: ReaderVolume? { volume(at: -1) }
  public var next: ReaderVolume? { volume(at: 1) }

  private func volume(at offset: Int) -> ReaderVolume? {
    guard let currentIndex, volumes.indices.contains(currentIndex + offset) else { return nil }
    return volumes[currentIndex + offset]
  }
}

public enum ProgressSaveResult: Equatable, Sendable {
  /// Saved on the server, or, for a file on this device, saved where it lives.
  case saved
  /// Kept on this device; `retryable` when the server might take it later.
  case savedLocally(retryable: Bool)
}

public struct ReaderActions: Sendable {
  public var savePosition: @Sendable (ReadingPosition) async -> ProgressSaveResult
  public var saveDirection: @Sendable (ReadingDirectionPreference) async -> Void
  public var saveMode: @Sendable (ReadingMode) async -> Void
  /// Replaces the reader with another volume of the series.
  public var openVolume: (@Sendable (String) async -> Void)?
  /// Leaves the reader for the series page.
  public var showSeries: (@Sendable () async -> Void)?
  public var cover: @Sendable (String) async -> Data?

  public init(
    savePosition: @escaping @Sendable (ReadingPosition) async -> ProgressSaveResult = { _ in .saved
    },
    saveDirection: @escaping @Sendable (ReadingDirectionPreference) async -> Void = { _ in },
    saveMode: @escaping @Sendable (ReadingMode) async -> Void = { _ in },
    openVolume: (@Sendable (String) async -> Void)? = nil,
    showSeries: (@Sendable () async -> Void)? = nil,
    cover: @escaping @Sendable (String) async -> Data? = { _ in nil }
  ) {
    self.savePosition = savePosition
    self.saveDirection = saveDirection
    self.saveMode = saveMode
    self.openVolume = openVolume
    self.showSeries = showSeries
    self.cover = cover
  }
}
