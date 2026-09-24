import AVFoundation
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
    if call.method == "readVideoLetterSource" {
      VideoLetterSourceReader.read(call, result: result)
      return
    }
    if call.method == "playPcm" {
      LetterPcmPlayer.play(call, result: result)
      return
    }
    if call.method == "stopPcm" {
      LetterPcmPlayer.stop()
      result(nil)
      return
    }
    if call.method == "videoDuration" {
      VideoLetterSourceReader.duration(call, result: result)
      return
    }
    if call.method == "readVideoStills" {
      VideoLetterSourceReader.stills(call, result: result)
      return
    }
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

/// The phone-authored video letter's source reader (2026-09-21): one
/// AVAssetReader pass over a clip the system camera recorded, scaled onto
/// the letter's frame (144x256 portrait, preferredTransform applied first
/// so a portrait take is upright; a landscape take is squashed, never
/// cropped), decimated to the letter's fps by presentation time, written
/// as tightly packed I420 (limited range, the wire's BT.601 assumption) —
/// and the audio mixed down to s16le 8 kHz mono for the Opus tail. Dart
/// then encodes with the vendored SVT-AV1 over FFI.
///
/// Arguments: path, width, height, fps, seconds. Result: {frames: <i420
/// path>, count: <frames written>, audio: <s16le path>}.
enum VideoLetterSourceReader {
  /// The clip's length in seconds, for the trim window (2026-09-23).
  static func duration(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let a = call.arguments as? [String: Any] ?? [:]
    guard let path = a["path"] as? String else {
      result(FlutterError(code: "args", message: "path", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      let track = asset.tracks(withMediaType: .video).first
      let s = track?.timeRange.end.seconds ?? asset.duration.seconds
      DispatchQueue.main.async { result(s.isFinite ? s : 0) }
    }
  }

  /// The page band's source (2026-09-23): full-resolution frames at the
  /// asked times, drawn onto width x height (the same squash the motion
  /// band uses, so page and motion line up) and written as packed RGBA.
  /// Exact times, not the nearest keyframe: the sharpest frame is chosen
  /// in Dart by Laplacian variance.
  /// Arguments: path, times [seconds], width, height.
  /// Result: {rgba: <path>, count: <frames written>}.
  static func stills(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let a = call.arguments as? [String: Any] ?? [:]
    guard let path = a["path"] as? String, let times = a["times"] as? [Double],
      let w = a["width"] as? Int, let h = a["height"] as? Int
    else {
      result(FlutterError(code: "args", message: "path times width height", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("video_letter_stills.rgba")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        var count = 0
        let space = CGColorSpaceCreateDeviceRGB()
        for t in times {
          let img = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
          var buf = [UInt8](repeating: 0, count: w * h * 4)
          guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
          else { continue }
          ctx.interpolationQuality = .high
          ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
          fh.write(Data(buf))
          count += 1
        }
        try fh.close()
        DispatchQueue.main.async { result(["rgba": url.path, "count": count]) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "stills", message: "\(error)", details: nil))
        }
      }
    }
  }

  static func read(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let a = call.arguments as? [String: Any] ?? [:]
    guard let path = a["path"] as? String,
      let w = a["width"] as? Int, let h = a["height"] as? Int,
      let fps = a["fps"] as? Int, let secs = a["seconds"] as? Double
    else {
      result(FlutterError(code: "args", message: "path width height fps seconds", details: nil))
      return
    }
    let audioRate = (a["audioRate"] as? Int) ?? 8000
    // The window the person chose in a longer clip (2026-09-23): the reader
    // starts there; every timestamp below is relative to the asset.
    let start = (a["start"] as? Double) ?? 0
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let vt = asset.tracks(withMediaType: .video).first else {
          throw NSError(domain: "video", code: 1, userInfo: [NSLocalizedDescriptionKey: "no video track"])
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
          start: CMTime(seconds: start, preferredTimescale: 600),
          end: CMTime(seconds: start + secs, preferredTimescale: 600))
        // Rendered at 2x and box-averaged to w x h below: the compositor's
        // single-step 7.5x downscale aliased sensor noise straight into
        // the encoder (the most expensive thing AV1 can be asked to keep);
        // an area filter plus a temporal blend on Y is the phone's cheap
        // stand-in for the Mac's atadenoise/hqdn3d chain (2026-09-22).
        let w2 = w * 2, h2 = h * 2
        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: w2, height: h2)
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let up = vt.naturalSize.applying(vt.preferredTransform)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
        layer.setTransform(
          vt.preferredTransform.concatenating(
            CGAffineTransform(scaleX: CGFloat(w2) / abs(up.width), y: CGFloat(h2) / abs(up.height))),
          at: .zero)
        let instr = AVMutableVideoCompositionInstruction()
        // The track's own range, not asset.duration: a lazily loaded asset
        // answers an indefinite duration and the composition is then
        // "invalid" (AVFoundationErrorDomain -11841, seen on the phone
        // 2026-09-22); the instruction must cover the reader's whole range.
        let trackRange = vt.timeRange
        let coverEnd = max(
          trackRange.end.seconds.isFinite ? trackRange.end.seconds : 0, start + secs + 1)
        instr.timeRange = CMTimeRange(
          start: .zero, end: CMTime(seconds: coverEnd, preferredTimescale: 600))
        instr.layerInstructions = [layer]
        comp.instructions = [instr]
        let vout = AVAssetReaderVideoCompositionOutput(
          videoTracks: [vt],
          videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
          ])
        vout.videoComposition = comp
        vout.alwaysCopiesSampleData = false
        reader.add(vout)
        var aout: AVAssetReaderAudioMixOutput? = nil
        let at = asset.tracks(withMediaType: .audio)
        if !at.isEmpty {
          let o = AVAssetReaderAudioMixOutput(
            audioTracks: at,
            audioSettings: [
              AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audioRate,
              AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
              AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
              AVLinearPCMIsNonInterleaved: false,
            ])
          reader.add(o)
          aout = o
        }
        guard reader.startReading() else {
          throw reader.error ?? NSError(domain: "video", code: 2, userInfo: [NSLocalizedDescriptionKey: "reader did not start"])
        }
        let dir = FileManager.default.temporaryDirectory
        let fURL = dir.appendingPathComponent("video_letter.i420")
        let aURL = dir.appendingPathComponent("video_letter.s16le")
        FileManager.default.createFile(atPath: fURL.path, contents: nil)
        FileManager.default.createFile(atPath: aURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: fURL)
        let ah = try FileHandle(forWritingTo: aURL)
        var count = 0
        var next = start
        var prevY = [UInt8]()
        let maxFrames = Int(secs * Double(fps))
        while count < maxFrames, let sb = vout.copyNextSampleBuffer() {
          let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
          if t + 1e-6 < next { continue }  // decimate by pts, whatever cadence came out
          next += 1.0 / Double(fps)
          guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
          CVPixelBufferLockBaseAddress(pb, .readOnly)
          var out = Data(capacity: w * h * 3 / 2)
          let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
          let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
          // Y: 2x2 box average, then a temporal blend with the previous
          // frame where the pixel barely moved (|d| <= 12) — atadenoise-like.
          var y = [UInt8](repeating: 0, count: w * h)
          let havePrev = prevY.count == w * h
          for r in 0..<h {
            let r0 = 2 * r * ys, r1 = (2 * r + 1) * ys
            for c in 0..<w {
              let c0 = 2 * c
              let s = Int(yb[r0 + c0]) + Int(yb[r0 + c0 + 1]) + Int(yb[r1 + c0]) + Int(yb[r1 + c0 + 1])
              var v = (s + 2) >> 2
              if havePrev {
                let q = Int(prevY[r * w + c])
                if abs(v - q) <= 12 { v = (v + q + 1) >> 1 }
              }
              y[r * w + c] = UInt8(v)
            }
          }
          prevY = y
          out.append(contentsOf: y)
          // Chroma: plane 1 is w x h interleaved CbCr at 2x; 2x2 box to w/2 x h/2.
          let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
          let cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
          var u = [UInt8](repeating: 0, count: w * h / 4)
          var v = u  // NV12 -> I420
          for r in 0..<(h / 2) {
            let r0 = 2 * r * cs, r1 = (2 * r + 1) * cs
            for c in 0..<(w / 2) {
              let c0 = 4 * c
              let su = Int(cb[r0 + c0]) + Int(cb[r0 + c0 + 2]) + Int(cb[r1 + c0]) + Int(cb[r1 + c0 + 2])
              let sv = Int(cb[r0 + c0 + 1]) + Int(cb[r0 + c0 + 3]) + Int(cb[r1 + c0 + 1]) + Int(cb[r1 + c0 + 3])
              u[r * (w / 2) + c] = UInt8((su + 2) >> 2)
              v[r * (w / 2) + c] = UInt8((sv + 2) >> 2)
            }
          }
          out.append(contentsOf: u)
          out.append(contentsOf: v)
          CVPixelBufferUnlockBaseAddress(pb, .readOnly)
          fh.write(out)
          count += 1
        }
        while let sb = aout?.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
          var len = 0
          var p: UnsafeMutablePointer<Int8>? = nil
          CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &p)
          if let p = p { ah.write(Data(bytes: p, count: len)) }
        }
        try fh.close()
        try ah.close()
        DispatchQueue.main.async { result(["frames": fURL.path, "count": count, "audio": aURL.path]) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "read", message: "\(error)", details: nil))
        }
      }
    }
  }
}

/// The basic letter player's sound (2026-09-24): s16le mono PCM at the
/// letter's own rate, through AVAudioEngine — part of iOS, no plugin. The
/// session is play-and-record so the microphone keeps working afterwards.
enum LetterPcmPlayer {
  static var engine: AVAudioEngine?
  static var node: AVAudioPlayerNode?

  static func stop() {
    node?.stop()
    engine?.stop()
    node = nil
    engine = nil
  }

  static func play(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let a = call.arguments as? [String: Any] ?? [:]
    guard let path = a["path"] as? String, let rate = a["rate"] as? Int, rate > 0 else {
      result(FlutterError(code: "args", message: "path rate", details: nil))
      return
    }
    do {
      stop()
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      let frames = data.count / 2
      guard frames > 0,
        let fmt = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))
      else {
        result(0.0)
        return
      }
      buf.frameLength = AVAudioFrameCount(frames)
      data.withUnsafeBytes { raw in
        let s = raw.bindMemory(to: Int16.self)
        let dst = buf.floatChannelData![0]
        for i in 0..<frames { dst[i] = Float(s[i]) / 32768.0 }
      }
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
      try session.setActive(true)
      let e = AVAudioEngine()
      let n = AVAudioPlayerNode()
      e.attach(n)
      e.connect(n, to: e.mainMixerNode, format: fmt)
      try e.start()
      n.scheduleBuffer(buf, completionHandler: nil)
      n.play()
      engine = e
      node = n
      result(Double(frames) / Double(rate))
    } catch {
      result(FlutterError(code: "play", message: "\(error)", details: nil))
    }
  }
}
