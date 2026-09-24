import NinevehKit
import SwiftUI

@main
struct NinevehReaderApp: App {
  @StateObject private var model: ApplicationModel

  init() {
    let isPreview = ProcessInfo.processInfo.arguments.contains("--demo-catalog")
    _model = StateObject(wrappedValue: isPreview ? .preview() : .live())
  }

  var body: some Scene {
    WindowGroup {
      NinevehReaderRootView(model: model)
        .onOpenURL { url in
          #if os(macOS)
            Task { await model.addLocalFiles([url], kind: .external) }
          #else
            // A book shared from another app arrives as a copy in the inbox,
            // which the library imports rather than leaving where it landed.
            Task {
              await model.addLocalFiles([url], kind: .imported)
              if url.path(percentEncoded: false).contains("/Documents/Inbox/") {
                try? FileManager.default.removeItem(at: url)
              }
            }
          #endif
        }
    }
    #if os(macOS)
      // The library's top bar is the toolbar, with the window's buttons in it.
      .windowToolbarStyle(.unified(showsTitle: false))
      .defaultSize(width: 1180, height: 780)
      .windowResizability(.contentMinSize)
    #endif
    .commands {
      LibraryCommands(model: model)
    }
  }
}
