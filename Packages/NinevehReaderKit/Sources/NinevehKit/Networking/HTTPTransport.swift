import Foundation

public protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
  func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

public protocol ProgressReportingHTTPTransport: HTTPTransport {
  func download(
    for request: URLRequest,
    progress: @Sendable @escaping (Double) -> Void
  ) async throws -> (URL, URLResponse)
}

extension URLSession: HTTPTransport, ProgressReportingHTTPTransport {
  public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
    try await download(for: request, delegate: nil)
  }

  public func download(
    for request: URLRequest,
    progress: @Sendable @escaping (Double) -> Void
  ) async throws -> (URL, URLResponse) {
    let delegate = DownloadProgressDelegate(progress: progress)
    return try await download(for: request, delegate: delegate)
  }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let progress: @Sendable (Double) -> Void

  init(progress: @Sendable @escaping (Double) -> Void) {
    self.progress = progress
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else { return }
    progress(min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1))
  }
}
