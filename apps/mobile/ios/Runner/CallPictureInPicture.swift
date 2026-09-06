import AVKit
import Flutter
import UIKit
import WebRTC
import flutter_webrtc

/// Keeps a call visible in a small window after the user leaves the app.
///
/// Android shrinks the whole activity, so its window shows what the call view
/// draws. iOS does not: `AVPictureInPictureController` owns the window and
/// draws one `AVSampleBufferDisplayLayer`, and the Flutter view is not in it.
/// So exactly one participant's video is copied into that layer, named from
/// Dart through `setVideoTrack`.
///
/// The frames come from the track `flutter_webrtc` already decodes. The plugin
/// hands out its remote tracks (`remoteTrackForId`), so nothing is decoded
/// twice and the picture in the window is the one on the call screen.
final class CallPictureInPicture: NSObject {
  static let channelName = "com.nkshub.nextcloudtalk/call_picture_in_picture"

  private let channel: FlutterMethodChannel
  private weak var host: UIView?

  private var controller: AVPictureInPictureController?
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var sink: TrackSink?
  private var track: RTCVideoTrack?

  init(messenger: FlutterBinaryMessenger, host: UIView) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    self.host = host
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setAvailable":
      result(setAvailable(call.arguments as? Bool ?? false))
    case "setVideoTrack":
      setVideoTrack(call.arguments as? String)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Arms or disarms the window. The answer is whether this device can show
  /// one at all — below iOS 15, or on a device without the feature, the call
  /// screen keeps the app in front instead of promising a window.
  private func setAvailable(_ available: Bool) -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      teardown()
      return false
    }
    guard available else {
      teardown()
      return false
    }
    if controller != nil {
      return true
    }
    guard #available(iOS 15.0, *), let host else {
      return false
    }

    // The layer has to be in the view hierarchy for the system to start the
    // window from it, but it must not cover the Flutter view: one pixel in a
    // corner is enough, and the window scales the frames itself.
    displayLayer.videoGravity = .resizeAspect
    displayLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    if displayLayer.superlayer == nil {
      host.layer.insertSublayer(displayLayer, at: 0)
    }

    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    // What makes the window appear on the home gesture rather than on a
    // button nobody would find.
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    self.controller = controller
    return true
  }

  private func setVideoTrack(_ trackId: String?) {
    guard trackId != track?.trackId else {
      return
    }
    detachTrack()
    guard let trackId,
      let plugin = FlutterWebRTCPlugin.sharedSingleton(),
      let remote = plugin.remoteTrack(forId: trackId) as? RTCVideoTrack
    else {
      return
    }
    let sink = TrackSink(layer: displayLayer)
    remote.add(sink)
    self.sink = sink
    track = remote
  }

  private func detachTrack() {
    if let sink, let track {
      track.remove(sink)
    }
    sink = nil
    track = nil
    displayLayer.flushAndRemoveImage()
  }

  private func teardown() {
    detachTrack()
    controller?.delegate = nil
    controller = nil
    displayLayer.removeFromSuperlayer()
  }
}

extension CallPictureInPicture: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    channel.invokeMethod("modeChanged", arguments: true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    channel.invokeMethod("modeChanged", arguments: false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("[call] picture-in-picture failed to start: %@", error.localizedDescription)
    channel.invokeMethod("modeChanged", arguments: false)
  }
}

/// A live call has no timeline to scrub and no end to seek to, so the playback
/// delegate answers the way a live stream does and ignores every control.
extension CallPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {}

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }
}

/// Copies the track's frames into the display layer.
///
/// Only frames that already carry a `CVPixelBuffer` are forwarded, which on a
/// device is all of them: VideoToolbox decodes into one. An I420 frame from a
/// software decoder is dropped rather than converted — the window would cost
/// more than it is worth if every frame had to be converted on the main path,
/// and the call screen still shows it.
private final class TrackSink: NSObject, RTCVideoRenderer {
  private let layer: AVSampleBufferDisplayLayer

  init(layer: AVSampleBufferDisplayLayer) {
    self.layer = layer
    super.init()
  }

  func setSize(_ size: CGSize) {}

  func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame,
      let buffer = frame.buffer as? RTCCVPixelBuffer,
      let sample = Self.sampleBuffer(from: buffer.pixelBuffer, timestamp: frame.timeStampNs)
    else {
      return
    }
    DispatchQueue.main.async { [layer] in
      if layer.status == .failed {
        layer.flush()
      }
      layer.enqueue(sample)
    }
  }

  private static func sampleBuffer(
    from pixelBuffer: CVPixelBuffer,
    timestamp: Int64
  ) -> CMSampleBuffer? {
    var formatDescription: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      ) == noErr, let formatDescription
    else {
      return nil
    }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(value: timestamp, timescale: 1_000_000_000),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
      ) == noErr, let sampleBuffer
    else {
      return nil
    }

    // Without this the layer holds the first frame back waiting for a clock
    // it will never get.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ) {
      let first = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        first,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    return sampleBuffer
  }
}
