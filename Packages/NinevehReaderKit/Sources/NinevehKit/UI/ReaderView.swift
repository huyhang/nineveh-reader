import ImageIO
import NinevehCore
import SwiftUI

#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

public struct ReaderView: View {
  @StateObject private var model: ReaderSessionModel
  @State private var chromeVisible = true
  @State private var chromeHideTask: Task<Void, Never>?
  @State private var isHoveringChrome = false
  @State private var sliderDraft: Double?
  @State private var zoom: CGFloat = 1
  @State private var zoomAtGestureStart: CGFloat?
  @State private var isFullScreen = false
  @State private var measuredTitleRow: TitleRowMetrics?
  @State private var topBarHeight: CGFloat = 32
  /// The bottom bar with its margin, which a finger-sized bar on an iPad makes
  /// taller than the Mac's.
  @State private var bottomBarHeight: CGFloat = 48
  @State private var scrollPosition = ScrollPosition(idType: Int.self)
  @State private var scrollOffset: CGFloat = 0
  /// The page a continuous view is still being scrolled to; until it arrives,
  /// the offset says nothing about where the reader is.
  @State private var pendingScrollPage: Int?
  @State private var stripPositioned = false
  #if os(macOS)
    @State private var scrollMonitor = ScrollTurnMonitor()
  #else
    /// How tall the stage is, for scrolling by a share of the screen.
    @State private var viewportHeight: CGFloat = 800
    @Environment(\.scenePhase) private var scenePhase
  #endif
  @FocusState private var focused: Bool
  @Environment(\.displayScale) private var displayScale
  @Environment(\.isNarrow) private var isNarrow
  private let onClose: () -> Void

  /// How long the controls stay up after the pointer or a tap last asked for them.
  private static let chromeTimeout: Duration = .milliseconds(3200)
  private static let zoomRange: ClosedRange<CGFloat> = 1...5

  public init(destination: ReaderDestination, onClose: @escaping () -> Void) {
    _model = StateObject(wrappedValue: ReaderSessionModel(destination: destination))
    self.onClose = onClose
  }

  public var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color.black.ignoresSafeArea()
        stage(in: proxy.size)
        chrome
      }
    }
    // In a window the reader runs up under the title bar, which its own
    // toolbar shares with the window buttons.
    .ignoresSafeArea(.container, edges: titleRow == nil ? [] : .top)
    #if os(macOS)
      .background(
        ReaderWindowChrome(controlsVisible: chromeVisible, isFullScreen: isFullScreen) { metrics in
          measuredTitleRow = metrics
        })
    #endif
    .preferredColorScheme(.dark)
    // The reader takes focus from the library beneath it so keys turn pages.
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(phases: .down, action: handle)
    .onContinuousHover { phase in
      if case .active = phase { revealChrome() }
    }
    .onAppear {
      focused = true
      revealChrome()
      startScrollMonitor()
    }
    .onDisappear {
      chromeHideTask?.cancel()
      #if os(macOS)
        scrollMonitor.stop()
      #endif
      Task { await model.flush() }
    }
    .task { await model.load() }
    #if os(macOS)
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification))
      { _ in isFullScreen = true }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification))
      { _ in isFullScreen = false }
      .onAppear { isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
    #else
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
      // The status bar stays hidden rather than coming and going with the
      // controls, so the stage, and the continuous strip laid out to it, keep
      // their size. The home indicator does follow the controls.
      .statusBarHidden()
      .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
      .onChange(of: scenePhase) { _, phase in
        // Leaving the screen, the place is saved before iOS suspends the app.
        if phase != .active { flushInBackground(model) }
      }
    #endif
  }

  // MARK: - Stage

  @ViewBuilder
  private func stage(in size: CGSize) -> some View {
    if model.isLoading {
      ProgressView().controlSize(.large).tint(.white)
    } else if let error = model.errorMessage {
      ContentUnavailableView {
        Label("Unable to Open Book", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error)
      } actions: {
        Button("Close", action: close)
      }
      .foregroundStyle(.white)
    } else if model.mode == .scroll {
      continuous(in: size)
    } else if model.isFinished {
      ScrollView {
        endCard
          .frame(maxWidth: .infinity, minHeight: size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    } else {
      paged(in: size)
    }
  }

  private func paged(in size: CGSize) -> some View {
    let visible = model.visiblePages
    let ordered = model.direction == .rightToLeft ? Array(visible.reversed()) : visible
    let loader = pageLoader
    return ScrollView([.horizontal, .vertical]) {
      HStack(spacing: 0) {
        ForEach(Array(ordered.enumerated()), id: \.element) { index, number in
          PageImageView(
            page: number,
            pageCount: model.pageCount,
            aspectRatio: model.layout.aspectRatio(of: number),
            load: loader
          )
          // A pair meets at the gutter, like the book it was printed in.
          .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: ordered.count == 2 ? (index == 0 ? .trailing : .leading) : .center)
        }
      }
      .padding(.top, chromeVisible ? topBarHeight + 8 : 10)
      #if os(macOS)
        .padding(.bottom, chromeVisible ? 58 : 10)
      #else
        .padding(.bottom, chromeVisible ? bottomBarHeight + 4 : 10)
      #endif
      .padding(.horizontal, 10)
      .frame(width: size.width * zoom, height: size.height * zoom)
      .animation(.easeOut(duration: 0.2), value: chromeVisible)
    }
    .scrollDisabled(zoom <= 1)
    .scrollIndicators(zoom > 1 ? .automatic : .hidden)
    .defaultScrollAnchor(.center)
    .contentShape(Rectangle())
    .onTapGesture(coordinateSpace: .local) { location in
      tap(at: location, width: size.width)
    }
    .gesture(swipe, including: zoom <= 1 ? .all : .subviews)
    .simultaneousGesture(magnify)
  }

  private func continuous(in size: CGSize) -> some View {
    let metrics = ContinuousMetrics(
      layout: model.layout, viewport: size, zoom: zoom, spacing: 10, topInset: topBarHeight + 8)
    let window = model.layout.activeWindow(around: model.page)
    // A copy no wider than the screen can show, up to twice the point width;
    // the original follows once the reader settles.
    let renditionWidth =
      model.servesRenditions ? Int(metrics.standardWidth * min(displayScale, 2)) : nil
    let loader = pageLoader
    return ScrollView(.vertical) {
      LazyVStack(spacing: metrics.spacing) {
        ForEach(1...max(model.pageCount, 1), id: \.self) { number in
          let pageSize = metrics.size(of: number)
          ContinuousPageView(
            page: number,
            pageCount: model.pageCount,
            isActive: window.contains(number),
            isCurrent: number == model.page,
            renditionWidth: renditionWidth,
            load: loader
          )
          .frame(width: pageSize.width, height: pageSize.height)
          .id(number)
        }
        endCard
          .frame(maxWidth: .infinity, minHeight: size.height * 0.7)
          .onScrollVisibilityChange(threshold: 0.55) { visible in
            if visible { model.completeReading() }
          }
      }
      .padding(.top, metrics.topInset)
      .frame(maxWidth: .infinity)
    }
    .scrollPosition($scrollPosition)
    .onScrollGeometryChange(for: StripGeometry.self) { geometry in
      StripGeometry(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height)
    } action: { old, new in
      scrollOffset = new.offset
      if let pending = pendingScrollPage {
        let target = metrics.offset(of: pending)
        guard abs(new.offset - target) < 4 else {
          // Asked before the strip was laid out, the scroll fell short; the
          // strip has grown since, so ask again.
          if new.contentHeight != old.contentHeight { scrollPosition.scrollTo(y: target) }
          return
        }
        pendingScrollPage = nil
        stripPositioned = true
      }
      // Until the strip first reaches the reader's page, where it happens to
      // be says nothing about where the reader is.
      guard stripPositioned else { return }
      model.recordScrolledPage(metrics.page(atY: new.offset + size.height / 2))
    }
    .onAppear {
      stripPositioned = false
      scroll(to: model.page, metrics: metrics)
    }
    .onDisappear { stripPositioned = false }
    .onChange(of: model.scrollRequest) { _, request in
      if let request { scroll(to: request.page, metrics: metrics) }
    }
    .onChange(of: zoom) { _, _ in
      scroll(to: model.page, metrics: metrics.rezoomed(zoom))
    }
    .contentShape(Rectangle())
    .onTapGesture { toggleChrome() }
    .simultaneousGesture(magnify)
  }

  private var endCard: some View {
    let next = model.context.next
    var onReadNext: (() -> Void)?
    if let next { onReadNext = { open(next) } }
    var onBackToSeries: (() -> Void)?
    if model.destination.actions.showSeries != nil { onBackToSeries = { backToSeries() } }
    let model = model
    return EndCardView(
      title: model.title,
      savedMessage: model.savedMessage,
      next: next,
      isInSeries: model.context.volumes.count > 1,
      loadCover: model.destination.actions.cover,
      onReadNext: onReadNext,
      onBackToSeries: onBackToSeries,
      onReadAgain: { model.readAgain() }
    )
  }

  private var pageLoader: PageLoader {
    let model = model
    return { page, width in try await model.image(page: page, width: width) }
  }

  // MARK: - Chrome

  @ViewBuilder
  private var chrome: some View {
    if chromeVisible && !model.isLoading {
      VStack(spacing: 0) {
        topBar
        Spacer(minLength: 0)
        if model.errorMessage == nil { bottomBar }
      }
      .transition(.opacity)
    }
  }

  /// The title bar row the reader's toolbar shares with the window buttons,
  /// in a window; in full screen the toolbar has the top to itself.
  private var titleRow: TitleRowMetrics? {
    #if os(macOS)
      isFullScreen ? nil : measuredTitleRow ?? .standard
    #else
      nil
    #endif
  }

  private var topBar: some View {
    let row = titleRow
    return HStack(spacing: 12) {
      leaveButton
      titleBlock
      if isNarrow {
        // A narrow window keeps the volume and folds the rest into a menu.
        if model.context.volumes.count > 1 { volumeMenu }
        readingOptionsMenu
      } else {
        if model.context.volumes.count > 1 { volumeControls }
        modePicker
        directionButton
        fullScreenButton
      }
    }
    .readerBarButtonStyle()
    .controlSize(.regular)
    .padding(.leading, row?.leadingInset ?? 14)
    .padding(.trailing, 14)
    .padding(.vertical, row == nil ? 7 : 3)
    // Centred on the window buttons.
    .frame(minHeight: row?.height ?? 0)
    .clearsWindowControls()
    .background(.ultraThinMaterial)
    .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    .contentShape(Rectangle())
    #if os(macOS)
      // The bar is where the title bar was, so it moves the window as that did.
      .gesture(WindowDragGesture())
    #endif
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topBarHeight = $0 }
    .onHover(perform: hoverChrome)
  }

  private var leaveButton: some View {
    let inSeries = model.destination.actions.showSeries != nil
    return Button {
      if inSeries { backToSeries() } else { close() }
    } label: {
      Label(inSeries ? "Series" : "Close", systemImage: "chevron.backward")
    }
    #if os(iOS)
      .labelStyle(ConditionalIconOnlyLabelStyle(iconOnly: isNarrow))
    #endif
    .help(inSeries ? "Back to the series" : "Close the reader")
  }

  private var titleBlock: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(model.title)
        .font(.headline)
        .lineLimit(1)
        .layoutPriority(1)
      if let subtitle = model.subtitle,
        model.title.range(of: subtitle, options: [.caseInsensitive, .diacriticInsensitive]) == nil
      {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(model.subtitle.map { "\(model.title) — \($0)" } ?? model.title)
  }

  private var modePicker: some View {
    let model = model
    let selection = Binding<ReadingMode>(get: { model.mode }, set: { model.setMode($0) })
    return Picker("Reading Mode", selection: selection) {
      ForEach(ReadingMode.allCases, id: \.self) { mode in
        Label(mode.title, systemImage: mode.systemImage).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelStyle(.iconOnly)
    .labelsHidden()
    .fixedSize()
    .help("Reading mode (1, 2, 3)")
  }

  private var directionButton: some View {
    let symbol = model.direction == .rightToLeft ? "arrow.left" : "arrow.right"
    return Button {
      model.cycleDirection()
    } label: {
      Label(model.directionPreference.shortTitle, systemImage: symbol)
    }
    .labelStyle(.titleAndIcon)
    .fixedSize()
    .help(directionHelp)
  }

  /// The reading mode and direction, in one menu for a narrow window.
  private var readingOptionsMenu: some View {
    let model = model
    let selection = Binding<ReadingMode>(get: { model.mode }, set: { model.setMode($0) })
    let symbol = model.direction == .rightToLeft ? "arrow.left" : "arrow.right"
    return Menu {
      Picker("Reading Mode", selection: selection) {
        ForEach(ReadingMode.allCases, id: \.self) { mode in
          Label(mode.title, systemImage: mode.systemImage).tag(mode)
        }
      }
      Button {
        model.cycleDirection()
      } label: {
        Label("Direction: \(model.directionPreference.shortTitle)", systemImage: symbol)
      }
    } label: {
      Label("Reading Options", systemImage: "ellipsis.circle")
        .labelStyle(.iconOnly)
        #if os(iOS)
          .frame(minWidth: 44, minHeight: 44)
        #endif
    }
    .menuIndicator(.hidden)
    .fixedSize()
    #if os(iOS)
      .tint(.white)
    #endif
  }

  @ViewBuilder
  private var fullScreenButton: some View {
    #if os(macOS)
      let symbol =
        isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
      Button(action: toggleFullScreen) {
        Label(isFullScreen ? "Exit Full Screen" : "Full Screen", systemImage: symbol)
      }
      .labelStyle(.iconOnly)
      .help("Full screen (F)")
    #endif
  }

  private var volumeControls: some View {
    let context = model.context
    return HStack(spacing: 2) {
      Button {
        if let previous = context.previous { open(previous) }
      } label: {
        Image(systemName: "chevron.left")
      }
      .disabled(context.previous == nil)
      .help("Previous volume ([)")
      .accessibilityLabel("Previous volume")

      volumeMenu

      Button {
        if let next = context.next { open(next) }
      } label: {
        Image(systemName: "chevron.right")
      }
      .disabled(context.next == nil)
      .help("Next volume (])")
      .accessibilityLabel("Next volume")
    }
  }

  private var volumeMenu: some View {
    let context = model.context
    let current = context.currentIndex ?? 0
    return Menu {
      ForEach(Array(context.volumes.enumerated()), id: \.element.id) { index, volume in
        Button {
          if index != current { open(volume) }
        } label: {
          if index == current {
            Label(volume.menuTitle, systemImage: "checkmark")
          } else {
            Text(volume.menuTitle)
          }
        }
      }
    } label: {
      Label("\(current + 1) / \(context.volumes.count)", systemImage: "books.vertical")
        .labelStyle(.titleAndIcon)
        .monospacedDigit()
        #if os(iOS)
          .frame(minHeight: 44)
        #endif
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    #if os(iOS)
      .tint(.white)
    #endif
    .help("Volumes in this series")
  }

  private var bottomBar: some View {
    let pageCount = model.pageCount
    let draftPage = sliderDraft.map { Int($0.rounded()) }
    let label = draftPage.map { model.layout.label(for: $0, mode: model.mode) } ?? model.pageLabel
    // A narrow window leaves page turning to taps and swipes, and the sync
    // status to its symbol.
    return HStack(spacing: 12) {
      if !isNarrow { arrowButton(pointingRight: false) }
      Text(model.isFinished ? "Finished" : label)
        .monospacedDigit()
        .font(.callout.weight(.medium))
        .frame(minWidth: isNarrow ? 72 : 92)
      Slider(
        value: Binding(
          get: { sliderDraft ?? Double(model.page) },
          // Rounded here rather than stepped, which would draw a tick per page.
          set: { sliderDraft = $0.rounded() }
        ),
        in: 1...Double(max(pageCount, 2)),
        onEditingChanged: { editing in
          if editing {
            chromeHideTask?.cancel()
          } else {
            if let draftPage { model.go(to: draftPage) }
            sliderDraft = nil
            focused = true
            scheduleChromeHide()
          }
        }
      )
      .disabled(pageCount < 2)
      // The slider runs the way the pages do, so right to left starts at the right.
      .scaleEffect(x: model.direction == .rightToLeft ? -1 : 1, y: 1)
      .frame(minWidth: isNarrow ? 100 : 160, maxWidth: 460)
      .accessibilityLabel("Page")
      .accessibilityValue(label)
      if !isNarrow { arrowButton(pointingRight: true) }
      // A stack, not a group, so the space stays put while there is no status.
      ZStack(alignment: .leading) {
        if let status = model.syncStatus.title {
          Label(status, systemImage: syncSymbol)
            #if os(iOS)
              .labelStyle(ConditionalIconOnlyLabelStyle(iconOnly: isNarrow))
            #endif
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(width: isNarrow ? 22 : 104, alignment: .leading)
    }
    .readerBarButtonStyle()
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    .padding(.horizontal, isNarrow ? 10 : 20)
    .padding(.bottom, 14)
    #if os(iOS)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomBarHeight = $0 }
    #endif
    .onHover(perform: hoverChrome)
  }

  private func arrowButton(pointingRight: Bool) -> some View {
    let step = model.direction.step(forArrowPointingRight: pointingRight)
    return Button {
      arrow(pointingRight: pointingRight)
    } label: {
      Image(systemName: pointingRight ? "chevron.right" : "chevron.left")
        .font(.body.weight(.semibold))
        .frame(width: 22, height: 22)
    }
    .disabled(step > 0 ? !model.canMoveForward : !model.canMoveBackward)
    .accessibilityLabel(step > 0 ? "Next page" : "Previous page")
  }

  private var syncSymbol: String {
    switch model.syncStatus {
    case .saving: "arrow.triangle.2.circlepath"
    case .saved: "checkmark.icloud"
    case .savedLocally: "internaldrive"
    case .idle: "circle"
    }
  }

  private var directionHelp: String {
    let resolved = model.direction.title.lowercased()
    return switch model.directionPreference {
    case .automatic: "Reading direction: automatic, \(resolved) (D)"
    default: "Reading direction: \(resolved) (D)"
    }
  }

  // MARK: - Input

  private func handle(_ press: KeyPress) -> KeyPress.Result {
    if press.modifiers.contains(.command) {
      switch press.characters {
      case "=", "+": setZoom(zoom * 1.25)
      case "-": setZoom(zoom / 1.25)
      case "0": setZoom(1)
      default: return .ignored
      }
      return .handled
    }
    let backward = press.modifiers.contains(.shift)
    switch press.key {
    case .leftArrow: arrow(pointingRight: false)
    case .rightArrow: arrow(pointingRight: true)
    case .downArrow: advance(by: 1, fraction: 0.25)
    case .upArrow: advance(by: -1, fraction: 0.25)
    case .space: advance(by: backward ? -1 : 1, fraction: 0.9)
    case .pageDown: advance(by: 1, fraction: 0.9)
    case .pageUp: advance(by: -1, fraction: 0.9)
    case .home: model.goToStart()
    case .end: model.goToEnd()
    case .escape: escape()
    default:
      switch press.characters.lowercased() {
      case "f": toggleFullScreen()
      case "1": model.setMode(.single)
      case "2": model.setMode(.double)
      case "3": model.setMode(.scroll)
      case "d": model.cycleDirection()
      case "[": if let previous = model.context.previous { open(previous) }
      case "]": if let next = model.context.next { open(next) }
      default: return .ignored
      }
    }
    return .handled
  }

  /// Arrows point at a side of the screen; which way that turns depends on
  /// the reading direction.
  private func arrow(pointingRight: Bool) {
    if model.mode == .scroll {
      let step = model.direction.step(forArrowPointingRight: pointingRight)
      if step > 0, model.page >= model.pageCount {
        model.completeReading()
      } else {
        model.go(to: model.page + step)
      }
    } else {
      model.turn(pointingRight: pointingRight)
    }
  }

  /// Forward or back in reading order: a page turn, or in continuous mode a
  /// `fraction` of the screen.
  private func advance(by step: Int, fraction: CGFloat) {
    guard model.mode == .scroll else {
      model.move(step)
      return
    }
    let viewport = scrollViewportHeight
    withAnimation(.easeOut(duration: 0.18)) {
      scrollPosition.scrollTo(y: max(0, scrollOffset + CGFloat(step) * viewport * fraction))
    }
  }

  private var scrollViewportHeight: CGFloat {
    #if os(macOS)
      NSApp.keyWindow?.contentLayoutRect.height ?? 800
    #else
      viewportHeight
    #endif
  }

  private func tap(at location: CGPoint, width: CGFloat) {
    // The outer thirds turn pages; the middle, or anywhere while zoomed,
    // shows or hides the controls.
    guard zoom <= 1, width > 0 else { return toggleChrome() }
    let position = location.x / width
    if position < 0.3 {
      model.turn(pointingRight: false)
    } else if position > 0.7 {
      model.turn(pointingRight: true)
    } else {
      toggleChrome()
    }
  }

  private var swipe: some Gesture {
    DragGesture(minimumDistance: 24)
      .onEnded { value in
        let horizontal = value.translation.width
        guard abs(horizontal) >= 55, abs(horizontal) > abs(value.translation.height) else { return }
        // Pulling the page left brings in what lies to its right.
        model.turn(pointingRight: horizontal < 0)
      }
  }

  private var magnify: some Gesture {
    MagnifyGesture()
      .onChanged { value in
        let start = zoomAtGestureStart ?? zoom
        zoomAtGestureStart = start
        zoom = min(max(start * value.magnification, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
      }
      .onEnded { _ in
        zoomAtGestureStart = nil
        if zoom < 1.05 { withAnimation(.easeOut(duration: 0.15)) { zoom = 1 } }
      }
  }

  private func setZoom(_ value: CGFloat) {
    withAnimation(.easeOut(duration: 0.15)) {
      zoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }
  }

  private func scroll(to page: Int, metrics: ContinuousMetrics) {
    pendingScrollPage = page
    scrollPosition.scrollTo(y: metrics.offset(of: page))
    // Try once more, then, should the view settle short of the page, as it
    // does at the very end of the volume, stop waiting for it.
    Task {
      try? await Task.sleep(for: .milliseconds(300))
      guard pendingScrollPage == page else { return }
      scrollPosition.scrollTo(y: metrics.offset(of: page))
      try? await Task.sleep(for: .milliseconds(600))
      guard pendingScrollPage == page else { return }
      pendingScrollPage = nil
      stripPositioned = true
    }
  }

  private func startScrollMonitor() {
    #if os(macOS)
      let model = model
      scrollMonitor.start(
        isActive: { model.mode != .scroll && !model.isLoading && zoom <= 1 },
        onTurn: { turn in
          switch turn {
          case .side(let pointingRight): model.turn(pointingRight: pointingRight)
          case .reading(let forward): model.move(forward ? 1 : -1)
          }
        }
      )
    #endif
  }

  // MARK: - Chrome visibility

  private func revealChrome() {
    if !chromeVisible {
      withAnimation(.easeOut(duration: 0.18)) { chromeVisible = true }
    }
    scheduleChromeHide()
  }

  private func toggleChrome() {
    if chromeVisible {
      hideChrome()
    } else {
      revealChrome()
    }
  }

  private func hoverChrome(_ hovering: Bool) {
    isHoveringChrome = hovering
    if hovering {
      chromeHideTask?.cancel()
    } else {
      scheduleChromeHide()
    }
  }

  private func scheduleChromeHide() {
    chromeHideTask?.cancel()
    guard !isHoveringChrome, sliderDraft == nil else { return }
    chromeHideTask = Task {
      try? await Task.sleep(for: Self.chromeTimeout)
      guard !Task.isCancelled, !isHoveringChrome, sliderDraft == nil else { return }
      hideChrome()
    }
  }

  private func hideChrome() {
    chromeHideTask?.cancel()
    withAnimation(.easeOut(duration: 0.25)) { chromeVisible = false }
    #if os(macOS)
      NSCursor.setHiddenUntilMouseMoves(true)
    #endif
  }

  // MARK: - Leaving

  private func escape() {
    if isFullScreen {
      toggleFullScreen()
    } else {
      close()
    }
  }

  private func toggleFullScreen() {
    #if os(macOS)
      NSApp.keyWindow?.toggleFullScreen(nil)
    #endif
  }

  private func close() {
    Task {
      await model.flush()
      onClose()
    }
  }

  private func backToSeries() {
    Task {
      await model.flush()
      if let showSeries = model.destination.actions.showSeries {
        await showSeries()
      } else {
        onClose()
      }
    }
  }

  private func open(_ volume: ReaderVolume) {
    Task {
      await model.flush()
      await model.destination.actions.openVolume?(volume.id)
    }
  }
}

extension ReadingMode {
  var systemImage: String {
    switch self {
    case .single: "rectangle.portrait"
    case .double: "book"
    case .scroll: "scroll"
    }
  }
}

extension View {
  /// The reader bars' buttons: borderless on the Mac, and on an iPad, white
  /// symbols with room for a finger.
  @ViewBuilder
  fileprivate func readerBarButtonStyle() -> some View {
    #if os(macOS)
      buttonStyle(.borderless)
    #else
      buttonStyle(ReaderBarButtonStyle())
    #endif
  }
}

#if os(iOS)
  /// Shows a label's symbol alone when asked to, and otherwise leaves the
  /// label to the style around it.
  private struct ConditionalIconOnlyLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
      if iconOnly {
        Label(configuration).labelStyle(.iconOnly)
      } else {
        Label(configuration)
      }
    }
  }

  private struct ReaderBarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .foregroundStyle(.white)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.3)
    }
  }

  /// Saves the reader's place as the app leaves the screen, in the time iOS
  /// gives an app to finish up before it is suspended.
  @MainActor
  private func flushInBackground(_ model: ReaderSessionModel) {
    let task = BackgroundTask()
    task.identifier = UIApplication.shared.beginBackgroundTask(withName: "Save reading position") {
      task.end()
    }
    Task {
      await model.flush()
      task.end()
    }
  }

  @MainActor
  private final class BackgroundTask {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
      guard identifier != .invalid else { return }
      UIApplication.shared.endBackgroundTask(identifier)
      identifier = .invalid
    }
  }
#endif

typealias PageLoader = @MainActor (_ page: Int, _ width: Int?) async throws -> CGImage

// MARK: - Pages

/// One page of a spread, fitted to its half of the screen.
private struct PageImageView: View {
  let page: Int
  let pageCount: Int
  let aspectRatio: Double?
  let load: PageLoader
  @State private var image: CGImage?
  @State private var failure: String?
  @State private var attempt = 0

  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .shadow(color: .black.opacity(0.45), radius: 11, y: 3)
      } else {
        PagePlaceholder(page: page, failure: failure) { attempt += 1 }
          .aspectRatio(aspectRatio ?? 2 / 3, contentMode: .fit)
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Page \(page) of \(pageCount)")
    .task(id: PageRequest(page: page, attempt: attempt)) {
      image = nil
      failure = nil
      do {
        image = try await load(page, nil)
      } catch {
        if !Task.isCancelled { failure = error.localizedDescription }
      }
    }
  }
}

/// One page of the continuous strip. Its box is reserved whether or not the
/// image is loaded, so pages far from the reader can let theirs go.
private struct ContinuousPageView: View {
  let page: Int
  let pageCount: Int
  let isActive: Bool
  let isCurrent: Bool
  let renditionWidth: Int?
  let load: PageLoader
  @State private var image: CGImage?
  @State private var isOriginal = false
  @State private var failure: String?
  @State private var attempt = 0

  var body: some View {
    ZStack {
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
      } else {
        PagePlaceholder(page: page, failure: failure, showsProgress: isActive) { attempt += 1 }
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Page \(page) of \(pageCount)")
    .task(id: PageRequest(page: page, attempt: attempt, isActive: isActive)) {
      guard isActive else {
        image = nil
        isOriginal = false
        return
      }
      guard image == nil else { return }
      failure = nil
      do {
        let loaded = try await load(page, renditionWidth)
        if !isOriginal { image = loaded }
        isOriginal = isOriginal || renditionWidth == nil
      } catch {
        if !Task.isCancelled { failure = error.localizedDescription }
      }
    }
    .task(id: isCurrent && isActive) {
      // Once the reader settles here, quietly swap in the original. A failure
      // leaves the readable copy where it is.
      guard isCurrent, isActive, renditionWidth != nil, !isOriginal else { return }
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled, let original = try? await load(page, nil), !Task.isCancelled
      else { return }
      image = original
      isOriginal = true
    }
  }
}

private struct PageRequest: Hashable {
  let page: Int
  let attempt: Int
  var isActive = true
}

private struct PagePlaceholder: View {
  let page: Int
  let failure: String?
  var showsProgress = true
  let retry: () -> Void

  var body: some View {
    ZStack {
      Rectangle().fill(Color(white: 0.07))
      if let failure {
        VStack(spacing: 10) {
          Image(systemName: "photo.badge.exclamationmark")
            .font(.title)
          Text("Page \(page) could not be loaded.")
            .font(.headline)
          Text(failure)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
          Button("Retry", action: retry)
        }
        .padding()
        .foregroundStyle(.white)
      } else if showsProgress {
        ProgressView().tint(.white)
      }
    }
  }
}

/// What the continuous view watches of its scrolling.
private struct StripGeometry: Equatable {
  let offset: CGFloat
  let contentHeight: CGFloat
}

/// Where each page of the continuous strip sits. Every page is as tall as the
/// screen allows unless the window is too narrow for it, as on the web.
struct ContinuousMetrics {
  let viewport: CGSize
  let zoom: CGFloat
  let spacing: CGFloat
  let topInset: CGFloat
  private let ratios: [CGFloat]
  private let offsets: [CGFloat]
  private let heights: [CGFloat]
  private let layout: PageLayout

  static let defaultRatio: CGFloat = 2 / 3

  init(layout: PageLayout, viewport: CGSize, zoom: CGFloat, spacing: CGFloat, topInset: CGFloat) {
    self.layout = layout
    self.viewport = viewport
    self.zoom = zoom
    self.spacing = spacing
    self.topInset = topInset
    let count = max(layout.totalPages, 1)
    ratios = (1...count).map { CGFloat(layout.aspectRatio(of: $0) ?? Double(Self.defaultRatio)) }
    let box = max(viewport.height - 32, 200) * zoom
    let maximumWidth = max(viewport.width - 24, 200)
    var heights: [CGFloat] = []
    var offsets: [CGFloat] = []
    var y = topInset
    for ratio in ratios {
      let width = min(maximumWidth, box * ratio)
      let height = width / ratio
      offsets.append(y)
      heights.append(height)
      y += height + spacing
    }
    self.heights = heights
    self.offsets = offsets
  }

  /// The width of an ordinary page, which renditions are sized for.
  var standardWidth: CGFloat {
    min(max(viewport.width - 24, 200), max(viewport.height - 32, 200) * zoom * Self.defaultRatio)
  }

  func size(of page: Int) -> CGSize {
    let index = min(max(page - 1, 0), ratios.count - 1)
    return CGSize(width: heights[index] * ratios[index], height: heights[index])
  }

  /// The scroll offset that puts `page` at the top, just under the toolbar.
  func offset(of page: Int) -> CGFloat {
    guard page >= 1 else { return 0 }
    let index = min(page - 1, offsets.count - 1)
    return max(0, offsets[index] - topInset)
  }

  func page(atY y: CGFloat) -> Int {
    var low = 0
    var high = offsets.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if offsets[middle] <= y { low = middle } else { high = middle - 1 }
    }
    return low + 1
  }

  func rezoomed(_ zoom: CGFloat) -> ContinuousMetrics {
    ContinuousMetrics(
      layout: layout, viewport: viewport, zoom: zoom, spacing: spacing, topInset: topInset)
  }
}

// MARK: - End card

private struct EndCardView: View {
  let title: String
  let savedMessage: String
  let next: ReaderVolume?
  let isInSeries: Bool
  let loadCover: @Sendable (String) async -> Data?
  let onReadNext: (() -> Void)?
  let onBackToSeries: (() -> Void)?
  let onReadAgain: () -> Void
  @State private var cover: CGImage?

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 46, weight: .semibold))
        .foregroundStyle(.green)
        .accessibilityHidden(true)
      VStack(spacing: 6) {
        Text("Finished")
          .font(.largeTitle.weight(.bold))
        Text(title)
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Text(savedMessage)
          .font(.callout)
          .foregroundStyle(.tertiary)
      }

      if let next, let onReadNext {
        HStack(alignment: .top, spacing: 16) {
          Group {
            if let cover {
              Image(decorative: cover, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
              Rectangle().fill(Color(white: 0.14))
                .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
          }
          .frame(width: 76, height: 114)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .shadow(color: .black.opacity(0.4), radius: 6, y: 3)

          VStack(alignment: .leading, spacing: 5) {
            Text("UP NEXT")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(next.volume.map { "Volume \($0)" } ?? next.title)
              .font(.headline)
            if next.volume != nil {
              Text(next.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: 6)
            Button(action: onReadNext) {
              Label("Read next", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        // As tall as its contents, however much room the card is given.
        .fixedSize(horizontal: false, vertical: true)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .task(id: next.id) {
          guard let data = await loadCover(next.id) else { return }
          cover = await decodedImage(data)
        }
      } else if isInSeries {
        Text("You're caught up with this series.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 10) {
        if let onBackToSeries {
          Button("Back to series", action: onBackToSeries)
        }
        Button(action: onReadAgain) {
          Label("Read again", systemImage: "arrow.counterclockwise")
        }
      }
      .buttonStyle(.bordered)
    }
    .foregroundStyle(.white)
    .frame(maxWidth: 440)
    .padding(32)
  }
}

/// Decodes an image away from the main thread.
func decodedImage(_ data: Data) async -> CGImage? {
  await Task.detached(priority: .userInitiated) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(
      source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  }.value
}

// MARK: - Trackpad

#if os(macOS)
  /// Turns trackpad swipes and mouse-wheel notches into page turns while the
  /// pages are not scrollable themselves.
  @MainActor
  private final class ScrollTurnMonitor {
    enum Turn {
      case side(pointingRight: Bool)
      case reading(forward: Bool)
    }

    private var token: Any?
    private var accumulated = CGSize.zero
    private var hasTurned = false
    private var lastWheelTurn = Date.distantPast
    private var isActive: () -> Bool = { false }
    private var onTurn: (Turn) -> Void = { _ in }

    /// How far a two-finger swipe travels before it turns the page.
    private static let threshold: CGFloat = 60

    func start(isActive: @escaping () -> Bool, onTurn: @escaping (Turn) -> Void) {
      stop()
      self.isActive = isActive
      self.onTurn = onTurn
      token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        let consumed = MainActor.assumeIsolated {
          self?.handle(
            dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, phase: event.phase,
            momentum: event.momentumPhase, precise: event.hasPreciseScrollingDeltas) ?? false
        }
        return consumed ? nil : event
      }
    }

    func stop() {
      if let token { NSEvent.removeMonitor(token) }
      token = nil
    }

    private func handle(
      dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase, precise: Bool
    ) -> Bool {
      guard isActive() else { return false }
      // The glide after a swipe belongs to the swipe that already turned.
      guard momentum.isEmpty else { return true }
      guard precise else {
        guard dy != 0, Date.now.timeIntervalSince(lastWheelTurn) > 0.25 else { return true }
        lastWheelTurn = .now
        onTurn(.reading(forward: dy < 0))
        return true
      }
      if phase.contains(.began) {
        accumulated = .zero
        hasTurned = false
      }
      accumulated.width += dx
      accumulated.height += dy
      if !hasTurned {
        let horizontal = abs(accumulated.width)
        let vertical = abs(accumulated.height)
        if horizontal > Self.threshold, horizontal > vertical {
          hasTurned = true
          // Content pulled left brings in what lies to its right.
          onTurn(.side(pointingRight: accumulated.width < 0))
        } else if vertical > Self.threshold, vertical > horizontal {
          hasTurned = true
          onTurn(.reading(forward: accumulated.height < 0))
        }
      }
      if phase.contains(.ended) || phase.contains(.cancelled) {
        accumulated = .zero
        hasTurned = false
      }
      return true
    }
  }
#endif
