import AVFoundation
import CoreImage
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VideoLutPlugin") {
      VideoLutPlugin.register(with: registrar)
    }
  }
}

/// Bakes a 3D LUT into a recorded clip (AF-Log encoding and/or a look).
/// Mirrors the Android Media3 implementation in MainActivity.kt.
class VideoLutPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "auto_frame/video_lut", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VideoLutPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(true)
    case "bake":
      bake(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func bake(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let input = args["input"] as? String,
      let output = args["output"] as? String,
      let size = args["size"] as? Int,
      let typed = args["data"] as? FlutterStandardTypedData
    else {
      result(FlutterError(code: "bad_args", message: "input, output, size, data required", details: nil))
      return
    }

    // .cube order (red fastest) matches CIColorCube; expand RGB -> RGBA.
    let count = size * size * size
    var rgba = [Float](repeating: 1, count: count * 4)
    typed.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let floats = raw.bindMemory(to: Float32.self)
      guard floats.count >= count * 3 else { return }
      for i in 0..<count {
        rgba[i * 4] = floats[i * 3]
        rgba[i * 4 + 1] = floats[i * 3 + 1]
        rgba[i * 4 + 2] = floats[i * 3 + 2]
      }
    }
    let cubeData = rgba.withUnsafeBufferPointer { Data(buffer: $0) }

    guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
      result(FlutterError(code: "no_filter", message: "CIColorCubeWithColorSpace unavailable", details: nil))
      return
    }
    filter.setValue(size, forKey: "inputCubeDimension")
    filter.setValue(cubeData, forKey: "inputCubeData")
    filter.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")

    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    let composition = AVMutableVideoComposition(asset: asset) { request in
      let source = request.sourceImage.clampedToExtent()
      filter.setValue(source, forKey: kCIInputImageKey)
      let out = filter.outputImage?.cropped(to: request.sourceImage.extent) ?? request.sourceImage
      request.finish(with: out, context: nil)
    }

    let outURL = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: outURL)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
    else {
      result(FlutterError(code: "export_failed", message: "Could not create export session", details: nil))
      return
    }
    export.videoComposition = composition
    export.outputURL = outURL
    export.outputFileType = .mov
    export.exportAsynchronously {
      DispatchQueue.main.async {
        if export.status == .completed {
          result(output)
        } else {
          result(FlutterError(
            code: "export_failed",
            message: export.error?.localizedDescription ?? "Export failed",
            details: nil))
        }
      }
    }
  }
}
