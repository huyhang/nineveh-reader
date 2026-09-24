import Foundation
import NinevehCore

public actor LocalLibraryService {
  private let store: ReaderStore

  public init(store: ReaderStore) {
    self.store = store
  }

  public func add(url: URL, kind: LocalBookKind) async throws -> LocalBook {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }

    let source = CBZArchiveSource(url: url)
    let manifest = try await source.manifest()
    let title = url.deletingPathExtension().lastPathComponent

    switch kind {
    case .imported:
      let directory = await store.importsDirectory
      let filename = try ReaderStore.placeFile(named: url.lastPathComponent, in: directory) {
        try FileManager.default.copyItem(at: url, to: $0)
      }
      return try await store.saveLocalBook(
        title: title,
        kind: .imported,
        pageCount: manifest.totalPages,
        localFilename: filename,
        bookmark: nil
      )
    case .external:
      #if os(macOS)
        // The sandbox grants only read access to files the user picks, and a
        // bookmark asking for more fails with a bare "couldn't be opened".
        let bookmark = try url.bookmarkData(options: ReaderStore.externalBookmarkOptions)
      #else
        let bookmark = try url.bookmarkData()
      #endif
      return try await store.saveLocalBook(
        title: title,
        kind: .external,
        pageCount: manifest.totalPages,
        localFilename: nil,
        bookmark: bookmark
      )
    }
  }

  public func source(for book: LocalBook) async throws -> CBZArchiveSource {
    let location = try await store.localBookLocation(id: book.id)
    // Outside the sandbox's container a file is invisible until its bookmark's
    // access starts.
    let accessed = location.bookmark != nil && location.url.startAccessingSecurityScopedResource()
    defer { if accessed { location.url.stopAccessingSecurityScopedResource() } }
    guard FileManager.default.fileExists(atPath: location.url.path) else {
      throw ReaderError.fileUnavailable
    }
    return CBZArchiveSource(url: location.url, bookmark: location.bookmark)
  }
}
