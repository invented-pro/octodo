import Cocoa
import FlutterMacOS

/// `FlutterView`'s `isOpaque` is hardcoded to `YES` in the engine (see
/// `shell/platform/darwin/macos/framework/Source/FlutterView.mm`), so even
/// with `NSWindow.isOpaque = false`, `NSWindow.backgroundColor = .clear`,
/// AND `FlutterViewController.backgroundColor = .clear`, the Flutter
/// view's CALayer still composes as opaque. AppKit sees `isOpaque = YES`
/// and skips the alpha compositing path, replacing the alpha scaffold
/// with whatever was buffered under it (typically the desktop's
/// initial paint or another solid color).
///
/// Subclassing FlutterViewController is the only seam exposed to the
/// Runner: at `viewDidLoad` time the FlutterView + its CALayer exist
/// (they were created in `loadView`), so we can reach in and reset
/// `view.layer.isOpaque = false`. The base class's `setBackgroundColor:`
/// already set `view.layer.backgroundColor = .clear` via the
/// FlutterView subclass, so this is the only missing piece.
class TransparentFlutterViewController: FlutterViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    // The Flutter engine writes opaque pixels (the terminal grid) into
    // the layer via Metal — pixels that AREN'T drawn by the engine
    // remain .clear and composite over the (now non-opaque) NSWindow
    // background and the desktop. That's the desired effect.
    if let layer = self.view.layer {
      layer.isOpaque = false
      // Some engine builds / Metal layers re-assert isOpaque = true
      // on each frame as part of the "direct to display" optimization
      // (see flutter/engine#45994). Re-apply on the next runloop turn
      // so the alpha scaffold is honored on every frame, not just the
      // first. Cost is a single CALayer property write per appearance.
      DispatchQueue.main.async { [weak layer] in
        layer?.isOpaque = false
      }
    }
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = TransparentFlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Window-level transparency so the desktop / native acrylic backdrop
    // can show through when the Flutter scaffold draws at <1.0 alpha.
    // Three things must all be true at the AppKit layer:
    //   1. NSWindow.isOpaque = false (opt out of opaque compositing)
    //   2. NSWindow.backgroundColor = .clear (AppKit-default is opaque)
    //   3. FlutterViewController.backgroundColor = .clear (the
    //      FlutterView's layer.backgroundColor; FlutterView's
    //      isOpaque is hardcoded to YES in the engine — see
    //      TransparentFlutterViewController for the workaround)
    // window_manager re-sets (2) when the user lowers the opacity
    // slider, but pinning it here covers the initial frame.
    self.isOpaque = false
    self.hasShadow = true
    self.backgroundColor = .clear
    flutterViewController.backgroundColor = .clear

    super.awakeFromNib()
  }
}
