import CryptoKit
import Foundation
import NinevehCore
import Testing

@testable import NinevehKit

// Nineveh's app contract and responses captured from a running server live in
// `Contract/`, put there by `Scripts/sync-api-contract.sh` and
// `Scripts/capture-api-fixtures.py`. The client keeps its own forgiving
// decoders rather than generated ones, so these tests hold what it sends and
// what it reads to what the contract promises.

// MARK: - What the client sends

@Test func everyRequestTheClientBuildsIsPublished() async throws {
  let contract = try Contract()
  let transport = FixtureTransport()
  try await exerciseEveryRequest(makeContractClient(transport))
  // A server without library navigation is still filed by category.
  let byCategory = FixtureTransport(overrides: [
    "/opds/v2/catalog.json": Data(
      #"{"metadata": {"title": "Nineveh"}, "links": [], "navigation": []}"#.utf8)
  ])
  _ = try await makeContractClient(byCategory).catalog()

  var called = Set<String>()
  for request in await transport.requests + byCategory.requests {
    let url = try #require(request.url)
    let method = request.httpMethod ?? "GET"
    let operation = try #require(
      contract.operation(method, url.path), "\(method) \(url.path) is not in the contract")
    called.insert("\(method) \(operation.template)")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let sent = Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    for (name, value) in sent {
      let parameter = try #require(
        operation.query[name], "\(method) \(operation.template) takes no \(name)")
      if let listed = contract.listed(parameter) {
        #expect(listed.contains(value), "\(name)=\(value) is not one of \(listed)")
      }
    }
    #expect(
      operation.requiredQuery.isSubset(of: sent.keys),
      "\(method) \(url) leaves out a required parameter")
  }
  #expect(
    called == [
      "GET /opds/v2/authentication.json",
      "GET /api/v1/auth/me",
      "GET /opds/v2/catalog.json",
      "GET /opds/v2/navigation.json",
      "GET /opds/v2/publications.json",
      "GET /api/v1/series/{series_id}",
      "GET /api/v1/series/{series_id}/cover",
      "GET /api/v1/publications/{publication_id}/pages",
      "GET /api/v1/publications/{publication_id}/pages/{number}",
      "GET /api/v1/publications/{publication_id}/cover",
      "GET /api/v1/publications/{publication_id}/file",
      "GET /api/v1/publications/{publication_id}/progress",
      "PUT /api/v1/publications/{publication_id}/progress",
      "DELETE /api/v1/publications/{publication_id}/progress",
    ])
}

@Test func asksOnlyForTheWidthsTheContractLists() throws {
  let contract = try Contract()
  let page = try #require(contract.operation("GET", "/api/v1/publications/p/pages/1"))
  let cover = try #require(contract.operation("GET", "/api/v1/publications/p/cover"))

  // Ascending, as `pageRenditionWidth(covering:)` relies on.
  #expect(NinevehClient.pageRenditionWidths.map(String.init) == page.query["width"].flatMap(contract.listed))
  #expect(NinevehClient.coverWidths.map(String.init) == cover.query["width"].flatMap(contract.listed))
}

@Test func savesProgressInTheShapeTheContractTakes() async throws {
  let contract = try Contract()
  let transport = FixtureTransport()
  try await makeContractClient(transport).save(
    ReadingPosition(publicationID: "volume-1", page: 12, mode: .double, completed: true))

  let body = try #require(await transport.requests.first?.httpBody)
  let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
  let operation = try #require(contract.operation("PUT", "/api/v1/publications/p/progress"))
  let schema = contract.concrete(operation.requestSchema)
  #expect(Set(sent.keys).isSubset(of: schema["properties"].object.keys))
  #expect(Set(schema["required"].array.compactMap(\.string)).isSubset(of: sent.keys))
  // Every mode the reader offers can be saved, and every saved one read back.
  #expect(
    Set(ReadingMode.allCases.map(\.rawValue))
      == Set(contract.listed(schema["properties"]["mode"]) ?? []))
}

// MARK: - What the client reads

/// The fields each decoder takes from Nineveh and the JSON type it expects,
/// as paths into the response the operation publishes. The decoders also read
/// OPDS fields Nineveh never sends, such as `subject` and `number`, for other
/// servers; those are not listed.
private let fieldsRead: [String: [String: String]] = {
  let navigation = [
    "navigation[].href": "string",
    "navigation[].title": "string",
    "navigation[].properties.numberOfItems": "integer",
  ]
  let position = [
    "publicationId": "string",
    "page": "integer",
    "mode": "string",
    "completed": "boolean",
    "updatedAt": "string",
  ]
  return [
    "GET /opds/v2/authentication.json": ["authentication[].type": "string"],
    "GET /opds/v2/catalog.json": navigation,
    "GET /opds/v2/navigation.json": navigation,
    "GET /opds/v2/publications.json": [
      "links[].href": "string",
      "links[].rel": "string",
      "publications[].metadata.identifier": "string",
      "publications[].metadata.title": "string",
      "publications[].metadata.author[].name": "string",
      "publications[].metadata.belongsTo.series[].identifier": "string",
      "publications[].metadata.belongsTo.series[].name": "string",
      "publications[].metadata.belongsTo.series[].position": "number",
      "publications[].metadata.numberOfPages": "integer",
      "publications[].metadata.modified": "string",
      "publications[].metadata.description": "string",
      "publications[].links[].href": "string",
      "publications[].links[].rel": "string",
      "publications[].links[].properties.length": "integer",
      "publications[].images[].href": "string",
    ],
    "GET /api/v1/series/{series_id}": [
      "id": "string",
      "library": "string",
      "category": "string",
      "localName": "string",
      "title": "string",
      "publicationCount": "integer",
      "metadata.provider": "string",
      "metadata.sourceUrl": "string",
      "metadata.editedFields": "array",
      "metadata.license": "string",
      "metadata.values.title": "string",
      "metadata.values.alternative_titles": "array",
      "metadata.values.authors": "array",
      "metadata.values.artists": "array",
      "metadata.values.publishers": "array",
      "metadata.values.tags": "array",
      "metadata.values.description": "string",
      "metadata.values.published_start": "string",
      "metadata.values.published_end": "string",
      "metadata.values.status": "string",
      "metadata.values.content_rating": "string",
      "metadata.values.media_type": "string",
      "metadata.values.rating": "number",
      "metadata.values.final_volume": "number",
      "metadata.values.total_chapters": "number",
    ],
    "GET /api/v1/publications/{publication_id}/pages": [
      "publicationId": "string",
      "revision": "string",
      "totalPages": "integer",
      "pairingAnchor": "integer",
      "next": "string",
      "pages[].number": "integer",
      "pages[].width": "integer",
      "pages[].height": "integer",
      "pages[].spread": "boolean",
    ],
    "GET /api/v1/publications/{publication_id}/progress": position,
    "PUT /api/v1/publications/{publication_id}/progress": position,
  ]
}()

@Test func everyFieldTheDecodersReadIsPublished() throws {
  let contract = try Contract()
  for (call, fields) in fieldsRead {
    let parts = call.split(separator: " ", maxSplits: 1).map(String.init)
    let operation = try #require(
      contract.operation(parts[0], parts[1]), "\(call) is not in the contract")
    let response = operation.responseSchema
    try #require(!response.isNull, "\(call) publishes no response schema")
    for (path, type) in fields {
      let field = try #require(contract.field(path, in: response), "\(call) sends no \(path)")
      #expect(field["type"].string == type, "\(call) sends \(path) as \(field["type"].string ?? "?")")
    }
  }
}

@Test func acceptsTheCapturedAuthenticationDocument() async throws {
  try await makeContractClient(FixtureTransport()).authenticate()
}

@Test func filesTheCapturedCatalog() async throws {
  let catalog = try await makeContractClient(FixtureTransport()).catalog()
  let root = try Captured.json("catalog.json")
  let shelves = try Captured.json("navigation.json")
  let feed = try Captured.json("publications.json")

  // The links name each library form-encoded, as `Sample+Library`.
  let libraries = root["navigation"].array
  #expect(catalog.libraries.map(\.name) == libraries.map { $0["title"].string })
  #expect(
    catalog.libraries.map(\.publicationCount)
      == libraries.map { $0["properties"]["numberOfItems"].int })
  // Every shelf answers with the one captured page, so each volume is filed
  // once, under the first library and the captured shelf's category.
  let category = try #require(shelves["navigation"].array.first?["title"].string)
  let captured = feed["publications"].array
  try #require(catalog.publications.count == captured.count)
  for (publication, raw) in zip(catalog.publications, captured) {
    let metadata = raw["metadata"]
    let series = metadata["belongsTo"]["series"].array.first
    let acquisition = raw["links"].array.first {
      $0["rel"].string == "http://opds-spec.org/acquisition"
    }
    #expect(publication.id == metadata["identifier"].string.map(withoutURNPrefix))
    #expect(publication.title == metadata["title"].string)
    #expect(publication.authors == metadata["author"].array.compactMap { $0["name"].string })
    #expect(publication.pageCount == metadata["numberOfPages"].int)
    #expect(publication.revision == metadata["modified"].string)
    #expect(publication.summary == metadata["description"].string)
    #expect(publication.series?.title == series?["name"].string)
    #expect(publication.series?.serverID == series?["identifier"].string.map(withoutURNPrefix))
    #expect(publication.volume == series?["position"].double.map { String(format: "%g", $0) })
    #expect(publication.coverURL?.absoluteString == raw["images"].array.first?["href"].string)
    #expect(publication.fileSize == acquisition?["properties"]["length"].int.map(Int64.init))
    #expect(publication.category == PublicationCategory(rawValue: category))
    #expect(publication.library == catalog.libraries.first?.name)
  }
}

@Test(.enabled(if: Captured.exists("series.json")))
func readsTheCapturedSeries() async throws {
  let raw = try Captured.json("series.json")
  let id = try #require(raw["id"].string)

  let detail = try await makeContractClient(FixtureTransport()).seriesDetail(id: id)

  #expect(detail.id == id)
  #expect(detail.library == raw["library"].string)
  #expect(detail.category.rawValue == raw["category"].string)
  #expect(detail.localName == raw["localName"].string)
  #expect(detail.title == raw["title"].string)
  #expect(detail.publicationCount == raw["publicationCount"].int)
  #expect((detail.metadata == nil) == raw["metadata"].isNull)
}

@Test func readsTheCapturedManifest() async throws {
  let raw = try Captured.json("pages.json")
  let id = try #require(raw["publicationId"].string)

  let manifest = try await makeContractClient(FixtureTransport()).manifest(for: id)

  #expect(manifest.publicationID == id)
  #expect(manifest.revision == raw["revision"].string)
  #expect(manifest.totalPages == raw["totalPages"].int)
  #expect(manifest.pairingAnchor == raw["pairingAnchor"].int)
  // Only the first slice was captured; a longer volume repeats it.
  let pages = raw["pages"].array
  let decoded = manifest.pages.prefix(pages.count)
  #expect(decoded.map(\.number) == pages.map { $0["number"].int })
  #expect(decoded.map(\.width) == pages.map { $0["width"].int })
  #expect(decoded.map(\.height) == pages.map { $0["height"].int })
  #expect(decoded.map(\.spread) == pages.map { $0["spread"].bool })
}

@Test(.enabled(if: Captured.exists("progress.json")))
func readsTheCapturedProgress() async throws {
  let raw = try Captured.json("progress.json")
  let id = try #require(raw["publicationId"].string)

  let position = try #require(try await makeContractClient(FixtureTransport()).position(for: id))

  #expect(position.publicationID == id)
  #expect(position.page == raw["page"].int)
  #expect(position.mode.rawValue == raw["mode"].string)
  #expect(position.completed == raw["completed"].bool)
  // The decoder falls back to now on a date it cannot read, so compare.
  let text = try #require(raw["updatedAt"].string)
  let updated =
    try (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
    ?? Date.ISO8601FormatStyle().parse(text)
  #expect(abs(position.updatedAt.timeIntervalSince(updated)) < 0.001)
}

// MARK: - The vendored copy

@Test func theVendoredContractIsTheOneItsSourceRecords() throws {
  let source = try String(
    contentsOf: Contract.directory.appending(path: "SOURCE"), encoding: .utf8)
  let recorded = source.split(separator: "\n")
    .first { $0.hasPrefix("sha256:") }?
    .split(separator: " ").last.map(String.init)
  let digest = SHA256.hash(data: try Data(contentsOf: Contract.document))
    .map { String(format: "%02x", $0) }.joined()

  #expect(recorded == digest, "Contract/SOURCE is stale; run Scripts/sync-api-contract.sh")
}

/// The checkout the sync script copies from: `NINEVEH_CHECKOUT`, or Nineveh
/// beside this repository.
private let serverContract: URL = {
  let checkout =
    ProcessInfo.processInfo.environment["NINEVEH_CHECKOUT"].map { URL(filePath: $0) }
    ?? Contract.directory.appending(path: "../../../../nineveh").standardized
  return checkout.appending(path: "docs/app-openapi.json")
}()

/// Skipped without a checkout, as on CI.
@Test(.enabled(if: FileManager.default.fileExists(atPath: serverContract.path)))
func theVendoredContractMatchesTheServerCheckout() throws {
  let vendored = try Data(contentsOf: Contract.document)
  let current = try Data(contentsOf: serverContract)

  #expect(
    vendored == current,
    "Contract/app-openapi.json differs from \(serverContract.path); run Scripts/sync-api-contract.sh"
  )
}

// MARK: - Helpers

/// Everything the app asks of a server, once each.
private func exerciseEveryRequest(_ client: NinevehClient) async throws {
  try await client.authenticate()
  let catalog = try await client.catalog()
  let publication = try #require(catalog.publications.first { $0.series?.serverID != nil })
  let series = try #require(publication.series)
  let seriesID = try #require(series.serverID)
  _ = try await client.publications(in: series, library: publication.library)
  _ = try await client.seriesDetail(id: seriesID)
  _ = try await client.seriesCover(id: seriesID)
  let manifest = try await client.manifest(for: publication.id)
  for width in [nil, 900] {
    _ = try await client.page(
      publicationID: publication.id, number: 1, revision: manifest.revision,
      maximumPixelWidth: width)
  }
  // The feed names a cover; without one the client builds the request itself.
  _ = try await client.cover(for: publication)
  _ = try await client.cover(for: Publication(id: publication.id, title: publication.title))
  _ = try await client.download(publication: publication)
  _ = try await client.position(for: publication.id)
  try await client.save(
    ReadingPosition(publicationID: publication.id, page: 2, mode: .double, completed: false))
  try await client.clearPosition(for: publication.id)
}

private func makeContractClient(_ transport: FixtureTransport) -> NinevehClient {
  // Where the responses were captured, so their absolute links resolve as they did.
  let connection = try! ServerConnection.validated(
    urlText: "http://127.0.0.1:8081", username: "reader")
  return NinevehClient(
    connection: connection,
    credentials: Credentials(username: "reader", password: "secret"),
    transport: transport
  )
}

private func withoutURNPrefix(_ identifier: String) -> String {
  identifier.hasPrefix("urn:uuid:") ? String(identifier.dropFirst(9)) : identifier
}

/// Whether `path` is one `template` describes, such as
/// `/api/v1/series/{series_id}`.
private func matches(_ path: String, _ template: String) -> Bool {
  let actual = path.split(separator: "/", omittingEmptySubsequences: false)
  let expected = template.split(separator: "/", omittingEmptySubsequences: false)
  return actual.count == expected.count
    && zip(actual, expected).allSatisfy { actual, expected in
      expected.hasPrefix("{") && expected.hasSuffix("}") ? !actual.isEmpty : actual == expected
    }
}

/// Just enough of a JSON reader to walk the contract and compare decoded
/// values with the captured ones.
private struct JSONNode {
  let value: Any?

  init(_ value: Any?) {
    self.value = value is NSNull ? nil : value
  }

  subscript(key: String) -> JSONNode { JSONNode((value as? [String: Any])?[key]) }
  var object: [String: JSONNode] { (value as? [String: Any])?.mapValues { JSONNode($0) } ?? [:] }
  var array: [JSONNode] { (value as? [Any])?.map { JSONNode($0) } ?? [] }
  var string: String? { value as? String }
  var int: Int? { value as? Int }
  var double: Double? { value as? Double }
  var bool: Bool? { value as? Bool }
  var isNull: Bool { value == nil }
}

/// The vendored contract, read as plain JSON.
private struct Contract {
  static let directory = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Contract")
  static let document = directory.appending(path: "app-openapi.json")

  struct Operation {
    let template: String
    let node: JSONNode

    /// Each query parameter's schema, by name.
    var query: [String: JSONNode] {
      Dictionary(
        parameters.map { ($0["name"].string ?? "", $0["schema"]) }) { first, _ in first }
    }
    var requiredQuery: Set<String> {
      Set(parameters.filter { $0["required"].bool == true }.compactMap { $0["name"].string })
    }
    var requestSchema: JSONNode { node["requestBody"]["content"]["application/json"]["schema"] }
    /// The success body's schema, whatever its media type.
    var responseSchema: JSONNode {
      node["responses"]["200"]["content"].object.values.first?["schema"] ?? JSONNode(nil)
    }

    private var parameters: [JSONNode] {
      node["parameters"].array.filter { $0["in"].string == "query" }
    }
  }

  let root: JSONNode

  init() throws {
    root = JSONNode(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.document)))
  }

  /// The published operation a request for `path` reaches.
  func operation(_ method: String, _ path: String) -> Operation? {
    for (template, item) in root["paths"].object where matches(path, template) {
      let node = item[method.lowercased()]
      if !node.isNull { return Operation(template: template, node: node) }
    }
    return nil
  }

  /// The schema a `$ref` names, or the non-null branch of an optional.
  func concrete(_ schema: JSONNode) -> JSONNode {
    if let reference = schema["$ref"].string, let name = reference.split(separator: "/").last {
      return concrete(root["components"]["schemas"][String(name)])
    }
    if let option = schema["anyOf"].array.first(where: { $0["type"].string != "null" }) {
      return concrete(option)
    }
    return schema
  }

  /// The values a parameter or field is limited to, as text, if it is.
  func listed(_ schema: JSONNode) -> [String]? {
    let values = concrete(schema)["enum"].array.compactMap(\.value)
    return values.isEmpty ? nil : values.map { "\($0)" }
  }

  /// The schema of the field at `path`, such as `pages[].number`, or nil when
  /// some step of it is not published.
  func field(_ path: String, in schema: JSONNode) -> JSONNode? {
    var node = concrete(schema)
    for step in path.split(separator: ".") {
      let isList = step.hasSuffix("[]")
      let name = String(isList ? step.dropLast(2) : step)
      let next = node["properties"][name]
      guard !next.isNull else { return nil }
      node = concrete(next)
      if isList {
        guard node["type"].string == "array" else { return nil }
        node = concrete(node["items"])
      }
    }
    return node
  }
}

/// A response saved from a running server by `Scripts/capture-api-fixtures.py`.
private enum Captured {
  static let directory = Contract.directory.appending(path: "responses")

  static func data(_ name: String) throws -> Data {
    try Data(contentsOf: directory.appending(path: name))
  }

  static func json(_ name: String) throws -> JSONNode {
    JSONNode(try JSONSerialization.jsonObject(with: data(name)))
  }

  static func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: directory.appending(path: name).path)
  }
}

/// Answers each request with the response captured for its route, whatever
/// the ids and query, and records what the client sent. Routes nothing was
/// captured for, such as images, answer with an empty body.
private actor FixtureTransport: HTTPTransport {
  private static let captured = [
    "/opds/v2/authentication.json": "authentication.json",
    "/api/v1/auth/me": "me.json",
    "/opds/v2/catalog.json": "catalog.json",
    "/opds/v2/navigation.json": "navigation.json",
    "/opds/v2/publications.json": "publications.json",
    "/api/v1/series/{series_id}": "series.json",
    "/api/v1/publications/{publication_id}/pages": "pages.json",
    "/api/v1/publications/{publication_id}/progress": "progress.json",
  ]
  private let overrides: [String: Data]
  private(set) var requests: [URLRequest] = []

  init(overrides: [String: Data] = [:]) {
    self.overrides = overrides
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let url = request.url!
    var status = 200
    var body = Data()
    if let override = overrides[url.path] {
      body = override
    } else if let name = Self.captured.first(where: { matches(url.path, $0.key) })?.value {
      if let data = try? Captured.data(name) {
        body = data
      } else if request.httpMethod == "GET" {
        // Nothing captured, as for a volume nobody has opened.
        status = 404
      }
    }
    return (body, response(for: url, status: status))
  }

  func download(for request: URLRequest) async throws -> (URL, URLResponse) {
    requests.append(request)
    let file = FileManager.default.temporaryDirectory
      .appending(path: "contract-\(UUID().uuidString).cbz")
    try Data().write(to: file)
    return (file, response(for: request.url!, status: 200))
  }

  private func response(for url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
  }
}
