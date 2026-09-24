import NinevehCore
import SwiftUI

// MARK: - Home

struct HomeView: View {
  @ObservedObject var model: ApplicationModel
  @Environment(\.contentPadding) private var contentPadding

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
            model: model, title: "Continue Reading", detail: source,
            publications: continueReading, opensReader: true)
        }

        if !upNext.isEmpty {
          PublicationShelf(
            model: model, title: "Up Next", detail: source, publications: upNext,
            opensReader: true)
        }

        ForEach(seriesShelves, id: \.title) { shelf in
          SeriesShelf(model: model, title: shelf.title, detail: shelf.detail, series: shelf.series)
        }
      }
      .padding(contentPadding)
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
            description: Text(
              "Connect to Nineveh or open \(LibrarySection.onDevice.title) to start reading.")
          )
        }
      }
    }
    .navigationTitle("Home")
  }

  /// Where Home's shelves come from, when that is one library.
  private var source: String? {
    model.libraries.count == 1 ? model.libraries.first?.name : nil
  }

  /// One shelf per library when there are several, otherwise one per category.
  private var seriesShelves: [(title: String, detail: String?, series: [SeriesGroup])] {
    let libraries = model.libraries.map(\.name).filter { !model.seriesGroups(in: $0).isEmpty }
    if libraries.count > 1 {
      return libraries.map { (title: $0, detail: nil, series: model.seriesGroups(in: $0)) }
    }
    return model.categories(in: nil).map { category in
      (
        title: category.shelfTitle, detail: source,
        series: model.seriesGroups(in: nil, category: category)
      )
    }
  }
}

private struct FeatureBanner: View {
  @ObservedObject var model: ApplicationModel
  private let publication: Publication?
  private let series: SeriesGroup?
  @State private var coverData: Data?
  @Environment(\.isNarrow) private var isNarrow

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
    HStack(alignment: .center, spacing: isNarrow ? 16 : 22) {
      cover

      VStack(alignment: .leading, spacing: 7) {
        Text(eyebrow(progress))
          .font(.system(size: 11, weight: .heavy))
          .tracking(1.3)
          .foregroundStyle(ReaderTheme.accent)
        Text(headline)
          .font(.system(size: 28, weight: .bold))
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
            ReadingProgressBar(fraction: progress.fraction, track: .white.opacity(0.2))
              .frame(width: isNarrow ? 90 : 200)
            Text("\(progress.label) · \(progress.percent)%")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.white.opacity(0.7))
          }
        }

        ActionRow(spacing: 8) {
          if let publication {
            Button {
              Task { await model.beginReading(publication) }
            } label: {
              Label(
                progress?.resumePage == nil ? "Read Now" : "Continue", systemImage: "play.fill")
            }
            .buttonStyle(.accent)
          }

          if let series {
            NavigationLink(value: LibraryRoute.series(series.key)) {
              Label(series.volumes.count > 1 ? "Series" : "Details", systemImage: "info.circle")
            }
            .buttonStyle(.chrome)
          }
        }
        .padding(.top, 4)
      }

      Spacer(minLength: 0)
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    // A background cannot change the card's size, however large the art is.
    .background { backdrop }
    .clipShape(RoundedRectangle(cornerRadius: 4))
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
    .frame(width: isNarrow ? 80 : 118, height: isNarrow ? 120 : 177)
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
        colors: [posterColor.opacity(0.5), Color(white: 0.08)],
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
        colors: [.black.opacity(0.7), .black.opacity(0.25)],
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
  var detail: String?
  let publications: [Publication]
  /// Opens the reader on click rather than the publication's page.
  var opensReader = false

  var body: some View {
    ShelfContainer(title: title, detail: detail) {
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
  var detail: String?
  let series: [SeriesGroup]

  var body: some View {
    ShelfContainer(title: title, detail: detail) {
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

/// A row of cards under a heading, paged with the arrows at its end.
private struct ShelfContainer<Content: View>: View {
  let title: String
  var detail: String?
  @ViewBuilder let content: Content
  @State private var tallestCard: CGFloat = 0
  @State private var position = ScrollPosition(edge: .leading)
  @State private var scroll = ShelfScroll()
  @Environment(\.contentPadding) private var contentPadding

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center) {
        SectionHeading(title: title, detail: detail)
        Spacer()
        if scroll.overflows {
          HStack(spacing: 2) {
            Button {
              page(by: -1)
            } label: {
              Image(systemName: "chevron.left")
            }
            .disabled(scroll.atStart)
            .help("Previous")
            Button {
              page(by: 1)
            } label: {
              Image(systemName: "chevron.right")
            }
            .disabled(scroll.atEnd)
            .help("Next")
          }
          .buttonStyle(.chromeIcon(size: 26))
        }
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
        .padding(.vertical, 6)
      }
      .scrollIndicators(.never)
      .scrollPosition($position)
      .onScrollGeometryChange(for: ShelfScroll.self) { geometry in
        ShelfScroll(
          offset: geometry.contentOffset.x + geometry.contentInsets.leading,
          visible: geometry.containerSize.width,
          content: geometry.contentSize.width + geometry.contentInsets.leading
            + geometry.contentInsets.trailing)
      } action: { _, new in
        scroll = new
      }
      .shelfBleed()
    }
  }

  /// Moves a shelf's width less a card, so the last card seen stays in view.
  private func page(by direction: CGFloat) {
    let step = max(scroll.visible - 2 * contentPadding - 150, 150)
    let target = min(max(scroll.offset + direction * step, 0), scroll.maxOffset)
    withAnimation(.easeInOut(duration: 0.35)) {
      position.scrollTo(x: target - scrollInsetLeading)
    }
  }

  private var scrollInsetLeading: CGFloat { contentPadding }
}

/// How far a shelf is scrolled, measured from its first card.
private struct ShelfScroll: Equatable {
  var offset: CGFloat = 0
  var visible: CGFloat = 0
  var content: CGFloat = 0

  var maxOffset: CGFloat { max(content - visible, 0) }
  var overflows: Bool { maxOffset > 1 }
  var atStart: Bool { offset <= 1 }
  var atEnd: Bool { offset >= maxOffset - 1 }
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
  @Environment(\.contentPadding) private var contentPadding

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
      .padding(contentPadding)
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
    return VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 14) {
        Text(library ?? "All Series").pageTitleStyle()
        Text("\(seriesCount.formatted()) series · \(volumeCount.formatted()) volumes")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(ReaderTheme.secondaryText)
      }
      // Every tab in one row where there is room, as on the Mac; in a narrow
      // window, the categories under the arrangements, scrolling if need be.
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 28) {
          arrangementTabs
          if categories.count > 1 {
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16)
            categoryTabs(categories)
          }
          Spacer()
          sortMenu
        }
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .center, spacing: 16) {
            arrangementTabs
            Spacer(minLength: 0)
            sortMenu
          }
          if categories.count > 1 {
            ScrollView(.horizontal) {
              categoryTabs(categories)
            }
            .scrollIndicators(.never)
          }
        }
      }
      .padding(.bottom, 6)
      .overlay(alignment: .bottom) {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
      }
    }
  }

  private var arrangementTabs: some View {
    TextTabs(options: BrowseArrangement.allCases, selection: $arrangement, title: \.title)
  }

  private func categoryTabs(_ categories: [PublicationCategory]) -> some View {
    TextTabs(
      options: [nil] + categories.map(Optional.some), selection: $category,
      title: { $0?.title ?? "All" })
  }

  @ViewBuilder
  private var sortMenu: some View {
    if arrangement == .series {
      Menu {
        Picker("Sort By", selection: $sort) {
          ForEach(SeriesSort.allCases) { option in
            Text(option.title).tag(option)
          }
        }
        .pickerStyle(.inline)
      } label: {
        HStack(spacing: 5) {
          Text("Sort:").foregroundStyle(ReaderTheme.secondaryText)
          Text(sort.title).foregroundStyle(.white)
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(ReaderTheme.secondaryText)
        }
        .font(.system(size: 13, weight: .semibold))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
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
  @Environment(\.contentPadding) private var contentPadding

  var body: some View {
    let results = model.series(matching: query, in: library)
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
          Text("Results for “\(query)”").pageTitleStyle()
          Text(scopeDescription(count: results.count))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ReaderTheme.secondaryText)
        }
        SeriesGrid(model: model, series: results, showsLibrary: library == nil)
      }
      .padding(contentPadding)
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
  @Environment(\.isNarrow) private var isNarrow

  /// Two posters abreast even in a narrow window.
  private var columns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: isNarrow ? 120 : 150, maximum: 190), spacing: ReaderTheme.cardSpacing)
    ]
  }

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
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .overlay {
      RoundedRectangle(cornerRadius: 4)
        .strokeBorder(ReaderTheme.accent, lineWidth: hovering ? 3 : 0)
    }
    .animation(.easeOut(duration: 0.12), value: hovering)
    .onHover { hovering = $0 }
  }
}

struct PublicationGridView: View {
  @ObservedObject var model: ApplicationModel
  let title: String
  let publications: [Publication]
  var embedsScrollView = true
  var showsHeader = true
  @Environment(\.isNarrow) private var isNarrow
  @Environment(\.contentPadding) private var contentPadding

  /// Two covers abreast even in a narrow window.
  private var columns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: isNarrow ? 120 : 145, maximum: 190), spacing: ReaderTheme.cardSpacing)
    ]
  }

  var body: some View {
    Group {
      if embedsScrollView {
        ScrollView { content.padding(contentPadding) }
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
        SectionHeading(
          title: title,
          detail: publications.count == 1 ? "1 title" : "\(publications.count) titles")
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
    VStack(alignment: .leading, spacing: 3) {
      SeriesCoverView(model: model, series: series)
        .aspectRatio(ReaderTheme.coverRatio, contentMode: .fit)
        .hoverOutline(hovering)
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
              CoverBadge(
                text: "\(series.volumes.count)", label: "\(series.volumes.count) volumes",
                tint: ReaderTheme.accent)
            }
          }
          .padding(7)
        }
        .overlay(alignment: .bottom) {
          if progress.fraction > 0, progress.fraction < 1 {
            ReadingProgressBar(fraction: progress.fraction)
          }
        }
        .padding(.bottom, 5)
      Text(model.displayTitle(for: series))
        .cardTitleStyle()
      if let detail, detail.isRetitled {
        Text(detail.localName)
          .cardSubtitleStyle()
      }
      Text(subtitle(progress))
        .cardSubtitleStyle()
      if showsLibrary, !eyebrow.isEmpty {
        Text(eyebrow)
          .cardDetailStyle()
      }
    }
    .contentShape(Rectangle())
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
    VStack(alignment: .leading, spacing: 3) {
      CoverImageView(model: model, publication: publication)
        .aspectRatio(ReaderTheme.coverRatio, contentMode: .fit)
        .hoverOutline(hovering)
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
            ReadingProgressBar(fraction: progress.fraction)
          }
        }
        .padding(.bottom, 5)
      Text(publication.title)
        .cardTitleStyle()
      Text(subtitle)
        .cardSubtitleStyle()
      if progress.resumePage != nil {
        Text(progress.label)
          .monospacedDigit()
          .cardDetailStyle()
      }
    }
    .contentShape(Rectangle())
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
    .font(.system(size: 11, weight: .heavy))
    .foregroundStyle(tint == ReaderTheme.accent ? .black.opacity(0.85) : .white)
    .padding(.horizontal, 5)
    .frame(minWidth: 20, minHeight: 20)
    .background(tint, in: RoundedRectangle(cornerRadius: 3))
    .help(label)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
  }
}

/// Marks a cover whose volume, or some of whose volumes, are on this device.
struct DownloadedBadge: View {
  var count: Int?
  var total: Int?

  var body: some View {
    if let count, let total, count < total {
      CoverBadge(
        systemImage: "arrow.down", text: "\(count)",
        label: "\(count) of \(total) volumes downloaded")
    } else {
      CoverBadge(systemImage: "arrow.down", label: "Downloaded")
    }
  }
}

/// A slim bar showing how much of something has been read, gold on a dark
/// track as it runs along the foot of a Plex poster.
struct ReadingProgressBar: View {
  let fraction: Double
  var tint: Color = ReaderTheme.accent
  var track: Color = .black.opacity(0.6)

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Rectangle().fill(track)
        Rectangle()
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
    .clipShape(RoundedRectangle(cornerRadius: ReaderTheme.coverRadius))
  }
}

extension View {
  /// Plex's hover: a gold frame around the poster rather than a lift.
  func hoverOutline(_ hovering: Bool) -> some View {
    overlay {
      RoundedRectangle(cornerRadius: ReaderTheme.coverRadius)
        .strokeBorder(ReaderTheme.accent, lineWidth: hovering ? 3 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
    .clipShape(RoundedRectangle(cornerRadius: ReaderTheme.coverRadius))
  }

  /// A card's name: bold white, up to two lines.
  func cardTitleStyle() -> some View {
    font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(2)
  }

  /// The line under a card's name.
  func cardSubtitleStyle() -> some View {
    font(.system(size: 12, weight: .medium)).foregroundStyle(ReaderTheme.secondaryText)
      .lineLimit(1)
  }

  /// A card's last, quietest line.
  func cardDetailStyle() -> some View {
    font(.system(size: 12)).foregroundStyle(ReaderTheme.tertiaryText).lineLimit(1)
  }
}

/// Plex's tabs: words in a row, the chosen one white over a gold rule.
struct TextTabs<Option: Hashable>: View {
  let options: [Option]
  @Binding var selection: Option
  let title: (Option) -> String

  var body: some View {
    HStack(spacing: 22) {
      ForEach(options, id: \.self) { option in
        let chosen = option == selection
        Button {
          selection = option
        } label: {
          Text(title(option).uppercased())
            .font(.system(size: 12, weight: .heavy))
            .tracking(0.7)
            .foregroundStyle(chosen ? .white : ReaderTheme.secondaryText)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
              Rectangle().fill(chosen ? ReaderTheme.accent : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
      }
    }
  }
}

private struct PosterPlaceholder: View {
  let title: String
  let category: PublicationCategory

  var body: some View {
    // The gradient alone sizes the poster, so it fits any frame it is given.
    LinearGradient(
      colors: [Color.posterColor(for: title), Color(white: 0.07)],
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
          .font(.system(size: 10, weight: .heavy))
          .tracking(1.4)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .foregroundStyle(.white.opacity(0.65))
        Spacer()
        Text(title)
          .font(.system(size: 20, weight: .heavy))
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
