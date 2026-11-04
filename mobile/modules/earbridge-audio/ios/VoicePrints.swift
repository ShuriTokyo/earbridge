import Foundation
import SherpaOnnxC

/** Speech is brought to this loudness (RMS, full scale 1) first: prints shift a little with it. */
private let LOUDNESS: Float = 0.1
private let PRINT_SAMPLE_RATE: Int32 = 16_000
/** Two of the phone's fast cores, as on Android. */
private let PRINT_THREADS: Int32 = 2

/** Where the downloaded speaker models are kept: the app's own folder, out of backups. */
enum VoiceModels {
  static var folder: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("voice-models", isDirectory: true)
  }

  /** Only plain file names: the model lives in the app's own folder. */
  static func file(_ name: String) throws -> URL {
    guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil, !name.hasPrefix(".") else {
      throw OnDeviceError("Bad model name.")
    }
    return folder.appendingPathComponent(name)
  }
}

/**
 Voice prints with sherpa-onnx's speaker model front end, as EarbridgeVoiceModule.kt and
 VoiceIsolator.kt make them on Android. Not thread-safe: each user keeps its own, on one queue.
 */
final class SpeakerPrinter {
  let model: URL
  private let extractor: OpaquePointer

  init(model: URL) throws {
    guard FileManager.default.fileExists(atPath: model.path) else {
      throw OnDeviceError("The voice model is missing. Try again to download it.")
    }
    let made: OpaquePointer? = model.path.withCString { path in
      "cpu".withCString { cpu in
        var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
        config.model = path
        config.num_threads = PRINT_THREADS
        config.debug = 0
        config.provider = cpu
        return SherpaOnnxCreateSpeakerEmbeddingExtractor(&config)
      }
    }
    guard let made else { throw OnDeviceError("Couldn’t load the voice model.") }
    self.model = model
    extractor = made
  }

  deinit {
    SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor)
  }

  /** A print of 16 kHz mono speech from -1 to 1; nil for silence or too little sound. */
  func print(_ sound: [Float]) -> [Float]? {
    var samples = sound
    guard normalizeLoudness(&samples), let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else {
      return nil
    }
    defer { SherpaOnnxDestroyOnlineStream(stream) }
    samples.withUnsafeBufferPointer { buffer in
      SherpaOnnxOnlineStreamAcceptWaveform(stream, PRINT_SAMPLE_RATE, buffer.baseAddress, Int32(buffer.count))
    }
    SherpaOnnxOnlineStreamInputFinished(stream)
    guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
      let embedding = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream)
    else { return nil }
    defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(embedding) }
    let size = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
    return Array(UnsafeBufferPointer(start: embedding, count: size))
  }
}

/** Brings speech to the loudness prints are made at, in place. False for silence. */
func normalizeLoudness(_ samples: inout [Float]) -> Bool {
  guard !samples.isEmpty else { return false }
  var sum = 0.0
  var peak: Float = 0
  for sample in samples {
    sum += Double(sample * sample)
    peak = max(peak, abs(sample))
  }
  if peak == 0 { return false }
  let gain = min(LOUDNESS / Float(sqrt(sum / Double(samples.count))), 1 / peak)
  for i in samples.indices { samples[i] *= gain }
  return true
}

func cosine(_ a: [Float], _ b: [Float]) -> Double {
  if a.count != b.count { return -1 }
  var dot = 0.0
  var aa = 0.0
  var bb = 0.0
  for i in a.indices {
    dot += Double(a[i] * b[i])
    aa += Double(a[i] * a[i])
    bb += Double(b[i] * b[i])
  }
  return aa == 0 || bb == 0 ? -1 : dot / (aa * bb).squareRoot()
}

// ---------------------------------------------------------------- the model's fix

// The few ONNX protobuf fields the fix reads (onnx.proto).
private let MODEL_GRAPH = 7
private let GRAPH_NODE = 1
private let NODE_OP_TYPE = 4
private let NODE_ATTRIBUTE = 5
private let ATTRIBUTE_NAME = 1
private let ATTRIBUTE_I = 3
private let ATTRIBUTE_INTS = 8
private let UNKNOWN_MODEL = OnDeviceError("This isn’t a voice model Alo knows.")

/**
 Makes the model's AveragePool layers average real frames only, as in training: the same
 one-byte-per-layer change as fixAveragePools in EarbridgeVoiceModule.kt, for the same
 runtime (ONNX Runtime 1.28 inside sherpa-onnx 1.13.8), so prints match Android's.
 */
func fixAveragePools(_ model: URL) throws {
  var bytes = [UInt8](try Data(contentsOf: model))
  guard let graph = try protoFields(bytes, 0, bytes.count).first(where: { $0.number == MODEL_GRAPH }) else {
    throw UNKNOWN_MODEL
  }
  for node in try protoFields(bytes, graph.start, graph.end) where node.number == GRAPH_NODE {
    let nodeFields = try protoFields(bytes, node.start, node.end)
    guard nodeFields.contains(where: { $0.number == NODE_OP_TYPE && protoText(bytes, $0) == "AveragePool" }) else { continue }
    var attributes: [String: [ProtoField]] = [:]
    for attribute in nodeFields where attribute.number == NODE_ATTRIBUTE {
      let attributeFields = try protoFields(bytes, attribute.start, attribute.end)
      guard let name = attributeFields.first(where: { $0.number == ATTRIBUTE_NAME }) else { continue }
      attributes[protoText(bytes, name)] = attributeFields
    }
    let padded = (attributes["pads"] ?? []).contains { field in
      field.number == ATTRIBUTE_INTS && bytes[field.start..<field.end].contains { $0 != 0 }
    }
    guard !padded, let include = attributes["count_include_pad"]?.first(where: { $0.number == ATTRIBUTE_I }),
      try protoVarint(bytes, include.start).value == 1
    else { continue }
    bytes[include.start] = 0
  }
  try Data(bytes).write(to: model, options: .atomic)
}

/** A field of a protobuf message: its number, and where its value is. */
private struct ProtoField {
  let number: Int
  let start: Int
  let end: Int
}

private func protoFields(_ bytes: [UInt8], _ start: Int, _ end: Int) throws -> [ProtoField] {
  var fields: [ProtoField] = []
  var at = start
  while at < end {
    let (key, value) = try protoVarint(bytes, at)
    let number = Int(key >> 3)
    let field: ProtoField
    switch key & 7 {
    case 0: field = ProtoField(number: number, start: value, end: try protoVarint(bytes, value).next)
    case 1: field = ProtoField(number: number, start: value, end: value + 8)
    case 2:
      let (length, data) = try protoVarint(bytes, value)
      field = ProtoField(number: number, start: data, end: data + Int(length))
    case 5: field = ProtoField(number: number, start: value, end: value + 4)
    default: throw UNKNOWN_MODEL
    }
    guard field.end <= end else { throw UNKNOWN_MODEL }
    fields.append(field)
    at = field.end
  }
  if at != end { throw UNKNOWN_MODEL }
  return fields
}

/** The varint at `at`, and where what follows it starts. */
private func protoVarint(_ bytes: [UInt8], _ at: Int) throws -> (value: UInt64, next: Int) {
  var value: UInt64 = 0
  var shift: UInt64 = 0
  var next = at
  while true {
    guard next < bytes.count else { throw UNKNOWN_MODEL }
    let byte = bytes[next]
    next += 1
    value |= UInt64(byte & 0x7f) << shift
    if byte & 0x80 == 0 { return (value, next) }
    shift += 7
    if shift >= 64 { throw UNKNOWN_MODEL }
  }
}

private func protoText(_ bytes: [UInt8], _ field: ProtoField) -> String {
  String(decoding: bytes[field.start..<field.end], as: UTF8.self)
}
