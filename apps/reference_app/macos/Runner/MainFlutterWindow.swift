import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Held for as long as the window lives. Without it macOS naps an app whose
  /// window is not in front and runs its timers late — and sealed letters are
  /// found on a schedule: a look every few seconds to every fifteen minutes,
  /// and a journal line every thirty seconds that says the app is on. The Mac
  /// itself may still go to sleep when it is idle.
  private var scheduleActivity: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    scheduleActivity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "sealed letters are looked for on a schedule")

    super.awakeFromNib()
  }
}
