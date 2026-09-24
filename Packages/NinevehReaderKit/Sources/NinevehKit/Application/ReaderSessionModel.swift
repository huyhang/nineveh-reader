import Combine
import Foundation
import ImageIO
import NinevehCore

/// One open publication: where the reader is, how it is laid out, and keeping
/// the server told. Mirrors the web reader's behaviour so both leave the same
/// progress behind.
@MainActor
public final class ReaderSessionModel: ObservableObject {
  public enum SyncStatus: Equatable, Sendable {
    case idle
    case saving
    case saved
    case savedLocally

    public var title: String? {
      switch self {
      case .idle: nil
      case .saving: "Saving…"
      case .saved: "Saved"
      case .savedLocally: "Saved locally"
      }
    }
  }

  /// Asks a continuous view to bring a page to the top.
  public struct ScrollRequest: Equatable, Sendable {
    public let page: Int
    let token = UUID()
  }

  @Published public private(set) var layout = PageLayout(pages: [], totalPages: 0)
  @Published public private(set) var isLoading = true
  @Published public private(set) var errorMessage: String?
  @Published public private(set) var page: Int
  @Published public private(set) var mode: ReadingMode
  @Published public private(set) var directionPreference: ReadingDirectionPreference
  @Published public private(set) var completed: Bool
  /// The end card is showing in place of the pages.
  @Published public private(set) var isFinished = false
  @Published public private(set) var syncStatus: SyncStatus = .idle
  @Published public private(set) var scrollRequest: ScrollRequest?

  public let destination: ReaderDestination
  private let cache = ImageDataCache(byteLimit: 256 * 1_024 * 1_024)
  private var saveTask: Task<Void, Never>?
  private var prefetchTask: Task<Void, Never>?
  private var saveGeneration = 0
  private var hasUnsavedChanges = false

  /// How long page turns settle before the position is sent, as on the web.
  static let saveDelay: Duration = .milliseconds(800)
  /// How long to wait before offering a position the server failed to take again.
  static let retryDelay: Duration = .seconds(5)

  public init(destination: ReaderDestination) {
    self.destination = destination
    let initial = destination.initialPosition
    page = destination.startsAtBeginning ? 1 : initial?.page ?? 1
    mode = destination.initialMode
    directionPreference = destination.directionPreference
    completed = initial?.completed ?? false
  }

  public var title: String { destination.title }
  public var subtitle: String? { destination.subtitle }
  public var context: ReaderContext { destination.context }
  public var pageCount: Int { layout.totalPages }
  public var direction: ReadingDirection {
    directionPreference.resolved(default: destination.defaultDirection)
  }
  public var visiblePages: [Int] { layout.visiblePages(for: page, mode: mode) }
  public var pageLabel: String { layout.label(for: page, mode: mode) }
  public var canMoveBackward: Bool { isFinished || page > 1 }
  public var canMoveForward: Bool { !isFinished && pageCount > 0 }
  public var servesRenditions: Bool { destination.source.servesRenditions }

  /// What the end card says about the save.
  public var savedMessage: String {
    switch syncStatus {
    case .saved: "Your progress has been saved."
    case .savedLocally: "Your progress is saved on this device."
    case .idle, .saving: completed ? "Your progress has been saved." : "Saving your progress…"
    }
  }

  public func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let manifest = try await destination.source.manifest()
      let layout = PageLayout(manifest: manifest)
      guard layout.totalPages > 0 else { throw ReaderError.emptyArchive }
      self.layout = layout
      page = layout.normalized(layout.clamp(page), mode: mode)
      // Only the last page can be complete; anywhere else the flag would be refused.
      if !layout.reachesEnd(page, mode: mode) { completed = false }
      prefetchAdjacent()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  public func imageData(page: Int, width: Int? = nil) async throws -> Data {
    let key = "\(page)|\(width ?? 0)"
    if let cached = await cache.value(for: key) { return cached }
    let data = try await destination.source.page(number: page, maximumPixelWidth: width)
    await cache.insert(data, for: key)
    return data
  }

  /// The page decoded away from the main thread.
  public func image(page: Int, width: Int? = nil) async throws -> CGImage {
    let data = try await imageData(page: page, width: width)
    return try await Task.detached(priority: .userInitiated) {
      let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, options)
      else { throw ReaderError.invalidArchive }
      return image
    }.value
  }

  // MARK: - Navigation

  /// Turns a page in reading order: `1` forward, `-1` back. Past the last page
  /// is the end card; back from the end card is the last page again.
  public func move(_ step: Int) {
    guard pageCount > 0 else { return }
    if isFinished {
      if step < 0 { isFinished = false }
      return
    }
    guard let target = layout.adjacentPage(to: page, mode: mode, step: step) else {
      if step > 0 { showEndCard() }
      return
    }
    go(to: target)
  }

  /// Turns toward a side of the screen, whichever way that is in this direction.
  public func turn(pointingRight: Bool) {
    move(direction.step(forArrowPointingRight: pointingRight))
  }

  public func go(to target: Int) {
    guard pageCount > 0 else { return }
    setPage(target)
    isFinished = false
    if mode == .scroll { scrollRequest = ScrollRequest(page: page) }
    prefetchAdjacent()
    scheduleSave()
  }

  public func goToStart() { go(to: 1) }
  public func goToEnd() { go(to: pageCount) }

  /// Continuous reading reports the page crossing the middle of the view.
  public func recordScrolledPage(_ scrolled: Int) {
    guard mode == .scroll, pageCount > 0, layout.clamp(scrolled) != page else { return }
    setPage(scrolled)
    scheduleSave()
  }

  public func setMode(_ value: ReadingMode) {
    guard value != mode else { return }
    mode = value
    isFinished = false
    page = layout.normalized(page, mode: mode)
    if value == .scroll { scrollRequest = ScrollRequest(page: page) }
    prefetchAdjacent()
    scheduleSave()
    let actions = destination.actions
    Task { await actions.saveMode(value) }
  }

  public func setDirection(_ value: ReadingDirectionPreference) {
    directionPreference = value
    let actions = destination.actions
    Task { await actions.saveDirection(value) }
  }

  public func cycleDirection() {
    setDirection(directionPreference.next)
  }

  public func showEndCard() {
    isFinished = true
    page = pageCount
    completeReading()
  }

  /// Marks the volume read, as reaching its end card does.
  public func completeReading() {
    guard !completed, pageCount > 0 else { return }
    completed = true
    page = pageCount
    scheduleSave(immediately: true)
  }

  public func readAgain() {
    isFinished = false
    completed = false
    page = 1
    if mode == .scroll { scrollRequest = ScrollRequest(page: 1) }
    prefetchAdjacent()
    scheduleSave(immediately: true)
  }

  /// Saves anything pending now, before the reader closes or changes volume.
  public func flush() async {
    prefetchTask?.cancel()
    // A save already under way finishes; one still waiting to go is sent now.
    let pending = saveTask
    pending?.cancel()
    await pending?.value
    guard hasUnsavedChanges else { return }
    await save()
  }

  // MARK: - Private

  private func setPage(_ value: Int) {
    page = layout.normalized(layout.clamp(value), mode: mode)
    // Leaving the last page un-completes the volume. The server refuses a
    // completed flag on any other page, and that refusal would never clear.
    if page != pageCount { completed = false }
  }

  private func scheduleSave(immediately: Bool = false) {
    hasUnsavedChanges = true
    syncStatus = .saving
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      if !immediately { try? await Task.sleep(for: Self.saveDelay) }
      guard !Task.isCancelled else { return }
      await self?.save()
    }
  }

  private func save() async {
    guard pageCount > 0 else { return }
    saveGeneration += 1
    let generation = saveGeneration
    hasUnsavedChanges = false
    let position = ReadingPosition(
      publicationID: destination.publicationID, page: page, mode: mode, completed: completed)
    let result = await destination.actions.savePosition(position)
    // A newer save owns the status now.
    guard generation == saveGeneration, !hasUnsavedChanges else { return }
    switch result {
    case .saved:
      syncStatus = .saved
    case .savedLocally(let retryable):
      syncStatus = .savedLocally
      guard retryable else { return }
      hasUnsavedChanges = true
      saveTask = Task { [weak self] in
        try? await Task.sleep(for: Self.retryDelay)
        guard !Task.isCancelled else { return }
        await self?.save()
      }
    }
  }

  /// Fetches the spreads either side, so a page turn shows the page at once.
  private func prefetchAdjacent() {
    prefetchTask?.cancel()
    guard pageCount > 0, mode != .scroll else { return }
    var pages: [Int] = []
    for step in [1, 2, -1] {
      var target = page
      for _ in 0..<abs(step) {
        target = layout.adjacentPage(to: target, mode: mode, step: step.signum()) ?? target
      }
      pages += layout.visiblePages(for: target, mode: mode)
    }
    let wanted = pages.filter { !visiblePages.contains($0) }
    prefetchTask = Task { [weak self] in
      for number in wanted {
        guard !Task.isCancelled else { return }
        _ = try? await self?.imageData(page: number)
      }
    }
  }
}
