import Foundation
import NinevehCore

public actor NinevehClient: Authenticating, CatalogProviding, ProgressSyncing {
  private let connection: ServerConnection
  private let credentials: Credentials
  private let transport: any HTTPTransport
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder

  public init(
    connection: ServerConnection,
    credentials: Credentials,
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.connection = connection
    self.credentials = credentials
    self.transport = transport
    self.decoder = JSONDecoder()
    self.encoder = JSONEncoder()
  }

  public func authenticate() async throws {
    var discoveryRequest = URLRequest(
      url: connection.baseURL.appending(path: "/opds/v2/authentication.json"))
    discoveryRequest.setValue(
      "application/opds-authentication+json", forHTTPHeaderField: "Accept")
    let discoveryData = try await responseData(for: discoveryRequest)
    let discovery = try decoder.decode(AuthenticationDocumentDTO.self, from: discoveryData)
    guard discovery.authentication.contains(where: { $0.type == "http://opds-spec.org/auth/basic" })
    else {
      throw ReaderError.unsupportedAuthentication
    }
    let request = try makeRequest(path: "/api/v1/auth/me")
    _ = try await responseData(for: request)
  }

  /// Every publication the account can read, each filed under the library
  /// and category whose feed lists it.
  public func catalog() async throws -> CatalogSnapshot {
    let root = try await feed(path: "/opds/v2/catalog.json")
    // The query value is what the feeds filter on; the title is for people.
    let libraries = root.navigation.compactMap { link -> LibrarySummary? in
      guard let name = queryValue("library", in: link.href) ?? link.title else { return nil }
      return LibrarySummary(name: name, publicationCount: link.properties?.numberOfItems)
    }
    guard !libraries.isEmpty else {
      return CatalogSnapshot(publications: try await catalogByCategory())
    }

    // Shelves load side by side, then land in the order the server listed them.
    var shelves: [(library: String, category: PublicationCategory)] = []
    for library in libraries {
      let navigation = try await feed(
        path: "/opds/v2/navigation.json", query: [URLQueryItem(name: "library", value: library.name)])
      for link in navigation.navigation {
        guard let name = queryValue("category", in: link.href) ?? link.title,
          let category = PublicationCategory(rawValue: name.lowercased())
        else { continue }
        shelves.append((library.name, category))
      }
    }
    let loaded = try await withThrowingTaskGroup(of: (Int, [Publication]).self) { group in
      for (index, shelf) in shelves.enumerated() {
        group.addTask {
          let values = try await self.loadAllPublications(
            path: "/opds/v2/publications.json",
            query: [
              URLQueryItem(name: "library", value: shelf.library),
              URLQueryItem(name: "category", value: shelf.category.rawValue),
            ]
          )
          return (index, values.map { $0.filed(in: shelf.category, library: shelf.library) })
        }
      }
      var results: [(Int, [Publication])] = []
      for try await result in group { results.append(result) }
      return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
    }
    var seen = Set<String>()
    let publications = loaded.filter { seen.insert($0.id).inserted }
    return CatalogSnapshot(publications: publications, libraries: libraries)
  }

  /// A server without library navigation still files everything by category.
  private func catalogByCategory() async throws -> [Publication] {
    var publications: [Publication] = []
    var seen = Set<String>()
    for category in [PublicationCategory.comics, .manga] {
      let values = try await loadAllPublications(
        path: "/opds/v2/publications.json",
        query: [URLQueryItem(name: "category", value: category.rawValue)]
      )
      for publication in values where seen.insert(publication.id).inserted {
        publications.append(publication.filed(in: category, library: nil))
      }
    }
    return publications
  }

  public func publications(in series: SeriesReference, library: String?) async throws
    -> [Publication]
  {
    // Feeds filter by the series' name; the library tells two same-named
    // series apart.
    var query = [URLQueryItem(name: "series", value: series.title)]
    if let library { query.append(URLQueryItem(name: "library", value: library)) }
    return try await loadAllPublications(path: "/opds/v2/publications.json", query: query)
      .filter { $0.series?.id == series.id || $0.series?.serverID == nil }
      .map { $0.filed(in: $0.category, library: library) }
  }

  public func seriesDetail(id: String) async throws -> SeriesDetail {
    let request = try makeRequest(path: "/api/v1/series/\(escaped(id))")
    let data = try await responseData(for: request)
    return try decoder.decode(SeriesDetailDTO.self, from: data).model
  }

  /// The series' own cover: one chosen with its metadata, or its first volume's.
  public func seriesCover(id: String) async throws -> Data {
    let request = try makeRequest(path: "/api/v1/series/\(escaped(id))/cover")
    return try await responseData(for: request)
  }

  public func pageSource(for publication: Publication) -> RemotePageSource {
    RemotePageSource(publication: publication, client: self)
  }

  /// The whole page manifest. The server sends it a slice at a time, so this
  /// follows `next` until every page is described.
  public func manifest(for publicationID: String) async throws -> PageManifest {
    var request: URLRequest? = try makeRequest(
      path: "/api/v1/publications/\(escaped(publicationID))/pages")
    var first: PageManifestDTO?
    var pages: [ManifestPage] = []
    var visited = Set<URL>()
    while let current = request, let url = current.url, visited.insert(url).inserted {
      let data = try await responseData(for: current)
      let slice = try decoder.decode(PageManifestDTO.self, from: data)
      // A volume rescanned mid-walk would mix two revisions' pages.
      if let first, first.revision != slice.revision { throw ReaderError.invalidResponse }
      first = first ?? slice
      pages.append(contentsOf: slice.pages.map(\.model))
      request = slice.next.flatMap(resolve).map(authenticatedRequest(url:))
      if pages.count >= slice.totalPages { request = nil }
    }
    guard let first else { throw ReaderError.invalidResponse }
    return PageManifest(
      publicationID: first.publicationID,
      revision: first.revision,
      totalPages: first.totalPages,
      pairingAnchor: first.pairingAnchor,
      pages: pages
    )
  }

  public func page(
    publicationID: String,
    number: Int,
    revision: String?,
    maximumPixelWidth: Int?
  ) async throws -> Data {
    var query: [URLQueryItem] = []
    if let revision { query.append(URLQueryItem(name: "revision", value: revision)) }
    if let width = Self.pageRenditionWidth(covering: maximumPixelWidth) {
      query.append(URLQueryItem(name: "width", value: String(width)))
    }
    let request = try makeRequest(
      path: "/api/v1/publications/\(escaped(publicationID))/pages/\(number)",
      query: query
    )
    return try await responseData(for: request)
  }

  public func cover(for publication: Publication, width: Int = 480) async throws -> Data {
    let request: URLRequest
    if let coverURL = publication.coverURL {
      request = authenticatedRequest(url: coverURL)
    } else {
      request = try makeRequest(
        path: "/api/v1/publications/\(escaped(publication.id))/cover",
        query: [URLQueryItem(name: "width", value: String(Self.coverWidth(covering: width)))]
      )
    }
    return try await responseData(for: request)
  }

  /// Nineveh only renders pages and covers at fixed widths and rejects any other value with a 422.
  static let pageRenditionWidths = [640, 960, 1280]
  static let coverWidths = [160, 320, 640]

  /// The narrowest page rendition at least `requested` wide, or nil to fetch the original page when
  /// no rendition is wide enough.
  static func pageRenditionWidth(covering requested: Int?) -> Int? {
    guard let requested else { return nil }
    return pageRenditionWidths.first { $0 >= requested }
  }

  static func coverWidth(covering requested: Int) -> Int {
    coverWidths.first { $0 >= requested } ?? coverWidths[coverWidths.count - 1]
  }

  public func download(
    publication: Publication,
    progress: @Sendable @escaping (Double) -> Void = { _ in }
  ) async throws -> (URL, HTTPURLResponse) {
    let request = try makeRequest(path: "/api/v1/publications/\(escaped(publication.id))/file")
    let result: (URL, URLResponse)
    if let transport = transport as? any ProgressReportingHTTPTransport {
      result = try await transport.download(for: request, progress: progress)
    } else {
      result = try await transport.download(for: request)
      progress(1)
    }
    let (url, response) = result
    let httpResponse = try validate(response: response)
    return (url, httpResponse)
  }

  public func position(for publicationID: String) async throws -> ReadingPosition? {
    let request = try makeRequest(path: "/api/v1/publications/\(escaped(publicationID))/progress")
    do {
      let data = try await responseData(for: request)
      return try decoder.decode(ReadingPositionDTO.self, from: data).model
    } catch ReaderError.server(let statusCode, _) where statusCode == 404 {
      return nil
    }
  }

  @discardableResult
  public func save(_ position: ReadingPosition) async throws -> ReadingPosition {
    var request = try makeRequest(
      path: "/api/v1/publications/\(escaped(position.publicationID))/progress",
      method: "PUT"
    )
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try encoder.encode(
      ProgressUpdateDTO(
        page: position.page, mode: position.mode.rawValue, completed: position.completed)
    )
    let data = try await responseData(for: request)
    return (try? decoder.decode(ReadingPositionDTO.self, from: data).model) ?? position
  }

  public func clearPosition(for publicationID: String) async throws {
    let request = try makeRequest(
      path: "/api/v1/publications/\(escaped(publicationID))/progress",
      method: "DELETE"
    )
    do {
      _ = try await responseData(for: request)
    } catch ReaderError.server(let statusCode, _) where statusCode == 404 {
      // Already unread.
    }
  }

  private func feed(path: String, query: [URLQueryItem] = []) async throws -> OPDSFeedDTO {
    let data = try await responseData(for: try makeRequest(path: path, query: query))
    return try decoder.decode(OPDSFeedDTO.self, from: data)
  }

  private func queryValue(_ name: String, in href: String) -> String? {
    guard let url = resolve(href) else { return nil }
    // Nineveh form-encodes its links, so a space arrives as `+`, which
    // URLComponents would leave in the name.
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .percentEncodedQueryItems?.first { $0.name == name }?.value?
      .replacingOccurrences(of: "+", with: " ").removingPercentEncoding
  }

  private func loadAllPublications(path: String, query: [URLQueryItem]) async throws
    -> [Publication]
  {
    var nextRequest: URLRequest? = try makeRequest(path: path, query: query)
    var result: [Publication] = []
    var visited = Set<URL>()

    while let request = nextRequest, let url = request.url, visited.insert(url).inserted {
      let data = try await responseData(for: request)
      let feed = try decoder.decode(OPDSFeedDTO.self, from: data)
      result.append(contentsOf: feed.publications.map { $0.model(baseURL: connection.baseURL) })

      guard result.count < 5_000,
        let next = feed.links.first(where: { $0.relationships.contains("next") })?.href,
        let nextURL = resolve(next)
      else {
        nextRequest = nil
        continue
      }
      nextRequest = authenticatedRequest(url: nextURL)
    }
    return result
  }

  private func makeRequest(
    path: String,
    query: [URLQueryItem] = [],
    method: String = "GET"
  ) throws -> URLRequest {
    guard
      var components = URLComponents(
        url: connection.baseURL.appending(path: path),
        resolvingAgainstBaseURL: false
      )
    else {
      throw ReaderError.invalidServerURL
    }
    components.queryItems = query.isEmpty ? nil : query
    // URLComponents leaves `+` as it is, and the server reads it as a space:
    // a series named "Rosario+Vampire" would come back empty.
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    guard let url = components.url else { throw ReaderError.invalidServerURL }
    var request = authenticatedRequest(url: url)
    request.httpMethod = method
    return request
  }

  private func authenticatedRequest(url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    let token = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
    request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    request.cachePolicy = .reloadRevalidatingCacheData
    request.timeoutInterval = 30
    return request
  }

  private func responseData(for request: URLRequest) async throws -> Data {
    let (data, response) = try await transport.data(for: request)
    _ = try validate(response: response, body: data)
    return data
  }

  private func validate(response: URLResponse, body: Data = Data()) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else { throw ReaderError.invalidResponse }
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 401 { throw ReaderError.authenticationFailed }
      let detail =
        (try? decoder.decode(ServerErrorDTO.self, from: body).detail)
        ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
      throw ReaderError.server(statusCode: response.statusCode, message: detail)
    }
    return response
  }

  private func resolve(_ href: String) -> URL? {
    URL(string: href, relativeTo: connection.baseURL)?.absoluteURL
  }

  private func escaped(_ component: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
  }
}

public actor RemotePageSource: PageProviding {
  private let publication: Publication
  private let client: NinevehClient
  private var cachedManifest: PageManifest?

  public init(publication: Publication, client: NinevehClient) {
    self.publication = publication
    self.client = client
  }

  public nonisolated var servesRenditions: Bool { true }

  public func manifest() async throws -> PageManifest {
    if let cachedManifest { return cachedManifest }
    let manifest = try await client.manifest(for: publication.id)
    cachedManifest = manifest
    return manifest
  }

  public func page(number: Int, maximumPixelWidth: Int?) async throws -> Data {
    let revision = try await manifest().revision
    return try await client.page(
      publicationID: publication.id,
      number: number,
      revision: revision,
      maximumPixelWidth: maximumPixelWidth
    )
  }
}

private struct ProgressUpdateDTO: Encodable {
  let page: Int
  let mode: String
  let completed: Bool
}

private struct ReadingPositionDTO: Decodable {
  let publicationID: String
  let page: Int
  let mode: ReadingMode
  let completed: Bool
  let updatedAt: String

  enum CodingKeys: String, CodingKey {
    case publicationID = "publicationId"
    case page, mode, completed, updatedAt
  }

  var model: ReadingPosition {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date =
      formatter.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt) ?? .now
    return ReadingPosition(
      publicationID: publicationID,
      page: page,
      mode: mode,
      completed: completed,
      updatedAt: date
    )
  }
}

private struct ServerErrorDTO: Decodable {
  let detail: String
}

private struct AuthenticationDocumentDTO: Decodable {
  let authentication: [AuthenticationMethodDTO]
}

private struct AuthenticationMethodDTO: Decodable {
  let type: String
}
