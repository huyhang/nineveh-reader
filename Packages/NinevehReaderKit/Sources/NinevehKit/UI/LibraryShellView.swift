import NinevehCore
import SwiftUI

enum LibrarySection: Hashable {
  case home
  case browse
  case library(String)
  case downloads
  case onMyMac
  case settings

  var title: String {
    switch self {
    case .home: "Home"
    case .browse: "All Series"
    case .library(let name): name
    case .downloads: "Downloads"
    case .onMyMac: "On My Mac"
    case .settings: "Settings"
    }
  }

  var icon: String {
    switch self {
    case .home: "house"
    case .browse: "square.grid.2x2"
    case .library: "books.vertical"
    case .downloads: "arrow.down.circle"
    case .onMyMac: "macbook"
    case .settings: "gearshape"
    }
  }

  /// The library a search from this section looks through.
  var library: String? {
    if case .library(let name) = self { return name }
    return nil
  }

  var isSearchable: Bool {
    switch self {
    case .home, .browse, .library: true
    case .downloads, .onMyMac, .settings: false
    }
  }
}

struct LibraryShellView: View {
  @ObservedObject var model: ApplicationModel
  @State private var selection: LibrarySection?
  @State private var search = ""
  private let initiallyShowsOrganizedBrowse: Bool

  init(model: ApplicationModel, initiallyShowsOrganizedBrowse: Bool = false) {
    self.model = model
    self.initiallyShowsOrganizedBrowse = initiallyShowsOrganizedBrowse
    _selection = State(initialValue: initiallyShowsOrganizedBrowse ? .browse : .home)
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        Section("Nineveh") {
          sidebarRow(.home)
          sidebarRow(.browse, badge: model.seriesGroups.count)
        }
        if !model.libraries.isEmpty {
          Section("Libraries") {
            ForEach(model.libraries) { library in
              sidebarRow(.library(library.name), badge: model.seriesGroups(in: library.name).count)
            }
          }
        }
        Section("Offline") {
          sidebarRow(
            .downloads, badge: model.shownDownloads.filter { $0.state != .completed }.count)
          sidebarRow(.onMyMac, badge: model.localBooks.count)
        }
        Section {
          sidebarRow(.settings)
        }
      }
      .navigationTitle("Nineveh")
      .navigationSplitViewColumnWidth(min: 190, ideal: 220)
    } detail: {
      NavigationStack(path: $model.libraryPath) {
        ZStack {
          QuietBackground()
          destination
        }
        .navigationDestination(for: LibraryRoute.self) { route in
          ZStack {
            QuietBackground()
            routeView(route)
          }
        }
      }
    }
    .searchable(text: $search, placement: .toolbar, prompt: "Search titles, alternate titles, or creators")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button("Refresh Library") {
            Task { await model.refresh() }
          }
          .disabled(model.isRefreshing)
          Button("Refresh Metadata") {
            Task { await model.refreshMetadata() }
          }
          .disabled(model.isRefreshingMetadata)
        } label: {
          if model.isRefreshing || model.isRefreshingMetadata {
            ProgressView().controlSize(.small)
          } else {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
        } primaryAction: {
          Task { await model.refresh() }
        }
        .disabled(model.connection == nil)
        .help("Refresh the library, or open the menu to refresh series metadata")
      }
    }
    .onChange(of: selection) { _, _ in
      // Each section starts at its own top level.
      model.libraryPath = []
    }
    .onChange(of: search) { _, value in
      if !value.isEmpty { model.libraryPath = [] }
    }
    .refreshable { await model.refresh() }
  }

  @ViewBuilder
  private var destination: some View {
    let section = selection ?? .home
    if !search.isEmpty, section.isSearchable {
      SearchResultsView(model: model, query: search, library: section.library)
    } else {
      switch section {
      case .home:
        HomeView(model: model)
      case .browse:
        BrowseView(
          model: model, library: nil,
          initialArrangement: initiallyShowsOrganizedBrowse ? .authors : .series)
      case .library(let name):
        BrowseView(model: model, library: name).id(name)
      case .downloads:
        DownloadsView(model: model)
      case .onMyMac:
        LocalLibraryView(model: model)
      case .settings:
        SettingsView(model: model)
      }
    }
  }

  @ViewBuilder
  private func routeView(_ route: LibraryRoute) -> some View {
    switch route {
    case .series(let key):
      SeriesDetailView(model: model, key: key)
    case .publication(let publication):
      PublicationDetailView(model: model, publication: publication)
    case .collection(let collection):
      PublicationGridView(
        model: model,
        title: collection.title,
        publications: collection.publications
      )
    }
  }

  private func sidebarRow(_ section: LibrarySection, badge: Int = 0) -> some View {
    Label {
      HStack {
        Text(section.title).lineLimit(1)
        Spacer()
        if badge > 0 {
          Text(badge, format: .number)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    } icon: {
      Image(systemName: section.icon)
    }
    .tag(section)
  }
}

/// Refreshing from the menu bar.
public struct LibraryCommands: Commands {
  @ObservedObject var model: ApplicationModel

  public init(model: ApplicationModel) {
    self.model = model
  }

  public var body: some Commands {
    CommandGroup(after: .sidebar) {
      Divider()
      Button("Refresh Library") {
        Task { await model.refresh() }
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(model.isRefreshing || model.connection == nil)
      Button("Refresh Metadata") {
        Task { await model.refreshMetadata() }
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(model.isRefreshingMetadata || model.connection == nil)
    }
  }
}
