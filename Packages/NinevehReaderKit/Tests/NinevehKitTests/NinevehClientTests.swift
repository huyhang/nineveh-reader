import Foundation
import NinevehCore
import Testing

@testable import NinevehKit

@Test func filesTheCatalogByLibraryAndCategoryAndSendsBasicAuthentication() async throws {
  let transport = RoutingTransport(responses: [
    "/opds/v2/catalog.json": Data(
      #"""
      {
        "metadata": {"title": "Nineveh"},
        "navigation": [
          {"href": "/opds/v2/navigation.json?library=Home", "title": "Home Shelf",
           "properties": {"numberOfItems": 3}}
        ]
      }
      """#.utf8),
    "/opds/v2/navigation.json?library=Home": Data(
      #"""
      {
        "metadata": {"title": "Home"},
        "navigation": [
          {"href": "/opds/v2/publications.json?library=Home&category=manga", "title": "Manga"},
          {"href": "/opds/v2/publications.json?library=Home&category=comics", "title": "Comics"}
        ]
      }
      """#.utf8),
    "/opds/v2/publications.json?library=Home&category=manga": feed(
      publications: [
        publication(
          id: "volume-1", title: "A Quiet Volume",
          series: #"{"identifier": "urn:uuid:series-1", "name": "Quiet Series", "position": 1}"#)
      ],
      next: "/opds/v2/publications.json?library=Home&category=manga&page=2"),
    "/opds/v2/publications.json?library=Home&category=manga&page=2": feed(publications: [
      publication(
        id: "volume-2", title: "A Louder Volume",
        series: #"{"identifier": "urn:uuid:series-1", "name": "Quiet Series", "position": 2}"#)
    ]),
    // A volume listed twice is kept once, where it was first filed.
    "/opds/v2/publications.json?library=Home&category=comics": feed(publications: [
      publication(id: "volume-1", title: "A Quiet Volume"),
      publication(id: "comic-1", title: "Harbor Lights"),
    ]),
  ])
  let client = makeClient(transport: transport)

  let catalog = try await client.catalog()

  #expect(catalog.libraries.map(\.name) == ["Home"])
  #expect(catalog.libraries.first?.publicationCount == 3)
  #expect(catalog.publications.map(\.id) == ["volume-1", "volume-2", "comic-1"])
  #expect(catalog.publications.map(\.category) == [.manga, .manga, .comics])
  #expect(catalog.publications.allSatisfy { $0.library == "Home" })
  let series = try #require(catalog.publications.first?.series)
  #expect(series.title == "Quiet Series")
  #expect(series.serverID == "series-1")
  #expect(catalog.publications.first?.volume == "1")
  #expect(catalog.publications.first?.authors == ["A. Reader"])
  let requests = await transport.requests
  #expect(
    requests.allSatisfy {
      $0.value(forHTTPHeaderField: "Authorization") == "Basic cmVhZGVyOnNlY3JldA=="
    })
}

@Test func filesTheCatalogByCategoryWithoutLibraries() async throws {
  let transport = RoutingTransport(responses: [
    "/opds/v2/catalog.json": Data(#"{"metadata": {"title": "Nineveh"}}"#.utf8),
    "/opds/v2/publications.json?category=comics": feed(publications: []),
    "/opds/v2/publications.json?category=manga": feed(publications: [
      publication(id: "volume-1", title: "A Quiet Volume")
    ]),
  ])
  let client = makeClient(transport: transport)

  let catalog = try await client.catalog()

  #expect(catalog.libraries.isEmpty)
  #expect(catalog.publications.map(\.id) == ["volume-1"])
  #expect(catalog.publications.first?.category == .manga)
  #expect(catalog.publications.first?.series == nil)
}

@Test func readsLibraryNamesFromFormEncodedLinks() async throws {
  let transport = RoutingTransport(responses: [
    "/opds/v2/catalog.json": Data(
      #"""
      {"metadata": {"title": "Nineveh"},
       "navigation": [{"href": "/opds/v2/navigation.json?library=Sample+Library%2B",
                       "title": "Sample Library+"}]}
      """#.utf8),
    "/opds/v2/navigation.json": Data(#"{"metadata": {"title": "Sample Library+"}}"#.utf8),
  ])
  let client = makeClient(transport: transport)

  let catalog = try await client.catalog()

  #expect(catalog.libraries.map(\.name) == ["Sample Library+"])
  let navigation = await transport.requests.last?.url
  #expect(navigation?.query == "library=Sample%20Library%2B")
}

@Test func sendsAPlusInAQueryValueAsAPlus() async throws {
  let transport = RoutingTransport(responses: [
    "/opds/v2/publications.json": feed(publications: [])
  ])
  let client = makeClient(transport: transport)

  _ = try await client.publications(
    in: SeriesReference(id: "series-1", title: "Rosario+Vampire"), library: "Home")

  let query = await transport.requests.first?.url?.query
  #expect(query == "series=Rosario%2BVampire&library=Home")
}

@Test func decodesSeriesMetadata() async throws {
  let transport = RoutingTransport(responses: [
    "/api/v1/series/series-1": Data(
      #"""
      {
        "id": "series-1",
        "library": "Home",
        "category": "manga",
        "localName": "Tsuki no Niwa",
        "title": "Moon Garden",
        "publicationCount": 3,
        "metadata": {
          "provider": "mangabaka",
          "sourceUrl": "https://mangabaka.dev/42",
          "editedFields": ["title"],
          "license": "CC BY-NC-SA 4.0",
          "values": {
            "title": "Moon Garden",
            "alternative_titles": ["月の庭", "  ", null],
            "authors": ["Ren Ishida"],
            "artists": ["Ren Ishida"],
            "publishers": ["Lantern Press"],
            "tags": ["Fantasy"],
            "description": "  A garden that only blooms at night.  ",
            "published_start": "2019-04-01",
            "published_end": null,
            "status": "releasing",
            "media_type": "manga",
            "rating": 88.4,
            "unexpected_key": {"nested": true}
          }
        }
      }
      """#.utf8)
  ])
  let client = makeClient(transport: transport)

  let detail = try await client.seriesDetail(id: "series-1")

  #expect(detail.localName == "Tsuki no Niwa")
  #expect(detail.isRetitled)
  #expect(detail.category == .manga)
  #expect(detail.publicationCount == 3)
  let metadata = try #require(detail.metadata)
  #expect(metadata.providerName == "MangaBaka")
  #expect(metadata.sourceURL == URL(string: "https://mangabaka.dev/42"))
  #expect(metadata.isEditedLocally)
  #expect(metadata.alternativeTitles == ["月の庭"])
  #expect(metadata.authors == ["Ren Ishida"])
  #expect(metadata.description == "A garden that only blooms at night.")
  #expect(metadata.badges == ["Manga", "Releasing", "2019", "88/100"])
  #expect(metadata.publishedRange == "2019-04-01")
}

@Test func keepsTheSeriesWhenItsMetadataIsUnreadable() async throws {
  let transport = RoutingTransport(responses: [
    "/api/v1/series/series-1": Data(
      #"{"id": "series-1", "localName": "Quiet Series", "metadata": {"values": 7}}"#.utf8)
  ])
  let client = makeClient(transport: transport)

  let detail = try await client.seriesDetail(id: "series-1")

  #expect(detail.title == "Quiet Series")
  #expect(!detail.isRetitled)
  #expect(detail.metadata == nil)
}

@Test func followsTheManifestUntilEveryPageIsDescribed() async throws {
  let transport = RoutingTransport(responses: [
    "/api/v1/publications/volume-1/pages": Data(
      #"""
      {"publicationId": "volume-1", "revision": "r1", "totalPages": 3, "pairingAnchor": 1,
       "next": "/api/v1/publications/volume-1/pages?offset=2",
       "pages": [{"number": 1, "width": 800, "height": 1200, "spread": false},
                 {"number": 2, "width": 1600, "height": 1200, "spread": true}]}
      """#.utf8),
    "/api/v1/publications/volume-1/pages?offset=2": Data(
      #"""
      {"publicationId": "volume-1", "revision": "r1", "totalPages": 3,
       "next": "/api/v1/publications/volume-1/pages?offset=3",
       "pages": [{"number": 3, "width": 800, "height": 1200, "spread": false}]}
      """#.utf8),
  ])
  let client = makeClient(transport: transport)

  let manifest = try await client.manifest(for: "volume-1")

  #expect(manifest.totalPages == 3)
  #expect(manifest.pairingAnchor == 1)
  #expect(manifest.pages.map(\.number) == [1, 2, 3])
  #expect(manifest.pages[1].spread)
  // Every page is described, so the final `next` is never followed.
  #expect(await transport.requests.count == 2)
}

@Test func refusesAManifestThatChangesRevisionMidway() async throws {
  let transport = RoutingTransport(responses: [
    "/api/v1/publications/volume-1/pages": Data(
      #"""
      {"publicationId": "volume-1", "revision": "r1", "totalPages": 2,
       "next": "/api/v1/publications/volume-1/pages?offset=1",
       "pages": [{"number": 1, "spread": false}]}
      """#.utf8),
    "/api/v1/publications/volume-1/pages?offset=1": Data(
      #"""
      {"publicationId": "volume-1", "revision": "r2", "totalPages": 2,
       "pages": [{"number": 2, "spread": false}]}
      """#.utf8),
  ])
  let client = makeClient(transport: transport)

  await #expect(throws: ReaderError.self) {
    _ = try await client.manifest(for: "volume-1")
  }
}

@Test @MainActor func keepsTheGeometryNinevehNowSendsForADownload() async throws {
  let archive = try temporaryArchiveURL()
  defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
  ReaderStore.save(geometry: geometry(totalPages: 3, pairingAnchor: nil), forDownloadAt: archive)
  let transport = RoutingTransport(responses: [
    "/api/v1/publications/volume-1/pages": Data(
      #"""
      {"publicationId": "volume-1", "revision": "r1", "totalPages": 3, "pairingAnchor": 2,
       "pages": [{"number": 1, "spread": false}, {"number": 2, "spread": false},
                 {"number": 3, "spread": false}]}
      """#.utf8)
  ])
  let resolver = PageSourceResolver(
    client: makeClient(transport: transport), store: try ReaderStore(inMemory: true),
    connectionID: "server")

  #expect(await resolver.refreshGeometry(publicationID: "volume-1", at: archive))
  #expect(ReaderStore.geometry(forDownloadAt: archive)?.pairingAnchor == 2)
  // Asked again, Nineveh says nothing new.
  #expect(await !resolver.refreshGeometry(publicationID: "volume-1", at: archive))
}

@Test func keepsADownloadsGeometryOnceNinevehsFileHasChanged() throws {
  let archive = try temporaryArchiveURL()
  defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
  let saved = geometry(totalPages: 3, pairingAnchor: nil)
  ReaderStore.save(geometry: saved, forDownloadAt: archive)

  #expect(!PageSourceResolver.keep(geometry(totalPages: 4, pairingAnchor: 2), forDownloadAt: archive))
  #expect(ReaderStore.geometry(forDownloadAt: archive) == saved)
}

@Test func namesADownloadAsNinevehNamesTheFile() throws {
  let url = try #require(URL(string: "https://reader.example.com/api/v1/publications/v1/file"))
  let volume = Publication(id: "v1", title: "Fate/Zero, Vol. 1")
  func filename(disposition: String?) throws -> String {
    let response = try #require(
      HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: disposition.map { ["Content-Disposition": $0] } ?? [:]))
    return DownloadService.filename(for: volume, response: response)
  }

  // How Starlette sends a name with spaces in it.
  #expect(
    try filename(
      disposition: "attachment; filename*=utf-8''Ragna%20Crimson%20v01%20%282021%29.cbz")
      == "Ragna Crimson v01 (2021).cbz")
  #expect(try filename(disposition: nil) == "Fate_Zero, Vol. 1.cbz")
}

@Test func numbersADownloadWhoseNameIsTakenButReplacesTheVolumesOldCopy() throws {
  let folder = try temporaryArchiveURL().deletingLastPathComponent()
  defer { try? FileManager.default.removeItem(at: folder) }
  let name = "Volume 01.cbz"
  func move(_ contents: String, replacing previous: String?) throws -> String {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data(contents.utf8).write(to: file)
    return try DownloadService.move(file, into: folder, named: name, replacing: previous)
  }
  func contents(_ filename: String) throws -> String {
    try String(contentsOf: folder.appending(path: filename), encoding: .utf8)
  }
  let old = folder.appending(path: name)
  try Data("old".utf8).write(to: old)
  ReaderStore.save(geometry: geometry(totalPages: 3, pairingAnchor: 2), forDownloadAt: old)

  // Other series' volumes of the same name.
  #expect(try move("other", replacing: nil) == "Volume 01 2.cbz")
  #expect(try move("third", replacing: nil) == "Volume 01 3.cbz")
  // The same volume downloaded again.
  #expect(try move("new", replacing: name) == name)

  #expect(try contents(name) == "new")
  #expect(ReaderStore.geometry(forDownloadAt: old) == nil)
  #expect(try contents("Volume 01 2.cbz") == "other")
}

@Test func hidesADownloadsGeometryFromFinderAndReadsWhereItWasKept() throws {
  let archive = try temporaryArchiveURL()
  let folder = archive.deletingLastPathComponent()
  defer { try? FileManager.default.removeItem(at: folder) }
  let saved = geometry(totalPages: 3, pairingAnchor: 2)
  func files() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path)
  }

  ReaderStore.save(geometry: saved, forDownloadAt: archive)
  #expect(try files() == [".volume-1.manifest.json"])

  // Beside a download named by UUID, before it was hidden.
  let legacy = folder.appending(path: "\(UUID().uuidString).cbz")
  try JSONEncoder().encode(saved)
    .write(to: legacy.deletingPathExtension().appendingPathExtension("manifest.json"))
  #expect(ReaderStore.geometry(forDownloadAt: legacy) == saved)
  ReaderStore.removeDownloadFiles(at: legacy)
  #expect(try files() == [".volume-1.manifest.json"])
}

@Test func savesAndClearsReadingProgress() async throws {
  let transport = RoutingTransport(
    responses: [:], statuses: ["GET /api/v1/publications/volume-2/progress": 404])
  let client = makeClient(transport: transport)

  try await client.save(
    ReadingPosition(publicationID: "volume-1", page: 12, mode: .double, completed: false))
  try await client.clearPosition(for: "volume-1")
  let missing = try await client.position(for: "volume-2")

  #expect(missing == nil)
  let requests = await transport.requests
  #expect(requests.map(\.httpMethod) == ["PUT", "DELETE", "GET"])
  #expect(requests[0].url?.path == "/api/v1/publications/volume-1/progress")
  let body = try #require(requests[0].httpBody)
  let sent = try JSONSerialization.jsonObject(with: body) as? [String: Any]
  #expect(sent?["page"] as? Int == 12)
  #expect(sent?["mode"] as? String == "double")
  #expect(sent?["completed"] as? Bool == false)
  #expect(requests[1].url?.path == "/api/v1/publications/volume-1/progress")
}

@Test func discoversBasicAuthenticationBeforeValidatingCredentials() async throws {
  let transport = RoutingTransport(responses: [
    "/opds/v2/authentication.json": Data(
      #"{"authentication":[{"type":"http://opds-spec.org/auth/basic"}]}"#.utf8),
    "/api/v1/auth/me": Data(#"{"id":"1"}"#.utf8),
  ])
  let client = makeClient(transport: transport)

  try await client.authenticate()

  let requests = await transport.requests
  #expect(requests.count == 2)
  #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
  #expect(requests[1].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
}

@Test func requestsOnlyImageWidthsTheServerRenders() async throws {
  let transport = RoutingTransport(responses: [:])
  let client = makeClient(transport: transport)

  for requested in [nil, 500, 960, 1800] {
    _ = try await client.page(
      publicationID: "volume-1", number: 1, revision: "r1", maximumPixelWidth: requested)
  }
  _ = try await client.cover(for: Publication(id: "volume-1", title: "A Quiet Volume"))

  let widths = await transport.requests.map { request in
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
      .queryItems?.first { $0.name == "width" }?.value
  }
  #expect(widths == [nil, "640", "960", nil, "640"])
}

// MARK: - Helpers

private func makeClient(transport: some HTTPTransport) -> NinevehClient {
  let connection = try! ServerConnection.validated(
    urlText: "https://reader.example.com",
    username: "reader"
  )
  return NinevehClient(
    connection: connection,
    credentials: Credentials(username: "reader", password: "secret"),
    transport: transport
  )
}

/// Where a downloaded archive would be, in a folder of its own.
private func temporaryArchiveURL() throws -> URL {
  let folder = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder.appending(path: "volume-1.cbz")
}

private func geometry(totalPages: Int, pairingAnchor: Int?) -> PageManifest {
  PageManifest(
    publicationID: "volume-1", revision: "r1", totalPages: totalPages,
    pairingAnchor: pairingAnchor, pages: (1...totalPages).map { ManifestPage(number: $0) })
}

private func publication(id: String, title: String, series: String? = nil) -> String {
  let belongsTo = series.map { #", "belongsTo": {"series": [\#($0)]}"# } ?? ""
  return #"""
    {
      "metadata": {
        "identifier": "urn:nineveh:publication:\#(id)",
        "title": "\#(title)",
        "author": [{"name": "A. Reader"}],
        "subject": [{"code": "manga", "name": "Manga"}],
        "numberOfPages": 120\#(belongsTo)
      },
      "images": [{"href": "/api/v1/publications/\#(id)/cover", "rel": "cover"}]
    }
    """#
}

private func feed(publications: [String], next: String? = nil) -> Data {
  let links = next.map { #"[{"href": "\#($0)", "rel": "next"}]"# } ?? "[]"
  return Data(
    #"""
    {
      "metadata": {"title": "Publications"},
      "publications": [\#(publications.joined(separator: ","))],
      "links": \#(links)
    }
    """#.utf8)
}

/// Answers by path and query, then by path alone; anything else is an empty 200.
private actor RoutingTransport: HTTPTransport {
  let responses: [String: Data]
  /// Status codes keyed by "METHOD path".
  let statuses: [String: Int]
  var requests: [URLRequest] = []

  init(responses: [String: Data], statuses: [String: Int] = [:]) {
    self.responses = responses
    self.statuses = statuses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let url = request.url!
    let status = statuses["\(request.httpMethod ?? "GET") \(url.path)"] ?? 200
    let response = HTTPURLResponse(
      url: url,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    let key = url.query.map { "\(url.path)?\($0)" } ?? url.path
    return (responses[key] ?? responses[url.path] ?? Data(), response)
  }

  func download(for request: URLRequest) async throws -> (URL, URLResponse) {
    throw ReaderError.invalidResponse
  }
}
