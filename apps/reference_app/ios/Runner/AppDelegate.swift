import Flutter
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Held for the process lifetime: the channel handler must outlive the
  /// call that registered it.
  private var photoFallback: PhotoLetterFallbackPicker?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    photoFallback = PhotoLetterFallbackPicker(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
  }
}

/// The second way to choose a photo letter, used only after `image_picker`
/// has already refused one.
///
/// Why this exists at all. `image_picker_ios` 0.8.13+6 builds its
/// `PHPickerConfiguration` with
/// `preferredAssetRepresentationMode = ...ModeCurrent`
/// (`FLTImagePickerPlugin.m:104`) and then asks the chosen item for
/// `public.image` data (`FLTPHPickerSaveImageToPathOperation.m:92-95`).
/// "Current" means *do not transcode*, so `public.image` resolves to the
/// asset's own native type — `public.heic` for anything the camera wrote —
/// and `NSItemProvider` fails outright when that exact representation cannot
/// be produced, which is what an iCloud asset whose original is not on the
/// device does. The plugin turns that into
/// `invalid_image / Cannot load representation of type public.heic /
/// NSItemProviderErrorDomain`, which is the banner the phone showed. That
/// line arrived in 0.8.13+3 as a *video* fix ("request the original asset to
/// avoid conversion"); the newest published version, 0.8.13+7, changes only
/// a dev dependency, so there is nothing to upgrade to.
///
/// This picker asks for the opposite: `.compatible`, the most widely
/// readable representation, which is what the letter wants anyway — the
/// bytes are re-encoded to a JPEG of at most
/// `photoLetterMaxBytes` a moment later, so the HEIC original was never of
/// any use. It also reads through `loadObject(ofClass: UIImage.self)`, which
/// lets the system derive the image from whatever representation it does
/// have instead of insisting on one name.
///
/// Deliberately second and not first: the plugin's path is the one that has
/// shipped, and a photo it can read must keep being read by it. This runs
/// only when that path threw, so the worst case is unchanged from today.
final class PhotoLetterFallbackPicker: NSObject {
  /// Must match `photoLetterFallbackChannel` in photo_letter_picker.dart.
  static let channelName = "com.tlscodes.reference_app/photo_letter_fallback"

  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?
  private var maxEdge: CGFloat = 1600
  private var quality: CGFloat = 0.85

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: PhotoLetterFallbackPicker.channelName,
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "pickCompatibleImage" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard #available(iOS 14.0, *) else {
      result(
        FlutterError(
          code: "unsupported",
          message: "The compatible picker needs iOS 14 or newer.",
          details: nil
        ))
      return
    }
    // A pick already on screen is never replaced by a second one — the rule
    // the Dart side learned with two live microphones.
    if pending != nil {
      result(
        FlutterError(
          code: "busy",
          message: "A photo picker is already open.",
          details: nil
        ))
      return
    }
    guard let host = PhotoLetterFallbackPicker.topViewController() else {
      result(
        FlutterError(
          code: "no_window",
          message: "There is no visible screen to open the picker from.",
          details: nil
        ))
      return
    }

    let arguments = call.arguments as? [String: Any] ?? [:]
    if let edge = (arguments["maxEdge"] as? NSNumber)?.doubleValue, edge > 0 {
      maxEdge = CGFloat(edge)
    }
    if let percent = (arguments["quality"] as? NSNumber)?.doubleValue,
      percent > 0, percent <= 100
    {
      quality = CGFloat(percent / 100.0)
    }

    // No photo library handed to the configuration on purpose: that is the
    // out-of-process picker, which needs no photo-library permission at all
    // and materialises the data inside the Photos extension.
    var configuration = PHPickerConfiguration()
    configuration.selectionLimit = 1
    configuration.filter = .images
    configuration.preferredAssetRepresentationMode = .compatible

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    pending = result
    host.present(picker, animated: true)
  }

  /// Answers the waiting Dart call exactly once.
  ///
  /// The hop to the main thread is not politeness: `NSItemProvider` calls its
  /// completion handlers on whatever queue it likes, and `pending` is the one
  /// piece of state that decides whether this call has already been answered.
  /// Reading and clearing it in exactly one place, on one thread, is what
  /// makes "exactly once" true rather than likely.
  private func settle(_ value: Any?) {
    let deliver = { [weak self] in
      guard let self = self, let result = self.pending else { return }
      self.pending = nil
      result(value)
    }
    if Thread.isMainThread {
      deliver()
    } else {
      DispatchQueue.main.async(execute: deliver)
    }
  }

  private func settle(image: UIImage) {
    guard let data = uprightJpeg(image) else {
      settle(
        FlutterError(
          code: "unreadable",
          message: "That picture could not be re-encoded.",
          details: nil
        ))
      return
    }
    settle(FlutterStandardTypedData(bytes: data))
  }

  /// Redraws [image] the right way up and no longer than [maxEdge] on its
  /// long side, then encodes it. Drawing is what bakes the EXIF rotation in:
  /// handing `jpegData` a sideways `UIImage` would send the Dart ladder a
  /// picture that arrives on its ear.
  private func uprightJpeg(_ image: UIImage) -> Data? {
    let size = image.size
    let longest = max(size.width, size.height)
    guard longest > 0 else { return nil }
    let scale = longest > maxEdge ? maxEdge / longest : 1
    let target = CGSize(
      width: max(1, (size.width * scale).rounded()),
      height: max(1, (size.height * scale).rounded())
    )
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    let redrawn = UIGraphicsImageRenderer(size: target, format: format).image { context in
      // JPEG has no alpha, and an opaque context starts black: a screenshot
      // with a transparent corner would otherwise gain one.
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: target))
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return redrawn.jpegData(compressionQuality: quality)
  }

  /// The data path, tried when the system would not hand over a `UIImage`.
  /// Only types this build can certainly decode are asked for by name.
  private func loadData(from provider: NSItemProvider, after failure: Error?) {
    let wanted: [String]
    if #available(iOS 14.0, *) {
      wanted = [UTType.jpeg.identifier, UTType.png.identifier]
    } else {
      wanted = ["public.jpeg", "public.png"]
    }
    guard
      let identifier = wanted.first(where: provider.hasItemConformingToTypeIdentifier)
    else {
      settle(
        FlutterError(
          code: "unreadable",
          message: failure?.localizedDescription
            ?? "That photo is not stored in a format this app can read.",
          details: provider.registeredTypeIdentifiers.joined(separator: ", ")
        ))
      return
    }
    provider.loadDataRepresentation(forTypeIdentifier: identifier) { [weak self] data, error in
      guard let self = self else { return }
      if let data = data, let image = UIImage(data: data) {
        self.settle(image: image)
        return
      }
      self.settle(
        FlutterError(
          code: "unreadable",
          message: (error ?? failure)?.localizedDescription
            ?? "That photo could not be read.",
          details: identifier
        ))
    }
  }

  /// The frontmost view controller, found without `UIWindowScene.keyWindow`
  /// — this target still deploys to iOS 13, where that property does not
  /// exist.
  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    // Front scene first, without a sort: a predicate that is not a strict
    // ordering is a trap in Swift's sort, and "is this one active" is not one.
    let ordered =
      scenes.filter { $0.activationState == .foregroundActive }
      + scenes.filter { $0.activationState != .foregroundActive }
    let windows = ordered.flatMap { $0.windows }
    var top = (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?.rootViewController
    while let next = top?.presentedViewController, !next.isBeingDismissed {
      top = next
    }
    return top
  }
}

@available(iOS 14.0, *)
extension PhotoLetterFallbackPicker: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let provider = results.first?.itemProvider else {
      // Backed out: null, not an error — the Dart side says "no photo was
      // chosen" for exactly this.
      settle(nil)
      return
    }
    guard provider.canLoadObject(ofClass: UIImage.self) else {
      loadData(from: provider, after: nil)
      return
    }
    provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
      guard let self = self else { return }
      if let image = object as? UIImage {
        self.settle(image: image)
        return
      }
      self.loadData(from: provider, after: error)
    }
  }
}
