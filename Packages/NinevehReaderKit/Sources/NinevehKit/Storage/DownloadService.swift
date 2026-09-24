import Foundation
import NinevehCore

public actor DownloadService {
  private let client: NinevehClient
  private let store: ReaderStore
  private let connectionID: String
  private var reportedProgress: [String: Double] = [:]
  private var activeDownloadKeys = Set<String>()

  public init(client: NinevehClient, store: ReaderStore, connectionID: String) {
    self.client = client
    self.store = store
    self.connectionID = connectionID
  }

  @discardableResult
  public func enqueue(_ publication: Publication) async throws -> DownloadRecord {
    try await store.prepareDownload(publication, connectionID: connectionID)
  }

  public func download(
    _ publication: Publication,
    didChange: @Sendable @escaping (DownloadRecord) async -> Void
  ) async {
    let key = "\(connectionID)|\(publication.id)"
    activeDownloadKeys.insert(key)
    do {
      let previousFilename = try await store.download(key: key)?.localFilename
      try await store.updateDownload(key: key, state: .downloading, progress: 0.05)
      await notify(key: key, didChange: didChange)

      let (temporaryURL, response) = try await client.download(publication: publication) {
        [weak self] progress in
        Task { await self?.recordProgress(progress, key: key, didChange: didChange) }
      }
      let source = CBZArchiveSource(url: temporaryURL)
      let pageCount = try await source.manifest().totalPages
      // Page geometry is what pairs spreads; keep it for reading offline.
      let geometry = try? await client.manifest(for: publication.id)

      let directory = await store.downloadsDirectory
      let filename = try Self.move(
        temporaryURL, into: directory,
        named: Self.filename(for: publication, response: response),
        replacing: previousFilename)
      let destination = directory.appending(path: filename)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableDestination = destination
      try? mutableDestination.setResourceValues(values)
      if let geometry, geometry.totalPages == pageCount {
        ReaderStore.save(geometry: geometry, forDownloadAt: destination)
      }

      let size =
        (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        ?? response.expectedContentLength
      try await store.updateDownload(
        key: key,
        state: .completed,
        progress: 1,
        localFilename: filename,
        revision: publication.revision,
        byteCount: size
      )
      activeDownloadKeys.remove(key)
      if let previousFilename, previousFilename != filename {
        ReaderStore.removeDownloadFiles(
          at: await store.downloadsDirectory.appending(path: previousFilename))
      }
      await notify(key: key, didChange: didChange)
      reportedProgress[key] = nil
    } catch is CancellationError {
      activeDownloadKeys.remove(key)
      try? await store.updateDownload(key: key, state: .queued, progress: 0)
      await notify(key: key, didChange: didChange)
      reportedProgress[key] = nil
    } catch {
      activeDownloadKeys.remove(key)
      try? await store.updateDownload(
        key: key,
        state: .failed,
        progress: 0,
        errorMessage: error.localizedDescription
      )
      await notify(key: key, didChange: didChange)
      reportedProgress[key] = nil
    }
  }

  public func remove(_ record: DownloadRecord) async throws {
    try await store.removeDownload(key: record.id)
  }

  /// The file's name on Nineveh's disk, which it sends with the file, or the
  /// volume's title.
  static func filename(for publication: Publication, response: HTTPURLResponse) -> String {
    // Without the header, Foundation makes a name up from the URL: "file".
    let suggested =
      response.value(forHTTPHeaderField: "Content-Disposition") == nil
      ? nil : response.suggestedFilename
    let name = (suggested ?? publication.title)
      .replacingOccurrences(of: "/", with: "_")
      .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
    let stem = name.isEmpty ? "Volume" : name
    return ["cbz", "zip"].contains((stem as NSString).pathExtension.lowercased())
      ? stem : "\(stem).cbz"
  }

  /// Moves a finished download into `directory` as `name`. A new copy of a
  /// volume takes its old copy's place; any other file keeps the name, and the
  /// download is numbered instead.
  static func move(
    _ file: URL,
    into directory: URL,
    named name: String,
    replacing previous: String?
  ) throws -> String {
    let destination = directory.appending(path: name)
    if name == previous, FileManager.default.fileExists(atPath: destination.path) {
      // The old copy's geometry may not fit the new one.
      ReaderStore.removeGeometry(forDownloadAt: destination)
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
      return name
    }
    return try ReaderStore.placeFile(named: name, in: directory) {
      try FileManager.default.moveItem(at: file, to: $0)
    }
  }

  private func notify(
    key: String,
    didChange: @Sendable (DownloadRecord) async -> Void
  ) async {
    guard let records = try? await store.downloads(connectionID: connectionID),
      let record = records.first(where: { $0.id == key })
    else { return }
    await didChange(record)
  }

  private func recordProgress(
    _ progress: Double,
    key: String,
    didChange: @Sendable (DownloadRecord) async -> Void
  ) async {
    guard activeDownloadKeys.contains(key) else { return }
    let previous = reportedProgress[key] ?? 0
    guard progress >= 1 || progress - previous >= 0.02 else { return }
    reportedProgress[key] = progress
    try? await store.updateDownload(key: key, state: .downloading, progress: progress)
    await notify(key: key, didChange: didChange)
  }
}
