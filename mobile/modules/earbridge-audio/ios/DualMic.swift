import Foundation

// The same as DualMic.kt on Android: telling which way sound came from with two microphones.

/** Where 100 ms of sound came from, as the phone's two microphones heard it. */
struct Direction {
  /** How many samples (at 16 kHz) after the first microphone the sound reached the second. */
  let delay: Double
  /** How clearly it came from one place: near 0 for chatter from all around, up to 1. */
  let clarity: Double
}

private let FRAME = 512
private let HOP = FRAME / 2
/** 219 Hz to 5 kHz. */
private let LOW_BIN = 7
private let HIGH_BIN = 160
private let BINS = HIGH_BIN - LOW_BIN + 1
private let MAX_DELAY = 12.0
private let DELAY_STEP = 0.25
private let STEPS = Int(2 * MAX_DELAY / DELAY_STEP) + 1
private let LEARN_FRAMES = 8
private let SPEECH_ABOVE_NOISE = 3.0
private let NOISE_RATE = 0.05
private let NOISE_RISE = 1.0074
private let WEIGHT_NOISE = 2.0
private let MIN_WEIGHT = 60.0

private func binAngle(_ bin: Int) -> Double { 2 * Double.pi * Double(LOW_BIN + bin) / Double(FRAME) }
private func delayAt(_ step: Int) -> Double { -MAX_DELAY + Double(step) * DELAY_STEP }

/**
 Tells every 100 ms which way the sound came from: how much later it reached one microphone
 than the other (GCC-PHAT), counting frequencies well above the background noise most.
 */
final class DirectionFinder {
  private let window = (0..<FRAME).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(FRAME)) }
  private let fft = Fft(FRAME)
  private var first = [Double](repeating: 0, count: FRAME)
  private var second = [Double](repeating: 0, count: FRAME)
  private var at = 0
  private var filled = 0
  private var sinceFrame = 0
  private var re = [Double](repeating: 0, count: FRAME)
  private var im = [Double](repeating: 0, count: FRAME)
  private var noise = [Double](repeating: 0, count: BINS)
  private var frames = 0
  private var sumRe = [Double](repeating: 0, count: BINS)
  private var sumIm = [Double](repeating: 0, count: BINS)
  private var weight = 0.0
  private let cosines = (0..<STEPS).map { step in (0..<BINS).map { cos(binAngle($0) * delayAt(step)) } }
  private let sines = (0..<STEPS).map { step in (0..<BINS).map { sin(binAngle($0) * delayAt(step)) } }

  /** Interleaved stereo; the direction, or nil when too little stood out from the background. */
  func add(_ stereo: [Int16]) -> Direction? {
    for i in 0..<(stereo.count / 2) {
      first[at] = Double(stereo[2 * i])
      second[at] = Double(stereo[2 * i + 1])
      at = (at + 1) % FRAME
      if filled < FRAME { filled += 1 }
      sinceFrame += 1
      if sinceFrame >= HOP && filled == FRAME {
        sinceFrame = 0
        analyze()
      }
    }
    return conclude()
  }

  private func analyze() {
    for n in 0..<FRAME {
      let index = (at + n) % FRAME
      re[n] = first[index] * window[n]
      im[n] = second[index] * window[n]
    }
    fft.transform(&re, &im)
    let learning = frames < LEARN_FRAMES
    for bin in 0..<BINS {
      let k = LOW_BIN + bin
      let ar = re[k], ai = im[k], br = re[FRAME - k], bi = im[FRAME - k]
      let firstRe = (ar + br) / 2
      let firstIm = (ai - bi) / 2
      let secondRe = (ai + bi) / 2
      let secondIm = (br - ar) / 2
      let firstPower = firstRe * firstRe + firstIm * firstIm
      let secondPower = secondRe * secondRe + secondIm * secondIm
      let power = firstPower + secondPower
      if learning {
        noise[bin] += (power - noise[bin]) / Double(frames + 1)
        continue
      }
      if power < SPEECH_ABOVE_NOISE * noise[bin] {
        noise[bin] += NOISE_RATE * (power - noise[bin])
      } else {
        noise[bin] *= NOISE_RISE
      }
      let standsOut = power > 0 ? 1 - WEIGHT_NOISE * noise[bin] / power : 0
      let magnitude = (firstPower * secondPower).squareRoot()
      if standsOut <= 0 || magnitude <= 0 { continue }
      sumRe[bin] += standsOut * (firstRe * secondRe + firstIm * secondIm) / magnitude
      sumIm[bin] += standsOut * (firstIm * secondRe - firstRe * secondIm) / magnitude
      weight += standsOut
    }
    frames += 1
  }

  private func conclude() -> Direction? {
    if weight < MIN_WEIGHT {
      reset()
      return nil
    }
    var values = [Double](repeating: 0, count: STEPS)
    var best = 0
    for step in 0..<STEPS {
      var value = 0.0
      let cosine = cosines[step]
      let sine = sines[step]
      for bin in 0..<BINS { value += sumRe[bin] * cosine[bin] + sumIm[bin] * sine[bin] }
      values[step] = value
      if value > values[best] { best = step }
    }
    var delay = delayAt(best)
    if best >= 1 && best < STEPS - 1 {
      let left = values[best - 1]
      let right = values[best + 1]
      let curve = left - 2 * values[best] + right
      if curve < 0 { delay += 0.5 * (left - right) / curve * DELAY_STEP }
    }
    let clarity = min(max(values[best] / weight, 0), 1)
    reset()
    return Direction(delay: delay, clarity: clarity)
  }

  private func reset() {
    for i in 0..<BINS {
      sumRe[i] = 0
      sumIm[i] = 0
    }
    weight = 0
  }
}

/** Tells whether a stereo recording really comes from two microphones. */
final class StereoCheck {
  enum Verdict { case two, same, firstOnly, secondOnly }

  private static let QUICK_CHUNKS = 3
  private static let IDENTICAL = 0.999
  private static let LOUD_CHUNKS = 20
  private static let LOUD: Int32 = 300
  private static let DEAD = 1e-4
  private static let SAME_SOUND = 0.995

  private(set) var verdict: Verdict?
  var plausible: Bool { verdict == nil || verdict == .two }

  private var heard = 0
  private var loud = 0
  private var firstEnergy = 0.0
  private var secondEnergy = 0.0
  private var together = 0.0
  private var lastFirst: Int32 = 0
  private var lastSecond: Int32 = 0

  func add(_ stereo: [Int16]) {
    if verdict != nil { return }
    var firstSum = 0.0, secondSum = 0.0, both = 0.0
    var firstChanges = 0, secondChanges = 0
    var peak: Int32 = 0
    for i in 0..<(stereo.count / 2) {
      let a = Int32(stereo[2 * i])
      let b = Int32(stereo[2 * i + 1])
      let da = Double(a - lastFirst)
      let db = Double(b - lastSecond)
      if a != lastFirst { firstChanges += 1 }
      if b != lastSecond { secondChanges += 1 }
      lastFirst = a
      lastSecond = b
      firstSum += da * da
      secondSum += db * db
      both += da * db
      peak = max(peak, max(abs(a), abs(b)))
    }
    if firstChanges == 0 && secondChanges == 0 { return }
    firstEnergy += firstSum
    secondEnergy += secondSum
    together += both
    heard += 1
    if peak >= Self.LOUD { loud += 1 }
    if heard < Self.QUICK_CHUNKS { return }
    let correlation = firstEnergy > 0 && secondEnergy > 0 ? together / (firstEnergy * secondEnergy).squareRoot() : 0
    if secondEnergy == 0 {
      verdict = .firstOnly
    } else if firstEnergy == 0 {
      verdict = .secondOnly
    } else if correlation >= Self.IDENTICAL {
      verdict = .same
    } else if loud < Self.LOUD_CHUNKS {
      verdict = nil
    } else if secondEnergy < firstEnergy * Self.DEAD {
      verdict = .firstOnly
    } else if firstEnergy < secondEnergy * Self.DEAD {
      verdict = .secondOnly
    } else if correlation >= Self.SAME_SOUND {
      verdict = .same
    } else {
      verdict = .two
    }
  }
}

/** A fast Fourier transform of a power-of-two size, in place: X[k] = Σ x[n]·e^(−2πikn/N). */
final class Fft {
  private let size: Int
  private let cosTable: [Double]
  private let sinTable: [Double]
  private let reversed: [Int]

  init(_ size: Int) {
    precondition(size >= 2 && size & (size - 1) == 0, "The size must be a power of two.")
    self.size = size
    cosTable = (0..<(size / 2)).map { cos(2 * Double.pi * Double($0) / Double(size)) }
    sinTable = (0..<(size / 2)).map { sin(2 * Double.pi * Double($0) / Double(size)) }
    let bits = size.trailingZeroBitCount
    reversed = (0..<size).map { index in
      var value = 0
      for bit in 0..<bits where index & (1 << bit) != 0 { value |= 1 << (bits - 1 - bit) }
      return value
    }
  }

  func transform(_ re: inout [Double], _ im: inout [Double]) {
    for i in 0..<size {
      let j = reversed[i]
      if j > i {
        re.swapAt(i, j)
        im.swapAt(i, j)
      }
    }
    var half = 1
    while half < size {
      let step = size / (half * 2)
      var start = 0
      while start < size {
        for k in 0..<half {
          let c = cosTable[k * step]
          let s = sinTable[k * step]
          let i = start + k
          let j = i + half
          let tr = re[j] * c + im[j] * s
          let ti = im[j] * c - re[j] * s
          re[j] = re[i] - tr
          im[j] = im[i] - ti
          re[i] += tr
          im[i] += ti
        }
        start += half * 2
      }
      half *= 2
    }
  }
}
