import AVFoundation
import CoreMotion
import ExpoModulesCore
import UIKit
import os

private let log = Logger(subsystem: "app.earbridge.mobile", category: "EarBridgeCapture")
private let CAPTURE_RATE = 16_000.0
private let CAPTURE_CHUNK = 1_600 // 100 ms
/** Remembered when the iPhone gave one microphone twice: not tried again until iOS changes. */
private let ONE_MICROPHONE_KEY = "earbridge.oneMicrophone"

final class CaptureException: Exception, @unchecked Sendable {
  private let message: String

  init(_ message: String) {
    self.message = message
    super.init()
  }

  override var reason: String { message }

  override var code: String { "ERR_CAPTURE" }
}

struct CaptureOptions: Record {
  /** Also tell which way the sound came from, by recording the phone's microphones in stereo. */
  @Field var directions: Bool = false
}

struct VoicesOptions: Record {
  @Field var model: String = ""
  @Field var prints: [[Double]] = []
  @Field var passUnmatched: Bool = false
}

/**
 iPhone's side of the capture Android does in EarbridgeAudioModule.kt: 16 kHz 16-bit mono in
 100 ms chunks, through the voice isolator (VoiceIsolator.swift) and, with `directions`, from
 the phone's microphones in stereo, telling which way each chunk came from (DualMic.swift).

 The app sets up the audio session and chooses the microphone first (ios-session.ts); this
 only records. For stereo, the built-in microphone's stereo pattern is chosen with its axis
 along the phone's length, as Android's two microphones are: the two people sit at its ends.
 */
public final class EarbridgeCaptureModule: Module {
  /** Starting, stopping and every chunk run here, in order. */
  private let queue = DispatchQueue(label: "EarBridge microphone")
  private let voices = VoiceIsolator()

  // Used on `queue` only.
  private var current = 0
  private var lastId = 0
  private var engine: AVAudioEngine?
  private var options = CaptureOptions()
  private var micMode = MicMode.off
  private var stereo = false
  private var channel = 0
  private var pending: [Int16] = []
  private var finder: DirectionFinder?
  private var check = StereoCheck()
  private var pose = 0
  private var poseWatcher: PoseWatcher?
  private var observers: [NSObjectProtocol] = []
  private var stereoChosen = false
  private var restarts: [Date] = []

  public func definition() -> ModuleDefinition {
    Name("EarbridgeCapture")
    Events("onAudio", "onLevel", "onTurnEnd", "onSeparation", "onIsolation", "onCaptureError")

    OnCreate {
      self.voices.onEvent = { [weak self] name, body in self?.sendEvent(name, body) }
    }

    OnDestroy {
      self.queue.sync { self.stop() }
      self.voices.release()
    }

    // Whether this iPhone may record its microphones in stereo; whether it really does shows once it records.
    Function("canRecordStereo") { () -> Bool in
      Self.mayRecordStereo()
    }

    Function("setMicMode") { (mode: String) in
      let next: MicMode = mode == "live" ? .live : mode == "silent" ? .silent : .off
      self.queue.async { self.micMode = next }
    }

    Function("keepVoices") { (options: VoicesOptions) throws in
      let model: URL
      do {
        model = try VoiceModels.file(options.model)
      } catch {
        throw CaptureException("Bad model name.")
      }
      self.voices.keep(options.prints.map { $0.map(Float.init) }, model: model, passUnmatched: options.passUnmatched)
    }

    Function("keepAllVoices") {
      self.voices.keepAll()
    }

    AsyncFunction("startCapture") { (options: CaptureOptions, promise: Promise) in
      self.queue.async {
        do {
          let input = try self.start(options)
          promise.resolve(input)
        } catch let error as Exception {
          promise.reject(error)
        } catch {
          promise.reject(CaptureException("Could not start the microphone: \(error.localizedDescription)"))
        }
      }
    }

    AsyncFunction("stopCapture") { (promise: Promise) in
      self.queue.async {
        self.stop()
        self.micMode = .off
        self.voices.release()
        promise.resolve()
      }
    }
  }

  // ---------------------------------------------------------------- capture

  private func start(_ options: CaptureOptions) throws -> [String: String] {
    stop()
    lastId += 1
    let id = lastId
    self.options = options
    let session = AVAudioSession.sharedInstance()
    let builtIn = session.currentRoute.inputs.first { $0.portType == .builtInMic }
    stereo = options.directions && builtIn != nil && Self.mayRecordStereo() && chooseStereo(session)
    if !stereo { chooseDefaultPattern(session) }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw CaptureException("Could not open the microphone. Check that Alo is allowed to use it.")
    }
    if stereo && format.channelCount < 2 {
      log.info("Asked for stereo, got \(format.channelCount) channel(s)")
      stereo = false
    }
    let channels: AVAudioChannelCount = stereo ? 2 : 1
    guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: CAPTURE_RATE, channels: channels, interleaved: true),
      let converter = AVAudioConverter(from: format, to: target)
    else {
      throw CaptureException("Could not open the microphone.")
    }
    input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
      guard let samples = Self.convert(buffer, converter, target) else { return }
      self?.queue.async { self?.take(id, samples) }
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw CaptureException("The microphone is in use by another app.")
    }
    self.engine = engine
    current = id
    channel = 0
    pending = []
    check = StereoCheck()
    finder = stereo ? DirectionFinder() : nil
    if stereo {
      log.info("Recording the microphones in stereo")
      // The phone may have been moved while it wasn't recording.
      pose += 1
      let watcher = PoseWatcher { [weak self] in self?.queue.async { self?.pose += 1 } }
      watcher.start()
      poseWatcher = watcher
    }
    watch(id, engine)
    return describe(session)
  }

  /** The built-in microphone in stereo, its axis along the phone's length. False if it can't. */
  private func chooseStereo(_ session: AVAudioSession) -> Bool {
    guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
      let source = builtIn.dataSources?.first(where: { $0.supportedPolarPatterns?.contains(.stereo) == true })
    else { return false }
    do {
      try source.setPreferredPolarPattern(.stereo)
      try builtIn.setPreferredDataSource(source)
      try session.setPreferredInput(builtIn)
      // In landscape, left and right lie along the phone's length.
      try session.setPreferredInputOrientation(.landscapeLeft)
      stereoChosen = true
      return true
    } catch {
      log.info("Stereo recording refused: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  /** Back to the microphone's usual pattern after stereo. */
  private func chooseDefaultPattern(_ session: AVAudioSession) {
    guard stereoChosen else { return }
    stereoChosen = false
    if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
      for source in builtIn.dataSources ?? [] where source.selectedPolarPattern == .stereo {
        try? source.setPreferredPolarPattern(nil)
      }
    }
  }

  private static func mayRecordStereo() -> Bool {
    UserDefaults.standard.string(forKey: ONE_MICROPHONE_KEY) != UIDevice.current.systemVersion
  }

  private func describe(_ session: AVAudioSession) -> [String: String] {
    guard let port = session.currentRoute.inputs.first else { return ["input": "phone", "name": "Phone microphone"] }
    switch port.portType {
    case .builtInMic: return ["input": "phone", "name": "Phone microphone"]
    default: return ["input": "earphones", "name": port.portName]
    }
  }

  /** Calls and Siri take the microphone; a route change stops the engine, which starts again. */
  private func watch(_ id: Int, _ engine: AVAudioEngine) {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .began
        else { return }
        self?.fail(id, "A call or another app interrupted the microphone.")
      })
    observers.append(
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
        self?.queue.async { self?.restart(id) }
      })
  }

  private func restart(_ id: Int) {
    guard current == id else { return }
    let now = Date()
    restarts = restarts.filter { now.timeIntervalSince($0) < 5 } + [now]
    if restarts.count > 4 {
      fail(id, "The microphone kept changing.")
      return
    }
    do {
      _ = try start(options)
    } catch {
      stop()
      sendEvent("onCaptureError", ["message": error.localizedDescription])
    }
  }

  private static func convert(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter, _ target: AVAudioFormat) -> [Int16]? {
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
    var given = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if given {
        inputStatus.pointee = .noDataNow
        return nil
      }
      given = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, let data = out.int16ChannelData else { return nil }
    return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength) * Int(target.channelCount)))
  }

  /** Samples as converted, interleaved when in stereo: on in 100 ms chunks. */
  private func take(_ id: Int, _ samples: [Int16]) {
    guard current == id else { return }
    pending.append(contentsOf: samples)
    let channels = stereo ? 2 : 1
    let size = CAPTURE_CHUNK * channels
    while pending.count >= size, current == id {
      let chunk = Array(pending[0..<size])
      pending.removeFirst(size)
      var direction: Direction?
      if stereo, let finder {
        let undecided = check.verdict == nil
        check.add(chunk)
        if undecided, let verdict = check.verdict, verdict != .two {
          // One microphone twice, or a silent channel: one channel from now on, and not tried again.
          log.info("Stereo gives one microphone: \(String(describing: verdict), privacy: .public)")
          UserDefaults.standard.set(UIDevice.current.systemVersion, forKey: ONE_MICROPHONE_KEY)
          if verdict == .secondOnly { channel = 1 }
        }
        if check.plausible { direction = finder.add(chunk) }
      }
      var mono = [Int16](repeating: 0, count: CAPTURE_CHUNK)
      for index in 0..<CAPTURE_CHUNK { mono[index] = chunk[index * channels + channel] }
      emit(mono, stereo && check.plausible, direction)
    }
  }

  private func emit(_ pcm: [Int16], _ twoMicrophones: Bool, _ direction: Direction?) {
    var sum = 0.0
    for sample in pcm {
      let value = Double(sample) / 32768
      sum += value * value
    }
    sendEvent("onLevel", ["level": min(1, (sum / Double(pcm.count)).squareRoot() * 4)])
    let mode = micMode
    voices.hear(Heard(pcm: pcm, mode: mode, pose: twoMicrophones ? pose : nil, direction: mode == .live ? direction : nil))
  }

  private func fail(_ id: Int, _ message: String) {
    queue.async {
      guard self.current == id else { return }
      self.stop()
      self.sendEvent("onCaptureError", ["message": message])
    }
  }

  private func stop() {
    current = 0
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    poseWatcher?.stop()
    poseWatcher = nil
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    engine = nil
    pending = []
    voices.endRun()
  }
}

/**
 Tells when the phone was turned or moved to lie another way, as PoseWatcher.kt does on
 Android: the directions voices came from until then no longer apply.
 */
private final class PoseWatcher {
  /** Turned by more than 25°: a nudge doesn't count. */
  private static let MOVED = cos(25 * Double.pi / 180)
  private let motion = CMMotionManager()
  private let updates = OperationQueue()
  private let onMove: () -> Void
  private var settled: CMRotationMatrix?

  init(onMove: @escaping () -> Void) {
    self.onMove = onMove
    updates.maxConcurrentOperationCount = 1
  }

  func start() {
    guard motion.isDeviceMotionAvailable else { return }
    motion.deviceMotionUpdateInterval = 0.2
    // Without the compass, which a metal table or the phone's own speaker can throw off.
    motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: updates) { [weak self] data, _ in
      guard let self, let rotation = data?.attitude.rotationMatrix else { return }
      guard let before = self.settled else {
        self.settled = rotation
        return
      }
      // The trace of one rotation times the other's inverse is 1 + 2·cos(angle).
      let trace =
        before.m11 * rotation.m11 + before.m12 * rotation.m12 + before.m13 * rotation.m13
        + before.m21 * rotation.m21 + before.m22 * rotation.m22 + before.m23 * rotation.m23
        + before.m31 * rotation.m31 + before.m32 * rotation.m32 + before.m33 * rotation.m33
      if (trace - 1) / 2 < Self.MOVED {
        self.settled = rotation
        self.onMove()
      }
    }
  }

  func stop() {
    motion.stopDeviceMotionUpdates()
  }
}
