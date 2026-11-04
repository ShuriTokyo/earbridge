// The microphone: 16 kHz mono 16-bit sound for the speech recognizer, in 100 ms chunks.
// Android records with the app's own module, which can use Bluetooth earphones'
// microphones and keeps listening while the phone is locked. iPhone records with the app's
// own module too (EarbridgeCapture), after choosing the microphone in the audio session; it
// keeps only some voices and tells directions as Android does. Without it, the audio
// library's recorder.

import { PermissionsAndroid, Platform } from 'react-native';
import { AudioManager, AudioRecorder } from 'react-native-audio-api';
import type { AudioBuffer } from 'react-native-audio-api';

import { StreamingResampler, rms } from '../../../client/src/audio/resampler.ts';
import type { Spatial } from '../../../shared/pipeline/direction.ts';
import { AUDIO_SAMPLE_RATE } from '../../../shared/protocol.ts';
import EarbridgeAudio from '../../modules/earbridge-audio/src/EarbridgeAudioModule.ts';
import type {
  AudioEvent,
  CaptureInput,
  IsolationEvent,
  SeparationEvent,
} from '../../modules/earbridge-audio/src/EarbridgeAudioModule.ts';
import EarbridgeCapture from '../../modules/earbridge-audio/src/EarbridgeCaptureModule.ts';
import { fromBase64 } from '../base64.ts';
import { startIosSession, stopIosSession } from './ios-session.ts';

/**
 * live:   the sound goes to the recognizer.
 * silent: silence goes instead, e.g. while the phone speaker reads a translation aloud,
 *         so the recognizer neither hears the phone nor gives up waiting.
 * off:    nothing is sent (muted, or hold-to-talk with no button held).
 */
export type MicMode = 'live' | 'silent' | 'off';

export interface MicrophoneOptions {
  /** Listen through the earphones' microphone when they have one. */
  earphoneMic: boolean;
  /** Also tell which way the sound comes from, when the phone can (see `canHearDirections`). */
  directions?: boolean;
  /** 16 kHz mono PCM16, and which way it came from when asked for and the phone could tell. */
  onAudio(pcm: ArrayBuffer, spatial?: Spatial): void;
  /** Input level 0..1, ten times a second, whatever the mode. */
  onLevel(level: number): void;
  /** The microphone stopped by itself, e.g. a call took it. The message says why, in a sentence. */
  onEnded(message: string): void;
  /**
   * The mode went off and all that was heard before has come (onAudio): the turn can be
   * finished. While keeping only some voices (see `isolate`), that is a moment later.
   */
  onTurnEnd?(): void;
  /** While keeping only some voices: how each stretch of sound was split. */
  onSeparation?(event: SeparationEvent): void;
  /** Keeping only some voices started, stopped, could not keep up, or failed to start. */
  onIsolation?(event: IsolationEvent): void;
}

/** Voice prints to keep, and the speaker model that made them (its file name). */
export interface KeptVoices {
  model: string;
  prints: readonly Float32Array[];
  /**
   * When no voice in a stretch of sound is like the prints, send the sound as heard rather
   * than nothing: for when whoever talks says it is them, by holding or choosing their side.
   */
  passUnmatched: boolean;
}

/**
 * Android test builds play this raw recording (in the app's files folder) wherever the
 * microphone would be used.
 */
const TEST_AUDIO = process.env.EXPO_PUBLIC_TEST_AUDIO || undefined;

/** A problem worth showing as is. */
export class MicrophoneError extends Error {
  /** The phone does not let the app use the microphone: the way out is the phone's settings. */
  readonly notAllowed: boolean;

  constructor(message: string, notAllowed = false) {
    super(message);
    this.notAllowed = notAllowed;
  }
}

export interface Microphone {
  mode: MicMode;
  /** Which microphone listens. */
  readonly input: CaptureInput;
  /**
   * Keeps only voices like these in the sound sent (onAudio), taking out everyone else and
   * most of the noise; every voice again with undefined. The sound then comes 0.5 to 2 s
   * late, in bursts. False where the phone can't.
   */
  isolate(voices: KeptVoices | undefined): boolean;
  /**
   * Listens through the earphones' microphone (when they are connected and have one) or
   * the phone's from now on, keeping the mode and the voices kept; resolves with the
   * microphone in use, which is the phone's when the earphones' could not be. Nothing is
   * heard meanwhile: a second or two for Bluetooth earphones. Fails when no microphone
   * could be opened again: then listening has stopped.
   */
  switchInput(earphoneMic: boolean): Promise<CaptureInput>;
  stop(): void;
}

const NOT_ALLOWED_ANDROID = 'Alo isn’t allowed to use the microphone. Allow it in Settings › Apps › Alo › Permissions.';
const NOT_ALLOWED_IOS = 'Alo isn’t allowed to use the microphone. Allow it in Settings › Alo.';

/**
 * Whether this phone may tell which way voices come from, by recording two of its
 * microphones; whether a phone really has two shows once it records.
 */
export function canHearDirections(): boolean {
  return EarbridgeAudio !== null || (EarbridgeCapture?.canRecordStereo() ?? false);
}

export async function openMicrophone(options: MicrophoneOptions): Promise<Microphone> {
  if (EarbridgeAudio) {
    const status = await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.RECORD_AUDIO);
    if (status !== PermissionsAndroid.RESULTS.GRANTED) throw new MicrophoneError(NOT_ALLOWED_ANDROID, true);
    const mic = new NativeMicrophone(EarbridgeAudio, options, false);
    await mic.start();
    return mic;
  }
  if (Platform.OS === 'ios') {
    if ((await AudioManager.requestRecordingPermissions()) !== 'Granted') throw new MicrophoneError(NOT_ALLOWED_IOS, true);
    const mic = EarbridgeCapture ? new NativeMicrophone(EarbridgeCapture, options, true) : new IosMicrophone(options);
    await mic.start();
    return mic;
  }
  throw new MicrophoneError('This device is not supported.');
}

/** What both phones' modules do to record: Android's EarbridgeAudio, iPhone's EarbridgeCapture. */
type CaptureModule = Pick<
  NonNullable<typeof EarbridgeCapture>,
  'addListener' | 'startCapture' | 'stopCapture' | 'setMicMode' | 'keepVoices' | 'keepAllVoices'
>;

/**
 * The phone's module applies the mode as it hears, and keeps only some voices if asked. On
 * iPhone (`ios`), the audio session chooses the microphone before the module records.
 */
class NativeMicrophone implements Microphone {
  input: CaptureInput = { input: 'phone', name: 'Microphone' };
  private readonly module: CaptureModule;
  private readonly options: MicrophoneOptions;
  private readonly ios: boolean;
  private readonly subscriptions: { remove(): void }[];
  private stopped = false;
  private current: MicMode = 'off';
  private kept: KeptVoices | undefined;
  private earphoneMic: boolean;

  constructor(module: CaptureModule, options: MicrophoneOptions, ios: boolean) {
    this.module = module;
    this.options = options;
    this.ios = ios;
    this.earphoneMic = options.earphoneMic;
    this.subscriptions = [
      module.addListener('onAudio', (event) => {
        if (!this.stopped) options.onAudio(fromBase64(event.pcm).buffer, spatialOf(event));
      }),
      module.addListener('onLevel', ({ level }) => {
        if (!this.stopped) options.onLevel(level);
      }),
      module.addListener('onTurnEnd', () => {
        if (!this.stopped) options.onTurnEnd?.();
      }),
      module.addListener('onSeparation', (event) => {
        if (!this.stopped) options.onSeparation?.(event);
      }),
      module.addListener('onIsolation', (event) => {
        if (!this.stopped) options.onIsolation?.(event);
      }),
      module.addListener('onCaptureError', (event) => {
        if (this.stopped) return;
        this.release();
        options.onEnded(event.message);
      }),
    ];
  }

  get mode(): MicMode {
    return this.current;
  }

  set mode(mode: MicMode) {
    this.current = mode;
    if (!this.stopped) this.module.setMicMode(mode);
  }

  isolate(voices: KeptVoices | undefined): boolean {
    if (this.stopped || sameVoices(voices, this.kept)) return true;
    try {
      if (voices) {
        const { model, passUnmatched } = voices;
        this.module.keepVoices({ model, prints: voices.prints.map((print) => Array.from(print)), passUnmatched });
      } else {
        this.module.keepAllVoices();
      }
    } catch {
      return false;
    }
    this.kept = voices && { ...voices, prints: voices.prints.map((print) => print.slice()) };
    return true;
  }

  async start(): Promise<void> {
    this.module.setMicMode(this.current);
    try {
      this.input = await this.capture();
    } catch (error) {
      this.release();
      throw new MicrophoneError(errorText(error));
    }
  }

  /**
   * The phone's module starts over with the other microphone, keeping the mode and the
   * voices kept. Starting over closes the microphone first, so if the other one can't be
   * opened, the one that worked is opened again; if that fails too, listening is over.
   */
  async switchInput(earphoneMic: boolean): Promise<CaptureInput> {
    if (this.stopped) return this.input;
    const previous = this.earphoneMic;
    this.earphoneMic = earphoneMic;
    try {
      this.input = await this.capture();
    } catch (error) {
      this.earphoneMic = previous;
      try {
        this.input = await this.capture();
      } catch {
        this.stop();
        throw new MicrophoneError(errorText(error));
      }
    }
    return this.input;
  }

  private async capture(): Promise<CaptureInput> {
    if (this.ios) {
      const input = await startIosSession(this.earphoneMic);
      // Directions only from the phone's own microphones.
      await this.module.startCapture({ directions: (this.options.directions ?? false) && input.input === 'phone' });
      return input;
    }
    // Android's module takes these too (EarbridgeAudioModule.ts).
    const android: Parameters<CaptureModule['startCapture']>[0] & { earphoneMic: boolean; testInputPath?: string } = {
      earphoneMic: this.earphoneMic,
      directions: this.options.directions ?? false,
      testInputPath: TEST_AUDIO,
    };
    return this.module.startCapture(android);
  }

  stop(): void {
    if (this.stopped) return;
    this.release();
    const stopped = this.module.stopCapture().catch(() => {});
    if (this.ios) void stopped.then(() => stopIosSession());
  }

  private release(): void {
    this.stopped = true;
    for (const subscription of this.subscriptions.splice(0)) subscription.remove();
  }
}

/** What the phone told about which way the sound came from (nothing for silence sent instead). */
function spatialOf(event: AudioEvent): Spatial | undefined {
  if (event.pose === undefined) return undefined;
  const { pose, delay, clarity } = event;
  return delay !== undefined && clarity !== undefined ? { pose, direction: { delay, clarity } } : { pose };
}

function sameVoices(a: KeptVoices | undefined, b: KeptVoices | undefined): boolean {
  if (!a || !b) return a === b;
  return (
    a.model === b.model &&
    a.passUnmatched === b.passUnmatched &&
    a.prints.length === b.prints.length &&
    a.prints.every((print, k) => {
      const other = b.prints[k];
      return other !== undefined && print.length === other.length && print.every((value, i) => value === other[i]);
    })
  );
}

class IosMicrophone implements Microphone {
  input: CaptureInput = { input: 'phone', name: 'Microphone' };
  private readonly options: MicrophoneOptions;
  private current: MicMode = 'off';
  private readonly recorder = new AudioRecorder();
  private resampler: StreamingResampler | undefined;
  private resamplerRate = 0;
  private interruption: { remove(): void } | undefined;
  private stopped = false;

  constructor(options: MicrophoneOptions) {
    this.options = options;
  }

  async start(): Promise<void> {
    try {
      this.input = await startIosSession(this.options.earphoneMic);
    } catch (error) {
      throw new MicrophoneError(`Could not start the microphone: ${errorText(error)}`);
    }
    // A call (or Siri) takes the microphone away; the conversation has to be restarted.
    this.interruption = AudioManager.addSystemEventListener('interruption', (event) => {
      if (event.type === 'began') this.fail('A call or another app interrupted the microphone.');
    });
    this.recorder.onError((event) => this.fail(`The microphone stopped working: ${event.message}`));
    const callback = this.recorder.onAudioReady(
      { sampleRate: AUDIO_SAMPLE_RATE, bufferLength: AUDIO_SAMPLE_RATE / 10, channelCount: 1 },
      (event) => this.onBuffer(event.buffer),
    );
    const result = callback.status === 'error' ? callback : await this.recorder.start();
    if (result.status === 'error') {
      this.release();
      throw new MicrophoneError(`Could not start the microphone: ${result.message}`);
    }
  }

  get mode(): MicMode {
    return this.current;
  }

  /** Sound goes on as it is heard, so a turn is over as soon as the mode goes off. */
  set mode(mode: MicMode) {
    const ended = mode === 'off' && this.current !== 'off';
    this.current = mode;
    if (ended && !this.stopped) this.options.onTurnEnd?.();
  }

  isolate(): boolean {
    return false;
  }

  /** The recorder keeps going; only the audio session's input changes. */
  async switchInput(earphoneMic: boolean): Promise<CaptureInput> {
    if (this.stopped) return this.input;
    try {
      this.input = await startIosSession(earphoneMic);
    } catch (error) {
      throw new MicrophoneError(`Could not switch the microphone: ${errorText(error)}`);
    }
    return this.input;
  }

  stop(): void {
    if (this.stopped) return;
    this.release();
  }

  private onBuffer(buffer: AudioBuffer): void {
    if (this.stopped) return;
    const samples = buffer.getChannelData(0);
    this.options.onLevel(Math.min(1, rms(samples) * 4));
    // The recorder may deliver another rate than asked for.
    if (!this.resampler || this.resamplerRate !== buffer.sampleRate) {
      this.resampler = new StreamingResampler(buffer.sampleRate, AUDIO_SAMPLE_RATE);
      this.resamplerRate = buffer.sampleRate;
    }
    const pcm = this.resampler.process(samples);
    if (this.mode === 'live') this.options.onAudio(pcm.buffer);
    else if (this.mode === 'silent') this.options.onAudio(new ArrayBuffer(pcm.byteLength));
  }

  private fail(message: string): void {
    if (this.stopped) return;
    this.release();
    this.options.onEnded(message);
  }

  private release(): void {
    this.stopped = true;
    this.interruption?.remove();
    this.recorder.clearOnAudioReady();
    this.recorder.clearOnError();
    void this.recorder
      .stop()
      .catch(() => {})
      .then(() => stopIosSession());
  }
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
