import Foundation
import NinevehCore

struct OPDSFeedDTO: Decodable {
  var publications: [OPDSPublicationDTO] = []
  var navigation: [OPDSLinkDTO] = []
  var links: [OPDSLinkDTO] = []

  enum CodingKeys: String, CodingKey { case publications, navigation, links }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    publications =
      try container.decodeIfPresent([OPDSPublicationDTO].self, forKey: .publications) ?? []
    navigation = try container.decodeIfPresent([OPDSLinkDTO].self, forKey: .navigation) ?? []
    links = try container.decodeIfPresent([OPDSLinkDTO].self, forKey: .links) ?? []
  }
}

struct OPDSPublicationDTO: Decodable {
  let metadata: OPDSMetadataDTO
  var links: [OPDSLinkDTO] = []
  var images: [OPDSLinkDTO] = []

  enum CodingKeys: String, CodingKey { case metadata, links, images }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    metadata = try container.decode(OPDSMetadataDTO.self, forKey: .metadata)
    links = try container.decodeIfPresent([OPDSLinkDTO].self, forKey: .links) ?? []
    images = try container.decodeIfPresent([OPDSLinkDTO].self, forKey: .images) ?? []
  }

  func model(baseURL: URL) -> Publication {
    let seriesDTO = metadata.belongsTo?.series.first
    let series = seriesDTO.map { grouping in
      let serverID = grouping.identifier.map { identifier in
        identifier.hasPrefix("urn:uuid:") ? String(identifier.dropFirst(9)) : identifier
      }
      return SeriesReference(id: serverID ?? grouping.name, title: grouping.name, serverID: serverID)
    }
    let subjects = metadata.subjects.map { "\($0.code ?? "") \($0.name)".lowercased() }.joined(
      separator: " ")
    let category: PublicationCategory =
      subjects.contains("manga") ? .manga : (subjects.contains("comic") ? .comics : .unknown)
    let image = images.first(where: { $0.relationships.contains("cover") }) ?? images.first
    let imageURL = image.flatMap { URL(string: $0.href, relativeTo: baseURL)?.absoluteURL }
    let publicationID = apiPublicationID(baseURL: baseURL) ?? metadata.identifier
    let acquisition = links.first { link in
      link.relationships.contains { $0.hasPrefix("http://opds-spec.org/acquisition") }
    }

    return Publication(
      id: publicationID,
      title: metadata.title,
      subtitle: metadata.subtitle,
      authors: metadata.authors.map(\.name),
      series: series,
      volume: metadata.volume ?? seriesDTO?.position.map { String(format: "%g", $0) },
      category: category,
      pageCount: metadata.numberOfPages,
      coverURL: imageURL,
      revision: metadata.modified,
      summary: metadata.description,
      fileSize: acquisition?.properties?.length
    )
  }

  private func apiPublicationID(baseURL: URL) -> String? {
    for link in links + images {
      guard let url = URL(string: link.href, relativeTo: baseURL)?.absoluteURL,
        let marker = url.pathComponents.lastIndex(of: "publications"),
        url.pathComponents.indices.contains(marker + 1)
      else { continue }

      let identifier = url.pathComponents[marker + 1]
      if !identifier.isEmpty {
        return identifier.removingPercentEncoding ?? identifier
      }
    }
    return nil
  }
}

struct OPDSMetadataDTO: Decodable {
  let identifier: String
  let title: String
  let subtitle: String?
  let authors: [OPDSContributorDTO]
  let belongsTo: OPDSBelongsToDTO?
  let subjects: [OPDSSubjectDTO]
  let numberOfPages: Int?
  let modified: String?
  let volume: String?
  let description: String?

  enum CodingKeys: String, CodingKey {
    case identifier, title, subtitle, author, belongsTo, subject, numberOfPages, modified
    case description
    case volume = "number"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    identifier = try container.decode(String.self, forKey: .identifier)
    title = try container.decode(String.self, forKey: .title)
    subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    authors =
      (try? container.decode([OPDSContributorDTO].self, forKey: .author))
      ?? (try? [container.decode(OPDSContributorDTO.self, forKey: .author)])
      ?? []
    belongsTo = try container.decodeIfPresent(OPDSBelongsToDTO.self, forKey: .belongsTo)
    subjects =
      (try? container.decode([OPDSSubjectDTO].self, forKey: .subject))
      ?? (try? [container.decode(OPDSSubjectDTO.self, forKey: .subject)])
      ?? []
    numberOfPages = try container.decodeIfPresent(Int.self, forKey: .numberOfPages)
    modified = try container.decodeIfPresent(String.self, forKey: .modified)
    description = try? container.decodeIfPresent(String.self, forKey: .description)
    if let string = try? container.decodeIfPresent(String.self, forKey: .volume) {
      volume = string
    } else if let number = try? container.decodeIfPresent(Double.self, forKey: .volume) {
      volume = String(format: "%g", number)
    } else {
      volume = nil
    }
  }
}

struct OPDSContributorDTO: Decodable {
  let name: String

  init(from decoder: Decoder) throws {
    if let value = try? decoder.singleValueContainer().decode(String.self) {
      name = value
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
  }

  enum CodingKeys: String, CodingKey { case name }
}

struct OPDSBelongsToDTO: Decodable {
  let series: [OPDSGroupingDTO]

  enum CodingKeys: String, CodingKey { case series }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    series =
      (try? container.decode([OPDSGroupingDTO].self, forKey: .series))
      ?? (try? [container.decode(OPDSGroupingDTO.self, forKey: .series)])
      ?? []
  }
}

struct OPDSGroupingDTO: Decodable {
  let identifier: String?
  let name: String
  let position: Double?
}

struct OPDSSubjectDTO: Decodable {
  let code: String?
  let name: String

  init(from decoder: Decoder) throws {
    if let value = try? decoder.singleValueContainer().decode(String.self) {
      code = nil
      name = value
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decodeIfPresent(String.self, forKey: .code)
    name = try container.decode(String.self, forKey: .name)
  }

  enum CodingKeys: String, CodingKey { case code, name }
}

struct OPDSLinkDTO: Decodable {
  let href: String
  let title: String?
  let relationships: [String]
  let properties: OPDSLinkPropertiesDTO?

  enum CodingKeys: String, CodingKey { case href, title, rel, properties }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    href = try container.decode(String.self, forKey: .href)
    title = try? container.decodeIfPresent(String.self, forKey: .title)
    properties = try? container.decodeIfPresent(OPDSLinkPropertiesDTO.self, forKey: .properties)
    if let values = try? container.decode([String].self, forKey: .rel) {
      relationships = values
    } else if let value = try? container.decode(String.self, forKey: .rel) {
      relationships = [value]
    } else {
      relationships = []
    }
  }
}

struct OPDSLinkPropertiesDTO: Decodable {
  let length: Int64?
  let numberOfItems: Int?

  enum CodingKeys: String, CodingKey { case length, numberOfItems }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    length = try? container.decodeIfPresent(Int64.self, forKey: .length)
    numberOfItems = try? container.decodeIfPresent(Int.self, forKey: .numberOfItems)
  }
}
