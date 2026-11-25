# @psync/webrtc-vad

Fast native WebRTC voice activity detection for React Native, built with Nitro Modules.

[![Version](https://img.shields.io/npm/v/@psync/webrtc-vad.svg)](https://www.npmjs.com/package/@psync/webrtc-vad)
[![Downloads](https://img.shields.io/npm/dm/@psync/webrtc-vad.svg)](https://www.npmjs.com/package/@psync/webrtc-vad)
[![License](https://img.shields.io/npm/l/@psync/webrtc-vad.svg)](https://github.com/New-Elysium/react-native-nitro-webrtc-vad/blob/main/LICENSE)

`@psync/webrtc-vad` is a fork of [`react-native-nitro-webrtc-vad`](https://github.com/enfp-dev-studio/react-native-nitro-webrtc-vad). It runs the WebRTC VAD engine in native C/C++ code and emits simple speech state transitions to JavaScript.

## Features

- Native WebRTC VAD for iOS and Android
- Nitro Modules JSI API
- Built-in microphone capture with `speechStart` and `speechEnd` events
- Plays nicely with other audio code: never takes over the iOS `AVAudioSession` or Android audio routing (expo-audio, react-native-webrtc, ...)
- Direct PCM16 frame classification with `processFrame`
- No WebRTC checkout, `depot_tools`, `gn`, or `ninja` setup required

## Requirements

- React Native 0.76 or newer (tested with Expo SDK 58 / React Native 0.88)
- Node.js 18 or newer
- `react-native-nitro-modules` 0.37.2 or newer
- Android minSdkVersion 23 or newer
- iOS through the React Native CocoaPods toolchain

Expo apps must use a prebuild/dev-client native build. Expo Go is not supported because this package contains native C/C++ code.

## Installation

```sh
bun add @psync/webrtc-vad react-native-nitro-modules
```

```sh
npm install @psync/webrtc-vad react-native-nitro-modules
```

```sh
yarn add @psync/webrtc-vad react-native-nitro-modules
```

For iOS, install pods after adding the package:

```sh
cd ios && pod install
```

For Expo prebuild/dev-client apps:

```sh
npx expo prebuild
```

## Permissions

Android includes `RECORD_AUDIO` in the library manifest, but your app still needs to request microphone permission at runtime before calling `start()`.

```ts
import { PermissionsAndroid, Platform } from 'react-native'

async function requestMicrophonePermission() {
  if (Platform.OS !== 'android') {
    return true
  }

  const result = await PermissionsAndroid.request(
    PermissionsAndroid.PERMISSIONS.RECORD_AUDIO
  )

  return result === PermissionsAndroid.RESULTS.GRANTED
}
```

On iOS, add `NSMicrophoneUsageDescription` to your app's `Info.plist`.

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to detect voice activity.</string>
```

## Usage

```ts
import { NitroWebrtcVad, type VadEventType } from '@psync/webrtc-vad'

NitroWebrtcVad.setListener((eventType: VadEventType, timestampMs: number) => {
  if (eventType === 'speechStart') {
    console.log('Speech started', timestampMs)
  }

  if (eventType === 'speechEnd') {
    console.log('Speech ended', timestampMs)
  }
})

NitroWebrtcVad.start({
  mode: 2,
  sampleRate: 16000,
  frameMs: 20,
  speechStartFrames: 3,
  speechEndFrames: 8,
})

// Later:
NitroWebrtcVad.stop()
NitroWebrtcVad.clearListener()
```

## Audio session and routing

The VAD only reads from the microphone, so it does not take over the app's audio setup. It works alongside `expo-audio`, `react-native-webrtc` and your own audio code.

### iOS

- `iosAudioSession: 'auto'` (default):
  - If the shared `AVAudioSession` can already record (`playAndRecord`/`record`), for example because `expo-audio` (`setAudioModeAsync({ allowsRecording: true })`) or `react-native-webrtc` set it up, the VAD leaves it alone. It does not change the category, mode, options such as `defaultToSpeaker`, the preferred sample rate, the IO buffer or the output route.
  - If the session cannot record yet, it is switched to `playAndRecord` with `defaultToSpeaker`, `mixWithOthers` and Bluetooth, so playback stays on the loudspeaker. `stop()` puts back the previous category, unless something else changed the session in the meantime.
  - The session is activated if needed. It is never deactivated, because other audio may still be using it.
- `iosAudioSession: 'none'`: the VAD never touches the session. Configure a record-capable session yourself before calling `start()`. Otherwise `start()` throws.
- Route changes (speaker toggles, headphones, Bluetooth, category changes made by other code) are never undone. The VAD only restarts its own capture engine when needed.

```ts
import { setAudioModeAsync } from 'expo-audio'

await setAudioModeAsync({ allowsRecording: true, playsInSilentMode: true })
NitroWebrtcVad.start() // speaker routing from expo-audio stays as is
```

### Android

The VAD never changes the `AudioManager` mode, speakerphone or communication device. When the app is in a call/communication mode (for example during a `react-native-webrtc` call, or when `expo-audio` routes through the earpiece), it captures from `VOICE_COMMUNICATION`, the same input path the call uses. This avoids re-routing the call and applies echo cancellation, so audio coming out of the speaker is not detected as local speech. Otherwise it uses `VOICE_RECOGNITION`.

## Direct PCM16 Frames

Use `processFrame()` when you already have mono PCM16 audio frames and want to classify them yourself.

```ts
NitroWebrtcVad.start({ sampleRate: 16000, frameMs: 20 })

const frame = new Int16Array(320)
const isSpeech = NitroWebrtcVad.processFrame(frame.buffer)
```

The frame byte length must match the configured `sampleRate` and `frameMs`.

## API

### `NitroWebrtcVad.start(options?)`

Starts native VAD processing and microphone capture.

Options:

- `mode`: WebRTC VAD aggressiveness from `0` to `3`. Higher values are more aggressive. Default: `2`.
- `sampleRate`: Input sample rate. Supported WebRTC VAD rates include `8000`, `16000`, `32000`, and `48000`. Default: `16000`.
- `frameMs`: Frame duration. Must be `10`, `20`, or `30`. Default: `20`.
- `speechStartFrames`: Consecutive speech frames required before `speechStart`. Default: `3`.
- `speechEndFrames`: Consecutive non-speech frames required before `speechEnd`. Default: `8`.
- `iosAudioSession`: iOS only. How the shared `AVAudioSession` is handled, `'auto'` or `'none'`. Default: `'auto'`. See [Audio session and routing](#audio-session-and-routing).

### `NitroWebrtcVad.stop()`

Stops native VAD processing and microphone capture.

### `NitroWebrtcVad.setListener(listener)`

Registers a listener for VAD state changes.

```ts
type VadEventType = 'speechStart' | 'speechEnd'
type VadListener = (eventType: VadEventType, timestampMs: number) => void
```

### `NitroWebrtcVad.clearListener()`

Removes the current listener.

### `NitroWebrtcVad.processFrame(pcm16)`

Processes a single mono PCM16 `ArrayBuffer` and returns `true` for speech or `false` for non-speech.

## Notes

- Call `start()` before `processFrame()`.
- Call `stop()` when your screen or recording session ends.
- `start()` throws if VAD is already running.
- `processFrame()` throws if the frame size does not match the configured VAD frame size.

## Migrating from `react-native-nitro-webrtc-vad`

- Replace the dependency and imports: `react-native-nitro-webrtc-vad` → `@psync/webrtc-vad`. The native module name (`NitroWebrtcVad`) is unchanged.
- Requires `react-native-nitro-modules` 0.37.2 or newer.
- iOS no longer forces `playAndRecord` + `measurement` mode, a 16 kHz preferred sample rate or a short IO buffer, and no longer deactivates the session on `stop()`. If you relied on the VAD to set up the session for you, it still does in `'auto'` mode when the session can't record yet.

## Build Contract

This package vendors the small WebRTC VAD source needed for native builds. Consumers should not need to install WebRTC-specific build tools. See [Consumer Build Contract](docs/consumer-build-contract.md) for details.

## License

MIT
