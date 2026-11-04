import CryptoKit
import ExpoModulesCore
import Foundation

final class VoiceException: Exception, @unchecked Sendable {
  private let message: String

  init(_ message: String) {
    self.message = message
    super.init()
  }

  override var reason: String { message }

  override var code: String { "ERR_VOICE" }
}

private func voiceException(_ error: Error, _ prefix: String? = nil) -> Exception {
  if let error = error as? Exception { return error }
  let text = error.localizedDescription
  return VoiceException(prefix.map { "\($0): \(text)" } ?? text)
}

private let PROGRESS_EVERY: TimeInterval = 0.25

/**
 Voice prints for "Only our voices", as on Android (EarbridgeVoiceModule.kt): a small speaker
 model, downloaded once, turns speech into a vector that points the same way for the same
 voice. Everything stays on the phone.
 */
public final class EarbridgeVoiceModule: Module {
  /** Loads the model and makes prints, one at a time. */
  private let prints = DispatchQueue(label: "EarBridge voice prints")
  /** Used on `prints` only. */
  private var printer: SpeakerPrinter?
  private var download: ModelDownload?

  public func definition() -> ModuleDefinition {
    Name("EarbridgeVoice")
    Events("onModelProgress")

    OnDestroy {
      self.download?.cancel()
      self.prints.async { self.printer = nil }
    }

    Function("hasModel") { (file: String) throws -> Bool in
      FileManager.default.fileExists(atPath: try VoiceModels.file(file).path)
    }

    AsyncFunction("downloadModel") { (url: String, sha256: String, file: String) async throws in
      do {
        let target = try VoiceModels.file(file)
        if FileManager.default.fileExists(atPath: target.path) { return }
        guard let source = URL(string: url) else { throw VoiceException("Bad download address.") }
        let download = ModelDownload { [weak self] received, total in
          self?.sendEvent("onModelProgress", ["received": Double(received), "total": Double(max(total, 0))])
        }
        self.download = download
        defer { self.download = nil }
        try await self.fetch(source, sha256.lowercased(), target, download)
      } catch {
        throw voiceException(error)
      }
    }

    Function("cancelDownload") {
      self.download?.cancel()
    }

    AsyncFunction("loadModel") { (file: String, promise: Promise) in
      let model: URL
      do {
        model = try VoiceModels.file(file)
      } catch {
        promise.reject(voiceException(error))
        return
      }
      self.prints.async {
        do {
          if self.printer?.model != model {
            self.printer = nil
            self.printer = try SpeakerPrinter(model: model)
          }
          promise.resolve()
        } catch {
          promise.reject(voiceException(error, "Couldn’t load the voice model"))
        }
      }
    }

    // A voice print of 16 kHz 16-bit mono speech (little-endian); empty when there is too little sound.
    AsyncFunction("voicePrint") { (pcm: Data, promise: Promise) in
      self.prints.async {
        guard let printer = self.printer else {
          promise.reject(VoiceException("The voice model isn’t loaded."))
          return
        }
        let samples: [Float] = pcm.withUnsafeBytes { raw in
          raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        promise.resolve((printer.print(samples) ?? []).map(Double.init))
      }
    }

    Function("unloadModel") {
      self.prints.async { self.printer = nil }
    }
  }

  private func fetch(_ source: URL, _ sha256: String, _ target: URL, _ download: ModelDownload) async throws {
    let folder = VoiceModels.folder
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var excluded = folder
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? excluded.setResourceValues(values)

    let part = folder.appendingPathComponent("\(target.lastPathComponent).part")
    defer { try? FileManager.default.removeItem(at: part) }
    let total = try await download.start(source, into: part)
    if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage, free < 50 * 1024 * 1024
    {
      throw VoiceException("There isn’t enough free space on the phone.")
    }
    guard try sha256Hex(part) == sha256 else { throw VoiceException("The download was damaged. Try again.") }
    try fixAveragePools(part)
    sendEvent("onModelProgress", ["received": Double(total), "total": Double(total)])
    try FileManager.default.moveItem(at: part, to: target)
    // Older models are of no use any more.
    for other in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    where other.lastPathComponent != target.lastPathComponent {
      try? FileManager.default.removeItem(at: other)
    }
  }
}

private func sha256Hex(_ file: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: file)
  defer { try? handle.close() }
  var hasher = SHA256()
  while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
    hasher.update(data: chunk)
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/** One model download, reporting progress; `start` resolves with how many bytes came. */
private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let progress: (Int64, Int64) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Int64, Error>?
  private var task: URLSessionDownloadTask?
  private var session: URLSession?
  private var target: URL?
  private var saved: Int64 = 0
  private var failure: Error?
  private var cancelled = false
  private var reported = Date.distantPast

  init(progress: @escaping (Int64, Int64) -> Void) {
    self.progress = progress
  }

  func start(_ source: URL, into target: URL) async throws -> Int64 {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if cancelled {
        lock.unlock()
        continuation.resume(throwing: VoiceException("Cancelled."))
        return
      }
      self.continuation = continuation
      self.target = target
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 30
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      self.session = session
      let task = session.downloadTask(with: source)
      self.task = task
      lock.unlock()
      task.resume()
    }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let task = self.task
    lock.unlock()
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    let now = Date()
    guard now.timeIntervalSince(reported) >= PROGRESS_EVERY else { return }
    reported = now
    progress(totalBytesWritten, totalBytesExpectedToWrite)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // The file is deleted once this returns: kept now, judged when the task completes.
    lock.lock()
    defer { lock.unlock() }
    if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
      failure = VoiceException("The download server answered \(status). Try again later.")
      return
    }
    guard let target else { return }
    do {
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.moveItem(at: location, to: target)
      saved = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
    } catch {
      failure = error
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    let result: Result<Int64, Error>
    if cancelled {
      result = .failure(VoiceException("Cancelled."))
    } else if let failure {
      result = .failure(failure)
    } else if error != nil {
      result = .failure(VoiceException("Check the internet connection and try again."))
    } else {
      result = .success(saved)
    }
    lock.unlock()
    session.finishTasksAndInvalidate()
    continuation?.resume(with: result)
  }
}
