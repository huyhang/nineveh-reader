/// How far a reader is through one volume, worded as the web series page has it.
public struct VolumeProgress: Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case notStarted
    case reading(page: Int)
    case completed
  }

  public let state: State
  public let pageCount: Int?

  public init(position: ReadingPosition?, pageCount: Int?) {
    self.pageCount = pageCount
    switch position {
    case nil: state = .notStarted
    case let position? where position.completed: state = .completed
    case let position?: state = .reading(page: position.page)
    }
  }

  public var fraction: Double {
    switch state {
    case .notStarted: return 0
    case .completed: return 1
    case .reading(let page):
      guard let pageCount, pageCount > 0 else { return 0 }
      return min(1, max(0, Double(page) / Double(pageCount)))
    }
  }

  public var percent: Int { Int((fraction * 100).rounded()) }

  /// "Completed", "Page 12 of 180", or "Not started".
  public var label: String {
    switch state {
    case .notStarted: return "Not started"
    case .completed: return "Completed"
    case .reading(let page): return pageCount.map { "Page \(page) of \($0)" } ?? "Page \(page)"
    }
  }

  public var isStarted: Bool { state != .notStarted }
  public var isCompleted: Bool { state == .completed }

  /// The page "Resume" opens at; only a volume part-way through has one.
  public var resumePage: Int? {
    guard case .reading(let page) = state else { return nil }
    return page
  }
}

/// How far a reader is through a series.
public struct SeriesProgress: Equatable, Sendable {
  public let volumeCount: Int
  public let completedCount: Int
  public let inProgressCount: Int
  public let fraction: Double

  public init(_ volumes: [VolumeProgress]) {
    volumeCount = volumes.count
    completedCount = volumes.filter(\.isCompleted).count
    inProgressCount = volumes.filter { $0.resumePage != nil }.count
    fraction = volumes.isEmpty ? 0 : volumes.map(\.fraction).reduce(0, +) / Double(volumes.count)
  }

  /// "All read", "2 of 5 read", "In progress", or `nil` for an untouched series.
  public var summary: String? {
    guard volumeCount > 0 else { return nil }
    if completedCount == volumeCount { return "All read" }
    if completedCount > 0 { return "\(completedCount) of \(volumeCount) read" }
    if inProgressCount > 0 { return "In progress" }
    return nil
  }
}
