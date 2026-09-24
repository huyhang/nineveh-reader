import NinevehCore
import SwiftUI

// MARK: - Home

struct HomeView: View {
  @ObservedObject var model: ApplicationModel

  var body: some View {
    let continueReading = model.continueReading
    let upNext = model.upNext
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 34) {
        if let publication = continueReading.first ?? upNext.first {
          FeatureBanner(model: model, publication: publication)
        } else if let series = model.seriesGroups.first {
          FeatureBanner(model: model, series: series)
        }

        if !continueReading.isEmpty {
          PublicationShelf(
            model: model, title: "Continue Reading", publications: continueReading,
            opensReader: true)
        }

        if !upNext.isEmpty {
          PublicationShelf(model: model, title: "Up Next", publications: upNext, opensReader: true)
        }

        ForEach(seriesShelves, id: \.title) { shelf in
          SeriesShelf(model: model, title: shelf.title, series: shelf.series)
        }
      }
      .padding(ReaderTheme.contentPadding)
    }
    .overlay {
      if model.publications.isEmpty && !model.isRefreshing {
        if model.libraries.isEmpty && !model.allLibraries.isEmpty {
          ContentUnavailableView(
            "Every Library Is Hidden",
            systemImage: "eye.slash",
            description: Text("Turn a library back on in Settings to see it here.")
          )
        } else {
          ContentUnavailableView(
            "No Publications",
            systemImage: "books.vertical",
            description: Text("Connect to Nineveh or open On My Mac to start reading.")
          )
        }
      }
    }
    .navigationTitle("Home")
  }

  /// One shelf per library when there are several, otherwise one per category.
  private var seriesShelves: [(title: String, series: [SeriesGroup])] {
    let libraries = model.libraries.map(\.name).filter { !model.seriesGroups(in: $0).isEmpty }
    if libraries.count > 1 {
      return libraries.map { (title: $0, series: model.seriesGroups(in: $0)) }
    }
    return model.categories(in: nil).map { category in
      (title: category.shelfTitle, series: model.seriesGroups(in: nil, category: category))
    }
  }
}

private struct FeatureBanner: View {
  @ObservedObject var model: ApplicationModel
  private let publication: Publication?
  private let series: SeriesGroup?
  @State private var coverData: Data?

  init(model: ApplicationModel, publication: Publication) {
    self.model = model
    self.publication = publication
    self.series = model.series(containing: publication)
  }

  init(model: ApplicationModel, series: SeriesGroup) {
    self.model = model
    self.publication = series.volumes.first
    self.series = series
  }

  var body: some View {
    let progress = publication.map(model.progress(for:))
    HStack(alignment: .center, spacing: 22) {
      cover

      VStack(alignment: .leading, spacing: 7) {
        Text(eyebrow(progress))
          .font(.caption2.weight(.bold))
          .tracking(1.3)
          .foregroundStyle(.white.opacity(0.7))
        Text(headline)
          .font(.system(size: 26, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .lineLimit(1)
        if let publication, series?.volumes.count ?? 0 > 1 || publication.series != nil {
          Text(publication.title)
            .font(.headline)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
        }
        if let summary = detailSummary {
          Text(summary)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(2)
            .frame(maxWidth: 600, alignment: .leading)
        }

        if let progress, progress.isStarted, !progress.isCompleted {
          HStack(spacing: 10) {
            ReadingProgressBar(fraction: progress.fraction, tint: .white)
              .frame(width: 200)
            Text("\(progress.label) · \(progress.percent)%")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.white.opacity(0.7))
          }
        }

        HStack(spacing: 8) {
          if let publication {
            Button {
              Task { await model.beginReading(publication) }
            } label: {
              Label(
                progress?.resumePage == nil ? "Read Now" : "Continue", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
          }

          if let series {
            NavigationLink(value: LibraryRoute.series(series.key)) {
              Label(series.volumes.count > 1 ? "Series" : "Details", systemImage: "info.circle")
            }
            .buttonStyle(.bordered)
            .tint(.white)
          }
        }
        .padding(.top, 4)
      }

      Spacer(minLength: 0)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    // A background cannot change the card's size, however large the art is.
    .background { backdrop }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .shadow(color: posterColor.opacity(0.18), radius: 14, y: 6)
    .accessibilityElement(children: .contain)
    .task(id: "\(publication?.id ?? "")|\(series?.id.id ?? "")|\(model.coverGeneration)") {
      if let publication {
        coverData = await model.coverData(for: publication)
      } else if let series {
        coverData = await model.seriesCoverData(for: series)
      }
    }
  }

  /// The volume the buttons act on, which opens it too.
  @ViewBuilder
  private var cover: some View {
    let artwork = CoverArtwork(
      data: coverData, title: publication?.title ?? headline,
      category: series?.category ?? publication?.category ?? .unknown
    )
    .frame(width: 118, height: 177)
    if let publication {
      Button {
        Task { await model.beginReading(publication) }
      } label: {
        artwork
      }
      .buttonStyle(.plain)
      .help("Read \(publication.title)")
      .accessibilityLabel("Cover of \(publication.title)")
    } else {
      artwork
    }
  }

  private var backdrop: some View {
    ZStack {
      LinearGradient(
        colors: [posterColor.opacity(0.9), .black.opacity(0.9)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      if let coverData, let image = PlatformImage(data: coverData) {
        platformImage(image)
          .resizable()
          .scaledToFill()
          .blur(radius: 40)
          .opacity(0.5)
      }
      LinearGradient(
        colors: [.black.opacity(0.55), .black.opacity(0.2)],
        startPoint: .leading,
        endPoint: .trailing
      )
    }
    .clipped()
    .accessibilityHidden(true)
  }

  private var headline: String {
    series.map(model.displayTitle(for:)) ?? publication?.title ?? ""
  }

  private var detailSummary: String? {
    guard let series, let description = model.detail(for: series)?.metadata?.description else {
      return publication?.summary
    }
    return description
  }

  private func eyebrow(_ progress: VolumeProgress?) -> String {
    switch progress?.state {
    case .reading: "CONTINUE READING"
    case .notStarted where publication.map(model.upNext.contains) ?? false: "UP NEXT"
    default: "FEATURED"
    }
  }

  private var posterColor: Color {
    Color.posterColor(for: headline)
  }
}

private struct PublicationShelf: View {
  @ObservedObject var model: ApplicationModel
  let title: String
  let publications: [Publication]
  /// Opens the reader on click rather than the publication's page.
  var opensReader = false

  var body: some View {
    ShelfContainer(title: title, count: publications.count) {
      ForEach(publications) { publication in
        Group {
          if opensReader {
            Button {
              Task { await model.beginReading(publication) }
            } label: {
              PublicationCard(model: model, publication: publication, showsSeries: true)
            }
          } else {
            NavigationLink(value: LibraryRoute.publication(publication)) {
              PublicationCard(model: model, publication: publication, showsSeries: true)
            }
          }
        }
        .buttonStyle(.plain)
        .frame(width: 150)
        .contextMenu { PublicationActions(model: model, publication: publication) }
      }
    }
  }
}

private struct SeriesShelf: View {
  @ObservedObject var model: ApplicationModel
  let title: String
  let series: [SeriesGroup]

  var body: some View {
    ShelfContainer(title: title, count: series.count) {
      ForEach(series) { group in
        NavigationLink(value: LibraryRoute.series(group.key)) {
          SeriesCard(model: model, series: group)
        }
        .buttonStyle(.plain)
        .frame(width: 150)
      }
    }
  }
}

private struct ShelfContainer<Content: View>: View {
  let title: String
  let count: Int
  @ViewBuilder let content: Content
  @State private var tallestCard: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.title2.weight(.semibold))
        Spacer()
        Text("\(count)")
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 18) {
          // A card with more lines of text grows rather than shrinking its
          // cover to the height of the others, and the shelf grows with it.
          ForEach(subviews: content) { card in
            card
              .fixedSize(horizontal: false, vertical: true)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                tallestCard = max(tallestCard, $0)
              }
          }
        }
        .frame(minHeight: tallestCard, alignment: .top)
        .padding(.vertical, 8)
      }
      .scrollIndicators(.hidden)
      .shelfBleed()
    }
  }
}

// MARK: - Browse

enum BrowseArrangement: String, CaseIterable, Identifiable {
  case series
  case volumes
  case authors

  var id: Self { self }

  var title: String {
    switch self {
    case .series: "Series"
    case .volumes: "Volumes"
    case .authors: "Authors"
    }
  }
}

private enum SeriesSort: String, CaseIterable, Identifiable {
  case title
  case recentlyRead
  case volumeCount

  var id: Self { self }

  var title: String {
    switch self {
    case .title: "Title"
    case .recentlyRead: "Recently Read"
    case .volumeCount: "Most Volumes"
    }
  }
}

struct BrowseView: View {
  @ObservedObject var model: ApplicationModel
  let library: String?
  @State private var arrangement: BrowseArrangement
  @State private var category: PublicationCategory?
  @State private var sort: SeriesSort = .title

  init(model: ApplicationModel, library: String?, initialArrangement: BrowseArrangement = .series) {
    self.model = model
    self.library = library
    _arrangement = State(initialValue: initialArrangement)
  }

  var body: some View {
    let series = sorted(model.seriesGroups(in: library, category: category))
    let volumes = series.flatMap(\.volumes)
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header(seriesCount: series.count, volumeCount: volumes.count)

        switch arrangement {
        case .series:
          SeriesGrid(model: model, series: series, showsLibrary: library == nil)
        case .volumes:
          PublicationGridView(
            model: model, title: "Volumes", publications: volumes, embedsScrollView: false,
            showsHeader: false)
        case .authors:
          CollectionGridView(
            model: model,
            collections: CatalogOrganizer.collections(
              from: volumes, groupedBy: .author, creators: { model.creators(of: $0) }))
        }
      }
      .padding(ReaderTheme.contentPadding)
    }
    .overlay {
      if series.isEmpty && !model.isRefreshing {
        ContentUnavailableView(
          "Nothing Here Yet",
          systemImage: "books.vertical",
          description: Text("Series added to this library on Nineveh will appear here.")
        )
      }
    }
    .navigationTitle(library ?? "All Series")
  }

  private func header(seriesCount: Int, volumeCount: Int) -> some View {
    let categories = model.categories(in: library)
    return VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text(library ?? "All Series")
          .font(.largeTitle.weight(.semibold))
        Text("\(seriesCount.formatted()) series · \(volumeCount.formatted()) volumes")
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 12) {
        if categories.count > 1 {
          Picker("Category", selection: $category) {
            Text("All").tag(PublicationCategory?.none)
            ForEach(categories, id: \.self) { category in
              Text(category.title).tag(Optional(category))
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        Spacer()
        Picker("Show", selection: $arrangement) {
          ForEach(BrowseArrangement.allCases) { option in
            Text(option.title).tag(option)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        if arrangement == .series {
          Picker("Sort By", selection: $sort) {
            ForEach(SeriesSort.allCases) { option in
              Text(option.title).tag(option)
            }
          }
          .fixedSize()
        }
      }
    }
  }

  private func sorted(_ series: [SeriesGroup]) -> [SeriesGroup] {
    switch sort {
    case .title:
      return series.sorted {
        model.displayTitle(for: $0).localizedStandardCompare(model.displayTitle(for: $1))
          == .orderedAscending
      }
    case .recentlyRead:
      var lastRead: [SeriesKey: Date] = [:]
      for group in series {
        lastRead[group.key] = group.volumes.compactMap { model.position(for: $0)?.updatedAt }.max()
      }
      return series.sorted { first, second in
        let firstDate = lastRead[first.key] ?? .distantPast
        let secondDate = lastRead[second.key] ?? .distantPast
        return firstDate > secondDate
      }
    case .volumeCount:
      return series.sorted { $0.volumes.count > $1.volumes.count }
    }
  }
}

struct SearchResultsView: View {
  @ObservedObject var model: ApplicationModel
  let query: String
  let library: String?

  var body: some View {
    let results = model.series(matching: query, in: library)
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Results for “\(query)”")
            .font(.largeTitle.weight(.semibold))
          Text(scopeDescription(count: results.count))
            .foregroundStyle(.secondary)
        }
        SeriesGrid(model: model, series: results, showsLibrary: library == nil)
      }
      .padding(ReaderTheme.contentPadding)
    }
    .overlay {
      if results.isEmpty { ContentUnavailableView.search(text: query) }
    }
    .navigationTitle("Search")
  }

  private func scopeDescription(count: Int) -> String {
    let matches = count == 1 ? "1 series" : "\(count) series"
    return library.map { "\(matches) in \($0)" } ?? matches
  }
}

struct SeriesGrid: View {
  @ObservedObject var model: ApplicationModel
  let series: [SeriesGroup]
  var showsLibrary = false

  private let columns = [
    GridItem(.adaptive(minimum: 150, maximum: 190), spacing: ReaderTheme.cardSpacing)
  ]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
      ForEach(series) { group in
        NavigationLink(value: LibraryRoute.series(group.key)) {
          SeriesCard(model: model, series: group, showsLibrary: showsLibrary)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

private struct CollectionGridView: View {
  @ObservedObject var model: ApplicationModel
  let collections: [PublicationCollection]
  private let columns = [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 20)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 20) {
      ForEach(collections) { collection in
        NavigationLink(value: LibraryRoute.collection(collection)) {
          CollectionCard(model: model, collection: collection)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

private struct CollectionCard: View {
  let model: ApplicationModel
  let collection: PublicationCollection
  @State private var hovering = false

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      LinearGradient(
        colors: [Color.posterColor(for: collection.title), .black.opacity(0.86)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      HStack(spacing: -22) {
        Spacer()
        ForEach(Array(collection.publications.prefix(3).enumerated()), id: \.element.id) {
          index, publication in
          CoverImageView(model: model, publication: publication)
            .frame(width: 82, height: 123)
            .rotationEffect(.degrees(Double(index - 1) * 4))
        }
        Spacer().frame(width: 18)
      }
      .offset(y: -28)

      LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)

      VStack(alignment: .leading, spacing: 3) {
        Text(collection.title)
          .font(.title3.weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(1)
        Text(collection.subtitle)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.7))
      }
      .padding(18)
    }
    .frame(height: 210)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 18 : 8, y: 7)
    .scaleEffect(hovering ? 1.015 : 1)
    .animation(.easeOut(duration: 0.16), value: hovering)
    .onHover { hovering = $0 }
  }
}

struct PublicationGridView: View {
  @ObservedObject var model: ApplicationModel
  let title: String
  let publications: [Publication]
  var embedsScrollView = true
  var showsHeader = true

  private let columns = [
    GridItem(.adaptive(minimum: 145, maximum: 190), spacing: ReaderTheme.cardSpacing)
  ]

  var body: some View {
    Group {
      if embedsScrollView {
        ScrollView { content.padding(ReaderTheme.contentPadding) }
          .navigationTitle(title)
      } else {
        content
      }
    }
    .overlay {
      if model.isRefreshing && publications.isEmpty { ProgressView() }
    }
  }

  private var content: some View {
    LazyVStack(alignment: .leading, spacing: 18) {
      if showsHeader {
        HStack {
          Text(title).font(.title2.weight(.semibold))
          Spacer()
          Text(publications.count == 1 ? "1 title" : "\(publications.count) titles")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
        ForEach(publications) { publication in
          NavigationLink(value: LibraryRoute.publication(publication)) {
            PublicationCard(model: model, publication: publication, showsSeries: true)
          }
          .buttonStyle(.plain)
          .contextMenu { PublicationActions(model: model, publication: publication) }
        }
      }
    }
  }
}

// MARK: - Cards

struct SeriesCard: View {
  @ObservedObject var model: ApplicationModel
  let series: SeriesGroup
  var showsLibrary = false
  @State private var hovering = false

  var body: some View {
    let detail = model.detail(for: series)
    let progress = model.progress(for: series)
    let downloaded = model.downloadedCount(in: series)
    VStack(alignment: .leading, spacing: 7) {
      SeriesCoverView(model: model, series: series)
        .aspectRatio(ReaderTheme.coverRatio, contentMode: .fit)
        .overlay(alignment: .topLeading) {
          HStack(spacing: 4) {
            if downloaded > 0 {
              DownloadedBadge(count: downloaded, total: series.volumes.count)
            }
            if detail?.metadata != nil {
              CoverBadge(systemImage: "sparkles", label: "Series details available")
            }
          }
          .padding(7)
        }
        .overlay(alignment: .topTrailing) {
          Group {
            if progress.completedCount == progress.volumeCount, progress.volumeCount > 0 {
              CoverBadge(systemImage: "checkmark", label: "All read", tint: .green)
            } else if series.volumes.count > 1 {
              CoverBadge(text: "\(series.volumes.count)", label: "\(series.volumes.count) volumes")
            }
          }
          .padding(7)
        }
        .overlay(alignment: .bottom) {
          if progress.fraction > 0, progress.fraction < 1 {
            ReadingProgressBar(fraction: progress.fraction, tint: .white)
              .padding(8)
          }
        }
      if showsLibrary {
        Text(eyebrow)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
          .lineLimit(1)
      }
      Text(model.displayTitle(for: series))
        .font(.headline)
        .lineLimit(2)
      if let detail, detail.isRetitled {
        Text(detail.localName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Text(subtitle(progress))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .contentShape(Rectangle())
    .scaleEffect(hovering ? 1.025 : 1)
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .combine)
  }

  private var eyebrow: String {
    [series.library, series.category == .unknown ? nil : series.category.title]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  private func subtitle(_ progress: SeriesProgress) -> String {
    let count = series.volumes.count == 1 ? "1 volume" : "\(series.volumes.count) volumes"
    return [count, progress.summary].compactMap { $0 }.joined(separator: " · ")
  }
}

struct PublicationCard: View {
  @ObservedObject var model: ApplicationModel
  let publication: Publication
  /// Names the series under the title; inside a series the volume is enough.
  var showsSeries = false
  @State private var hovering = false

  var body: some View {
    let progress = model.progress(for: publication)
    VStack(alignment: .leading, spacing: 7) {
      CoverImageView(model: model, publication: publication)
        .aspectRatio(ReaderTheme.coverRatio, contentMode: .fit)
        .overlay(alignment: .topLeading) {
          if model.isDownloaded(publication) {
            DownloadedBadge().padding(7)
          }
        }
        .overlay(alignment: .topTrailing) {
          if progress.isCompleted {
            CoverBadge(systemImage: "checkmark", label: "Completed", tint: .green).padding(7)
          }
        }
        .overlay(alignment: .bottom) {
          if progress.resumePage != nil {
            ReadingProgressBar(fraction: progress.fraction, tint: .white)
              .padding(8)
          }
        }
      Text(publication.title)
        .font(.headline)
        .lineLimit(2)
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if progress.resumePage != nil {
        Text(progress.label)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
    .contentShape(Rectangle())
    .scaleEffect(hovering ? 1.025 : 1)
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .combine)
  }

  private var subtitle: String {
    if showsSeries, let series = model.series(containing: publication),
      publication.series != nil
    {
      return model.displayTitle(for: series)
    }
    if let volume = publication.volume {
      return publication.pageCount.map { "Volume \(volume) · \($0) pages" } ?? "Volume \(volume)"
    }
    return model.creators(of: publication).first ?? publication.pageCount.map { "\($0) pages" }
      ?? "Standalone"
  }
}

/// Everything that can be done to a publication, for context menus and "More" buttons.
struct PublicationActions: View {
  @ObservedObject var model: ApplicationModel
  let publication: Publication
  var includesDetails = true

  var body: some View {
    let progress = model.progress(for: publication)
    Button {
      Task { await model.beginReading(publication, fromStart: progress.isCompleted) }
    } label: {
      Label(
        progress.resumePage.map { "Resume at Page \($0)" } ?? "Read",
        systemImage: "book.pages")
    }
    if progress.resumePage != nil {
      Button {
        Task { await model.beginReading(publication, fromStart: true) }
      } label: {
        Label("Read from Start", systemImage: "arrow.counterclockwise")
      }
    }
    if let series = model.series(containing: publication), publication.series != nil {
      Button {
        model.libraryPath.append(.series(series.key))
      } label: {
        Label("Show Series", systemImage: "books.vertical")
      }
    }
    if includesDetails {
      Button {
        model.libraryPath.append(.publication(publication))
      } label: {
        Label("Details", systemImage: "info.circle")
      }
    }
    Divider()
    if let record = model.downloadRecord(for: publication), record.localFilename != nil {
      if model.updateAvailable(for: publication) {
        Button {
          Task { await model.download(publication) }
        } label: {
          Label("Update Download", systemImage: "arrow.triangle.2.circlepath")
        }
      }
      Button(role: .destructive) {
        Task { await model.removeDownload(record) }
      } label: {
        Label("Remove Download", systemImage: "trash")
      }
    } else if model.connection != nil {
      Button {
        Task { await model.download(publication) }
      } label: {
        Label("Download CBZ", systemImage: "arrow.down.circle")
      }
    }
    Divider()
    if !progress.isCompleted {
      Button {
        Task { await model.markRead(publication) }
      } label: {
        Label("Mark as Read", systemImage: "checkmark.circle")
      }
    }
    if progress.isStarted {
      Button {
        Task { await model.markUnread(publication) }
      } label: {
        Label("Mark as Unread", systemImage: "circle")
      }
    }
  }
}

struct CoverBadge: View {
  var systemImage: String?
  var text: String?
  let label: String
  var tint: Color = .black.opacity(0.62)

  var body: some View {
    HStack(spacing: 3) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      if let text {
        Text(text).monospacedDigit()
      }
    }
    .font(.caption2.weight(.bold))
    .foregroundStyle(.white)
    .padding(.horizontal, 6)
    .frame(minWidth: 20, minHeight: 20)
    .background(tint, in: Capsule())
    .help(label)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
  }
}

/// Marks a cover whose volume, or some of whose volumes, are on this Mac.
struct DownloadedBadge: View {
  var count: Int?
  var total: Int?

  var body: some View {
    if let count, let total, count < total {
      CoverBadge(
        systemImage: "arrow.down", text: "\(count)",
        label: "\(count) of \(total) volumes downloaded", tint: .accentColor)
    } else {
      CoverBadge(systemImage: "arrow.down", label: "Downloaded", tint: .accentColor)
    }
  }
}

/// A slim bar showing how much of something has been read.
struct ReadingProgressBar: View {
  let fraction: Double
  var tint: Color = .accentColor

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(tint.opacity(0.25))
        Capsule()
          .fill(tint)
          .frame(width: max(fraction > 0 ? 4 : 0, proxy.size.width * min(max(fraction, 0), 1)))
      }
    }
    .frame(height: 4)
    .accessibilityElement()
    .accessibilityLabel("Progress")
    .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
  }
}

// MARK: - Covers

struct CoverImageView: View {
  let model: ApplicationModel
  let publication: Publication
  @State private var imageData: Data?

  var body: some View {
    CoverArtwork(data: imageData, title: publication.title, category: publication.category)
      .task(id: publication.id) {
        imageData = await model.coverData(for: publication)
      }
      .accessibilityLabel("Cover of \(publication.title)")
  }
}

struct SeriesCoverView: View {
  @ObservedObject var model: ApplicationModel
  let series: SeriesGroup
  @State private var imageData: Data?

  var body: some View {
    CoverArtwork(data: imageData, title: series.title, category: series.category)
      .task(id: "\(series.id.library ?? "")|\(series.id.id)|\(model.coverGeneration)") {
        imageData = await model.seriesCoverData(for: series)
      }
      .accessibilityLabel("Cover of \(series.title)")
  }
}

/// A cover, or a designed stand-in until one arrives.
struct CoverArtwork: View {
  let data: Data?
  let title: String
  let category: PublicationCategory

  var body: some View {
    ZStack {
      if let data, let image = PlatformImage(data: data) {
        platformImage(image)
          .resizable()
          .scaledToFill()
      } else {
        PosterPlaceholder(title: title, category: category)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: ReaderTheme.coverRadius, style: .continuous))
    .shadow(color: .black.opacity(0.2), radius: 9, y: 5)
  }
}

private struct PosterPlaceholder: View {
  let title: String
  let category: PublicationCategory

  var body: some View {
    // The gradient alone sizes the poster, so it fits any frame it is given.
    LinearGradient(
      colors: [Color.posterColor(for: title), .black.opacity(0.88)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .overlay {
      GeometryReader { proxy in
        let side = proxy.size.width
        Circle()
          .stroke(.white.opacity(0.15), lineWidth: side * 0.12)
          .frame(width: side, height: side)
          .position(x: side * 0.8, y: side * 0.15)
      }
    }
    .overlay {
      VStack(alignment: .leading) {
        Text(category == .manga ? "MANGA" : "NINEVEH")
          .font(.caption2.weight(.bold))
          .tracking(1.4)
          .foregroundStyle(.white.opacity(0.65))
        Spacer()
        Text(title)
          .font(.system(size: 20, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .lineLimit(4)
          .minimumScaleFactor(0.5)
        Rectangle()
          .fill(.white.opacity(0.7))
          .frame(width: 30, height: 2)
      }
      .padding(14)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
  }
}

extension PublicationCategory {
  var title: String {
    switch self {
    case .comics: "Comics"
    case .manga: "Manga"
    case .unknown: "Other"
    }
  }

  var shelfTitle: String {
    switch self {
    case .comics: "Comics"
    case .manga: "Manga"
    case .unknown: "More to Read"
    }
  }
}

extension Color {
  static func posterColor(for text: String) -> Color {
    let seed = text.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 360 }
    return Color(hue: Double(seed) / 360, saturation: 0.66, brightness: 0.72)
  }
}

#if canImport(AppKit)
  import AppKit
  typealias PlatformImage = NSImage
  func platformImage(_ image: PlatformImage) -> Image { Image(nsImage: image) }
#elseif canImport(UIKit)
  import UIKit
  typealias PlatformImage = UIImage
  func platformImage(_ image: PlatformImage) -> Image { Image(uiImage: image) }
#endif
