// Fork-only reproduction for raycast/extensions#32842. Not for upstream.
// Mirrors performOCR in swift/Sources/ScreenOCR/ScreenOCR.swift: stdout is muted
// only while Vision runs, then the JSON result is printed. Anything else that
// reaches stdout corrupts the result the Raycast bridge reads.
import AppKit
import Foundation
import Vision

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

func makeImage() -> CGImage {
  let size = NSSize(width: 900, height: 160)
  let image = NSImage(size: size)
  image.lockFocus()
  NSColor.white.setFill()
  NSRect(origin: .zero, size: size).fill()
  ("ScreenOCR cold start 12345" as NSString).draw(
    at: NSPoint(x: 20, y: 50),
    withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
  image.unlockFocus()
  var rect = NSRect(origin: .zero, size: size)
  return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
}

@main
struct ColdStart {
  static func main() async {
    let accurate = CommandLine.arguments.contains("--accurate")
    var request = RecognizeTextRequest()
    request.recognitionLevel = accurate ? .accurate : .fast
    request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
    let started = Date()
    do {
      let observations = try await silencingStdout { try await request.perform(on: makeImage()) }
      let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
      print(#"{"status":"recognized","text":"\#(text)"}"#)
    } catch {
      print(#"{"status":"error","message":"\#(error.localizedDescription)"}"#)
    }
    FileHandle.standardError.write("elapsed \(Int(Date().timeIntervalSince(started) * 1000)) ms\n".data(using: .utf8)!)
    // Give late background logging a chance to reach stdout before exit.
    try? await Task.sleep(nanoseconds: 1_500_000_000)
  }
}
