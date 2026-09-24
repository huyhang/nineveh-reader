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
          Task { await model.addLocalFiles([url], kind: .external) }
        }
    }
    // The library's top bar is the toolbar, with the window's buttons in it.
    .windowToolbarStyle(.unified(showsTitle: false))
    .defaultSize(width: 1180, height: 780)
    .windowResizability(.contentMinSize)
    .commands {
      LibraryCommands(model: model)
    }
  }
}
