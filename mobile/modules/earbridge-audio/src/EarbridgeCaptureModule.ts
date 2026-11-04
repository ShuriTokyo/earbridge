import { type NativeModule, requireOptionalNativeModule } from 'expo';

import type { CaptureInput, EarbridgeAudioEvents } from './EarbridgeAudioModule.ts';

/** The same events as Android's capture (see EarbridgeAudioModule.ts). */
export type EarbridgeCaptureEvents = Pick<
  EarbridgeAudioEvents,
  'onAudio' | 'onLevel' | 'onTurnEnd' | 'onSeparation' | 'onIsolation' | 'onCaptureError'
>;

declare class EarbridgeCaptureModule extends NativeModule<EarbridgeCaptureEvents> {
  /** Whether the iPhone may record its microphones in stereo, to tell directions. */
  canRecordStereo(): boolean;
  /**
   * Records whatever microphone the audio session uses (ios-session.ts chooses it first).
   * With `directions`, the phone's own microphones in stereo, telling which way sound came from.
   */
  startCapture(options: { directions?: boolean }): Promise<CaptureInput>;
  /** Also forgets the voices to keep. */
  stopCapture(): Promise<void>;
  setMicMode(mode: 'live' | 'silent' | 'off'): void;
  keepVoices(options: { model: string; prints: number[][]; passUnmatched?: boolean }): void;
  keepAllVoices(): void;
}

/**
 * iPhone only: the microphone with the voice checks Android's capture has (keeping only some
 * voices, and which way they come from). Null on Android, which uses EarbridgeAudio.
 */
export default requireOptionalNativeModule<EarbridgeCaptureModule>('EarbridgeCapture');
