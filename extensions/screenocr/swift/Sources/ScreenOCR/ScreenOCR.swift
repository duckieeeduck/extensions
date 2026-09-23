import Cocoa
import RaycastSwiftMacros
import ScreenCaptureKit
import Vision

/// Result returned to TypeScript. `status` is "recognized", "cancelled" or "error".
/// A cancelled selection or a failure never arrives as text, so it cannot be
/// copied to the clipboard or returned to another extension as a result.
struct CaptureOutcome: Encodable {
  let status: String
  let text: String?
  let message: String?

  static func recognized(_ text: String) -> CaptureOutcome {
    CaptureOutcome(status: "recognized", text: text, message: nil)
  }

  static var cancelled: CaptureOutcome {
    CaptureOutcome(status: "cancelled", text: nil, message: nil)
  }

  static func error(_ message: String) -> CaptureOutcome {
    CaptureOutcome(status: "error", text: nil, message: message)
  }
}

enum SelectedArea {
  case image(CGImage)
  case cancelled
  case failed
}

@raycast
func recognizeText(
  fullscreen: Bool,
  keepImage: Bool,
  fast: Bool,
  languageCorrection: Bool,
  ignoreLineBreaks: Bool,
  customWordsList: [String],
  languages: [String],
  playSound: Bool
) async -> CaptureOutcome {
  let capturedImage: CGImage
  if fullscreen {
    guard let image = await captureScreen(keepImage: keepImage) else {
      return .error("Failed to capture the screen")
    }
    capturedImage = image
  } else {
    switch captureSelectedArea(keepImage: keepImage, playSound: playSound) {
    case .image(let image): capturedImage = image
    case .cancelled: return .cancelled
    case .failed: return .error("Failed to capture the selected area")
    }
  }

  var request = RecognizeTextRequest()
  request.recognitionLevel = fast ? .fast : .accurate
  request.usesLanguageCorrection = languageCorrection
  request.customWords = customWordsList
  request.recognitionLanguages = (languages.isEmpty ? ["en-US"] : languages)
    .map { Locale.Language(identifier: $0) }

  do {
    let observations = try await silencingStdout {
      try await request.perform(on: capturedImage)
    }
    let separator = ignoreLineBreaks ? " " : "\n"
    return .recognized(
      observations
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: separator)
    )
  } catch {
    return .error(error.localizedDescription)
  }
}

@raycast
func detectBarcode(keepImage: Bool, playSound: Bool) async -> CaptureOutcome {
  let capturedImage: CGImage
  switch captureSelectedArea(keepImage: keepImage, playSound: playSound) {
  case .image(let image): capturedImage = image
  case .cancelled: return .cancelled
  case .failed: return .error("Failed to capture the selected area")
  }

  do {
    let observations = try await silencingStdout {
      try await DetectBarcodesRequest().perform(on: capturedImage)
    }
    // An empty text means no code was found.
    return .recognized(observations.compactMap(\.payloadString).joined(separator: "\n"))
  } catch {
    return .error(error.localizedDescription)
  }
}

func captureScreen(keepImage: Bool) async -> CGImage? {
  guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
    return nil
  }

  let mainDisplayID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
    return nil
  }

  let configuration = SCStreamConfiguration()
  if let mode = CGDisplayCopyDisplayMode(display.displayID) {
    configuration.width = mode.pixelWidth
    configuration.height = mode.pixelHeight
  } else {
    configuration.width = display.width
    configuration.height = display.height
  }
  configuration.showsCursor = false

  let filter = SCContentFilter(display: display, excludingWindows: [])
  guard let image = try? await SCScreenshotManager.captureImage(
    contentFilter: filter, configuration: configuration
  ) else {
    return nil
  }

  if keepImage {
    let pasteboardImage = NSImage(cgImage: image, size: .zero)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([pasteboardImage])
  }

  return image
}

func captureSelectedArea(keepImage: Bool, playSound: Bool) -> SelectedArea {
  let filePath = randomPngPath()
  // Pressing Escape in the selection leaves the clipboard untouched. Comparing the
  // change count keeps a cancelled selection from reading an older clipboard image.
  let clipboardChangeCount = NSPasteboard.general.changeCount
  let task = Process()
  task.launchPath = "/usr/sbin/screencapture"
  var arguments = ["-i"]
  arguments.append(keepImage ? "-c" : filePath)
  if !playSound {
    arguments.append("-x")
  }
  task.arguments = arguments
  task.launch()
  task.waitUntilExit()

  let image: NSImage?
  if keepImage {
    guard NSPasteboard.general.changeCount != clipboardChangeCount else {
      return .cancelled
    }
    guard
      let pasteboard = NSPasteboard.general.pasteboardItems?.first,
      let fileType = pasteboard.types.first,
      let data = pasteboard.data(forType: fileType)
    else {
      return .failed
    }
    image = NSImage(data: data)
  } else {
    defer { try? FileManager.default.removeItem(atPath: filePath) }
    // screencapture writes no file when the selection is cancelled.
    guard FileManager.default.fileExists(atPath: filePath) else {
      return .cancelled
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
      return .failed
    }
    image = NSImage(data: data)
  }

  var proposedRect = NSRect.zero
  guard let cgImage = image?.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
    return .failed
  }
  return .image(cgImage)
}

func randomPngPath() -> String {
  "\(NSTemporaryDirectory())/\(UUID().uuidString).png"
}

// On macOS 26 the Vision text models log to stdout, which the Raycast bridge
// uses to read a command's return value. Mute fd 1 while Vision runs.
func silencingStdout<T>(_ body: () async throws -> T) async rethrows -> T {
  fflush(stdout)
  let original = dup(1)
  let devNull = open("/dev/null", O_WRONLY)
  dup2(devNull, 1)
  close(devNull)
  defer {
    fflush(stdout)
    dup2(original, 1)
    close(original)
  }
  return try await body()
}