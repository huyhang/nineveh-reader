import Foundation
import NinevehCore
import Testing
import ZIPFoundation

@testable import NinevehKit

@Test func readsImageEntriesInNaturalOrder() async throws {
  let fixtureDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: ".build/test-fixtures", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
  let archiveURL = fixtureDirectory.appending(path: "ordered-pages-\(UUID().uuidString).cbz")
  defer { try? FileManager.default.removeItem(at: archiveURL) }

  let archive = try Archive(url: archiveURL, accessMode: .create)
  try add(Data("ten".utf8), path: "10.jpg", to: archive)
  try add(Data("two".utf8), path: "2.jpg", to: archive)
  try add(Data("ignored".utf8), path: "notes.txt", to: archive)

  let source = CBZArchiveSource(url: archiveURL)
  let manifest = try await source.manifest()

  #expect(manifest.totalPages == 2)
  #expect(try await source.page(number: 1, maximumPixelWidth: nil) == Data("two".utf8))
  #expect(try await source.page(number: 2, maximumPixelWidth: nil) == Data("ten".utf8))
}

private func add(_ data: Data, path: String, to archive: Archive) throws {
  try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
    position, size in
    let lowerBound = Int(position)
    let upperBound = min(lowerBound + size, data.count)
    return data.subdata(in: lowerBound..<upperBound)
  }
}
