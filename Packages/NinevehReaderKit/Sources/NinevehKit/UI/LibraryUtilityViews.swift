import NinevehCore
import SwiftUI
import UniformTypeIdentifiers

struct DownloadsView: View {
  @ObservedObject var model: ApplicationModel

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 30) {
        Text("Downloads").pageTitleStyle()
        ForEach(groupedDownloads, id: \.name) { group in
          VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
              title: group.name,
              detail:
                "\(group.records.filter { $0.state == .completed }.count) of \(group.records.count)"
            )
            VStack(spacing: 1) {
              ForEach(group.records) { record in
                DownloadRow(
                  record: record,
                  retry: { Task { await model.retryDownload(record) } },
                  reveal: revealAction(for: record),
                  remove: { Task { await model.removeDownload(record) } }
                )
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
          }
        }
      }
      .padding(ReaderTheme.contentPadding)
    }
    .overlay {
      if model.shownDownloads.isEmpty {
        ContentUnavailableView(
          "No Downloads",
          systemImage: "arrow.down.circle",
          description: Text("Download a publication or an entire series for offline reading.")
        )
      }
    }
    .navigationTitle("Downloads")
  }

  private var groupedDownloads: [(name: String, records: [DownloadRecord])] {
    Dictionary(grouping: model.shownDownloads) { $0.seriesTitle ?? "Individual Publications" }
      .map { (name: $0.key, records: $0.value) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Opens a Finder window on the downloads folder with the file selected.
  private func revealAction(for record: DownloadRecord) -> (() -> Void)? {
    #if os(macOS)
      guard record.state == .completed else { return nil }
      return {
        if let url = model.downloadedFileURL(for: record) {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
          model.alertMessage = "“\(record.title)” is no longer on this Mac. Download it again."
        }
      }
    #else
      return nil
    #endif
  }
}

private struct DownloadRow: View {
  let record: DownloadRecord
  let retry: () -> Void
  let reveal: (() -> Void)?
  let remove: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(iconColor)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 4) {
        Text(record.title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
        switch record.state {
        case .queued:
          Text("Queued").foregroundStyle(.secondary)
        case .downloading:
          ReadingProgressBar(fraction: record.progress, track: .white.opacity(0.15))
            .frame(maxWidth: 220)
        case .completed:
          Text(record.byteCount, format: .byteCount(style: .file))
            .foregroundStyle(.secondary)
        case .failed:
          Text(record.errorMessage ?? "Download failed")
            .foregroundStyle(.red)
        }
      }
      Spacer()
      if record.state == .failed {
        Button("Retry", action: retry).buttonStyle(.accent)
      }
      if let reveal {
        Button(action: reveal) {
          Image(systemName: "folder")
        }
        .buttonStyle(.chromeIcon)
        .help("Show in Finder")
        .accessibilityLabel("Show \(record.title) in Finder")
      }
      Button(role: .destructive, action: remove) {
        Image(systemName: "trash")
      }
      .buttonStyle(.chromeIcon)
      .accessibilityLabel("Remove \(record.title)")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.white.opacity(hovering ? 0.08 : 0.045))
    .onHover { hovering = $0 }
  }

  private var icon: String {
    switch record.state {
    case .queued: "clock"
    case .downloading: "arrow.down.circle"
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }

  private var iconColor: Color {
    switch record.state {
    case .completed: ReaderTheme.accent
    case .failed: .red
    default: ReaderTheme.secondaryText
    }
  }
}

struct LocalLibraryView: View {
  @ObservedObject var model: ApplicationModel
  @State private var showingImporter = false
  @State private var showingExternalPicker = false

  private let columns = [
    GridItem(.adaptive(minimum: 145, maximum: 190), spacing: ReaderTheme.cardSpacing)
  ]
  private let cbzType = UTType(filenameExtension: "cbz") ?? .zip

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text("On My Mac").pageTitleStyle()
            Text("Imported books and files kept in their original location.")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(ReaderTheme.secondaryText)
          }
          Spacer()
          Button("Open File…") { showingExternalPicker = true }
            .buttonStyle(.chrome)
          Button("Import…") { showingImporter = true }
            .buttonStyle(.accent)
        }

        if model.localBooks.isEmpty {
          ContentUnavailableView(
            "Add a CBZ",
            systemImage: "square.and.arrow.down",
            description: Text("Import a copy or open a file in place.")
          )
          .frame(maxWidth: .infinity, minHeight: 300)
          .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
        } else {
          ForEach(LocalBookKind.allCases, id: \.rawValue) { kind in
            let books = model.localBooks.filter { $0.kind == kind }
            if !books.isEmpty {
              SectionHeading(
                title: kind == .imported ? "Imported" : "External Files", detail: "On My Mac")
              LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                ForEach(books) { book in
                  LocalBookCard(model: model, book: book)
                }
              }
            }
          }
        }
      }
      .padding(ReaderTheme.contentPadding)
    }
    .navigationTitle("On My Mac")
    .fileImporter(
      isPresented: $showingImporter,
      allowedContentTypes: [cbzType],
      allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result {
        Task { await model.addLocalFiles(urls, kind: .imported) }
      }
    }
    .fileImporter(
      isPresented: $showingExternalPicker,
      allowedContentTypes: [cbzType],
      allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result {
        Task { await model.addLocalFiles(urls, kind: .external) }
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      Task { await model.addLocalFiles(urls, kind: .imported) }
      return true
    }
  }
}

private struct LocalBookCard: View {
  @ObservedObject var model: ApplicationModel
  let book: LocalBook
  @State private var coverData: Data?
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        Task { await model.beginReading(book) }
      } label: {
        ZStack {
          RoundedRectangle(cornerRadius: ReaderTheme.coverRadius)
            .fill(.quaternary)
          if let coverData, let image = LocalPlatformImage(data: coverData) {
            localPlatformImage(image).resizable().scaledToFill()
          } else {
            Image(systemName: "book.closed")
              .font(.system(size: 28, weight: .light))
              .foregroundStyle(.tertiary)
          }
        }
        .aspectRatio(ReaderTheme.coverRatio, contentMode: .fit)
        .hoverOutline(hovering)
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .padding(.bottom, 4)
      Text(book.title).cardTitleStyle()
      HStack {
        Label(
          book.kind == .imported ? "Imported" : "External",
          systemImage: book.kind == .imported ? "square.and.arrow.down" : "link"
        )
        .cardSubtitleStyle()
        Spacer()
        Menu {
          LocalBookActions(model: model, book: book)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
      }
    }
    .contextMenu { LocalBookActions(model: model, book: book) }
    .task(id: book.id) { coverData = await model.localCoverData(for: book) }
  }
}

private struct LocalBookActions: View {
  @ObservedObject var model: ApplicationModel
  let book: LocalBook

  var body: some View {
    Button {
      Task { await model.beginReading(book) }
    } label: {
      Label("Read", systemImage: "book.pages")
    }
    Divider()
    // An imported copy is the app's own; an external file stays where it is.
    Button(role: .destructive) {
      Task { await model.removeLocalBook(book) }
    } label: {
      Label("Remove from On My Mac", systemImage: "trash")
    }
    .help(
      book.kind == .imported
        ? "Delete the imported copy. The original file is left alone."
        : "Forget this file. It stays where it is on your Mac.")
  }
}

struct SettingsView: View {
  @ObservedObject var model: ApplicationModel

  var body: some View {
    Form {
      Section("Nineveh Account") {
        if model.connection != nil {
          LabeledContent("Server", value: model.connection?.baseURL.absoluteString ?? "—")
          LabeledContent("Username", value: model.connection?.username ?? "—")
          LabeledContent("Series metadata") {
            Button(model.isRefreshingMetadata ? "Refreshing…" : "Refresh Metadata") {
              Task { await model.refreshMetadata() }
            }
            .disabled(model.isRefreshingMetadata)
            .help("Fetch every series' details and cover from Nineveh again")
          }
          Button("Sign Out", role: .destructive) {
            Task { await model.signOut() }
          }
        } else {
          Text("Not connected")
            .foregroundStyle(.secondary)
          Button("Connect to Nineveh") {
            model.showSignIn()
          }
        }
      }
      if !model.allLibraries.isEmpty {
        Section {
          ForEach(model.allLibraries) { library in
            Toggle(isOn: shown(library.name)) {
              Text(library.name)
              if let count = library.publicationCount {
                Text(count == 1 ? "1 publication" : "\(count.formatted()) publications")
              }
            }
          }
        } header: {
          Text("Libraries")
        } footer: {
          Text(
            "A library that is turned off leaves the sidebar, Home, Search, and Downloads. Its downloads stay on this Mac."
          )
          .foregroundStyle(.secondary)
        }
      }
      Section("Connection Security") {
        Label("HTTPS is required for remote servers", systemImage: "lock.shield")
        Label("HTTP is permitted only for localhost development", systemImage: "desktopcomputer")
      }
      Section("About") {
        LabeledContent("Version", value: "1.0")
        Text(
          "Nineveh Reader stores credentials in Keychain and keeps reproducible downloads out of backups."
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .navigationTitle("Settings")
    .padding(.horizontal, ReaderTheme.contentPadding)
  }

  private func shown(_ library: String) -> Binding<Bool> {
    Binding(
      get: { !model.hiddenLibraries.contains(library) },
      set: { model.setLibrary(library, shown: $0) }
    )
  }
}

extension LocalBookKind {
  fileprivate static var allCases: [LocalBookKind] { [.imported, .external] }
}

#if canImport(AppKit)
  import AppKit
  private typealias LocalPlatformImage = NSImage
  private func localPlatformImage(_ image: LocalPlatformImage) -> Image { Image(nsImage: image) }
#elseif canImport(UIKit)
  import UIKit
  private typealias LocalPlatformImage = UIImage
  private func localPlatformImage(_ image: LocalPlatformImage) -> Image { Image(uiImage: image) }
#endif
