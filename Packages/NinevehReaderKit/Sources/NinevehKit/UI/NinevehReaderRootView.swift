import NinevehCore
import SwiftUI

public struct NinevehReaderRootView: View {
  @ObservedObject private var model: ApplicationModel
  private let initiallyShowsOrganizedBrowse: Bool
  private let initiallyShowsPrivateCollection: Bool

  public init(
    model: ApplicationModel, initiallyShowsOrganizedBrowse: Bool = false,
    initiallyShowsPrivateCollection: Bool = false
  ) {
    self.model = model
    self.initiallyShowsOrganizedBrowse = initiallyShowsOrganizedBrowse
    self.initiallyShowsPrivateCollection = initiallyShowsPrivateCollection
  }

  public var body: some View {
    ZStack {
      Group {
        switch model.phase {
        case .restoring:
          ProgressView("Opening your library…")
            #if os(macOS)
              .frame(minWidth: 720, minHeight: 520)
            #endif
        case .signedOut:
          SignInView(model: model)
        case .ready:
          LibraryShellView(
            model: model,
            initiallyShowsOrganizedBrowse: initiallyShowsOrganizedBrowse,
            initialSection: initiallyShowsPrivateCollection ? .privateCollection : nil
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
    // Plex's look is dark only, and gold where the system would be blue.
    .preferredColorScheme(.dark)
    .tint(ReaderTheme.accent)
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
  #if os(macOS)
    @State private var server = "http://127.0.0.1:8081"
  #else
    // An iPad has no Nineveh of its own for localhost to reach.
    @State private var server = ""
  #endif
  @State private var username = ""
  @State private var password = ""

  var body: some View {
    ZStack {
      QuietBackground()
      VStack(spacing: 24) {
        VStack(spacing: 10) {
          Wordmark(size: 40)
          Text("Your library, wherever you left off.")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(ReaderTheme.secondaryText)
        }

        VStack(spacing: 14) {
          Group {
            TextField("Server", text: $server)
              .textContentType(.URL)
              #if os(iOS)
                .keyboardType(.URL)
              #endif
            TextField("Username", text: $username)
              .textContentType(.username)
          }
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          #endif
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
          .buttonStyle(.accent)
          .disabled(model.isRefreshing || username.isEmpty || password.isEmpty)

          Button("Browse \(LibrarySection.onDevice.title)") {
            model.continueOffline()
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        #if os(macOS)
          .frame(width: 340)
        #else
          .frame(maxWidth: 340)
        #endif

        Text("Remote connections require HTTPS. Localhost HTTP is permitted.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
      .padding(48)
    }
    #if os(macOS)
      .frame(minWidth: 720, minHeight: 520)
    #endif
  }
}
