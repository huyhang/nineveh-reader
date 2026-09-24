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

  /// The icon filled in, where there is a filled one.
  var selectedIcon: String {
    if case .onMyMac = self { return icon }
    return "\(icon).fill"
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
  @State private var selection: LibrarySection
  @State private var search = ""
  @State private var sidebarShown = true
  private let initiallyShowsOrganizedBrowse: Bool

  init(model: ApplicationModel, initiallyShowsOrganizedBrowse: Bool = false) {
    self.model = model
    self.initiallyShowsOrganizedBrowse = initiallyShowsOrganizedBrowse
    _selection = State(initialValue: initiallyShowsOrganizedBrowse ? .browse : .home)
  }

  var body: some View {
    HStack(spacing: 0) {
        if sidebarShown {
          LibrarySidebar(model: model, selection: $selection)
            .transition(.move(edge: .leading))
        }
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
            // Going back is the top bar's.
            .navigationBarBackButtonHidden()
          }
        }
        .clipped()
    }
    .overlay(alignment: .top) {
      Rectangle().fill(.black.opacity(0.35)).frame(height: 1)
    }
    // The window's toolbar is the top bar, drawn over the same charcoal as
    // the sidebar, with the window's buttons beside it as in Plex.
    .background(ReaderTheme.chrome, ignoresSafeAreaEdges: .all)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        TopBarLeading(
          model: model, search: $search, selection: $selection, sidebarShown: $sidebarShown)
      }
      .withoutGlass()
      if #available(macOS 26, iOS 26, *) {
        ToolbarSpacer(.flexible)
      }
      ToolbarItem(placement: .primaryAction) {
        TopBarTrailing(model: model, selection: $selection)
      }
      .withoutGlass()
    }
    .toolbar(removing: .title)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .onChange(of: selection) { _, _ in
      // Each section starts at its own top level.
      model.libraryPath = []
    }
    .onChange(of: search) { _, value in
      guard !value.isEmpty else { return }
      model.libraryPath = []
      // A search from a page that can't show one looks through everything.
      if !selection.isSearchable { selection = .browse }
    }
    .refreshable { await model.refresh() }
  }

  @ViewBuilder
  private var destination: some View {
    if !search.isEmpty, selection.isSearchable {
      SearchResultsView(model: model, query: search, library: selection.library)
    } else {
      switch selection {
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
}

/// The start of the top bar: the sidebar and back buttons, the wordmark,
/// and search.
private struct TopBarLeading: View {
  @ObservedObject var model: ApplicationModel
  @Binding var search: String
  @Binding var selection: LibrarySection
  @Binding var sidebarShown: Bool
  @FocusState private var searchFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Button {
        withAnimation(.easeOut(duration: 0.2)) { sidebarShown.toggle() }
      } label: {
        Image(systemName: "line.3.horizontal")
      }
      .keyboardShortcut("s", modifiers: [.command, .control])
      .help(sidebarShown ? "Hide Sidebar" : "Show Sidebar")

      Button {
        model.libraryPath.removeLast()
      } label: {
        Image(systemName: "chevron.left")
      }
      .keyboardShortcut("[", modifiers: .command)
      .disabled(model.libraryPath.isEmpty)
      .help("Back")

      Button {
        search = ""
        selection = .home
      } label: {
        Wordmark()
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .help("Home")

      searchField
        .frame(width: 400)
    }
    .buttonStyle(.chromeIcon(size: 32))
    .padding(.leading, 6)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(ReaderTheme.secondaryText)
      TextField("Search", text: $search, prompt: Text("Search").foregroundStyle(ReaderTheme.tertiaryText))
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .focused($searchFocused)
        .onExitCommand { search = "" }
      if !search.isEmpty {
        Button {
          search = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(ReaderTheme.secondaryText)
        .accessibilityLabel("Clear Search")
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 34)
    .background(
      RoundedRectangle(cornerRadius: 17)
        .fill(searchFocused ? Color.white.opacity(0.14) : ReaderTheme.raised)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 17)
        .strokeBorder(searchFocused ? ReaderTheme.accent.opacity(0.7) : .clear, lineWidth: 1)
    )
    .background {
      // ⌘F reaches the field from anywhere in the library.
      Button("Find") { searchFocused = true }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .accessibilityHidden(true)
    }
    .help("Search titles, alternate titles, or creators")
  }
}

/// The end of the top bar: refreshing and settings.
private struct TopBarTrailing: View {
  @ObservedObject var model: ApplicationModel
  @Binding var selection: LibrarySection

  var body: some View {
    HStack(spacing: 6) {
      refreshButton
      Button {
        selection = .settings
      } label: {
        Image(systemName: "gearshape")
      }
      .help("Settings")
    }
    .buttonStyle(.chromeIcon(size: 32))
  }

  private var refreshButton: some View {
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
      Group {
        if model.isRefreshing || model.isRefreshingMetadata {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 15, weight: .semibold))
        }
      }
      .foregroundStyle(.white.opacity(0.8))
      .frame(width: 32, height: 32)
      .contentShape(Circle())
    } primaryAction: {
      Task { await model.refresh() }
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(model.connection == nil)
    .help("Refresh the library, or hold for series metadata")
    .accessibilityLabel("Refresh")
  }
}

/// "NINEVEH" in heavy capitals, its V in gold as Plex's X is.
struct Wordmark: View {
  var size: CGFloat = 19

  var body: some View {
    (Text("NINE") + Text("V").foregroundStyle(ReaderTheme.accent) + Text("EH"))
      .font(.system(size: size, weight: .black))
      .tracking(1.5)
      .foregroundStyle(.white)
      .accessibilityLabel("Nineveh")
  }
}

extension ToolbarContent {
  /// Leaves an item on the bar's own charcoal, without the glass that macOS
  /// puts behind toolbar items.
  @ToolbarContentBuilder
  func withoutGlass() -> some ToolbarContent {
    if #available(macOS 26, iOS 26, *) {
      sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
  }
}

/// A flat, dark list of places, the chosen one lit and marked in gold.
private struct LibrarySidebar: View {
  @ObservedObject var model: ApplicationModel
  @Binding var selection: LibrarySection

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          row(.home)
          row(.browse, badge: model.seriesGroups.count)
          if !model.libraries.isEmpty {
            heading("Libraries")
            ForEach(model.libraries) { library in
              row(.library(library.name), badge: model.seriesGroups(in: library.name).count)
            }
          }
          heading("Offline")
          row(.downloads, badge: model.shownDownloads.filter { $0.state != .completed }.count)
          row(.onMyMac, badge: model.localBooks.count)
        }
        .padding(.vertical, 12)
      }
      .scrollIndicators(.never)
      Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
      row(.settings).padding(.vertical, 8)
    }
    .frame(width: ReaderTheme.sidebarWidth)
    .background(ReaderTheme.chrome)
  }

  private func heading(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.system(size: 11, weight: .bold))
      .tracking(0.8)
      .foregroundStyle(ReaderTheme.tertiaryText)
      .padding(.leading, 22)
      .padding(.top, 20)
      .padding(.bottom, 6)
  }

  private func row(_ section: LibrarySection, badge: Int = 0) -> some View {
    SidebarRow(section: section, badge: badge, isSelected: selection == section) {
      selection = section
    }
  }
}

private struct SidebarRow: View {
  let section: LibrarySection
  let badge: Int
  let isSelected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: isSelected ? section.selectedIcon : section.icon)
          .font(.system(size: 16, weight: .medium))
          .frame(width: 22)
          .foregroundStyle(isSelected ? ReaderTheme.accent : .white.opacity(0.85))
        Text(section.title)
          .font(.system(size: 14, weight: isSelected ? .bold : .medium))
          .lineLimit(1)
        Spacer(minLength: 4)
        if badge > 0 {
          Text(badge, format: .number)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(ReaderTheme.tertiaryText)
        }
      }
      .foregroundStyle(isSelected || hovering ? .white : .white.opacity(0.78))
      .padding(.leading, 22)
      .padding(.trailing, 18)
      .frame(height: 40)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if isSelected {
          Color.white.opacity(0.09)
        } else if hovering {
          Color.white.opacity(0.04)
        }
      }
      .overlay(alignment: .leading) {
        if isSelected {
          Rectangle().fill(ReaderTheme.accent).frame(width: 3)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
