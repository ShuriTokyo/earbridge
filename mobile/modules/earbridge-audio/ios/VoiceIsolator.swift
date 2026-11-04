import Foundation
import onnxruntime_objc
import os

// The same as VoiceIsolator.kt on Android: see there for why each number is what it is.

private let log = Logger(subsystem: "app.earbridge.mobile", category: "EarBridgeVoices")
private let ISOLATOR_RATE = 16_000
private let CHUNK = ISOLATOR_RATE / 10
/** The separation model (Conv-TasNet, 8-bit): "mix" [1, samples] in, two voices out. */
private let SEPARATOR = "convtasnet"
private let BLOCK = 20
private let STRIDE = 15
private let OVERLAP = BLOCK - STRIDE
/** A separated voice at least this much like one of the prints is kept (CAM++'s scale). */
private let KEEP = 0.3
private let FLOOR = 1e-4
private let MAX_WAITING = 50
private let SEPARATOR_THREADS: Int32 = 2

/** What happens to the sound: sent as heard, sent as silence, or not sent. */
enum MicMode { case live, silent, off }

/** 100 ms of sound, with how it was to be sent when it was heard. */
struct Heard {
  /** 16-bit PCM, little-endian. */
  let pcm: [Int16]
  let mode: MicMode
  /** While recording two microphones. */
  let pose: Int?
  let direction: Direction?
}

/**
 Passes the microphone's sound on ("onAudio"), keeping only the voices asked for: each 2 s is
 split into two voices by a small separation model, and each voice is kept if its print is like
 one of the prints given. Everything runs on one queue, in the order heard.
 */
final class VoiceIsolator: @unchecked Sendable {
  private let queue = DispatchQueue(label: "EarBridge voices")
  /** Where events go: set once, before any sound is heard. */
  var onEvent: ((String, [String: Any]) -> Void)?
  private let waitingLock = NSLock()
  private var waitingCount = 0

  // Used on `queue` only.
  private var prints: [[Float]] = []
  private var passUnmatched = false
  private var environment: ORTEnv?
  private var separator: ORTSession?
  private var separatorOutput = ""
  private var printer: SpeakerPrinter?
  private var slow = false
  private var allowance = 0
  private var lastMode = MicMode.off
  private var run: [Heard] = []
  private var first = 0
  private var done = 0
  private var next = 0
  private var carry: [Float]?

  private func send(_ name: String, _ body: [String: Any]) {
    onEvent?(name, body)
  }

  private var keeping: Bool { !prints.isEmpty && separator != nil && printer != nil && !slow }

  private var waiting: Int {
    waitingLock.lock()
    defer { waitingLock.unlock() }
    return waitingCount
  }

  private func addWaiting(_ change: Int) {
    waitingLock.lock()
    waitingCount += change
    waitingLock.unlock()
  }

  /** From the microphone's queue. */
  func hear(_ heard: Heard) {
    addWaiting(1)
    queue.async {
      self.addWaiting(-1)
      self.take(heard)
    }
  }

  func keep(_ voices: [[Float]], model: URL, passUnmatched: Bool) {
    queue.async {
      self.passUnmatched = passUnmatched
      if self.keeping && self.printer?.model == model {
        if voices != self.prints { self.prints = voices }
        return
      }
      self.finishRun()
      do {
        try self.load(model)
        self.prints = voices
        self.allowance = self.waiting
        self.send("onIsolation", ["state": self.slow ? "slow" : "on"])
      } catch {
        log.warning("Couldn’t start separating voices: \(error.localizedDescription, privacy: .public)")
        self.prints = []
        self.send("onIsolation", ["state": "failed", "message": error.localizedDescription])
      }
    }
  }

  func keepAll() {
    queue.async {
      if self.prints.isEmpty { return }
      self.finishRun()
      self.prints = []
      self.send("onIsolation", ["state": "off"])
    }
  }

  /** The microphone stopped (maybe to start again another way): what is left is passed on. */
  func endRun() {
    queue.async { self.finishRun() }
  }

  /** The conversation is over: forgets the voices and frees the models. */
  func release() {
    queue.async {
      self.finishRun()
      self.prints = []
      self.slow = false
      self.lastMode = .off
      self.separator = nil
      self.environment = nil
      self.printer = nil
    }
  }

  // ---------------------------------------------------------------- the sound

  private func take(_ heard: Heard) {
    let mode = heard.mode
    let wasOff = lastMode == .off
    lastMode = mode
    if mode == .off {
      if !wasOff {
        finishRun()
        send("onTurnEnd", [:])
      }
      return
    }
    let chunk = mode == .silent ? Heard(pcm: [Int16](repeating: 0, count: heard.pcm.count), mode: mode, pose: heard.pose, direction: nil) : heard
    if !keeping {
      pass(chunk)
      return
    }
    run.append(chunk)
    if first + run.count >= next + BLOCK { separateBlock() }
    let behind = waiting
    allowance = min(allowance, behind)
    if behind > allowance + MAX_WAITING { giveUp() }
  }

  private func separateBlock() {
    let voices = separate(samples(next, next + BLOCK))
    passSeparated(voices, 0, STRIDE)
    carry = Array(voices[(STRIDE * CHUNK)..<(BLOCK * CHUNK)])
    next += STRIDE
    while first < next - BLOCK {
      run.removeFirst()
      first += 1
    }
  }

  private func finishRun() {
    if run.isEmpty { return }
    let end = first + run.count
    if end > done && keeping {
      let start = max(first, end - BLOCK)
      passSeparated(separate(samples(start, end)), (done - start) * CHUNK, end - done)
    } else {
      while done < end {
        pass(run[done - first])
        done += 1
      }
    }
    run.removeAll()
    carry = nil
    first = 0
    done = 0
    next = 0
  }

  private func passSeparated(_ voices: [Float], _ offset: Int, _ count: Int) {
    let previous = carry
    let fade = OVERLAP * CHUNK
    for k in 0..<count {
      let heard = run[done - first + k]
      var pcm = [Int16](repeating: 0, count: CHUNK)
      if heard.mode == .live {
        for i in 0..<CHUNK {
          let at = k * CHUNK + i
          var value = voices[offset + at]
          if let previous, at < fade {
            let share = Float(at) / Float(fade)
            value = previous[at] * (1 - share) + value * share
          }
          let scaled = value * 32768
          pcm[i] = scaled.isFinite ? Int16(clamping: Int(max(-40_000, min(40_000, scaled)))) : 0
        }
      }
      pass(Heard(pcm: pcm, mode: heard.mode, pose: heard.pose, direction: heard.direction))
    }
    done += count
    carry = nil
  }

  private func giveUp() {
    slow = true
    while done < first + run.count {
      pass(run[done - first])
      done += 1
    }
    run.removeAll()
    carry = nil
    first = 0
    done = 0
    next = 0
    send("onIsolation", ["state": "slow"])
  }

  private func pass(_ heard: Heard) {
    let data = heard.pcm.withUnsafeBufferPointer { buffer in
      Data(buffer: UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
    }
    var event: [String: Any] = ["pcm": data.base64EncodedString()]
    if let pose = heard.pose { event["pose"] = pose }
    if let direction = heard.direction {
      event["delay"] = direction.delay
      event["clarity"] = direction.clarity
    }
    send("onAudio", event)
  }

  private func samples(_ from: Int, _ to: Int) -> [Float] {
    var out = [Float](repeating: 0, count: (to - from) * CHUNK)
    for k in from..<to {
      let pcm = run[k - first].pcm
      let base = (k - from) * CHUNK
      for i in 0..<CHUNK { out[base + i] = Float(pcm[i]) / 32768 }
    }
    return out
  }

  // ---------------------------------------------------------------- the voices

  /** The voices in `sound` like the prints, together; with none, nothing, or `sound` itself when asked. */
  private func separate(_ sound: [Float]) -> [Float] {
    let n = sound.count
    var kept = [Float](repeating: 0, count: n)
    if sound.allSatisfy({ $0 == 0 }) { return kept }
    let started = Date()
    var voices: [[Float]]
    do {
      voices = try split(sound)
    } catch {
      // Not worth losing what was said: it goes on as heard.
      log.warning("Separating voices failed: \(error.localizedDescription, privacy: .public)")
      return sound
    }
    let splitAt = Date()
    var cross = 0.0
    var power = 0.0
    for i in 0..<n {
      let both = Double(voices[0][i] + voices[1][i])
      cross += Double(sound[i]) * both
      power += both * both
    }
    let gain = Float(cross / (power + 1e-12))
    var scores: [Double] = []
    var keep: [Bool] = []
    for v in voices.indices {
      var sum = 0.0
      for i in 0..<n {
        voices[v][i] *= gain
        sum += Double(voices[v][i] * voices[v][i])
      }
      let score = (sum / Double(n)).squareRoot() < FLOOR ? nil : likeness(voices[v])
      let ours = score.map { $0 >= KEEP } ?? false
      if ours { for i in 0..<n { kept[i] += voices[v][i] } }
      scores.append(score ?? -1)
      keep.append(ours)
    }
    let passed = passUnmatched && !keep.contains(true)
    let finished = Date()
    send(
      "onSeparation",
      [
        "seconds": Double(n) / Double(ISOLATOR_RATE),
        "splitMs": splitAt.timeIntervalSince(started) * 1000,
        "printMs": finished.timeIntervalSince(splitAt) * 1000,
        "scores": scores,
        "kept": keep,
        "passed": passed,
        "waiting": Double(waiting) / 10,
      ])
    return passed ? sound : kept
  }

  /** The separation model's two voices. */
  private func split(_ sound: [Float]) throws -> [[Float]] {
    guard let separator else { throw OnDeviceError("The separation model isn’t loaded.") }
    let n = sound.count
    let data = sound.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: n * MemoryLayout<Float>.size) }
    let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, NSNumber(value: n)])
    let outputs = try separator.run(withInputs: ["mix": input], outputNames: [separatorOutput], runOptions: nil)
    guard let output = outputs[separatorOutput] else { throw OnDeviceError("The separation model gave nothing.") }
    let bytes = try output.tensorData() as Data
    let values: [Float] = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard values.count >= 2 * n else { throw OnDeviceError("The separation model gave too little.") }
    return [Array(values[0..<n]), Array(values[n..<(2 * n)])]
  }

  private func likeness(_ voice: [Float]) -> Double? {
    guard let printer, let print = printer.print(voice) else { return nil }
    return prints.map { cosine(print, $0) }.max()
  }

  // ---------------------------------------------------------------- the models

  private func load(_ model: URL) throws {
    if separator == nil {
      guard let path = separatorPath() else { throw OnDeviceError("The separation model is missing from the app.") }
      let environment = try ORTEnv(loggingLevel: .warning)
      let options = try ORTSessionOptions()
      try options.setIntraOpNumThreads(SEPARATOR_THREADS)
      try options.setGraphOptimizationLevel(.all)
      let session = try ORTSession(env: environment, modelPath: path, sessionOptions: options)
      guard let output = try session.outputNames().first else { throw OnDeviceError("The separation model has no output.") }
      self.environment = environment
      separator = session
      separatorOutput = output
    }
    if printer?.model != model {
      printer = nil
      printer = try SpeakerPrinter(model: model)
    }
  }

  private func separatorPath() -> String? {
    for bundle in [Bundle.main, Bundle(for: VoiceIsolator.self)] {
      if let resources = bundle.url(forResource: "EarbridgeAudio", withExtension: "bundle"),
        let path = Bundle(url: resources)?.path(forResource: SEPARATOR, ofType: "onnx")
      {
        return path
      }
      if let path = bundle.path(forResource: SEPARATOR, ofType: "onnx") { return path }
    }
    return nil
  }
}
