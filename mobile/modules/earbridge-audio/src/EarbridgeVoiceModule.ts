import { type NativeModule, requireOptionalNativeModule } from 'expo';

export type EarbridgeVoiceEvents = {
  /** How much of the voice model is downloaded, in bytes; `total` is 0 when unknown. */
  onModelProgress: (event: { received: number; total: number }) => void;
};

declare class EarbridgeVoiceModule extends NativeModule<EarbridgeVoiceEvents> {
  /** Whether the voice model `file` is on the phone. */
  hasModel(file: string): boolean;
  /**
   * Downloads the voice model as `file`, keeping it only if its SHA-256 is `sha256`, and
   * deletes any other voice model. Rejects with a sentence that can be shown.
   */
  downloadModel(url: string, sha256: string, file: string): Promise<void>;
  /** Stops a download; it rejects. */
  cancelDownload(): void;
  /** Loads the voice model `file` (once), to make voice prints with it. */
  loadModel(file: string): Promise<void>;
  /** A voice print of 16 kHz 16-bit mono speech (little-endian), made with the loaded model. */
  voicePrint(pcm: Uint8Array): Promise<number[]>;
  /** Frees the loaded model's memory. */
  unloadModel(): void;
}

// Android, and iPhone (sherpa-onnx, the same speaker model): null elsewhere.
export default requireOptionalNativeModule<EarbridgeVoiceModule>('EarbridgeVoice');
