import Foundation
import Testing

@testable import NinevehCore

@Test func allowsHTTPSAndLoopbackHTTP() throws {
  #expect(throws: Never.self) {
    try ServerConnection.validated(urlText: "https://reader.example.com", username: "reader")
  }
  #expect(throws: Never.self) {
    try ServerConnection.validated(urlText: "http://127.0.0.1:8081", username: "reader")
  }
}

@Test func rejectsRemoteHTTP() {
  #expect(throws: ReaderError.insecureServer) {
    try ServerConnection.validated(urlText: "http://reader.example.com", username: "reader")
  }
}

@Test func derivesReadingDirectionFromCategory() {
  #expect(PublicationCategory.manga.defaultDirection == .rightToLeft)
  #expect(PublicationCategory.comics.defaultDirection == .leftToRight)
}
