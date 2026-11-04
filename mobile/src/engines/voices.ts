// "Only our voices": voice prints made on the phone by a small speaker model, downloaded
// once. The phone owner's print comes from a recording made in the settings and is kept
// in the phone's secure storage, like the prints of people they talk with, saved with
// those people's OK. Neither the recordings nor the prints leave the phone.

import * as SecureStore from 'expo-secure-store';

import { CAMPPLUS_BARS } from '../../../shared/pipeline/voices.ts';
import type { LearnedPrints, VoiceBars, VoicePrinter } from '../../../shared/pipeline/voices.ts';
import EarbridgeVoice from '../../modules/earbridge-audio/src/EarbridgeVoiceModule.ts';
import { fromBase64, toBase64 } from '../base64.ts';

/**
 * The speaker model. Voice prints can only be compared with prints from the same model,
 * and how alike they must be (`bars`) goes with it. Another model sherpa-onnx loads can
 * take its place here, with its own bars (see `VoiceBars`; the microphone's voice separation
 * keeps a voice by a bar of its own on the same scale, KEEP in VoiceIsolator.kt): a change of
 * file forgets the recorded and learned voices, which were prints of the old one.
 */
const MODEL = {
  // CAM++ from 3D-Speaker, trained on Chinese and English speech (Apache-2.0).
  file: '3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx',
  url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx',
  sha256: 'aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2',
  bars: CAMPPLUS_BARS satisfies VoiceBars,
};
/** How alike the model's voice prints must be to be the same voice. */
export const VOICE_BARS: VoiceBars = MODEL.bars;
/** The speaker model's file name, for the microphone's own voice separation (see mic.ts). */
export const VOICE_MODEL_FILE = MODEL.file;
/** About how much the voice model downloads, in MB. */
export const VOICE_MODEL_MB = 28;

const MY_VOICE = 'earbridge.myVoice';
/** Which microphones my voice is kept for as heard through them, as the secure storage cannot list what it keeps. */
const MY_MICS = 'earbridge.myMics';
/** Where my voice as heard through one microphone is kept. Ids are letters and digits, as keys must be. */
const myVoiceThrough = (id: string) => `earbridge.myVoiceHere.${id}`;
/** How many microphones my voice is kept for as heard through them: the ones used last. */
const KEPT_MICS = 4;
/** Who has a voice print saved: the secure storage cannot list what it keeps. */
const PEOPLE = 'earbridge.people';
/** Where one person's voice print is kept. Ids are letters and digits, as keys must be. */
const personVoice = (id: string) => `earbridge.voice.${id}`;
/** How long a name can be. */
export const NAME_LENGTH = 40;
/** Like the API keys: kept out of backups and off other phones. */
const SECURE_OPTIONS: SecureStore.SecureStoreOptions = { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY };

/** Whether this phone can tell voices apart: with the app’s own module (Android and iPhone). */
export function canCheckVoices(): boolean {
  return EarbridgeVoice !== null;
}

/** Whether the speaker model is on the phone already. */
export function hasVoiceModel(): boolean {
  return EarbridgeVoice?.hasModel(MODEL.file) ?? false;
}

/**
 * Gets the speaker model onto the phone unless it is there already, reporting how much
 * is done (0 to 1). Rejects with an error whose message can be shown.
 */
export async function prepareVoiceModel(signal: AbortSignal, progress: (done: number) => void): Promise<void> {
  const module = voiceModule();
  if (!module.hasModel(MODEL.file)) {
    const subscription = module.addListener('onModelProgress', ({ received, total }) => {
      if (total > 0) progress(Math.min(1, received / total));
    });
    const cancel = () => module.cancelDownload();
    signal.addEventListener('abort', cancel);
    try {
      if (signal.aborted) throw abortError(signal);
      await module.downloadModel(MODEL.url, MODEL.sha256, MODEL.file);
    } catch (error) {
      if (signal.aborted) throw abortError(signal);
      throw new Error(`Couldn’t download the voice model: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      signal.removeEventListener('abort', cancel);
      subscription.remove();
    }
  }
  await module.loadModel(MODEL.file);
  if (signal.aborted) throw abortError(signal);
}

/** A voice print of some 16 kHz mono speech, once the model is ready. */
export async function printVoice(samples: Int16Array): Promise<Float32Array | undefined> {
  // A copy: the module reads whole arrays, not views into larger ones.
  const pcm = new Uint8Array(samples.buffer.slice(samples.byteOffset, samples.byteOffset + samples.byteLength));
  const print = await voiceModule().voicePrint(pcm);
  return print.length > 0 ? Float32Array.from(print) : undefined;
}

/** Frees the speaker model's memory, e.g. once the conversation is over. */
export function releaseVoiceModel(): void {
  EarbridgeVoice?.unloadModel();
}

/**
 * Prints voices for a conversation: makes sure the model is ready, downloading it if it
 * went missing. Undefined when my voice is not recorded.
 */
export async function conversationVoices(
  signal: AbortSignal,
  progress: (text: string) => void,
): Promise<VoicePrinter | undefined> {
  const mine = loadMyVoice();
  if (!mine || !canCheckVoices()) return undefined;
  await prepareVoiceModel(signal, (done) => progress(`Downloading the voice model… ${Math.round(done * 100)}%`));
  return { mine, print: printVoice, bars: MODEL.bars };
}

// ---------------------------------------------------------------- my voice

/** A voice print as kept, with when it was recorded (not known for older ones). */
export interface KeptVoice {
  print: Float32Array;
  /** In ms since 1970. */
  saved: number | undefined;
}

/** My voice print, if it was recorded with the current model. */
export function loadMyVoice(): Float32Array | undefined {
  return readVoice(MY_VOICE)?.print;
}

export function readMyVoice(): KeptVoice | undefined {
  return readVoice(MY_VOICE);
}

/**
 * Rejects if the phone could not store it. How it sounds through each microphone is
 * learned afresh from then on.
 */
export async function saveMyVoice(print: Float32Array): Promise<void> {
  await forgetMyVoiceHere();
  await writeVoice(MY_VOICE, print, Date.now());
}

export async function deleteMyVoice(): Promise<void> {
  // How it sounds through each microphone first: my voice left on the phone can be deleted again.
  await forgetMyVoiceHere();
  await SecureStore.deleteItemAsync(MY_VOICE);
}

// ---------------------------------------------------------------- my voice as heard here

/** A microphone my voice is kept for, as heard through it. */
interface KeptMic {
  /** Letters and digits. */
  id: string;
  /** Which microphone, as the conversation names it. */
  mic: string;
  /** When my voice through it was last kept, in ms since 1970. */
  saved: number;
}

/**
 * My voice as heard through a microphone in earlier conversations, as the voice filter
 * learned it there, unless that was with another speaker model or it can no longer be read.
 */
export function loadMyVoiceHere(mic: string): LearnedPrints | undefined {
  const kept = listMics().find((other) => other.mic === mic);
  const voice = kept && readRecord(myVoiceThrough(kept.id));
  if (!voice) return undefined;
  const { lines, seconds, likenesses } = voice.record;
  if (typeof lines !== 'number' || !(lines >= 1) || !voice.print.every(Number.isFinite)) return undefined;
  const known = Array.isArray(likenesses) ? likenesses.filter((value): value is number => typeof value === 'number' && Number.isFinite(value)) : [];
  return { sum: voice.print, count: lines, ...(typeof seconds === 'number' && seconds > 0 && { seconds }), ...(known.length > 0 && { likenesses: known }) };
}

/**
 * Keeps my voice as heard through a microphone, for the next conversations through it:
 * for the few microphones used last. Rejects if the phone could not store it.
 */
export async function saveMyVoiceHere(mic: string, learned: LearnedPrints): Promise<void> {
  const mics = listMics();
  const kept: KeptMic = { id: mics.find((other) => other.mic === mic)?.id ?? newId(), mic, saved: Date.now() };
  const others = mics.filter((other) => other.id !== kept.id);
  // Each print on the list before it is written and until it is deleted, so that forgetting
  // them all leaves none behind.
  for (const old of others.slice(KEPT_MICS - 1)) await SecureStore.deleteItemAsync(myVoiceThrough(old.id));
  await writeMics([kept, ...others.slice(0, KEPT_MICS - 1)]);
  await writeVoice(myVoiceThrough(kept.id), learned.sum, kept.saved, { lines: learned.count, seconds: learned.seconds, likenesses: learned.likenesses });
}

/** Forgets my voice as heard through every microphone. */
async function forgetMyVoiceHere(): Promise<void> {
  for (const kept of listMics()) await SecureStore.deleteItemAsync(myVoiceThrough(kept.id));
  await SecureStore.deleteItemAsync(MY_MICS);
}

/** The microphones my voice is kept for, most recently first. */
function listMics(): KeptMic[] {
  try {
    const mics: unknown = JSON.parse(SecureStore.getItem(MY_MICS) ?? '[]');
    return Array.isArray(mics) ? mics.filter(isKeptMic).sort((a, b) => b.saved - a.saved) : [];
  } catch {
    return [];
  }
}

async function writeMics(mics: KeptMic[]): Promise<void> {
  await SecureStore.setItemAsync(MY_MICS, JSON.stringify(mics), SECURE_OPTIONS);
}

function isKeptMic(value: unknown): value is KeptMic {
  if (typeof value !== 'object' || value === null) return false;
  const { id, mic, saved } = value as Record<string, unknown>;
  return typeof id === 'string' && /^[a-z0-9]{1,40}$/.test(id) && typeof mic === 'string' && typeof saved === 'number';
}

// ---------------------------------------------------------------- people I talk with

/** Someone whose voice print is saved on the phone, with their OK, for the next conversations. */
export interface SavedPerson {
  /** Letters and digits. */
  id: string;
  name: string;
  /** When their voice was recorded, in ms since 1970. */
  saved: number;
}

/** Everyone with a saved voice print, most recently recorded first. */
export function listPeople(): SavedPerson[] {
  try {
    const people: unknown = JSON.parse(SecureStore.getItem(PEOPLE) ?? '[]');
    return Array.isArray(people) ? people.filter(isPerson).sort((a, b) => b.saved - a.saved) : [];
  } catch {
    return [];
  }
}

/** Their voice print, unless it was made by another speaker model or can no longer be read. */
export function readPersonVoice(id: string): KeptVoice | undefined {
  return readVoice(personVoice(id));
}

/** Saves their voice print under their name, instead of one saved under the same name. */
export async function savePerson(name: string, print: Float32Array): Promise<SavedPerson> {
  const people = listPeople();
  const trimmed = name.trim().slice(0, NAME_LENGTH);
  const same = people.find((person) => person.name.toLocaleLowerCase() === trimmed.toLocaleLowerCase());
  const person: SavedPerson = { id: same?.id ?? newId(), name: trimmed, saved: Date.now() };
  // The print first, so the list never names someone without one.
  await writeVoice(personVoice(person.id), print, person.saved);
  await writePeople([person, ...people.filter((other) => other.id !== person.id)]);
  return person;
}

export async function deletePerson(id: string): Promise<void> {
  // The print first: a name left on the list can be deleted again, a print left alone could not.
  await SecureStore.deleteItemAsync(personVoice(id));
  await writePeople(listPeople().filter((person) => person.id !== id));
}

async function writePeople(people: SavedPerson[]): Promise<void> {
  await SecureStore.setItemAsync(PEOPLE, JSON.stringify(people), SECURE_OPTIONS);
}

function isPerson(value: unknown): value is SavedPerson {
  if (typeof value !== 'object' || value === null) return false;
  const { id, name, saved } = value as Record<string, unknown>;
  return typeof id === 'string' && /^[a-z0-9]{1,40}$/.test(id) && typeof name === 'string' && typeof saved === 'number';
}

function newId(): string {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

// ---------------------------------------------------------------- kept voice prints

function readVoice(key: string): KeptVoice | undefined {
  const voice = readRecord(key);
  if (!voice) return undefined;
  const { saved } = voice.record;
  return { print: voice.print, saved: typeof saved === 'number' ? saved : undefined };
}

/** A voice print as kept, with whatever else was kept with it, unless it was made by another speaker model. */
function readRecord(key: string): { print: Float32Array; record: Record<string, unknown> } | undefined {
  try {
    const kept: unknown = JSON.parse(SecureStore.getItem(key) ?? 'null');
    if (typeof kept !== 'object' || kept === null) return undefined;
    const record = kept as Record<string, unknown>;
    const { model, print } = record;
    if (model !== MODEL.file || typeof print !== 'string') return undefined;
    const bytes = fromBase64(print);
    if (bytes.length === 0 || bytes.length % 4 !== 0) return undefined;
    return { print: new Float32Array(bytes.buffer), record };
  } catch {
    // Unreadable, e.g. Android reset its keystore: the voice has to be recorded again.
    return undefined;
  }
}

/** Rejects if the phone could not store it. */
async function writeVoice(key: string, print: Float32Array, saved: number, extra?: Record<string, unknown>): Promise<void> {
  const bytes = new Uint8Array(print.buffer, print.byteOffset, print.byteLength);
  const record = { ...extra, model: MODEL.file, print: toBase64(bytes), saved };
  await SecureStore.setItemAsync(key, JSON.stringify(record), SECURE_OPTIONS);
}

function voiceModule(): NonNullable<typeof EarbridgeVoice> {
  if (!EarbridgeVoice) throw new Error('Telling voices apart isn’t available on this phone.');
  return EarbridgeVoice;
}

function abortError(signal: AbortSignal): unknown {
  return signal.reason ?? new Error('Aborted');
}
