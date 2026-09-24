import NinevehCore
import SwiftUI

public struct NinevehReaderRootView: View {
  @ObservedObject private var model: ApplicationModel
  private let initiallyShowsOrganizedBrowse: Bool

  public init(model: ApplicationModel, initiallyShowsOrganizedBrowse: Bool = false) {
    self.model = model
    self.initiallyShowsOrganizedBrowse = initiallyShowsOrganizedBrowse
  }

  public var body: some View {
    ZStack {
      Group {
        switch model.phase {
        case .restoring:
          ProgressView("Opening your library…")
            .frame(minWidth: 720, minHeight: 520)
        case .signedOut:
          SignInView(model: model)
        case .ready:
          LibraryShellView(
            model: model,
            initiallyShowsOrganizedBrowse: initiallyShowsOrganizedBrowse
          )
        }
      }
      // The library stays mounted beneath the reader so its section, search and navigation are
      // where the reader left them, but it must not take focus or clicks while covered.
      .disabled(model.presentedReader != nil)
      .accessibilityHidden(model.presentedReader != nil)

      if let destination = model.presentedReader {
        ReaderView(destination: destination) { model.presentedReader = nil }
          .id(destination.id)
      }
    }
    // The reader takes the window's title bar itself; see ReaderWindowChrome.
    .task {
      if model.phase == .restoring { await model.restore() }
    }
    .alert(
      "Nineveh Reader",
      isPresented: Binding(
        get: { model.alertMessage != nil },
        set: { if !$0 { model.alertMessage = nil } }
      ),
      actions: { Button("OK") { model.alertMessage = nil } },
      message: { Text(model.alertMessage ?? "") }
    )
  }
}

private struct SignInView: View {
  @ObservedObject var model: ApplicationModel
  @State private var server = "http://127.0.0.1:8081"
  @State private var username = ""
  @State private var password = ""

  var body: some View {
    ZStack {
      QuietBackground()
      VStack(spacing: 24) {
        Image(systemName: "books.vertical.fill")
          .font(.system(size: 40, weight: .medium))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)

        VStack(spacing: 7) {
          Text("Nineveh Reader")
            .font(.largeTitle.weight(.semibold))
          Text("Your library, wherever you left off.")
            .foregroundStyle(.secondary)
        }

        VStack(spacing: 14) {
          TextField("Server", text: $server)
            .textContentType(.URL)
          TextField("Username", text: $username)
            .textContentType(.username)
          SecureField("Password", text: $password)
            .textContentType(.password)

          Button {
            Task { await model.signIn(server: server, username: username, password: password) }
          } label: {
            if model.isRefreshing {
              ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else {
              Text("Sign In").frame(maxWidth: .infinity)
            }
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(model.isRefreshing || username.isEmpty || password.isEmpty)

          Button("Browse On My Mac") {
            model.continueOffline()
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .frame(width: 340)

        Text("Remote connections require HTTPS. Localhost HTTP is permitted.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(48)
    }
    .frame(minWidth: 720, minHeight: 520)
  }
}
