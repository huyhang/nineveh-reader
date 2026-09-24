import SwiftUI

/// Where the window's own buttons sit in the row the reader's toolbar shares
/// with them.
struct TitleRowMetrics: Equatable {
  /// How far in the reader's controls start, clear of the window buttons.
  let leadingInset: CGFloat
  /// How far below the window's top edge the buttons are centred.
  let centerY: CGFloat

  var height: CGFloat { centerY * 2 }

  /// A window's title bar without a toolbar, until the window says otherwise.
  static let standard = TitleRowMetrics(leadingInset: 77, centerY: 16)
}

#if os(macOS)
  import AppKit

  /// Gives the reader the window's title bar while it is open. The library's
  /// toolbar is set aside, the reader's controls take the row beside the
  /// window buttons, and the buttons come and go with those controls. It is
  /// all put back when the reader closes.
  ///
  /// SwiftUI's own way of hiding the toolbar keeps its height and hides the
  /// window buttons with it, which leaves an empty band above the reader.
  struct ReaderWindowChrome: NSViewRepresentable {
    let controlsVisible: Bool
    let isFullScreen: Bool
    let onMeasure: (TitleRowMetrics?) -> Void

    func makeNSView(context: Context) -> WindowChromeView {
      WindowChromeView()
    }

    func updateNSView(_ view: WindowChromeView, context: Context) {
      view.onMeasure = onMeasure
      view.update(controlsVisible: controlsVisible, isFullScreen: isFullScreen)
    }

    static func dismantleNSView(_ view: WindowChromeView, coordinator: ()) {
      view.release()
    }
  }

  final class WindowChromeView: NSView {
    var onMeasure: (TitleRowMetrics?) -> Void = { _ in }
    private weak var claimedWindow: NSWindow?
    private var saved: SavedChrome?
    private var controlsVisible = true
    private var isFullScreen = false
    private var reported: TitleRowMetrics??

    private struct SavedChrome {
      let toolbarVisible: Bool
      let transparent: Bool
      let titleVisibility: NSWindow.TitleVisibility
    }

    private static let buttonTypes: [NSWindow.ButtonType] = [
      .closeButton, .miniaturizeButton, .zoomButton,
    ]

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      claim(window)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow !== claimedWindow { release() }
      super.viewWillMove(toWindow: newWindow)
    }

    func update(controlsVisible: Bool, isFullScreen: Bool) {
      let changed = controlsVisible != self.controlsVisible || isFullScreen != self.isFullScreen
      self.controlsVisible = controlsVisible
      self.isFullScreen = isFullScreen
      guard let window = claimedWindow else { return }
      // Something may have brought the toolbar back since.
      if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
      if changed { showButtons(in: window, animated: true) }
      measure(window)
    }

    /// Puts the window back as the library had it. Safe to call more than once.
    func release() {
      guard let window = claimedWindow, let saved else { return }
      for type in Self.buttonTypes {
        guard let button = window.standardWindowButton(type) else { continue }
        button.isHidden = false
        button.alphaValue = 1
      }
      window.toolbar?.isVisible = saved.toolbarVisible
      window.titlebarAppearsTransparent = saved.transparent
      window.titleVisibility = saved.titleVisibility
      // The title bar's separator comes back where the shorter title bar ended,
      // across the toolbar, and AppKit moves it only when the window resizes.
      // A resize undone before anything draws puts it back under the toolbar.
      if !window.styleMask.contains(.fullScreen) {
        let frame = window.frame
        var nudged = frame
        nudged.size.height += 1
        window.setFrame(nudged, display: false)
        window.setFrame(frame, display: true)
      }
      claimedWindow = nil
      self.saved = nil
    }

    private func claim(_ window: NSWindow) {
      guard claimedWindow !== window else { return }
      release()
      claimedWindow = window
      saved = SavedChrome(
        toolbarVisible: window.toolbar?.isVisible ?? false,
        transparent: window.titlebarAppearsTransparent,
        titleVisibility: window.titleVisibility)
      window.toolbar?.isVisible = false
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      showButtons(in: window, animated: false)
      // The buttons settle into the shorter title bar on the next pass.
      DispatchQueue.main.async { [weak self] in
        guard let self, let window = self.claimedWindow else { return }
        self.measure(window)
      }
    }

    /// The buttons follow the reader's controls in a window; in full screen
    /// they are the system's to show.
    private func showButtons(in window: NSWindow, animated: Bool) {
      let visible = controlsVisible || isFullScreen
      for type in Self.buttonTypes {
        guard let button = window.standardWindowButton(type) else { continue }
        if visible { button.isHidden = false }
        guard animated else {
          button.alphaValue = visible ? 1 : 0
          button.isHidden = !visible
          continue
        }
        NSAnimationContext.runAnimationGroup { context in
          context.duration = visible ? 0.18 : 0.25
          button.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
          MainActor.assumeIsolated {
            // A button that faded out still takes clicks until it is hidden.
            guard let self, self.claimedWindow === window else { return }
            if !(self.controlsVisible || self.isFullScreen) { button.isHidden = true }
          }
        }
      }
    }

    private func measure(_ window: NSWindow) {
      var metrics: TitleRowMetrics?
      if !isFullScreen, let frame = window.contentView?.superview,
        let close = window.standardWindowButton(.closeButton),
        let zoom = window.standardWindowButton(.zoomButton)
      {
        let closeFrame = close.convert(close.bounds, to: frame)
        let zoomFrame = zoom.convert(zoom.bounds, to: frame)
        let centerY = frame.isFlipped ? closeFrame.midY : frame.bounds.height - closeFrame.midY
        metrics = TitleRowMetrics(
          leadingInset: (zoomFrame.maxX + 14).rounded(), centerY: centerY.rounded())
      }
      guard reported != .some(metrics) else { return }
      reported = .some(metrics)
      let onMeasure = onMeasure
      // Reported after this update, not during it.
      DispatchQueue.main.async { onMeasure(metrics) }
    }
  }
#endif
