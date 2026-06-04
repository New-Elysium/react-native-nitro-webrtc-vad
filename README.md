# react-native-nitro-webrtc-vad

Fast native WebRTC voice activity detection for React Native, built with Nitro Modules.

[![Version](https://img.shields.io/npm/v/react-native-nitro-webrtc-vad.svg)](https://www.npmjs.com/package/react-native-nitro-webrtc-vad)
[![Downloads](https://img.shields.io/npm/dm/react-native-nitro-webrtc-vad.svg)](https://www.npmjs.com/package/react-native-nitro-webrtc-vad)
[![License](https://img.shields.io/npm/l/react-native-nitro-webrtc-vad.svg)](https://github.com/enfpdev/react-native-nitro-webrtc-vad/blob/main/LICENSE)

`react-native-nitro-webrtc-vad` runs the WebRTC VAD engine in native C/C++ code and emits simple speech state transitions to JavaScript.

## Features

- Native WebRTC VAD for iOS and Android
- Nitro Modules JSI API
- Built-in microphone capture with `speechStart` and `speechEnd` events
- Direct PCM16 frame classification with `processFrame`
- No WebRTC checkout, `depot_tools`, `gn`, or `ninja` setup required

## Requirements

- React Native 0.76 or newer
- Node.js 18 or newer
- `react-native-nitro-modules`
- Android minSdkVersion 23 or newer
- iOS through the React Native CocoaPods toolchain

Expo apps must use a prebuild/dev-client native build. Expo Go is not supported because this package contains native C/C++ code.

## Installation

```sh
bun add react-native-nitro-webrtc-vad react-native-nitro-modules
```

```sh
npm install react-native-nitro-webrtc-vad react-native-nitro-modules
```

```sh
yarn add react-native-nitro-webrtc-vad react-native-nitro-modules
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
import { NitroWebrtcVad, type VadEventType } from 'react-native-nitro-webrtc-vad'

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

## Build Contract

This package vendors the small WebRTC VAD source needed for native builds. Consumers should not need to install WebRTC-specific build tools. See [Consumer Build Contract](docs/consumer-build-contract.md) for details.

## License

MIT
