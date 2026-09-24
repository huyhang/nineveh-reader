import Testing

@testable import NinevehCore

@Test func organizesPublicationsByCategorySeriesAndEveryAuthor() {
  let series = SeriesReference(id: "series", title: "A Series")
  let first = Publication(
    id: "1",
    title: "First",
    authors: ["Ada", "Bea"],
    series: series,
    category: .comics
  )
  let second = Publication(
    id: "2",
    title: "Second",
    authors: ["Ada"],
    series: series,
    category: .manga
  )

  let categories = CatalogOrganizer.collections(from: [first, second], groupedBy: .category)
  let seriesCollections = CatalogOrganizer.collections(from: [first, second], groupedBy: .series)
  let authors = CatalogOrganizer.collections(from: [first, second], groupedBy: .author)

  #expect(categories.map(\.title) == ["Comics", "Manga"])
  #expect(seriesCollections.first?.publications.count == 2)
  #expect(authors.first(where: { $0.title == "Ada" })?.publications.count == 2)
  #expect(authors.first(where: { $0.title == "Bea" })?.publications.count == 1)
}

@Test func filesVolumesUnderTheCreatorsACallerSupplies() {
  let series = SeriesReference(id: "ragna", title: "Ragna Crimson")
  let first = Publication(id: "1", title: "v01", series: series, category: .manga)
  let second = Publication(id: "2", title: "v02", series: series, category: .manga)
  let loose = Publication(id: "3", title: "Loose", category: .manga)

  let authors = CatalogOrganizer.collections(
    from: [first, second, loose], groupedBy: .author,
    creators: { $0.series == nil ? [] : ["Daiki Kobayashi", "Daiki Kobayashi"] })

  #expect(authors.map(\.title) == ["Daiki Kobayashi", "Unknown Author"])
  #expect(authors.first?.publications.map(\.id) == ["1", "2"])
}
