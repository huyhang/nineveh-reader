import Foundation
import NinevehCore
import ZIPFoundation

public actor CBZArchiveSource: PageProviding {
  private let url: URL
  private let bookmark: Data?
  private let geometry: PageManifest?
  private static let imageExtensions = Set(["avif", "gif", "jpeg", "jpg", "png", "webp"])

  /// - Parameter geometry: The server's manifest for this archive, kept when
  ///   it was downloaded, so two-page spreads pair offline as they do online.
  public init(url: URL, bookmark: Data? = nil, geometry: PageManifest? = nil) {
    self.url = url
    self.bookmark = bookmark
    self.geometry = geometry
  }

  public func manifest() throws -> PageManifest {
    try withAccess { archive in
      let entries = imageEntries(in: archive)
      guard !entries.isEmpty else { throw ReaderError.emptyArchive }
      guard entries.count <= 50_000 else { throw ReaderError.invalidArchive }
      // Geometry for some other page count describes some other file.
      let geometry = geometry?.totalPages == entries.count ? geometry : nil
      return PageManifest(
        publicationID: url.lastPathComponent,
        revision: fileRevision(),
        totalPages: entries.count,
        pairingAnchor: geometry?.pairingAnchor,
        pages: geometry?.pages ?? []
      )
    }
  }

  public func page(number: Int, maximumPixelWidth: Int?) throws -> Data {
    try withAccess { archive in
      let entries = imageEntries(in: archive)
      guard entries.indices.contains(number - 1) else { throw ReaderError.fileUnavailable }
      guard entries[number - 1].uncompressedSize <= 200 * 1_024 * 1_024 else {
        throw ReaderError.invalidArchive
      }
      var data = Data()
      _ = try archive.extract(entries[number - 1]) { chunk in
        data.append(chunk)
      }
      return data
    }
  }

  private func withAccess<T>(_ body: (Archive) throws -> T) throws -> T {
    let accessed = bookmark == nil || url.startAccessingSecurityScopedResource()
    guard accessed else { throw ReaderError.permissionDenied }
    defer {
      if bookmark != nil { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let archive = try Archive(url: url, accessMode: .read)
      return try body(archive)
    } catch let error as ReaderError {
      throw error
    } catch {
      throw ReaderError.invalidArchive
    }
  }

  private func imageEntries(in archive: Archive) -> [Entry] {
    archive
      .filter { entry in
        entry.type == .file
          && Self.imageExtensions.contains(
            URL(fileURLWithPath: entry.path).pathExtension.lowercased())
          && !entry.path.hasPrefix("__MACOSX/")
      }
      .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  private func fileRevision() -> String {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values?.fileSize ?? 0)"
  }
}
