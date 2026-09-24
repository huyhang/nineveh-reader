import Foundation
import NinevehCore

public actor PageSourceResolver {
  private let client: NinevehClient
  private let store: ReaderStore
  private let connectionID: String

  public init(client: NinevehClient, store: ReaderStore, connectionID: String) {
    self.client = client
    self.store = store
    self.connectionID = connectionID
  }

  public func source(for publication: Publication) async throws -> any PageProviding {
    if let url = try await store.downloadedURL(
      publicationID: publication.id,
      connectionID: connectionID
    ) {
      var geometry = ReaderStore.geometry(forDownloadAt: url)
      if geometry == nil, let fetched = await remoteGeometry(for: publication) {
        // Downloaded before geometry was kept; the archive checks the counts.
        ReaderStore.save(geometry: fetched, forDownloadAt: url)
        geometry = fetched
      } else if geometry != nil {
        // Nineveh may pair the pages differently since the download. What it
        // says now is kept for the next time the volume opens; this time it
        // opens as saved, without waiting.
        let publicationID = publication.id
        Task { await refreshGeometry(publicationID: publicationID, at: url) }
      }
      return CBZArchiveSource(url: url, geometry: geometry)
    }
    return await client.pageSource(for: publication)
  }

  /// Checks a downloaded volume's saved page geometry against Nineveh's and
  /// keeps Nineveh's if it changed. Returns whether it did.
  @discardableResult
  public func refreshGeometry(publicationID: String) async -> Bool {
    guard
      let url = try? await store.downloadedURL(
        publicationID: publicationID, connectionID: connectionID)
    else { return false }
    return await refreshGeometry(publicationID: publicationID, at: url)
  }

  @discardableResult
  func refreshGeometry(publicationID: String, at url: URL) async -> Bool {
    guard let fetched = try? await client.manifest(for: publicationID) else { return false }
    return Self.keep(fetched, forDownloadAt: url)
  }

  /// Saves `manifest` beside a downloaded archive in place of the geometry
  /// kept there, unless nothing changed or it describes some other file.
  static func keep(_ manifest: PageManifest, forDownloadAt url: URL) -> Bool {
    let saved = ReaderStore.geometry(forDownloadAt: url)
    guard manifest != saved else { return false }
    // Another page count means Nineveh's file is no longer the one that was
    // downloaded, and its pairing would misplace this one's pages.
    if let saved, saved.totalPages != manifest.totalPages { return false }
    ReaderStore.save(geometry: manifest, forDownloadAt: url)
    return true
  }

  /// The server's manifest, if it answers promptly. A downloaded volume must
  /// open at once offline, so waiting any longer is not worth the pairing.
  private func remoteGeometry(for publication: Publication) async -> PageManifest? {
    let client = client
    return await withTaskGroup(of: PageManifest?.self) { group in
      group.addTask { try? await client.manifest(for: publication.id) }
      group.addTask {
        try? await Task.sleep(for: .seconds(2.5))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}
