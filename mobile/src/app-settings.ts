// What the app remembers: the web app's settings, plus what only the phone app asks for:
// who does the work, the server, the user's own API keys, the microphone, and whether the
// first-time setup is done.

import { getLocales } from 'expo-localization';
import * as SecureStore from 'expo-secure-store';

import { loadSettings, saveSettings } from '../../client/src/settings.ts';
import type { Settings } from '../../client/src/settings.ts';
import { localSupport, localWordTimings } from './engines/local.ts';
import { storage } from './storage.ts';

/**
 * auto: the phone's microphone with one phone (it hears you both, and Bluetooth earphones
 *       keep their full sound quality), the earphones' microphone in a room. Switching
 *       during a conversation makes it phone or earphones.
 */
export type MicChoice = 'auto' | 'phone' | 'earphones';

/**
 * Who does the work with one phone (a room always uses a server):
 * local:  the phone itself, with Android's speech recognition and translation.
 * keys:   Deepgram and DeepInfra, with the user's own API keys.
 * server: a computer running Alo's server.
 */
export type Engine = 'local' | 'keys' | 'server';

export interface AppSettings extends Settings {
  engine: Engine;
  /** The computer running the server, as typed, e.g. "192.168.1.20:8787". */
  server: string;
  /** The user's own keys, as typed. Stored encrypted, apart from the other settings. */
  deepgramKey: string;
  deepinfraKey: string;
  mic: MicChoice;
  /**
   * One phone, translated by the app itself (see `appFilters`): translate only my voice
   * (recorded once) and the other person's.
   */
  onlyOurVoices: boolean;
  /**
   * With `onlyOurVoices`, on Android: once both voices are known, split what the microphone
   * hears into voices before the speech recognizer hears it, and keep only ours.
   */
  separateVoices: boolean;
  /**
   * One phone, translated by the app itself: skip voices from the phone's sides, told by
   * which way they come (with a phone lying between the two people that records two
   * microphones).
   */
  ignoreSides: boolean;
  /** The first-time setup was finished (or the app was used before it existed). */
  setupDone: boolean;
}

export const MAX_KEY_LENGTH = 200;

const APP_KEY = 'earbridge.app';
const DEEPGRAM_KEY = 'earbridge.deepgramKey';
const DEEPINFRA_KEY = 'earbridge.deepinfraKey';
/** On iPhone, the keys stay out of backups and off other phones, as they do on Android. */
const KEY_OPTIONS: SecureStore.SecureStoreOptions = { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY };
/** Can be built in: EXPO_PUBLIC_SERVER_URL=http://192.168.1.20:8787 npx expo run:android */
const DEFAULT_SERVER = process.env.EXPO_PUBLIC_SERVER_URL ?? '';

export function loadAppSettings(): AppSettings {
  const languages = getLocales().map((locale) => locale.languageTag);
  const settings = loadSettings(storage, languages.length > 0 ? languages : ['en-US']);
  const stored = storage.getItem(APP_KEY);
  let saved: Record<string, unknown> = {};
  try {
    const parsed: unknown = JSON.parse(stored ?? '{}');
    if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
      saved = parsed as Record<string, unknown>;
    }
  } catch {
    // Unreadable: start from the defaults.
  }
  const server = typeof saved['server'] === 'string' && saved['server'].trim() ? saved['server'] : DEFAULT_SERVER;
  const mic = saved['mic'] === 'phone' || saved['mic'] === 'earphones' ? saved['mic'] : 'auto';
  const engine = isEngine(saved['engine']) ? saved['engine'] : defaultEngine(server);
  const onlyOurVoices = saved['onlyOurVoices'] === true;
  const separateVoices = saved['separateVoices'] !== false;
  const ignoreSides = saved['ignoreSides'] !== false;
  // Settings saved by a version without the setup were made by someone who set the app up.
  const setupDone = saved['setupDone'] === true || (stored !== null && !('setupDone' in saved));
  return {
    ...settings,
    engine,
    server: server.slice(0, 500),
    deepgramKey: readKey(DEEPGRAM_KEY),
    deepinfraKey: readKey(DEEPINFRA_KEY),
    mic,
    onlyOurVoices,
    separateVoices,
    ignoreSides,
    setupDone,
  };
}

export function saveAppSettings(settings: AppSettings): void {
  const { engine, server, deepgramKey, deepinfraKey, mic, onlyOurVoices, separateVoices, ignoreSides, setupDone, ...shared } = settings;
  saveSettings(storage, shared);
  storage.setItem(APP_KEY, JSON.stringify({ engine, server, mic, onlyOurVoices, separateVoices, ignoreSides, setupDone }));
  storeKey(DEEPGRAM_KEY, deepgramKey);
  storeKey(DEEPINFRA_KEY, deepinfraKey);
}

/**
 * Whether the noisy-place filters can work: they judge speech by its sound, so the speech
 * recognition must say when each word was said. The phone’s own does from Android 14 and iOS 26.
 */
export function filtersWork(engine: Engine): boolean {
  return engine !== 'local' || localWordTimings();
}

/** Whether the filters only the app runs itself work: voices from the sides, only our two voices. */
export function appFilters(engine: Engine): boolean {
  return engine !== 'server' && filtersWork(engine);
}

/** Whether to listen through the earphones' microphone, when they have one. */
export function wantsEarphoneMic(settings: AppSettings): boolean {
  return settings.mic === 'earphones' || (settings.mic === 'auto' && settings.mode === 'room');
}

function isEngine(value: unknown): value is Engine {
  return value === 'local' || value === 'keys' || value === 'server';
}

/** A server someone already set up, else the phone itself if it can, else own keys. */
function defaultEngine(server: string): Engine {
  if (server.trim()) return 'server';
  return localSupport().available ? 'local' : 'keys';
}

// ---------------------------------------------------------------- the keys

/** What the secure store holds, as far as this app knows. */
const storedKeys = new Map<string, string>();
/** Values still to be written, by name: only the latest of several quick changes is. */
const unsavedKeys = new Map<string, string>();
let keyWrites: Promise<void> = Promise.resolve();

function readKey(name: string): string {
  try {
    const value = (SecureStore.getItem(name) ?? '').slice(0, MAX_KEY_LENGTH);
    storedKeys.set(name, value);
    return value;
  } catch {
    // e.g. Android reset its keystore: the key has to be entered again.
    return '';
  }
}

function storeKey(name: string, value: string): void {
  if ((unsavedKeys.get(name) ?? storedKeys.get(name)) === value) return;
  unsavedKeys.set(name, value);
  keyWrites = keyWrites.then(async () => {
    const latest = unsavedKeys.get(name);
    if (latest === undefined) return; // an earlier write already took it
    unsavedKeys.delete(name);
    try {
      if (latest) await SecureStore.setItemAsync(name, latest, KEY_OPTIONS);
      else await SecureStore.deleteItemAsync(name);
      storedKeys.set(name, latest);
    } catch {
      // Not saved: it is written again with the next change.
      storedKeys.delete(name);
    }
  });
}
