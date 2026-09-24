import Foundation

public protocol Authenticating: Sendable {
  func authenticate() async throws
}

public protocol CatalogProviding: Sendable {
  func catalog() async throws -> CatalogSnapshot
  func publications(in series: SeriesReference, library: String?) async throws -> [Publication]
  func seriesDetail(id: String) async throws -> SeriesDetail
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
  /// The mode the reader last chose, which new publications open in.
  func preferredMode() async -> ReadingMode?
  func save(preferredMode: ReadingMode) async
}

public protocol LibraryVisibilityStoring: Sendable {
  /// The libraries on a server that the reader chose not to see.
  func hiddenLibraries(for connectionID: String) async -> Set<String>
  func save(hiddenLibraries: Set<String>, for connectionID: String) async
}
