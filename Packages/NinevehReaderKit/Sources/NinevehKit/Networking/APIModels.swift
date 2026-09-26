import Foundation
import NinevehCore

/// `GET /api/v1/auth/me`.
struct UserAccountDTO: Decodable {
  let username: String
  let isAdmin: Bool

  enum CodingKeys: String, CodingKey {
    case username, isAdmin
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    username = try container.decode(String.self, forKey: .username)
    isAdmin = try container.decodeIfPresent(Bool.self, forKey: .isAdmin) ?? false
  }

  var model: Account {
    Account(username: username, isAdministrator: isAdmin)
  }
}

/// `GET /api/v1/series/{id}`, and what `PUT /api/v1/series/{id}/privacy` answers.
struct SeriesDetailDTO: Decodable {
  let id: String
  let library: String
  let category: String
  let localName: String
  let title: String
  let publicationCount: Int
  let metadata: SeriesMetadataDTO?
  let isPrivate: Bool

  enum CodingKeys: String, CodingKey {
    case id, library, category, localName, title, publicationCount, metadata, isPrivate
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    library = try container.decodeIfPresent(String.self, forKey: .library) ?? ""
    category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
    localName = try container.decode(String.self, forKey: .localName)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? localName
    publicationCount = try container.decodeIfPresent(Int.self, forKey: .publicationCount) ?? 0
    // Metadata is a nicety: a shape this client does not understand must not
    // cost the reader the series page itself.
    metadata = try? container.decodeIfPresent(SeriesMetadataDTO.self, forKey: .metadata)
    // Servers from before the Private Collection have only public series.
    isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
  }

  var model: SeriesDetail {
    SeriesDetail(
      id: id,
      library: library,
      category: PublicationCategory(rawValue: category) ?? .unknown,
      localName: localName,
      title: title,
      publicationCount: publicationCount,
      metadata: metadata?.model,
      isPrivate: isPrivate
    )
  }
}

struct SeriesMetadataDTO: Decodable {
  let provider: String
  let sourceURL: String?
  let editedFields: [String]
  let license: String
  let values: SeriesValuesDTO

  enum CodingKeys: String, CodingKey {
    case provider, values, editedFields, license
    case sourceURL = "sourceUrl"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = (try? container.decode(String.self, forKey: .provider)) ?? "mangabaka"
    sourceURL = try? container.decodeIfPresent(String.self, forKey: .sourceURL)
    editedFields = (try? container.decodeIfPresent([String].self, forKey: .editedFields)) ?? []
    license = (try? container.decode(String.self, forKey: .license)) ?? "CC BY-NC-SA 4.0"
    values = try container.decode(SeriesValuesDTO.self, forKey: .values)
  }

  var model: SeriesMetadata {
    SeriesMetadata(
      provider: provider,
      sourceURL: sourceURL.flatMap(URL.init(string:)),
      editedFields: editedFields,
      license: license,
      title: values.title,
      alternativeTitles: values.alternativeTitles,
      authors: values.authors,
      artists: values.artists,
      publishers: values.publishers,
      tags: values.tags,
      description: values.description,
      publishedStart: values.publishedStart,
      publishedEnd: values.publishedEnd,
      status: values.status,
      contentRating: values.contentRating,
      mediaType: values.mediaType,
      rating: values.rating,
      finalVolume: values.finalVolume,
      totalChapters: values.totalChapters
    )
  }
}

/// The provider's values, snake_case and open to keys this client has never
/// heard of. Each field is read on its own so one surprise costs one field.
struct SeriesValuesDTO: Decodable {
  let title: String?
  let alternativeTitles: [String]
  let authors: [String]
  let artists: [String]
  let publishers: [String]
  let tags: [String]
  let description: String?
  let publishedStart: String?
  let publishedEnd: String?
  let status: String?
  let contentRating: String?
  let mediaType: String?
  let rating: Double?
  let finalVolume: Double?
  let totalChapters: Double?

  enum CodingKeys: String, CodingKey {
    case title, authors, artists, publishers, tags, description, status, rating
    case alternativeTitles = "alternative_titles"
    case publishedStart = "published_start"
    case publishedEnd = "published_end"
    case contentRating = "content_rating"
    case mediaType = "media_type"
    case finalVolume = "final_volume"
    case totalChapters = "total_chapters"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func text(_ key: CodingKeys) -> String? {
      guard let value = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    func list(_ key: CodingKeys) -> [String] {
      guard let values = try? container.decodeIfPresent([String?].self, forKey: key) else {
        return []
      }
      return values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    func number(_ key: CodingKeys) -> Double? {
      try? container.decodeIfPresent(Double.self, forKey: key)
    }
    title = text(.title)
    alternativeTitles = list(.alternativeTitles)
    authors = list(.authors)
    artists = list(.artists)
    publishers = list(.publishers)
    tags = list(.tags)
    description = text(.description)
    publishedStart = text(.publishedStart)
    publishedEnd = text(.publishedEnd)
    status = text(.status)
    contentRating = text(.contentRating)
    mediaType = text(.mediaType)
    rating = number(.rating)
    finalVolume = number(.finalVolume)
    totalChapters = number(.totalChapters)
  }
}

/// `GET /api/v1/publications/{id}/pages`, one slice of it.
struct PageManifestDTO: Decodable {
  let publicationID: String
  let revision: String
  let totalPages: Int
  let pairingAnchor: Int?
  let next: String?
  let pages: [ManifestPageDTO]

  enum CodingKeys: String, CodingKey {
    case publicationID = "publicationId"
    case revision, totalPages, pairingAnchor, next, pages
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    publicationID = try container.decode(String.self, forKey: .publicationID)
    revision = try container.decode(String.self, forKey: .revision)
    totalPages = try container.decode(Int.self, forKey: .totalPages)
    pairingAnchor = try? container.decodeIfPresent(Int.self, forKey: .pairingAnchor)
    next = try? container.decodeIfPresent(String.self, forKey: .next)
    pages = (try? container.decodeIfPresent([ManifestPageDTO].self, forKey: .pages)) ?? []
  }
}

struct ManifestPageDTO: Decodable {
  let number: Int
  let width: Int?
  let height: Int?
  let spread: Bool

  enum CodingKeys: String, CodingKey { case number, width, height, spread }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    number = try container.decode(Int.self, forKey: .number)
    width = try? container.decodeIfPresent(Int.self, forKey: .width)
    height = try? container.decodeIfPresent(Int.self, forKey: .height)
    spread = (try? container.decodeIfPresent(Bool.self, forKey: .spread)) ?? false
  }

  var model: ManifestPage {
    ManifestPage(number: number, width: width, height: height, spread: spread)
  }
}
