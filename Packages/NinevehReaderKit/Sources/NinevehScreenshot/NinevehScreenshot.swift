#if os(macOS)
  import AppKit
  import NinevehCore
  import NinevehKit
  import SwiftUI

  @main
  struct NinevehScreenshot {
    @MainActor
    static func main() throws {
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.count >= 4, arguments[2] == "--reader" {
        ReaderWindowCapture.run(
          output: URL(fileURLWithPath: arguments[1]),
          archive: URL(fileURLWithPath: arguments[3]),
          idle: arguments.dropFirst(4).contains("--idle"))
        return
      }
      guard (2...4).contains(arguments.count) else {
        throw ScreenshotError.expectedOutputPath
      }

      let outputURL = URL(fileURLWithPath: arguments[1])
      let showsOrganizedBrowse = arguments.dropFirst(2).contains("--browse")
      // Tall enough for every shelf on Home.
      let tall = arguments.dropFirst(2).contains("--tall")
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      let size = NSSize(width: 1_440, height: tall ? 1_900 : 900)
      let content = NinevehReaderRootView(
        model: .preview(),
        initiallyShowsOrganizedBrowse: showsOrganizedBrowse
      )
      .frame(width: size.width, height: size.height)
      .preferredColorScheme(.dark)
      let hostingView = NSHostingView(rootView: content)
      hostingView.frame = NSRect(origin: .zero, size: size)

      let application = NSApplication.shared
      application.setActivationPolicy(.prohibited)
      let window = NSWindow(
        contentRect: hostingView.bounds,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      window.contentView = hostingView
      window.orderFrontRegardless()
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
      hostingView.layoutSubtreeIfNeeded()
      hostingView.displayIfNeeded()

      guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
      else {
        throw ScreenshotError.renderFailed
      }
      hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
      window.orderOut(nil)

      guard let png = representation.representation(using: .png, properties: [:]) else {
        throw ScreenshotError.renderFailed
      }
      try png.write(to: outputURL, options: .atomic)
    }
  }

  /// The reader in a titled window, title bar included, since that is where
  /// the reader's chrome has to meet the window's own. SwiftUI runs the
  /// window's toolbar, as it does for the app's windows. `idle` waits for the
  /// controls to hide first.
  @MainActor
  enum ReaderWindowCapture {
    static func run(output: URL, archive: URL, idle: Bool) {
      let application = NSApplication.shared
      application.setActivationPolicy(.regular)
      let model = ApplicationModel.preview()
      let controller = NSHostingController(
        rootView: NinevehReaderRootView(model: model).preferredColorScheme(.dark))
      controller.sceneBridgingOptions = [.toolbars, .title]
      let window = NSWindow(contentViewController: controller)
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      // As the app's `.windowToolbarStyle(.unified(showsTitle: false))` has it.
      window.toolbarStyle = .unified
      window.setContentSize(NSSize(width: 1_180, height: 780))
      window.center()
      window.makeKeyAndOrderFront(nil)
      application.activate()

      Task {
        // Opened a moment after the library, as it is in the app. The library
        // is captured first, then with a page pushed, whose back button must
        // not bring a toolbar of its own.
        try? await Task.sleep(for: .milliseconds(800))
        capture(window, to: sibling(of: output, named: "library"))
        if let series = model.seriesGroups.first {
          model.libraryPath = [.series(series.key)]
          try? await Task.sleep(for: .milliseconds(600))
          capture(window, to: sibling(of: output, named: "pushed"))
          model.libraryPath = []
          try? await Task.sleep(for: .milliseconds(300))
        }
        model.presentedReader = destination(for: archive)
        try? await Task.sleep(for: .milliseconds(idle ? 5_000 : 1_500))
        capture(window, to: output)
        // The library gets its title bar back.
        model.presentedReader = nil
        try? await Task.sleep(for: .milliseconds(500))
        print(
          "after closing: title bar height "
            + "\(window.frame.height - window.contentLayoutRect.height), "
            + "toolbar visible \(window.toolbar?.isVisible ?? false)")
        exit(0)
      }
      // A capture that never finishes must not hang the caller.
      DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        FileHandle.standardError.write(Data("Timed out capturing the reader.\n".utf8))
        exit(2)
      }
      application.run()
    }

    private static func destination(for archive: URL) -> ReaderDestination {
      let series = archive.deletingLastPathComponent().lastPathComponent
      return ReaderDestination(
        id: "capture",
        publicationID: "capture",
        title: archive.deletingPathExtension().lastPathComponent,
        subtitle: series,
        source: CBZArchiveSource(url: archive),
        initialPosition: ReadingPosition(
          publicationID: "capture", page: 6, mode: .double, completed: false),
        initialMode: .double,
        defaultDirection: .rightToLeft,
        context: ReaderContext(
          seriesTitle: series,
          volumes: [
            ReaderVolume(id: "capture", title: "v01"), ReaderVolume(id: "next", title: "v02"),
          ],
          currentIndex: 0),
        actions: ReaderActions(showSeries: {})
      )
    }

    private static func sibling(of output: URL, named suffix: String) -> URL {
      let stem = output.deletingPathExtension().lastPathComponent
      return output.deletingLastPathComponent().appending(path: "\(stem)-\(suffix).png")
    }

    private static func capture(_ window: NSWindow, to output: URL) {
      guard let frameView = window.contentView?.superview,
        let representation = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
      else { return }
      let zoom = window.standardWindowButton(.zoomButton)
      let lights = zoom.map { $0.convert($0.bounds, to: nil) } ?? .zero
      print("window \(window.frame.size), content layout \(window.contentLayoutRect.size)")
      print("title bar height \(window.frame.height - window.contentLayoutRect.height)")
      print("zoom button \(lights) (window coordinates, origin bottom left)")
      print(
        "transparent title bar \(window.titlebarAppearsTransparent), "
          + "toolbar visible \(window.toolbar?.isVisible ?? false), "
          + "close button hidden \(window.standardWindowButton(.closeButton)?.isHidden ?? true)")
      frameView.cacheDisplay(in: frameView.bounds, to: representation)
      if let png = representation.representation(using: .png, properties: [:]) {
        try? png.write(to: output, options: .atomic)
      }
    }
  }

  private enum ScreenshotError: LocalizedError {
    case expectedOutputPath
    case renderFailed

    var errorDescription: String? {
      switch self {
      case .expectedOutputPath: "Pass one screenshot output path."
      case .renderFailed: "SwiftUI could not render the screenshot."
      }
    }
  }
#endif
