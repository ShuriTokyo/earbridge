# EarBridge

Live conversation translation for **any** earphones: AirPods, other Bluetooth buds, or wired ones.

Apple built live translation into AirPods. EarBridge does the same for any earphones. Open it in your phone's browser,
or install the [phone app](#the-phone-app), then put your earphones in and talk. Deepgram turns speech into text, a
language model on DeepInfra translates it, and a natural-sounding voice, also from DeepInfra, reads the translation
into your ears. The earphones need nothing special, because the app uses whatever microphone and audio output the
phone is already using.

The phone app also works without a server: with your own API keys, or entirely on the phone, offline, on Android 13
and later. See [Who translates](#who-translates).

## How it works

```
 phone (browser or app)                    relay server (this repo)
┌──────────────────────────┐  WebSocket  ┌──────────────────────────┐
│ microphone → 16 kHz PCM  │ ──────────► │ one session per phone    │ ──► Deepgram: streaming speech-to-text
│                          │             │ rooms, recent context    │
│ transcript + translation │ ◄────────── │                          │ ──► DeepInfra: translation, streamed
│ voice → your earphones   │ text, audio │                          │ ──► DeepInfra: natural voices
└──────────────────────────┘             └──────────────────────────┘
```

1. The phone streams its microphone to the relay server as 16 kHz audio over a WebSocket.
2. The relay forwards the audio to Deepgram. Deepgram sends back a live transcript and marks where each sentence ends.
3. Each finished sentence goes to a language model on DeepInfra, along with the last few lines of the conversation to
   help with names, pronouns and misheard words. The translation streams back to the phones as the model writes it.
4. A text-to-speech model on DeepInfra reads the finished translation in the listener's language, and the phone plays
   the audio. The sound goes wherever the phone is playing sound, which is your earphones.

The relay server's API keys stay on the server. The browser and the phone app never see them. Anthropic's Claude can
translate instead of DeepInfra; see [Configuration](#configuration).

The phone app can skip the relay in One phone mode. With **My own API keys**, it calls Deepgram and DeepInfra itself,
with keys you type into it. With **On this phone**, the phone does all three steps.

## Two ways to use it

### One phone

This mode is for two people sharing one phone. You wear the earphones, and the other person looks at the screen.

- **What you hear:** what they say, translated, in your earphones.
- **What they see:** what you say, translated, on the screen. **Flip ↻** turns that text around for someone sitting
  across from you. If you choose **On the phone speaker** instead, the phone reads both translations aloud.
- **Who is speaking:** detected automatically when both languages are among English, Spanish, French, German, Hindi,
  Russian, Portuguese, Japanese, Italian and Dutch. This uses Deepgram's multilingual mode. For other pairs, and in
  the phone app's **On this phone** mode, tap **Me** or **Them** to show who is talking.

### Room

In this mode, everyone uses their own phone and earphones. They can sit at the same table or be in different places on
a call.

- **Inviting people:** start a room, then share the invite as a 6-character code, a QR code or a link.
- **What you hear:** everyone else, in your own language. Each sentence is translated once for each language in the
  room.
- **Size:** up to 10 people.
- **Dropped connections:** a phone that loses its connection rejoins the same room on its own.

### Talking and listening

| Setting   | Choices |
|-----------|---------|
| Talking   | **Hands-free**: the microphone stays on. Best in quiet places. |
|           | **Hold to talk**: the microphone is on only while you hold the button (in a room on a computer, you can also hold the space bar). Best in noisy places, and in rooms where people sit together. |
| Listening | **In my earphones**: you hear the translations of the other person, or of the others in a room. |
|           | **On the phone speaker**: the phone reads translations aloud, for when nobody wears earphones. The microphone pauses while the phone speaks, so the app does not translate its own voice. |

### Voices

Natural-sounding voices from DeepInfra read the translations in 24 of the 34 languages:

- **Kokoro:** English (US and UK), Spanish, French, Hindi, Italian, Japanese, Brazilian Portuguese and Chinese.
- **Chatterbox:** Arabic, Danish, Dutch, Finnish, German, Greek, Korean, Malay, Norwegian, Polish, European Portuguese,
  Russian, Swedish and Turkish.

The phone's own voice reads the other ten: Bulgarian, Catalan, Czech, Hungarian, Indonesian, Romanian, Slovak, Thai,
Ukrainian and Vietnamese. It also steps in when a natural voice fails or takes longer than 6 seconds, so you still
hear the translation, and a short notice says why.

The natural voice usually starts about a second after the translation is finished. To use the phone's own voice for
everything, which starts sooner but sounds more robotic, open **Advanced → Voice**.

## Which microphone?

The web app uses whichever microphone the phone gives it. The phone app, set to **Automatic**, follows the advice
below. To choose one yourself, open **Advanced → Microphone**.

- **One phone: use the phone's own microphone,** held between you. It hears you both, and Bluetooth earphones keep
  their full sound quality. Earbud microphones are designed to pick up only the wearer's voice, so they can miss the
  other person.
- **Room: use the earphones' microphone.** Each phone only needs to hear its owner, and the earbuds' noise filtering
  keeps other people's voices out.
- Wired earphones with a microphone work too.

When any app opens a Bluetooth headset's microphone, the phone switches the headset to its hands-free profile (HFP).
That profile lowers the sound to phone-call quality until the microphone closes again. It is a Bluetooth limitation,
and apps cannot change it.

## Getting started

You need:

- Node.js 22.18 or newer.
- A [Deepgram](https://console.deepgram.com) API key, for speech recognition.
- A [DeepInfra](https://deepinfra.com/dash/api_keys) API key, for translation and voices.
- A computer and a phone on the same Wi-Fi network.

```sh
npm install
cp .env.example .env    # then add DEEPGRAM_API_KEY and DEEPINFRA_API_KEY
npm run dev
```

`npm run dev` starts two servers:

- the relay server, on port 8787;
- the app's development server, on port 5173. It uses HTTPS with a self-signed certificate, because phones only allow
  the microphone on HTTPS pages.

To try it on your phone:

1. Open the Network address that Vite prints, such as `https://192.168.1.20:5173`. You can also use
   `https://<computer-name>.local:5173`.
2. Accept the certificate warning. It appears because the development certificate is self-signed.
3. Allow the microphone, pick your languages and tap **Start**.

To try a room, other people open your invite link on their phones. While you use `npm run dev`, they must be on the
same Wi-Fi.

## The phone app

The [`mobile/`](mobile) folder holds a phone app for Android and iPhone, built with Expo. It has the same screens and
settings as the web app. What it adds:

- **It can work without a server.** In One phone mode, it can use your own API keys, or translate on the phone
  itself. See [Who translates](#who-translates).
- **It keeps translating with the screen off.** On Android, a notification shows during a conversation, with **Mute**
  and **End** buttons. The play/pause button on the earphones mutes and unmutes too.
- **It needs no HTTPS,** so it can use the relay server on your computer as it is, with no certificate warning.
- **It notices earphones.** When none are connected, it reads translations on the phone speaker and pauses the
  microphone while it speaks.
- **Invites open the app.** In a room, tap **Invite** to show a QR code and a link. They open EarBridge with the room
  and the server filled in. If the server uses HTTPS, the invite is a web link instead, which works in a browser too.

So far, the app has been built and tested for Android only, in the emulator. See [Limitations](#limitations).

### Who translates

With one phone, the start screen's **Translation** card offers three choices. A room always uses an EarBridge server,
because the phones have to reach each other.

|                 | On this phone | My own API keys | EarBridge server |
|-----------------|---------------|-----------------|------------------|
| Speech to text  | Android's on-device speech recognition | Deepgram | Deepgram, through the server |
| Translation     | Google ML Kit, on the phone | A language model on DeepInfra | A language model on DeepInfra, or Claude |
| Voice           | The phone's own | Natural voices from DeepInfra, or the phone's own | Natural voices from DeepInfra, or the phone's own |
| Who is speaking | Tap **Me** or **Them** | Detected automatically for many pairs | Detected automatically for many pairs |
| You need        | Android 13 or later, and the internet once per language | A Deepgram key and a DeepInfra key | A computer running the server |
| Cost            | Free | Deepgram and DeepInfra bill you for what you use | Whoever runs the server pays |
| Offline         | Yes, once the languages are downloaded | No | No |
| Quality         | Lower: see [Limitations](#limitations) | Best | Best |

The [research behind **On this phone**](docs/on-device.md) compares other ways to run everything on the phone.

### Using it on Android

1. Install the app on the phone. [Build it](#building-it-for-android), then either:
   - connect the phone with USB debugging turned on, and run `adb install app-release.apk`; or
   - copy the file to the phone and open it there. Android asks you to allow apps from that source, and Google Play
     Protect may show a warning first.
2. Open EarBridge and pick your languages. Under **Translation**, choose who translates:
   - **On this phone:** there is nothing to enter.
   - **My own API keys:** enter a [Deepgram](https://console.deepgram.com) key and a
     [DeepInfra](https://deepinfra.com/dash/api_keys) key.
   - **EarBridge server:** start the server on your computer with `npm run dev` or `npm start`. It prints the address
     for the app, for example `Server address for the EarBridge phone app: 192.168.1.20:8787`. Enter it under
     **Server address**; the phone must be on the same Wi-Fi as the computer. If the computer asks whether Node may
     accept incoming connections, allow it. If the server has an `ACCESS_TOKEN`, enter it under **Access code**.
3. Tap **Start**. Allow the microphone. Allow notifications too, so you can mute or end the conversation from the lock
   screen.

The first time you use a language **On this phone**, the phone needs the internet. Android may ask whether to
download speech recognition for it (49 MB for Spanish in our test): tap **Download**. The app then downloads the
translation, about 30 MB per language. The status line shows the progress, then **Listening**. After that, it works
offline.

For a room, choose **Room** at the top, and fill in the server as above.

### Building it for Android

You need Node.js 22.18 or newer, JDK 17, and the Android SDK, with `ANDROID_HOME` set to its folder. Android Studio
installs the SDK.

```sh
cd mobile
npm install
npx expo prebuild --platform android
cd android
./gradlew assembleRelease
```

The app is then in `mobile/android/app/build/outputs/apk/release/app-release.apk`. It is signed with a debug key, which
is fine for your own phones but not for Google Play.

To build the server's address into the app, so that nobody has to type it, set `EXPO_PUBLIC_SERVER_URL` when you run
Gradle: `EXPO_PUBLIC_SERVER_URL=http://192.168.1.20:8787 ./gradlew assembleRelease`. If you change it later, delete
`mobile/android/app/build` first, or Gradle keeps the old address.

Don't build API keys into the app: anyone who has the app could read them. Each person types their own under **My
own API keys**.

Notes from building on a Mac:

- Gradle finds no Java on its own on macOS: `export JAVA_HOME=$(/usr/libexec/java_home -v 17)` first (with Homebrew's
  OpenJDK 17, `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`).
- `./gradlew assembleRelease -PreactNativeArchitectures=arm64-v8a` builds for 64-bit ARM phones only, in a third of
  the time and size.
- `EXPO_PUBLIC_TALK_REPORT=1 ./gradlew assembleRelease` makes a build that writes a report of each conversation (who was
  heard, what was skipped and why) to `/sdcard/Android/data/app.earbridge.mobile/files/reports/`, to read with
  `adb pull`. See `mobile/src/engines/talk-report.ts`.
- A change under `shared/` alone does not make Gradle rebuild the JavaScript bundle: the build succeeds in seconds
  with the old code inside. Delete `mobile/android/app/build/generated/sourcemaps/react/release` first, and check that
  the output shows `> Task :app:createBundleReleaseJsAndAssets`.

### iPhone

The app builds for iPhone too, and has been run on one. [docs/iphone.md](docs/iphone.md)
explains the two ways to build it: on a Mac with Xcode, installed over a cable with a free Apple ID (the app then runs
for 7 days at a time), or in the cloud with EAS Build and a paid Apple Developer account. It also lists what works
on iPhone: **On this phone** from iOS 26, and everything under **Voices** (telling the two voices from everyone else's,
*Separate voices*, leaving out what someone said over a held line) and **Ignore voices from the sides**, in Swift
modules of their own.

## Deploying

```sh
npm run build   # builds the app into client/dist
npm start       # serves the app and the WebSocket (/ws) on PORT
```

Phone browsers need HTTPS to use the microphone. The phone app doesn't, but over the internet, HTTPS keeps
conversations and the access code private. Do one of the following:

- Set `TLS_CERT` and `TLS_KEY` to your certificate and key (PEM files).
- Run the server behind an HTTPS reverse proxy, such as Caddy, nginx or a tunnel, that forwards WebSocket upgrades on
  `/ws`. If the proxy changes the Host header, add your public address to `ALLOWED_ORIGINS`.

Set `ACCESS_TOKEN` on any server that can be reached from the internet. Without it, anyone who finds the server can
spend your API credits. People enter the code under **Access code**: in the web app, it is under **Advanced**; in the
phone app, below the server address.

Rooms are kept in memory. That means one server process only, and a restart ends every room. A room with nobody in it
stays open for 10 minutes, so people can rejoin.

## Configuration

Set these in `.env`, or in the server's environment.

| Variable               | Default                             | Description |
|------------------------|-------------------------------------|-------------|
| `DEEPGRAM_API_KEY`     | *(required)*                        | Deepgram key, for speech recognition. |
| `DEEPINFRA_API_KEY`    |                                     | DeepInfra key, for translation and natural voices. |
| `TRANSLATION_PROVIDER` | `deepinfra`                         | `deepinfra` or `claude`. If it is not set, the server uses DeepInfra when `DEEPINFRA_API_KEY` is set, and Claude when only `ANTHROPIC_API_KEY` is. |
| `TRANSLATION_MODEL`    | `google/gemma-4-31B-it`             | The model that translates: a chat model on DeepInfra, or with Claude, a Claude model (default `claude-opus-5`). |
| `VOICE`                | `deepinfra`                         | `deepinfra` for natural voices, or `phone` for each phone's own voice. Without `DEEPINFRA_API_KEY`, it is `phone`. |
| `ANTHROPIC_API_KEY`    |                                     | Claude key, to translate with Claude. Optional after `ant auth login`. `ANTHROPIC_AUTH_TOKEN` also works. |
| `TRANSLATION_EFFORT`   | `low`                               | Claude only: `low`, `medium`, `high`, `xhigh` or `max`. Lower is faster, and `low` suits live conversation. |
| `DEEPGRAM_MODEL`       | `nova-3`                            | Switches to `nova-2` on its own for languages `nova-3` doesn't support. |
| `DEEPGRAM_URL`         | `wss://api.deepgram.com/v1/listen`  | Change it for a regional or self-hosted Deepgram endpoint. |
| `PORT`                 | `8787`                              | Port the server listens on. |
| `ACCESS_TOKEN`         |                                     | Shared secret that people must enter to use the server. |
| `TLS_CERT`, `TLS_KEY`  |                                     | Paths to a PEM certificate and key, to serve HTTPS directly. Set both or neither. |
| `ALLOWED_ORIGINS`      |                                     | Extra page origins allowed to open the WebSocket, separated by commas. |

The server refuses to start without a way to translate: set `DEEPINFRA_API_KEY`, or set up Claude. When it starts, it
logs which services it uses.

**Kokoro voices use DeepInfra's priority tier.** It costs about 50% more than the default tier, but usually keeps
the voice under a second. On the default tier it sometimes took several seconds.

**Translating with Claude.** Set `TRANSLATION_PROVIDER=claude` and `ANTHROPIC_API_KEY`. Claude translation requests
use refusal fallbacks: the `server-side-fallback-2026-07-01` beta with `fallbacks: 'default'`. If a safety classifier
declines a sentence, the API runs the request again on Anthropic's recommended fallback model instead of returning a
refusal. If that is declined too, the app shows *"The translation service declined to translate this utterance."*
Refusal fallbacks are a Claude API feature, so they don't apply to translation on DeepInfra. The voices still come from
DeepInfra if `DEEPINFRA_API_KEY` is set.

## Languages

The app offers 34 languages, from English, Spanish, Chinese and Arabic to Catalan and Slovak. The full list is in
[`shared/languages.ts`](shared/languages.ts). Recognition quality depends on the language and on the Deepgram model.

**On this phone** translates all 34, but which languages it can recognize depends on the phone. The app says when the
phone can't recognize one.

## Limitations

- **Bluetooth microphones lower the sound quality** while they are in use. See [Which microphone?](#which-microphone).
- **Sound plays where the phone sends it:** to the earphones when they are connected, otherwise to the speaker.
  Phones don't let web pages pick an audio output, and the phone app follows the phone's choice too. **On the phone
  speaker** means "read everything aloud". It does not force the sound to the speaker.
- **In the browser, locked screens pause translation.** The web app asks the phone to keep the screen on during a
  conversation. If the phone locks anyway, the browser pauses the page until you come back. The connection then
  returns on its own. If the phone stopped the microphone in the meantime, the app tells you so. The
  [phone app](#the-phone-app) keeps listening.
- **iPhone is untested.** The web app has been tested only in Chrome, and the phone app only on Android. In Safari, iOS
  may also play speech through the earpiece instead of the loudspeaker while the microphone is on, or play it more
  quietly.
- **The phone app has been tested only in the Android emulator.** Real Bluetooth earphones, their microphones and
  buttons, and long conversations with the screen off still need testing on real phones. So does **On this phone**,
  which relies on each phone's own speech recognition.
- **On this phone is less accurate.** Android's speech recognition makes more mistakes than Deepgram: in our French
  test, "près d'ici" ("near here") came out as "préjudice". ML Kit translates each sentence on its own, without the
  conversation around it, and Google describes it as "intended for casual and simple translations". Chinese comes out
  in simplified characters.
- **On this phone downloads each language once:** its speech recognition (49 MB for Spanish and 57 MB for French, in
  our tests) and its translation (about 30 MB). Android sometimes finishes a download in its own time. The app waits up
  to 3 minutes, then asks you to try again later.
- **Natural voices aren't perfect.** They come from small, fast models. They sometimes mispronounce a word or read a
  time such as "8:00" oddly. The Chatterbox voices (German, Russian, Korean and the rest of its list) can sound
  accented, and now and then slur a word.
- **Phones in the same room hear each other.** When a room's members sit at one table, a phone can pick up a neighbour's
  voice and translate it as its owner's words. Use earphone microphones, or **Hold to talk**.
- **Translation waits for a pause.** It starts when the speaker stops talking. Until then, you see the live
  transcript.
- **Home screen icon:** the web app can be added to the home screen, but it ships only an SVG icon, and iOS expects a
  PNG.

## Privacy

- **Where audio goes:** from the phone to your relay server, then to Deepgram for speech recognition. With **My own
  API keys**, it goes straight from the phone to Deepgram. **On this phone**, it stays on the phone.
- **Where text goes:** the recognized text goes to DeepInfra for translation, along with the last ten lines of the
  conversation as context. Translations then go to DeepInfra again to be read aloud, unless you choose the phone's
  own voice. With `TRANSLATION_PROVIDER=claude` on the server, translation goes to Anthropic instead. **On this
  phone**, the phone translates, and Google's translation component (ML Kit) sends Google only usage statistics, such
  as which languages are used.
- **Provider policies:** Deepgram's and DeepInfra's data policies (and Anthropic's, with Claude) apply to what they
  receive.
- **What the server keeps:** nothing is stored. There are no recordings, transcripts or accounts. Conversations and
  rooms exist in memory only while they are active, and the logs never contain what people say.
- **What the phone keeps:** your settings. These are your languages, mode, name, microphone, voice and access code.
  The web app keeps them in the browser's local storage. The phone app keeps them, with the server's address and who
  translates, in a file in its own storage. Your own API keys are kept apart from them and encrypted, using Android's
  keystore or the iPhone's keychain. They are left out of backups, and don't move to a new phone. **On this phone**
  also keeps the languages it downloaded.

## Security

- **API keys:** the server's keys never leave it, and neither the web app nor the phone app contains any. With **My
  own API keys**, each person types their own into the phone app, which stores them encrypted and sends them only to
  Deepgram and DeepInfra.
- **`ACCESS_TOKEN`:** keeps strangers from using your server. It is compared in constant time.
- **WebSocket origin check:** in a browser, only pages served from the server's own address or from `ALLOWED_ORIGINS`
  can open the WebSocket. Other websites cannot use your server through their visitors' browsers. Apps that aren't
  browsers, like the phone app, send no origin and are let in. On a server that others can reach, `ACCESS_TOKEN` is
  what keeps them out.
- **Content Security Policy:** it is strict, with no inline scripts or styles.
- **Size limits:** messages, audio chunks, names and rooms all have a maximum size.

## Project layout

```
server/src/
  index.ts             entry point: reads the configuration and starts the server
  app.ts               HTTP(S) server, static files, WebSocket upgrades, Origin and access checks
  session.ts           one phone's connection: hello, audio, messages
  rooms.ts             rooms: codes, participants, one translation per language
  deepgram-socket.ts   opens Deepgram's streaming connection
  translate/claude.ts  the Claude translator
client/src/
  setup-view.ts        start screen
  live-view.ts         conversation screen
  live-session.ts      connects the microphone, the server and the spoken translations
  connection.ts        WebSocket that reconnects on its own
  audio/               microphone capture, resampling to 16 kHz
  voice-player.ts      plays the natural voices
  speech-queue.ts      reads translations one at a time, in the order they were said
  tts.ts               text-to-speech with the phone's voices
client/public/         audio worklet, web app manifest, icon
shared/                protocol, languages, room codes (used by the server and both apps)
  pipeline/            the conversation itself, used by the server and the phone app:
    solo.ts            one-phone conversations: who is speaking, Me / Them
    stt/               speech-to-text: the SttProvider interface, Deepgram, on-device, sentence segmentation
    translate/         the Translator interface, the DeepInfra translator, and the prompt
    voice/             the SpeechSynthesizer interface and DeepInfra's natural voices
    deepinfra.ts       what the DeepInfra translator and voices share
mobile/                the phone app (Expo); it reuses code from client/src/ and shared/
  App.tsx              setup screen, then a conversation
  src/                 screens, settings, the conversation, microphone and voices
  src/engines/         who translates: an EarBridge server, your own API keys, or the phone itself
  modules/             Android: microphone, earphones, the notification that keeps it running, and
                       on-device speech recognition and translation
docs/on-device.md      research: speech recognition and translation on the phone itself
server/test/, client/test/
```

## Development

| Command             | What it does |
|---------------------|--------------|
| `npm run dev`       | Starts the relay server, which restarts when files change, and the app's HTTPS development server. |
| `npm test`          | Runs the unit and integration tests. Speech recognition, translation and voices are faked, so no keys are needed. |
| `npm run typecheck` | Type-checks the server and the app. |
| `npm run build`     | Builds the app for production. |
| `npm start`         | Runs the production server. |

The server runs TypeScript directly with Node's type stripping, so it has no build step. Only erasable TypeScript
syntax is allowed: for example, no `enum` and no constructor parameter properties.

For the phone app, run these in `mobile/`:

| Command                | What it does |
|------------------------|--------------|
| `npx expo run:android` | Builds a development version, installs it on a connected phone or emulator, and starts the bundler. |
| `npx tsc --noEmit`     | Type-checks the phone app. |
| `npx expo lint`        | Lints the phone app. |

The phone app imports the settings, speech queue, resampler, protocol and language list from `client/src/` and
`shared/`, so changes there affect both apps. For **My own API keys** and **On this phone**, it also runs the server's
conversation, speech recognition, translation and voice code, from `shared/pipeline/`.

### Measuring the voice filters

[`tools/voice-rig/`](tools/voice-rig) plays synthetic clips (two macOS voices, with and without a crowd's chatter)
through the real pipeline with the real recognizer and voice prints on a Mac, and counts how many of each talker's
words would have been translated. See its README. The filters themselves are in `shared/pipeline/voices.ts` (whose
voice a stretch of speech is in) and `shared/pipeline/solo.ts` (what is done with each line).

### Another speech recognizer, translator or voice

To use another service, implement one of these interfaces and pass it to `createApp` in `server/src/index.ts`:

- `SttProvider` in [`shared/pipeline/stt/types.ts`](shared/pipeline/stt/types.ts), for speech recognition;
- `Translator` in [`shared/pipeline/translate/types.ts`](shared/pipeline/translate/types.ts), for translation;
- `SpeechSynthesizer` in [`shared/pipeline/voice/types.ts`](shared/pipeline/voice/types.ts), for the voices.

The phone app puts them together in `mobile/src/engines/keys.ts` and `mobile/src/engines/local.ts`. The tests use
fake versions of all three, in `server/test/fakes.ts`.

Automatic speaker detection in One phone mode relies on Deepgram's multilingual mode, which tags the language of each
word. See `AUTO_DETECT_BASES` in `shared/languages.ts`.

## Roadmap

- Test the phone app on real phones with Bluetooth earphones, and build it for iPhone
  ([docs/iphone.md](docs/iphone.md)): the voice filters need the Android module's speaker model ported to Swift.
- **On this phone** for iPhone, with Apple's on-device speech recognition and translation. See
  [docs/on-device.md](docs/on-device.md).
- Open models, such as Whisper and Gemma, on the phone: for the languages and phones that the built-in engines don't
  cover, and for better translations offline.
- The phone's own voice played by the app itself, so that a future Android can't mute it while the screen is off.
- Natural voices for the ten languages that don't have one yet.
- More speech recognizers, through `SttProvider`.
- PNG icons for the iOS home screen.

## License

MIT

The Android app includes a voice separation model, `convtasnet.onnx`: Conv-TasNet by Joris Cosentino, trained with
Asteroid on Libri2Mix ([JorisCos/ConvTasNet_Libri2Mix_sepnoisy_16k](https://huggingface.co/JorisCos/ConvTasNet_Libri2Mix_sepnoisy_16k)),
licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). It was converted to ONNX, with its
convolutions quantized to 8 bits, and the converted file is under the same license. The model runs on
[ONNX Runtime](https://github.com/microsoft/onnxruntime) (MIT): the runtime that comes with sherpa-onnx, and the Java
library of the same build, in `mobile/modules/earbridge-audio/android/` (`libs/get-onnxruntime-java.sh` there gets it).
