// Everything that can be changed: who translates, how to talk, where translations are
// heard, help for noisy places, and the microphone and voice under "More options".

import { useState } from 'react';
import { Pressable, Text, View } from 'react-native';

import { appFilters, filtersWork, wantsEarphoneMic } from '../app-settings.ts';
import { canHearDirections } from '../audio/mic.ts';
import type { AppSettings, MicChoice } from '../app-settings.ts';
import { Divider, Note, SectionTitle } from '../components/Basics.tsx';
import { Button, CompactButton } from '../components/Button.tsx';
import { ChoiceCard, RadioRow, Segments, SwitchRow } from '../components/Choices.tsx';
import { Icon } from '../components/Icon.tsx';
import { Screen } from '../components/Screen.tsx';
import { VoiceRecorder } from '../components/VoiceRecorder.tsx';
import { canCheckVoices, listPeople, loadMyVoice, saveMyVoice } from '../engines/voices.ts';
import { normalizeServerUrl } from '../server-url.ts';
import { RADIUS, themedStyles, type } from '../theme.ts';
import { EngineCards, OutputCards, SERVER_MISSING, ServerFields, useBackButton } from './parts.tsx';
import type { Update } from './parts.tsx';

const PRIVACY: Readonly<Record<AppSettings['engine'], string>> = {
  local: 'What you say stays on this phone. Alo keeps no recordings or transcripts.',
  keys: 'Your voice goes to Deepgram and the text to DeepInfra, with your keys. Alo keeps no recordings or transcripts.',
  server: 'What you say goes to the computer running Alo. Alo keeps no recordings or transcripts.',
};

const MICROPHONES = [
  { value: 'auto', top: 'Automatic' },
  { value: 'phone', top: 'Phone' },
  { value: 'earphones', top: 'Earphones' },
] as const satisfies readonly { value: MicChoice; top: string }[];

interface SettingsScreenProps {
  settings: AppSettings;
  onChange: Update;
  onDone(): void;
  onKeys(): void;
  /** Opens the voices kept on the phone. */
  onVoices(): void;
  /** Opened because a conversation needs the computer's address: says so at once. */
  check?: boolean;
}

export function SettingsScreen({ settings, onChange, onDone, onKeys, onVoices, check = false }: SettingsScreenProps) {
  const { styles, palette } = useStyles();
  const [serverError, setServerError] = useState(() =>
    check && !normalizeServerUrl(settings.server) ? SERVER_MISSING : undefined,
  );
  const [myVoice, setMyVoice] = useState(() => loadMyVoice() !== undefined);
  const [people] = useState(() => listPeople().length);
  const [recording, setRecording] = useState(false);
  const [more, setMore] = useState(false);

  useBackButton(() => {
    onDone();
    return true;
  });

  const { engine } = settings;
  const filters = filtersWork(engine);
  const voices = appFilters(engine) && canCheckVoices();
  const sides = appFilters(engine) && canHearDirections();
  // A computer only skips far-away voices.
  const notHere = engine === 'server' ? ' Not through a computer.' : '';
  // Deepgram is paid by the second of sound sent to it, so other voices are kept from it.
  const unsent =
    engine === 'keys'
      ? ' Once your voice has been heard here, other voices are not even sent to Deepgram, so they can’t be translated after all.'
      : '';
  // Deepgram tells talkers apart for about a fifth more per minute: what someone says over one of us is left out.
  const apart = engine === 'keys' ? ' Deepgram is also asked who said each word (about a fifth more per minute), so what someone says over you is left out.' : '';
  const keysSaved = settings.deepgramKey.trim() !== '' && settings.deepinfraKey.trim() !== '';

  const setOnlyOurVoices = (on: boolean) => {
    if (!on) onChange({ onlyOurVoices: false });
    else if (myVoice) onChange({ onlyOurVoices: true });
    else setRecording(true);
  };
  // Kept voices can be seen and deleted even where they can't be used.
  const showVoices = canCheckVoices() && (voices || myVoice || people > 0);
  const others = `${people} ${people === 1 ? 'person' : 'people'} you talk with`;
  const kept = myVoice ? (people > 0 ? `Yours, and ${others}` : 'Yours') : people > 0 ? others : 'None saved yet';

  return (
    <>
      <Screen gap={28}>
        <View style={styles.header}>
          <Text style={styles.title} accessibilityRole="header">
            Settings
          </Text>
          <CompactButton label="Done" icon="check" onPress={onDone} />
        </View>

        <View style={styles.section}>
          <SectionTitle>Translation</SectionTitle>
          <EngineCards
            settings={settings}
            onChange={onChange}
            details={
              engine === 'keys' ? (
                <View style={styles.box}>
                  <View style={styles.boxHead}>
                    <Icon name={keysSaved ? 'circle-check' : 'circle-alert'} size={26} color={keysSaved ? palette.live : palette.busy} />
                    <Text style={styles.boxTitle}>{keysSaved ? 'Account keys: saved' : 'Account keys: not entered yet'}</Text>
                  </View>
                  <Button label={keysSaved ? 'Change keys' : 'Enter keys'} icon="key-round" onPress={onKeys} />
                </View>
              ) : (
                engine === 'server' && (
                  <ServerFields
                    settings={settings}
                    onChange={onChange}
                    addressLabel="The computer’s address"
                    error={serverError}
                    onEdit={() => setServerError(undefined)}
                  />
                )
              )
            }
          />
        </View>
        <Divider />

        <View style={styles.section}>
          <SectionTitle>Talking</SectionTitle>
          <View style={styles.cards} accessibilityRole="radiogroup">
            <ChoiceCard
              icon="mic"
              title="Talk freely"
              description="The microphone stays on. Best in quiet places."
              selected={settings.talkMode === 'handsfree'}
              onPress={() => onChange({ talkMode: 'handsfree' })}
            />
            <ChoiceCard
              icon="hand"
              title="Press and hold to talk"
              description="Best in noisy places."
              selected={settings.talkMode === 'hold'}
              onPress={() => onChange({ talkMode: 'hold' })}
            />
          </View>
        </View>
        <Divider />

        <View style={styles.section}>
          <SectionTitle>Hearing translations</SectionTitle>
          <OutputCards settings={settings} onChange={onChange} />
        </View>
        <Divider />

        <View style={styles.section}>
          {filters ? (
            <SectionTitle hint="For conversations on one phone.">Noisy places</SectionTitle>
          ) : (
            <>
              <SectionTitle muted>Noisy places</SectionTitle>
              <View style={styles.why}>
                <Icon name="info" size={22} color={palette.idle} />
                <Text style={styles.whyText}>
                  On this phone, they need Android 14 or iOS 26 or newer. Press and hold to talk works best in noisy places.
                </Text>
              </View>
            </>
          )}
          <SwitchRow
            title="Ignore far-away voices"
            description="Skips speech much quieter than you two, like other tables, a TV or a radio."
            value={settings.nearbyOnly}
            disabled={!filters}
            onChange={(nearbyOnly) => onChange({ nearbyOnly })}
          />
          <SwitchRow
            title="Ignore voices from the sides"
            description={`Lay the phone between you, top toward them. Skips people at its sides.${notHere}`}
            value={sides && settings.ignoreSides}
            disabled={!sides}
            onChange={(ignoreSides) => onChange({ ignoreSides })}
          />
          <SwitchRow
            title="Only our two voices"
            description={`Shows and translates only you two: your recorded voice, and theirs, learned as they talk.${notHere}${unsent}${apart}`}
            value={voices && myVoice && settings.onlyOurVoices}
            disabled={!voices}
            onChange={setOnlyOurVoices}
          />
          <SwitchRow
            title="Separate voices"
            description="Takes other voices out of the sound before it is written: while you hold or choose Me, every voice but yours; otherwise, once their voice is learned or recorded, all but you two. Words come a bit later."
            value={voices && myVoice && settings.onlyOurVoices && settings.separateVoices}
            disabled={!voices || !myVoice || !settings.onlyOurVoices}
            onChange={(separateVoices) => onChange({ separateVoices })}
          />
          {showVoices && (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel={`Voices: ${kept}`}
              onPress={onVoices}
              style={({ pressed }) => [styles.toggle, pressed && styles.pressed]}
            >
              <Icon name="audio-lines" size={26} color={palette.accent} />
              <View style={styles.entry}>
                <Text style={styles.entryTitle}>Voices</Text>
                <Text style={styles.entryText}>{kept}</Text>
              </View>
              <Icon name="chevron-right" size={26} color={palette.text} />
            </Pressable>
          )}
          {filters && (
            <Note icon="info" tone="muted">
              Anything skipped by mistake can still be translated: tap Translate on it. Voices taken out before writing can’t be.
            </Note>
          )}
        </View>
        <Divider />

        <View style={styles.more}>
          <Pressable
            accessibilityRole="button"
            accessibilityState={{ expanded: more }}
            onPress={() => setMore((open) => !open)}
            style={({ pressed }) => [styles.toggle, pressed && styles.pressed]}
          >
            <Text style={styles.moreTitle}>More options</Text>
            <Text style={styles.moreState}>{more ? 'Hide' : 'Show'}</Text>
            <Icon name={more ? 'chevron-up' : 'chevron-down'} size={26} color={palette.text} />
          </Pressable>
          {more && (
            <View style={styles.moreContent}>
              <View style={styles.field}>
                <Segments<MicChoice>
                  label="Microphone"
                  options={MICROPHONES}
                  value={settings.mic}
                  onChange={(mic) => onChange({ mic })}
                />
                <Text style={styles.hint}>
                  With one phone, the phone’s own microphone usually works best. While earphones are connected, you can
                  also switch during a conversation: tap the microphone’s name under the words.
                </Text>
              </View>
              {engine !== 'local' && (
                <View style={styles.field} accessibilityRole="radiogroup" accessibilityLabel="Voice">
                  <Text style={styles.label}>Voice</Text>
                  <RadioRow
                    label="Natural voice"
                    selected={settings.voice === 'natural'}
                    onPress={() => onChange({ voice: 'natural' })}
                  />
                  <RadioRow
                    label="The phone’s own voice"
                    selected={settings.voice === 'phone'}
                    onPress={() => onChange({ voice: 'phone' })}
                  />
                </View>
              )}
            </View>
          )}
        </View>

        <Divider />

        <View style={styles.section}>
          <SectionTitle>Privacy</SectionTitle>
          <View style={styles.privacy}>
            <Icon name="lock" size={24} color={palette.accent} />
            <Text style={styles.privacyText}>{PRIVACY[engine]}</Text>
          </View>
        </View>
        <Button kind="primary" label="Done" icon="check" onPress={onDone} />
      </Screen>
      {recording && (
        <VoiceRecorder
          earphoneMic={wantsEarphoneMic({ ...settings, mode: 'solo' })}
          save={saveMyVoice}
          onDone={() => {
            setRecording(false);
            setMyVoice(true);
            onChange({ onlyOurVoices: true });
          }}
          onClose={() => setRecording(false)}
        />
      )}
    </>
  );
}

const useStyles = themedStyles((palette) => ({
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },
  title: {
    ...type.title,
    flexShrink: 1,
    color: palette.text,
  },
  section: {
    gap: 12,
  },
  more: {
    gap: 20,
  },
  cards: {
    gap: 12,
  },
  box: {
    gap: 12,
    padding: 14,
    borderWidth: 2,
    borderColor: palette.border,
    borderRadius: 16,
    backgroundColor: palette.surface,
  },
  boxHead: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  boxTitle: {
    ...type.bodyBold,
    flex: 1,
    color: palette.text,
  },
  entry: {
    flex: 1,
    gap: 2,
    paddingVertical: 10,
  },
  entryTitle: {
    ...type.button,
    color: palette.text,
  },
  entryText: {
    ...type.secondary,
    color: palette.muted,
  },
  why: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 12,
    padding: 14,
    borderRadius: 14,
    backgroundColor: palette.idleSoft,
  },
  whyText: {
    ...type.secondary,
    flex: 1,
    color: palette.text,
  },
  toggle: {
    minHeight: 64,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingRight: 14,
    paddingLeft: 18,
    borderWidth: 2,
    borderColor: palette.borderStrong,
    borderRadius: RADIUS,
    backgroundColor: palette.surface,
  },
  pressed: {
    opacity: 0.75,
  },
  moreTitle: {
    ...type.button,
    flex: 1,
    color: palette.text,
  },
  moreState: {
    ...type.secondaryBold,
    color: palette.muted,
  },
  moreContent: {
    gap: 20,
  },
  field: {
    gap: 10,
  },
  label: {
    ...type.bodyBold,
    color: palette.text,
  },
  hint: {
    ...type.secondary,
    color: palette.muted,
  },
  privacy: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 12,
  },
  privacyText: {
    ...type.secondary,
    flex: 1,
    color: palette.text,
  },
}));
