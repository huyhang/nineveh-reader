public enum CatalogGrouping: String, CaseIterable, Hashable, Sendable {
  case all
  case category
  case series
  case author

  public var title: String {
    switch self {
    case .all: "All Titles"
    case .category: "Categories"
    case .series: "Series"
    case .author: "Authors"
    }
  }
}

public struct PublicationCollection: Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let subtitle: String
  public let publications: [Publication]

  public init(id: String, title: String, subtitle: String, publications: [Publication]) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.publications = publications
  }
}

public enum CatalogOrganizer {
  /// - Parameter creators: Who a publication is filed under when grouping by
  ///   author. Volumes often name no one, so a caller that knows the series'
  ///   creators can supply them.
  public static func collections(
    from publications: [Publication],
    groupedBy grouping: CatalogGrouping,
    creators: (Publication) -> [String] = \.authors
  ) -> [PublicationCollection] {
    switch grouping {
    case .all:
      return []
    case .category:
      return groupedCollections(
        publications,
        key: { $0.category == .unknown ? "Other" : $0.category.rawValue.capitalized },
        idPrefix: "category",
        subtitle: titleCount
      )
    case .series:
      return groupedCollections(
        publications,
        key: { $0.series?.title ?? "Standalone" },
        idPrefix: "series",
        subtitle: { $0 == 1 ? "1 volume" : "\($0) volumes" }
      )
    case .author:
      var grouped: [String: [Publication]] = [:]
      for publication in publications {
        let named = creators(publication)
        let authors = named.isEmpty ? ["Unknown Author"] : named
        for author in Set(authors) { grouped[author, default: []].append(publication) }
      }
      return makeCollections(grouped, idPrefix: "author", subtitle: titleCount)
    }
  }

  private static func groupedCollections(
    _ publications: [Publication],
    key: (Publication) -> String,
    idPrefix: String,
    subtitle: (Int) -> String
  ) -> [PublicationCollection] {
    makeCollections(
      Dictionary(grouping: publications, by: key),
      idPrefix: idPrefix,
      subtitle: subtitle
    )
  }

  private static func makeCollections(
    _ grouped: [String: [Publication]],
    idPrefix: String,
    subtitle: (Int) -> String
  ) -> [PublicationCollection] {
    grouped.map { title, publications in
      PublicationCollection(
        id: "\(idPrefix)|\(title)",
        title: title,
        subtitle: subtitle(publications.count),
        publications: publications
      )
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  private static func titleCount(_ count: Int) -> String {
    count == 1 ? "1 title" : "\(count) titles"
  }
}

/// Names a series across refreshes. The library is part of it because, without
/// a server id, two libraries may file different series under one name.
public struct SeriesKey: Codable, Hashable, Sendable {
  public let id: String
  public let library: String?

  public init(id: String, library: String?) {
    self.id = id
    self.library = library
  }
}

/// A series as the catalog lists it: its volumes, in reading order.
public struct SeriesGroup: Hashable, Identifiable, Sendable {
  public let key: SeriesKey
  /// The name the series is filed under.
  public let title: String
  public let serverID: String?
  public let category: PublicationCategory
  public let volumes: [Publication]

  public init(
    key: SeriesKey,
    title: String,
    serverID: String?,
    category: PublicationCategory,
    volumes: [Publication]
  ) {
    self.key = key
    self.title = title
    self.serverID = serverID
    self.category = category
    self.volumes = volumes
  }

  public var id: SeriesKey { key }
  public var library: String? { key.library }

  public func volume(after publication: Publication) -> Publication? {
    guard let index = volumes.firstIndex(where: { $0.id == publication.id }),
      volumes.indices.contains(index + 1)
    else { return nil }
    return volumes[index + 1]
  }
}

extension CatalogOrganizer {
  /// Every series in the catalog, alphabetically. A publication that names no
  /// series stands as a series of one.
  public static func series(from publications: [Publication]) -> [SeriesGroup] {
    var order: [SeriesKey] = []
    var grouped: [SeriesKey: [Publication]] = [:]
    for publication in publications {
      let key = seriesKey(for: publication)
      if grouped[key] == nil { order.append(key) }
      grouped[key, default: []].append(publication)
    }
    return order.compactMap { key -> SeriesGroup? in
      guard let volumes = grouped[key], let first = volumes.first else { return nil }
      return SeriesGroup(
        key: key,
        title: first.series?.title ?? first.title,
        serverID: first.series?.serverID,
        category: first.category,
        volumes: volumes.sorted(by: readingOrder)
      )
    }
    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  public static func seriesKey(for publication: Publication) -> SeriesKey {
    guard let series = publication.series else {
      return SeriesKey(id: "publication|\(publication.id)", library: publication.library)
    }
    return SeriesKey(id: series.id, library: publication.library)
  }

  /// Numbered volumes by number, then everything else by title as a person
  /// would sort it: "v2" before "v10".
  public static func readingOrder(_ first: Publication, _ second: Publication) -> Bool {
    switch (first.volumeNumber, second.volumeNumber) {
    case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
    case (.some, nil): return true
    case (nil, .some): return false
    default: return first.title.localizedStandardCompare(second.title) == .orderedAscending
    }
  }
}
