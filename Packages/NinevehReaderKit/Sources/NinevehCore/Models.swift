import Foundation

public struct ServerConnection: Codable, Hashable, Sendable {
  public let baseURL: URL
  public let username: String

  public init(baseURL: URL, username: String) {
    self.baseURL = baseURL
    self.username = username
  }

  public var identity: String {
    "\(baseURL.absoluteString.lowercased())|\(username.lowercased())"
  }

  public static func validated(urlText: String, username: String) throws -> ServerConnection {
    let trimmedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedURL), let scheme = url.scheme?.lowercased(), url.host != nil
    else {
      throw ReaderError.invalidServerURL
    }
    guard !trimmedUsername.isEmpty else { throw ReaderError.missingCredentials }

    let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    guard scheme == "https" || (scheme == "http" && isLoopback) else {
      throw ReaderError.insecureServer
    }
    return ServerConnection(baseURL: url, username: trimmedUsername)
  }
}

public struct Credentials: Sendable, Equatable {
  public let username: String
  public let password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }
}

public enum PublicationCategory: String, Codable, CaseIterable, Sendable {
  case comics
  case manga
  case unknown

  public var defaultDirection: ReadingDirection {
    self == .manga ? .rightToLeft : .leftToRight
  }
}

public struct SeriesReference: Codable, Hashable, Sendable {
  public let id: String
  public let title: String
  /// The id `/api/v1/series/{id}` takes. Servers that predate series
  /// identifiers in their feeds leave it out, and then only the name is known.
  public let serverID: String?

  public init(id: String, title: String, serverID: String? = nil) {
    self.id = id
    self.title = title
    self.serverID = serverID
  }
}

public struct Publication: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let subtitle: String?
  public let authors: [String]
  public let series: SeriesReference?
  public let volume: String?
  public let category: PublicationCategory
  public let pageCount: Int?
  public let coverURL: URL?
  public let revision: String?
  public let summary: String?
  public let fileSize: Int64?
  public let library: String?

  public init(
    id: String,
    title: String,
    subtitle: String? = nil,
    authors: [String] = [],
    series: SeriesReference? = nil,
    volume: String? = nil,
    category: PublicationCategory = .unknown,
    pageCount: Int? = nil,
    coverURL: URL? = nil,
    revision: String? = nil,
    summary: String? = nil,
    fileSize: Int64? = nil,
    library: String? = nil
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.authors = authors
    self.series = series
    self.volume = volume
    self.category = category
    self.pageCount = pageCount
    self.coverURL = coverURL
    self.revision = revision
    self.summary = summary
    self.fileSize = fileSize
    self.library = library
  }

  /// The same publication filed under the library and category whose feed
  /// listed it; OPDS publications do not name either themselves.
  public func filed(in category: PublicationCategory, library: String?) -> Publication {
    Publication(
      id: id, title: title, subtitle: subtitle, authors: authors, series: series, volume: volume,
      category: category, pageCount: pageCount, coverURL: coverURL, revision: revision,
      summary: summary, fileSize: fileSize, library: library ?? self.library)
  }

  /// The volume as a number, for ordering a series; `nil` sorts last.
  public var volumeNumber: Double? {
    volume.flatMap { Double($0) }
  }
}

public struct CatalogSnapshot: Sendable, Equatable {
  public let publications: [Publication]
  public let libraries: [LibrarySummary]

  public init(publications: [Publication], libraries: [LibrarySummary] = []) {
    self.publications = publications
    self.libraries = libraries
  }
}

public struct ManifestPage: Codable, Hashable, Sendable {
  public let number: Int
  public let width: Int?
  public let height: Int?
  /// The server found this page to be a two-page spread.
  public let spread: Bool

  public init(number: Int, width: Int? = nil, height: Int? = nil, spread: Bool = false) {
    self.number = number
    self.width = width
    self.height = height
    self.spread = spread
  }

  /// Width over height, when the page was measured.
  public var aspectRatio: Double? {
    guard let width, let height, width > 0, height > 0 else { return nil }
    return Double(width) / Double(height)
  }
}

public struct PageManifest: Codable, Hashable, Sendable {
  public let publicationID: String
  public let revision: String
  public let totalPages: Int
  public let pairingAnchor: Int?
  /// Page geometry, in page order. Empty when nothing was measured, as for a
  /// CBZ opened from disk; every page then counts as an ordinary single page.
  public let pages: [ManifestPage]

  public init(
    publicationID: String,
    revision: String,
    totalPages: Int,
    pairingAnchor: Int? = nil,
    pages: [ManifestPage] = []
  ) {
    self.publicationID = publicationID
    self.revision = revision
    self.totalPages = totalPages
    self.pairingAnchor = pairingAnchor
    self.pages = pages
  }

  /// One entry per page, filling in any the server did not describe.
  public var layoutPages: [ManifestPage] {
    guard totalPages > 0 else { return [] }
    let described = Dictionary(pages.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
    return (1...totalPages).map { described[$0] ?? ManifestPage(number: $0) }
  }
}

public struct LibrarySummary: Codable, Hashable, Identifiable, Sendable {
  public let name: String
  public let publicationCount: Int?

  public init(name: String, publicationCount: Int? = nil) {
    self.name = name
    self.publicationCount = publicationCount
  }

  public var id: String { name }
}

/// What Nineveh knows about a series beyond its folder name.
public struct SeriesDetail: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let library: String
  public let category: PublicationCategory
  /// The folder name the series is filed under on the server.
  public let localName: String
  /// The metadata title when there is one, otherwise the local name.
  public let title: String
  public let publicationCount: Int
  public let metadata: SeriesMetadata?

  public init(
    id: String,
    library: String,
    category: PublicationCategory,
    localName: String,
    title: String,
    publicationCount: Int,
    metadata: SeriesMetadata? = nil
  ) {
    self.id = id
    self.library = library
    self.category = category
    self.localName = localName
    self.title = title
    self.publicationCount = publicationCount
    self.metadata = metadata
  }

  /// Whether the display title hides the name the series is filed under.
  public var isRetitled: Bool { title != localName }
}

public struct SeriesMetadata: Codable, Hashable, Sendable {
  public let provider: String
  public let sourceURL: URL?
  public let editedFields: [String]
  public let license: String
  public let title: String?
  public let alternativeTitles: [String]
  public let authors: [String]
  public let artists: [String]
  public let publishers: [String]
  public let tags: [String]
  public let description: String?
  public let publishedStart: String?
  public let publishedEnd: String?
  public let status: String?
  public let contentRating: String?
  public let mediaType: String?
  public let rating: Double?
  public let finalVolume: Double?
  public let totalChapters: Double?

  public init(
    provider: String = "mangabaka",
    sourceURL: URL? = nil,
    editedFields: [String] = [],
    license: String = "CC BY-NC-SA 4.0",
    title: String? = nil,
    alternativeTitles: [String] = [],
    authors: [String] = [],
    artists: [String] = [],
    publishers: [String] = [],
    tags: [String] = [],
    description: String? = nil,
    publishedStart: String? = nil,
    publishedEnd: String? = nil,
    status: String? = nil,
    contentRating: String? = nil,
    mediaType: String? = nil,
    rating: Double? = nil,
    finalVolume: Double? = nil,
    totalChapters: Double? = nil
  ) {
    self.provider = provider
    self.sourceURL = sourceURL
    self.editedFields = editedFields
    self.license = license
    self.title = title
    self.alternativeTitles = alternativeTitles
    self.authors = authors
    self.artists = artists
    self.publishers = publishers
    self.tags = tags
    self.description = description
    self.publishedStart = publishedStart
    self.publishedEnd = publishedEnd
    self.status = status
    self.contentRating = contentRating
    self.mediaType = mediaType
    self.rating = rating
    self.finalVolume = finalVolume
    self.totalChapters = totalChapters
  }

  /// The short labels the web client shows under the title, in its order.
  public var badges: [String] {
    var badges: [String] = []
    if let mediaType, !mediaType.isEmpty { badges.append(Self.label(mediaType)) }
    if let status, !status.isEmpty { badges.append(Self.label(status)) }
    if let publishedStart, !publishedStart.isEmpty { badges.append(String(publishedStart.prefix(4))) }
    if let rating { badges.append("\(Int(rating.rounded()))/100") }
    return badges
  }

  /// "2019-04-01 – 2023-02-10", "Unknown – 2023", or `nil` when neither end is known.
  public var publishedRange: String? {
    let start = publishedStart.flatMap { $0.isEmpty ? nil : $0 }
    let end = publishedEnd.flatMap { $0.isEmpty ? nil : $0 }
    guard start != nil || end != nil else { return nil }
    return (start ?? "Unknown") + (end.map { " – \($0)" } ?? "")
  }

  /// The provider as a reader would name it.
  public var providerName: String {
    provider.lowercased() == "mangabaka" ? "MangaBaka" : provider.capitalized
  }

  public var isEditedLocally: Bool { !editedFields.isEmpty }

  /// "releasing" → "Releasing", "one_shot" → "One Shot".
  public static func label(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

public enum ReadingMode: String, Codable, CaseIterable, Sendable {
  case single
  case double
  case scroll

  public var title: String {
    switch self {
    case .single: "Single Page"
    case .double: "Two Page"
    case .scroll: "Continuous"
    }
  }
}

public enum ReadingDirection: String, Codable, CaseIterable, Sendable {
  case leftToRight
  case rightToLeft

  public var title: String {
    self == .leftToRight ? "Left to Right" : "Right to Left"
  }
}

/// A reader's choice of direction. `automatic` follows the publication:
/// right to left for manga, left to right for everything else.
public enum ReadingDirectionPreference: String, Codable, CaseIterable, Sendable {
  case automatic
  case leftToRight
  case rightToLeft

  public init(_ direction: ReadingDirection) {
    self = direction == .leftToRight ? .leftToRight : .rightToLeft
  }

  public func resolved(default fallback: ReadingDirection) -> ReadingDirection {
    switch self {
    case .automatic: fallback
    case .leftToRight: .leftToRight
    case .rightToLeft: .rightToLeft
    }
  }

  /// The next choice when the reader cycles through them.
  public var next: ReadingDirectionPreference {
    switch self {
    case .automatic: .leftToRight
    case .leftToRight: .rightToLeft
    case .rightToLeft: .automatic
    }
  }

  public var shortTitle: String {
    switch self {
    case .automatic: "Auto"
    case .leftToRight: "LTR"
    case .rightToLeft: "RTL"
    }
  }
}

public struct ReadingPosition: Codable, Hashable, Sendable {
  public let publicationID: String
  public let page: Int
  public let mode: ReadingMode
  public let completed: Bool
  public let updatedAt: Date

  public init(
    publicationID: String,
    page: Int,
    mode: ReadingMode,
    completed: Bool,
    updatedAt: Date = .now
  ) {
    self.publicationID = publicationID
    self.page = page
    self.mode = mode
    self.completed = completed
    self.updatedAt = updatedAt
  }
}

public enum LocalBookKind: String, Codable, Sendable {
  case imported
  case external
}

public struct LocalBook: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let kind: LocalBookKind
  public let pageCount: Int
  public let createdAt: Date

  public init(
    id: String, title: String, kind: LocalBookKind, pageCount: Int, createdAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.pageCount = pageCount
    self.createdAt = createdAt
  }
}

public enum DownloadState: String, Codable, Sendable {
  case queued
  case downloading
  case completed
  case failed
}

public struct DownloadRecord: Identifiable, Hashable, Sendable {
  public let id: String
  public let publicationID: String
  public let title: String
  public let seriesTitle: String?
  public let state: DownloadState
  public let progress: Double
  public let localFilename: String?
  public let revision: String?
  public let byteCount: Int64
  public let errorMessage: String?

  public init(
    id: String,
    publicationID: String,
    title: String,
    seriesTitle: String? = nil,
    state: DownloadState,
    progress: Double = 0,
    localFilename: String? = nil,
    revision: String? = nil,
    byteCount: Int64 = 0,
    errorMessage: String? = nil
  ) {
    self.id = id
    self.publicationID = publicationID
    self.title = title
    self.seriesTitle = seriesTitle
    self.state = state
    self.progress = progress
    self.localFilename = localFilename
    self.revision = revision
    self.byteCount = byteCount
    self.errorMessage = errorMessage
  }
}

public enum ReaderError: LocalizedError, Equatable, Sendable {
  case invalidServerURL
  case insecureServer
  case missingCredentials
  case authenticationFailed
  case invalidResponse
  case server(statusCode: Int, message: String)
  case invalidArchive
  case emptyArchive
  case fileUnavailable
  case permissionDenied
  case unsupportedAuthentication

  public var errorDescription: String? {
    switch self {
    case .invalidServerURL: "Enter a valid server URL."
    case .insecureServer: "Remote servers must use HTTPS. HTTP is allowed only for localhost."
    case .missingCredentials: "Enter both a username and password."
    case .authenticationFailed: "The username or password was not accepted."
    case .invalidResponse: "Nineveh returned an unexpected response."
    case .server(_, let message): message
    case .invalidArchive: "This file is not a readable CBZ archive."
    case .emptyArchive: "This CBZ file does not contain readable images."
    case .fileUnavailable: "The local file is no longer available."
    case .permissionDenied: "Nineveh Reader no longer has permission to open this file."
    case .unsupportedAuthentication: "This server does not offer a supported sign-in method."
    }
  }
}
