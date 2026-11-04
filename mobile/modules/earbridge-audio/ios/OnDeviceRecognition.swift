import AVFoundation
import Foundation
import Speech
import os

private let log = Logger(subsystem: "app.earbridge.mobile", category: "EarBridgeOnDevice")
private let SAMPLE_RATE = 16_000.0

/**
 The Android SpeechRecognizer error codes the app's messages are keyed on
 (shared/pipeline/stt/on-device.ts), reported for the same failures on iOS.
 */
enum RecognitionErrorCode {
  static let client = 5
  static let insufficientPermissions = 9
  static let languageNotSupported = 12
  static let languageUnavailable = 13
}

struct OnDeviceError: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

let NEEDS_IOS_26 = OnDeviceError("On-phone speech recognition needs iOS 26 or newer.")

typealias EmitEvent = @Sendable (_ name: String, _ body: [String: Any?]) -> Void

/** One turn of speech in one language, from its first audio until its last word is recognized. */
final class RecognitionSession: @unchecked Sendable {
  let id: Int
  let language: String
  /** What the app writes, 16 kHz 16-bit mono PCM, kept until the analyzer is ready for it. */
  let audio: AsyncStream<Data>
  private let audioIn: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var _cancelled = false
  var task: Task<Void, Never>?

  init(id: Int, language: String) {
    self.id = id
    self.language = language
    (audio, audioIn) = AsyncStream.makeStream(of: Data.self)
  }

  var cancelled: Bool {
    lock.withLock { _cancelled }
  }

  func write(_ pcm: Data) {
    audioIn.yield(pcm)
  }

  /** No more audio: the rest of what was written is recognized, then "end". */
  func end() {
    audioIn.finish()
  }

  func cancel() {
    lock.withLock { _cancelled = true }
    audioIn.finish()
    task?.cancel()
  }
}

/**
 Speech recognition that runs on the iPhone itself, with no server: Apple's SpeechAnalyzer
 and SpeechTranscriber (iOS 26 and newer), whose models iOS downloads once per language.

 Unlike Android's recognizer, each session gets an analyzer of its own, so sessions are
 recognized side by side; the app tells their events apart by session id.
 */
final class OnDeviceRecognition: @unchecked Sendable {
  private let lock = NSLock()
  private var sessions: [Int: RecognitionSession] = [:]
  var emit: EmitEvent = { _, _ in }

  static var isAvailable: Bool {
    if #available(iOS 26.0, *) {
      return SpeechTranscriber.isAvailable
    }
    return false
  }

  // ---------------------------------------------------------------- languages and downloads

  /** Recognizer locales (BCP 47, such as "en-US") installed on the phone or that can be downloaded. */
  func languages() async throws -> [String: [String]] {
    guard #available(iOS 26.0, *) else { throw NEEDS_IOS_26 }
    await askPermission()
    let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
    let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
    return ["installed": installed, "pending": [], "supported": supported.filter { !installed.contains($0) }]
  }

  /** Downloads what the recognizer needs for a locale, unless it is there; resolves "done". */
  func download(_ language: String) async throws -> String {
    guard #available(iOS 26.0, *) else { throw NEEDS_IOS_26 }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
      throw OnDeviceError("Speech recognition on this iPhone doesn't support \"\(language)\".")
    }
    // Keeps the language on the phone for this app; it may fail when the app keeps too many.
    let reserved = (try? await AssetInventory.reserve(locale: locale)) ?? false
    let kept = await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
    NSLog("[EarBridgeOnDevice] download %@: reserved %@ (%d of %d kept: %@)", locale.identifier(.bcp47),
          reserved ? "yes" : "no", kept.count, AssetInventory.maximumReservedLocales, kept.joined(separator: ", "))
    let transcriber = Self.transcriber(locale)
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
      NSLog("[EarBridgeOnDevice] download %@: already installed", locale.identifier(.bcp47))
      return "done"
    }
    // Progress is read every second, not only when iOS reports a change: a download iOS has
    // not started yet then shows as 0%, and the log says it is waiting.
    let emit = self.emit
    let progress = request.progress
    emit("onDownloadProgress", ["language": language, "percent": 0])
    let watcher = Task {
      var last = -1
      var seconds = 0
      while !Task.isCancelled {
        let percent = Int(progress.fractionCompleted * 100)
        if percent != last {
          last = percent
          emit("onDownloadProgress", ["language": language, "percent": percent])
        }
        if seconds % 10 == 0 {
          NSLog("[EarBridgeOnDevice] download %@: %d%% after %d s (%lld of %lld units)", locale.identifier(.bcp47),
                percent, seconds, progress.completedUnitCount, progress.totalUnitCount)
        }
        seconds += 1
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
    defer { watcher.cancel() }
    do {
      try await request.downloadAndInstall()
    } catch {
      NSLog("[EarBridgeOnDevice] download %@ failed: %@", locale.identifier(.bcp47), error.localizedDescription)
      throw error
    }
    NSLog("[EarBridgeOnDevice] download %@: done", locale.identifier(.bcp47))
    return "done"
  }

  /**
   Asks once whether the app may use speech recognition. A refusal is not taken as final here:
   it is reported if recognition then fails.
   */
  private func askPermission() async {
    guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
    }
  }

  // ---------------------------------------------------------------- recognition

  func start(_ id: Int, _ language: String) throws {
    guard #available(iOS 26.0, *) else { throw NEEDS_IOS_26 }
    let session = RecognitionSession(id: id, language: language)
    let previous = lock.withLock { () -> RecognitionSession? in
      let previous = sessions[id]
      sessions[id] = session
      return previous
    }
    previous?.cancel()
    session.task = Task.detached(priority: .userInitiated) { [weak self] in
      await self?.run(session)
    }
  }

  func write(_ id: Int, _ pcm: Data) {
    session(id)?.write(pcm)
  }

  func end(_ id: Int) {
    session(id)?.end()
  }

  /** Stops at once; reports "end" too. */
  func cancel(_ id: Int) {
    session(id)?.cancel()
  }

  func shutDown() {
    let all = lock.withLock { () -> [RecognitionSession] in
      let all = Array(sessions.values)
      sessions.removeAll()
      return all
    }
    for session in all { session.cancel() }
  }

  private func session(_ id: Int) -> RecognitionSession? {
    lock.withLock { sessions[id] }
  }

  @available(iOS 26.0, *)
  private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
    // Volatile results are what it hears so far; each finalized one is a phrase that is done.
    SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults],
      attributeOptions: [.audioTimeRange]
    )
  }

  @available(iOS 26.0, *)
  private func run(_ session: RecognitionSession) async {
    defer {
      lock.withLock {
        if sessions[session.id] === session { sessions.removeValue(forKey: session.id) }
      }
      emit(session, "end")
    }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: session.language)) else {
      fatal(session, RecognitionErrorCode.languageNotSupported)
      return
    }
    _ = try? await AssetInventory.reserve(locale: locale)
    let transcriber = Self.transcriber(locale)
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
      fatal(session, RecognitionErrorCode.languageUnavailable)
      return
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
      let converter = PcmConverter(to: format)
    else {
      fatal(session, RecognitionErrorCode.client)
      return
    }

    let (input, inputIn) = AsyncStream.makeStream(of: AnalyzerInput.self)
    let analyzer = SpeechAnalyzer(
      modules: [transcriber],
      // The model stays loaded between turns, so the next one starts at once.
      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
    )
    let results = Task { [weak self] () -> Error? in
      do {
        for try await result in transcriber.results {
          self?.report(session, result)
        }
        return nil
      } catch {
        return error
      }
    }
    do {
      try await analyzer.prepareToAnalyze(in: format)
      try await analyzer.start(inputSequence: input)
    } catch {
      log.error("session \(session.id): could not start: \(error.localizedDescription, privacy: .public)")
      inputIn.finish()
      results.cancel()
      await analyzer.cancelAndFinishNow()
      if !session.cancelled { fatal(session, permissionDenied() ? RecognitionErrorCode.insufficientPermissions : RecognitionErrorCode.client) }
      return
    }
    log.debug("session \(session.id): listening")
    emit(session, "ready")

    for await pcm in session.audio {
      if session.cancelled { break }
      if let buffer = converter.convert(pcm) { inputIn.yield(AnalyzerInput(buffer: buffer)) }
    }
    inputIn.finish()

    if session.cancelled {
      results.cancel()
      await analyzer.cancelAndFinishNow()
      return
    }
    do {
      try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
      log.error("session \(session.id): could not finish: \(error.localizedDescription, privacy: .public)")
      results.cancel()
      await analyzer.cancelAndFinishNow()
      fatal(session, RecognitionErrorCode.client)
      return
    }
    if let error = await results.value, !session.cancelled {
      log.error("session \(session.id): results failed: \(error.localizedDescription, privacy: .public)")
      fatal(session, RecognitionErrorCode.client)
    }
  }

  @available(iOS 26.0, *)
  private func report(_ session: RecognitionSession, _ result: SpeechTranscriber.Result) {
    if session.cancelled { return }
    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return }
    // Seconds since the session's first audio: the analyzer's clock starts with it.
    let range = result.range
    var start: Double?
    var end: Double?
    if range.start.isNumeric && range.duration.isNumeric {
      start = range.start.seconds
      end = range.end.seconds
    }
    emit(session, result.isFinal ? "segment" : "partial", text: text, start: start, end: end)
  }

  private func permissionDenied() -> Bool {
    let status = SFSpeechRecognizer.authorizationStatus()
    return status == .denied || status == .restricted
  }

  private func fatal(_ session: RecognitionSession, _ code: Int) {
    emit(session, "error", code: code, fatal: true)
  }

  private func emit(
    _ session: RecognitionSession,
    _ type: String,
    text: String? = nil,
    code: Int? = nil,
    fatal: Bool? = nil,
    start: Double? = nil,
    end: Double? = nil
  ) {
    var event: [String: Any?] = ["session": session.id, "type": type]
    if let text { event["text"] = text }
    if let code { event["code"] = code }
    if let fatal { event["fatal"] = fatal }
    if let start, let end {
      event["start"] = start
      event["end"] = max(start, end)
    }
    // Never the words themselves: they stay on the phone, out of the logs.
    if type != "partial" {
      let details = (code.map { " \($0)" } ?? "") + (text.map { " (\($0.count) chars)" } ?? "")
      log.debug("session \(session.id): \(type, privacy: .public)\(details, privacy: .public)")
    }
    emit("onRecognition", event)
  }
}

/** The app's 16 kHz 16-bit mono PCM, as buffers in the format the analyzer wants. */
final class PcmConverter {
  private let source: AVAudioFormat
  private let target: AVAudioFormat
  private let converter: AVAudioConverter?

  init?(to target: AVAudioFormat) {
    guard let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: SAMPLE_RATE, channels: 1, interleaved: true)
    else { return nil }
    self.source = source
    self.target = target
    if target == source {
      converter = nil
    } else {
      guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
      self.converter = converter
    }
  }

  func convert(_ pcm: Data) -> AVAudioPCMBuffer? {
    let frames = AVAudioFrameCount(pcm.count / 2)
    guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames),
      let samples = input.int16ChannelData
    else { return nil }
    input.frameLength = frames
    pcm.withUnsafeBytes { bytes in
      _ = memcpy(samples[0], bytes.baseAddress!, Int(frames) * 2)
    }
    guard let converter else { return input }

    let capacity = AVAudioFrameCount((Double(frames) * target.sampleRate / source.sampleRate).rounded(.up)) + 16
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
    var supplied = false
    var error: NSError?
    // The converter keeps its state from one buffer to the next, so resampling stays seamless.
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return input
    }
    if status == .error || output.frameLength == 0 { return nil }
    return output
  }
}
