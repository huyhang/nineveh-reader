import NinevehCore
import SwiftUI

struct SeriesDetailView: View {
  @ObservedObject var model: ApplicationModel
  let key: SeriesKey

  var body: some View {
    if let series = model.series(for: key) {
      SeriesPage(model: model, series: series)
    } else {
      ContentUnavailableView(
        "Series Unavailable",
        systemImage: "books.vertical",
        description: Text("This series is no longer in the library.")
      )
    }
  }
}

private struct SeriesPage: View {
  @ObservedObject var model: ApplicationModel
  let series: SeriesGroup
  @State private var coverData: Data?
  @State private var showsFullDescription = false
  @State private var pageWidth: CGFloat = 0
  @Environment(\.openURL) private var openURL
  @Environment(\.isNarrow) private var isNarrow
  @Environment(\.contentPadding) private var contentPadding

  /// Cards side by side, or in a narrow window, one under another.
  private var columns: [GridItem] {
    isNarrow
      ? [GridItem(.flexible(), spacing: 18)]
      : [GridItem(.adaptive(minimum: 330, maximum: 480), spacing: 18)]
  }

  var body: some View {
    let detail = model.detail(for: series)
    let metadata = detail?.metadata
    ScrollView {
      VStack(alignment: .leading, spacing: 34) {
        hero(detail: detail, metadata: metadata)
        if let metadata { about(metadata) }
        volumes
      }
      .padding(contentPadding)
      .frame(maxWidth: 1_180, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    // Measured for the hero, which stacks on a narrow page.
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
    .background(alignment: .top) { backdrop }
    .navigationTitle(model.displayTitle(for: series))
    .task(id: "\(series.id.library ?? "")|\(series.id.id)|\(model.coverGeneration)") {
      coverData = await model.seriesCoverData(for: series)
    }
    .task(id: series.id) {
      await model.refreshSeries(series)
    }
  }

  // MARK: Hero

  private var backdrop: some View {
    ZStack {
      if let coverData, let image = PlatformImage(data: coverData) {
        platformImage(image)
          .resizable()
          .scaledToFill()
          .blur(radius: 70)
          .opacity(0.4)
      } else {
        Color.posterColor(for: series.title).opacity(0.25)
      }
    }
    .frame(height: 460)
    .frame(maxWidth: .infinity)
    .clipped()
    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func hero(detail: SeriesDetail?, metadata: SeriesMetadata?) -> some View {
    let progress = model.progress(for: series)
    let layout = heroLayout(
      narrow: isNarrow || stacksHero(pageWidth: pageWidth, padding: contentPadding))
    return layout {
      CoverArtwork(data: coverData, title: series.title, category: series.category)
        .frame(width: 220, height: 330)
        .accessibilityLabel("Cover of \(model.displayTitle(for: series))")

      VStack(alignment: .leading, spacing: 13) {
        Text(eyebrow)
          .font(.system(size: 12, weight: .heavy))
          .tracking(1.1)
          .foregroundStyle(ReaderTheme.secondaryText)
          .textCase(.uppercase)

        Text(model.displayTitle(for: series))
          .font(.system(size: 34, weight: .heavy))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        if let detail, detail.isRetitled {
          Text("Filed locally as \(detail.localName)")
            .foregroundStyle(.secondary)
        }

        if let metadata {
          if !metadata.alternativeTitles.isEmpty {
            Text(metadata.alternativeTitles.prefix(4).joined(separator: " · "))
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .textSelection(.enabled)
          }
          if !metadata.badges.isEmpty {
            FlowLayout(spacing: 6) {
              ForEach(metadata.badges, id: \.self) { badge in
                Text(badge)
                  .font(.caption.weight(.semibold))
                  .padding(.horizontal, 9)
                  .padding(.vertical, 4)
                  .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                  .foregroundStyle(.tint)
              }
            }
          }
        } else {
          Text("No series metadata is available. Local volumes remain fully accessible below.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        actions
          .padding(.top, 6)

        if progress.volumeCount > 0, progress.fraction > 0 {
          VStack(alignment: .leading, spacing: 6) {
            ReadingProgressBar(fraction: progress.fraction)
              .frame(maxWidth: 360)
            Text(seriesProgressText(progress))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .padding(.top, 2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var eyebrow: String {
    let count = series.volumes.count == 1 ? "1 volume" : "\(series.volumes.count) volumes"
    // Marked as the web marks it, going by where the catalog lists the series.
    return [
      series.category == .unknown ? nil : series.category.title, count, series.library,
      series.isPrivate ? "Private" : nil,
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
  }

  private func seriesProgressText(_ progress: SeriesProgress) -> String {
    let percent = Int((progress.fraction * 100).rounded())
    return [progress.summary, "\(percent)%"].compactMap { $0 }.joined(separator: " · ")
  }

  /// Where "Continue" picks up: the volume being read, else the first one not
  /// yet finished after the last finished one, else the beginning again.
  private var nextToRead: (publication: Publication, title: String, fromStart: Bool)? {
    let readings = series.volumes.compactMap { volume in
      model.position(for: volume).map { (volume, $0) }
    }
    if let (volume, position) = readings.filter({ !$0.1.completed })
      .max(by: { $0.1.updatedAt < $1.1.updatedAt })
    {
      let name = volume.volume.map { "Volume \($0)" } ?? volume.title
      return (volume, "Continue \(name), page \(position.page)", false)
    }
    let lastCompleted = series.volumes.lastIndex { model.progress(for: $0).isCompleted }
    let candidates = series.volumes.indices.filter { index in
      index > (lastCompleted ?? -1) && !model.progress(for: series.volumes[index]).isCompleted
    }
    if let index = candidates.first {
      let volume = series.volumes[index]
      if lastCompleted == nil { return (volume, "Start Reading", true) }
      let name = volume.volume.map { "Volume \($0)" } ?? volume.title
      return (volume, "Read \(name)", true)
    }
    guard let first = series.volumes.first else { return nil }
    return (first, "Read Again", true)
  }

  /// Continue on a line of its own, and under it every other action, alike
  /// in width. Where their labels no longer fit on one line, only their
  /// icons show, each still named in its tooltip.
  private var actions: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let next = nextToRead {
        Button {
          Task { await model.beginReading(next.publication, fromStart: next.fromStart) }
        } label: {
          Label(next.title, systemImage: "play.fill")
        }
        .buttonStyle(.accent)
      }

      ViewThatFits(in: .horizontal) {
        secondaryActions
        secondaryActions.labelStyle(.iconOnly)
      }
    }
  }

  private var secondaryActions: some View {
    EqualWidthRow(spacing: 10) {
      downloadAllButton

      if let webURL {
        Button {
          openURL(webURL)
        } label: {
          Label("Open in Browser", systemImage: "safari")
        }
        .help("Open this series in Nineveh's web client")
      }

      if series.serverID != nil, model.connection != nil {
        Button {
          Task { await model.refreshMetadata(for: series) }
        } label: {
          Label(
            model.isRefreshingMetadata ? "Refreshing…" : "Refresh Metadata",
            systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshingMetadata)
        .help("Fetch this series' details and cover from Nineveh again")
      }

      if let serverID = series.serverID, model.isAdministrator {
        let moving = model.seriesBeingMoved.contains(serverID)
        Button {
          Task { await model.setPrivate(!series.isPrivate, for: series) }
        } label: {
          Label(
            moving ? "Moving…" : series.isPrivate ? "Move to Library" : "Make Private",
            systemImage: series.isPrivate ? "lock.open" : "lock")
        }
        .disabled(moving)
        .help(
          series.isPrivate
            ? "List this series in its library again"
            : "List this series only in the Private Collection, out of its library")
      }
    }
    .buttonStyle(.chrome(fillsWidth: true))
  }

  @ViewBuilder
  private var downloadAllButton: some View {
    let records = series.volumes.compactMap(model.downloadRecord(for:))
    let pending = records.filter { $0.state == .queued || $0.state == .downloading }
    let downloaded = series.volumes.filter(model.isDownloaded)
    let needsUpdate = series.volumes.contains(where: model.updateAvailable(for:))
    if !pending.isEmpty {
      Label("Downloading \(pending.count)…", systemImage: "arrow.down.circle")
        .foregroundStyle(.secondary)
        .help("Downloading \(pending.count) of this series' volumes")
    } else if downloaded.count == series.volumes.count, !needsUpdate {
      Label(
        series.volumes.count == 1 ? "Downloaded" : "All Downloaded",
        systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
      .help("Every volume in this series is on this \(Device.name)")
    } else if model.connection != nil {
      Button {
        Task { await model.downloadSeries(series) }
      } label: {
        Label(
          needsUpdate
            ? "Update Downloads" : series.volumes.count == 1 ? "Download" : "Download All",
          systemImage: needsUpdate ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
      }
      .help(
        needsUpdate
          ? "Download the newer copies Nineveh has of this series' volumes"
          : "Download every volume in this series to read offline")
    }
  }

  private var webURL: URL? {
    guard let serverID = series.serverID, let base = model.connection?.baseURL else { return nil }
    return base.appending(path: "series").appending(path: serverID)
  }

  // MARK: About

  private func about(_ metadata: SeriesMetadata) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      if let description = metadata.description, !description.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text(description)
            .lineLimit(showsFullDescription ? nil : 5)
            .textSelection(.enabled)
            .frame(maxWidth: 760, alignment: .leading)
          if description.count > 360 {
            Button(showsFullDescription ? "Show Less" : "Show More") {
              withAnimation(.easeOut(duration: 0.2)) { showsFullDescription.toggle() }
            }
            .linkButtonStyle()
          }
        }
      }

      let facts = facts(metadata)
      if !facts.isEmpty {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
          ForEach(facts, id: \.label) { fact in
            GridRow {
              Text(fact.label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
              Text(fact.value)
                .textSelection(.enabled)
            }
          }
        }
        .font(.callout)
      }

      if !metadata.tags.isEmpty {
        FlowLayout(spacing: 6) {
          ForEach(metadata.tags, id: \.self) { tag in
            Text(tag)
              .font(.caption)
              .padding(.horizontal, 9)
              .padding(.vertical, 4)
              .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
          }
        }
        .frame(maxWidth: 760, alignment: .leading)
      }

      attribution(metadata)
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
  }

  private func facts(_ metadata: SeriesMetadata) -> [(label: String, value: String)] {
    var facts: [(label: String, value: String)] = []
    if !metadata.authors.isEmpty {
      facts.append(("Written by", metadata.authors.joined(separator: ", ")))
    }
    if !metadata.artists.isEmpty {
      facts.append(("Art by", metadata.artists.joined(separator: ", ")))
    }
    if !metadata.publishers.isEmpty {
      facts.append(("Publishers", metadata.publishers.joined(separator: ", ")))
    }
    if let published = metadata.publishedRange {
      facts.append(("Published", published))
    }
    return facts
  }

  private func attribution(_ metadata: SeriesMetadata) -> some View {
    var text = AttributedString("Metadata from ")
    var provider = AttributedString(metadata.providerName)
    provider.link = metadata.sourceURL
    text += provider
    text += AttributedString(", licensed ")
    var license = AttributedString(metadata.license)
    if metadata.license == "CC BY-NC-SA 4.0" {
      license.link = URL(string: "https://creativecommons.org/licenses/by-nc-sa/4.0/")
    }
    text += license
    text += AttributedString(metadata.isEditedLocally ? "; edited locally." : ".")
    return Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  // MARK: Volumes

  private var volumes: some View {
    VStack(alignment: .leading, spacing: 16) {
      SectionHeading(title: "Volumes and Issues", detail: series.library)
      LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
        ForEach(series.volumes) { volume in
          VolumeCard(model: model, publication: volume)
        }
      }
    }
  }
}

/// One volume of a series page, with the web page's actions.
private struct VolumeCard: View {
  @ObservedObject var model: ApplicationModel
  let publication: Publication
  @State private var hovering = false

  var body: some View {
    let progress = model.progress(for: publication)
    HStack(alignment: .top, spacing: 16) {
      CoverImageView(model: model, publication: publication)
        .frame(width: 92, height: 138)
        .overlay(alignment: .topLeading) {
          if model.isDownloaded(publication) {
            DownloadedBadge().padding(5)
          }
        }
        .overlay(alignment: .topTrailing) {
          if progress.isCompleted {
            Image(systemName: "checkmark.circle.fill")
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, .green)
              .padding(5)
              .accessibilityLabel("Completed")
          }
        }

      VStack(alignment: .leading, spacing: 7) {
        Text(heading)
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(ReaderTheme.secondaryText)
          .textCase(.uppercase)
        Text(publication.title)
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(.white)
          .lineLimit(2)

        VStack(alignment: .leading, spacing: 4) {
          ReadingProgressBar(fraction: progress.fraction)
          HStack {
            Text(progress.label)
            Spacer()
            Text("\(progress.percent)%")
          }
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        .padding(.top, 2)

        Spacer(minLength: 4)

        HStack(spacing: 8) {
          ActionRow(spacing: 8) {
            if let page = progress.resumePage {
              // The progress line above already names the page.
              Button("Resume") {
                Task { await model.beginReading(publication) }
              }
              .buttonStyle(.accent)
              .help("Resume at page \(page)")
              .fixedSize()
              Button("Start over") {
                Task { await model.beginReading(publication, fromStart: true) }
              }
              .buttonStyle(.chrome)
              .fixedSize()
            } else {
              Button("Read from start") {
                Task { await model.beginReading(publication, fromStart: true) }
              }
              .buttonStyle(.accent)
            }
          }
          Spacer(minLength: 0)
          Menu {
            PublicationActions(model: model, publication: publication)
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("More actions")
          .accessibilityLabel("More actions for \(publication.title)")
        }
        .controlSize(.small)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .frame(minHeight: 166)
    .background(
      .white.opacity(hovering ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 4)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .strokeBorder(ReaderTheme.accent.opacity(hovering ? 0.8 : 0), lineWidth: 2)
    )
    .animation(.easeOut(duration: 0.12), value: hovering)
    .contentShape(RoundedRectangle(cornerRadius: 4))
    .onTapGesture {
      Task { await model.beginReading(publication, fromStart: progress.isCompleted) }
    }
    .onHover { hovering = $0 }
    .contextMenu { PublicationActions(model: model, publication: publication) }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
  }

  private var heading: String {
    let pages = publication.pageCount.map { "\($0) pages" }
    let volume = publication.volume.map { "Volume \($0)" }
    return [volume, pages].compactMap { $0 }.joined(separator: " · ")
  }
}

// MARK: - Publication

struct PublicationDetailView: View {
  @ObservedObject var model: ApplicationModel
  let publication: Publication
  @State private var pageWidth: CGFloat = 0
  @Environment(\.isNarrow) private var isNarrow
  @Environment(\.contentPadding) private var contentPadding

  var body: some View {
    let series = model.series(containing: publication)
    let progress = model.progress(for: publication)
    let hero = heroLayout(
      narrow: isNarrow || stacksHero(pageWidth: pageWidth, padding: contentPadding))
    ScrollView {
      VStack(alignment: .leading, spacing: 30) {
        hero {
          CoverImageView(model: model, publication: publication)
            .frame(width: 220, height: 330)

          VStack(alignment: .leading, spacing: 14) {
            if let series, publication.series != nil {
              NavigationLink(value: LibraryRoute.series(series.key)) {
                HStack(spacing: 3) {
                  Text(model.displayTitle(for: series))
                  Image(systemName: "chevron.right").imageScale(.small)
                }
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
              }
              .linkButtonStyle()
            }
            Text(publication.title)
              .font(.system(size: 32, weight: .heavy))
              .textSelection(.enabled)
            let creators = model.creators(of: publication)
            if !creators.isEmpty {
              Text(creators.joined(separator: ", "))
                .font(.title3)
                .foregroundStyle(.secondary)
            }
            Text(facts)
              .font(.subheadline)
              .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
              ReadingProgressBar(fraction: progress.fraction)
                .frame(maxWidth: 360)
              Text("\(progress.label) · \(progress.percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            actionButtons(progress)
              .padding(.top, 4)

            if let summary = publication.summary ?? publication.subtitle {
              Text(summary)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.top, 6)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let series, series.volumes.count > 1 {
          VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "More in This Series", detail: model.displayTitle(for: series))
            ScrollView(.horizontal) {
              LazyHStack(alignment: .top, spacing: 18) {
                ForEach(series.volumes) { volume in
                  NavigationLink(value: LibraryRoute.publication(volume)) {
                    PublicationCard(model: model, publication: volume)
                      .opacity(volume.id == publication.id ? 0.5 : 1)
                  }
                  .buttonStyle(.plain)
                  .disabled(volume.id == publication.id)
                  .frame(width: 130)
                  .fixedSize(horizontal: false, vertical: true)
                  .contextMenu { PublicationActions(model: model, publication: volume) }
                }
              }
              .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .shelfBleed()
          }
        }
      }
      .padding(contentPadding)
    }
    // Measured for the hero, which stacks on a narrow page.
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
    .navigationTitle(publication.title)
  }

  private var facts: String {
    var parts: [String] = []
    if let volume = publication.volume { parts.append("Volume \(volume)") }
    if let pages = publication.pageCount { parts.append("\(pages) pages") }
    if let size = publication.fileSize {
      parts.append(size.formatted(.byteCount(style: .file)))
    }
    if publication.category != .unknown { parts.append(publication.category.title) }
    if let library = publication.library { parts.append(library) }
    return parts.joined(separator: " · ")
  }

  private func actionButtons(_ progress: VolumeProgress) -> some View {
    ActionRow {
      if let page = progress.resumePage {
        Button {
          Task { await model.beginReading(publication) }
        } label: {
          Label("Resume at Page \(page)", systemImage: "play.fill")
        }
        .buttonStyle(.accent)
        Button("Read from Start") {
          Task { await model.beginReading(publication, fromStart: true) }
        }
      } else {
        Button {
          Task { await model.beginReading(publication, fromStart: true) }
        } label: {
          Label(progress.isCompleted ? "Read Again" : "Read", systemImage: "play.fill")
        }
        .buttonStyle(.accent)
      }

      downloadButton

      Menu {
        PublicationActions(model: model, publication: publication, includesDetails: false)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("More actions")
    }
    .buttonStyle(.chrome)
  }

  @ViewBuilder
  private var downloadButton: some View {
    if let record = model.downloadRecord(for: publication),
      record.state == .queued || record.state == .downloading
    {
      Label(
        record.state == .queued ? "Queued" : "Downloading",
        systemImage: record.state == .queued ? "clock" : "arrow.down.circle"
      )
      .foregroundStyle(.secondary)
    } else if model.updateAvailable(for: publication) {
      Button {
        Task { await model.download(publication) }
      } label: {
        Label("Update", systemImage: "arrow.triangle.2.circlepath")
      }
    } else if model.isDownloaded(publication) {
      Label("Downloaded", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    } else if model.connection != nil {
      Button {
        Task { await model.download(publication) }
      } label: {
        Label("Download", systemImage: "arrow.down.circle")
      }
    }
  }
}

// MARK: - Layout

/// A detail page's cover beside its text, or in a narrow window, above it.
private func heroLayout(narrow: Bool) -> AnyLayout {
  narrow
    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
    : AnyLayout(HStackLayout(alignment: .top, spacing: 32))
}

/// Whether a detail page this wide puts its cover above its text. Beside the
/// cover, the text needs room for its title and a couple of buttons a line;
/// a Mac window is never narrow, but its page can be, with the sidebar open.
private func stacksHero(pageWidth: CGFloat, padding: CGFloat) -> Bool {
  pageWidth > 0 && pageWidth - 2 * padding < 220 + 32 + 340
}

/// Lays views out side by side, each as wide as the widest of them.
struct EqualWidthRow: Layout {
  var spacing: CGFloat = 10

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let width = sizes.map(\.width).max() ?? 0
    return CGSize(
      width: width * CGFloat(sizes.count) + spacing * CGFloat(max(sizes.count - 1, 0)),
      height: sizes.map(\.height).max() ?? 0)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let width = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    for (offset, subview) in subviews.enumerated() {
      subview.place(
        at: CGPoint(
          x: bounds.minX + (width + spacing) * CGFloat(offset) + width / 2, y: bounds.midY),
        anchor: .center,
        proposal: ProposedViewSize(width: width, height: nil))
    }
  }
}

/// Lays views out in rows, wrapping when a row is full, like tags on the web.
/// A view wider than a row on its own gets the row's width, so its label
/// wraps rather than running off the page.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(for: subviews, width: proposal.width ?? .infinity)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in rows(for: subviews, width: bounds.width) {
      var x = bounds.minX
      for (index, size) in zip(row.indices, row.sizes) {
        subviews[index].place(
          at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
          proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var sizes: [CGSize] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      var size = subviews[index].sizeThatFits(.unspecified)
      if size.width > width {
        size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
      }
      let proposed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if proposed > width, !current.indices.isEmpty {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
      current.sizes.append(size)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
