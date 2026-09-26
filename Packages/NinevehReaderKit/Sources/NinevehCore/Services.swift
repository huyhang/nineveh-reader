import Foundation

public protocol Authenticating: Sendable {
  @discardableResult func authenticate() async throws -> Account
}

public protocol CatalogProviding: Sendable {
  func catalog() async throws -> CatalogSnapshot
  /// Every volume of a series. A private series is only in the Private
  /// Collection's feeds, so the caller says which collection to look in.
  func publications(in series: SeriesReference, library: String?, isPrivate: Bool) async throws
    -> [Publication]
  func seriesDetail(id: String) async throws -> SeriesDetail
}

public protocol SeriesCurating: Sendable {
  /// Moves a series into or out of the Private Collection and returns it as
  /// the server now describes it. Only an administrator may.
  func setPrivate(_ isPrivate: Bool, seriesID: String) async throws -> SeriesDetail
}

public protocol PageProviding: Sendable {
  func manifest() async throws -> PageManifest
  func page(number: Int, maximumPixelWidth: Int?) async throws -> Data
  /// Whether a width asks for a smaller copy of the page rather than being
  /// ignored, so a screen-sized copy is worth fetching before the original.
  var servesRenditions: Bool { get }
}

extension PageProviding {
  public var servesRenditions: Bool { false }
}

public protocol ProgressSyncing: Sendable {
  func position(for publicationID: String) async throws -> ReadingPosition?
  /// Saves a position and returns it as the server recorded it.
  @discardableResult func save(_ position: ReadingPosition) async throws -> ReadingPosition
  /// Forgets a position, marking the publication unread.
  func clearPosition(for publicationID: String) async throws
}

public protocol CredentialStoring: Sendable {
  func save(password: String, for connection: ServerConnection) async throws
  func password(for connection: ServerConnection) async throws -> String?
  func removePassword(for connection: ServerConnection) async throws
}

public protocol ConnectionStoring: Sendable {
  func save(_ connection: ServerConnection) async throws
  func load() async throws -> ServerConnection?
  func remove() async throws
}

public protocol ReadingPreferenceStoring: Sendable {
  func direction(for identifier: String) async -> ReadingDirectionPreference?
  func save(direction: ReadingDirectionPreference, for identifier: String) async
  /// The mode chosen on this device for a series, or for a book outside one.
  func mode(for identifier: String) async -> ReadingMode?
  func save(mode: ReadingMode, for identifier: String) async
}

public protocol LibraryVisibilityStoring: Sendable {
  /// The libraries on a server that the reader chose not to see.
  func hiddenLibraries(for connectionID: String) async -> Set<String>
  func save(hiddenLibraries: Set<String>, for connectionID: String) async
}
