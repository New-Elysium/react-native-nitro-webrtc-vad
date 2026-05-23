# Consumer Build Contract

This package must remain a normal installable React Native native dependency for Expo prebuild/dev-client projects. The consumer should not need to learn or run any WebRTC-specific build flow.

## Target Consumer Flow

The intended consumer setup is:

```sh
bun add react-native-nitro-webrtc-vad react-native-nitro-modules
npx expo prebuild
```

From there, the app should build through the normal Expo/RN native build path, including EAS Build, `expo run:ios`, or `expo run:android`.

## Non-Negotiable Constraints

- Do not require consumers to install or run WebRTC `depot_tools`.
- Do not require consumers to check out the full WebRTC repository.
- Do not require consumers to run `gn`, `ninja`, or any WebRTC-specific build command.
- Do not require consumers to manually edit generated iOS or Android projects after prebuild.
- Do not require consumers to add native source paths by hand.
- Do not require a separate precompiled binary download step.
- Do not convert this package to Expo Modules API just for Expo compatibility.

Android CMake/NDK and iOS CocoaPods/Xcode are allowed only as part of the normal React Native native build toolchain. They must not be presented as package-specific manual setup steps.

## Implementation Direction

Use the existing Nitro module architecture as the integration boundary:

```text
src/                 TypeScript public API and Nitro spec
cpp/                 C++ wrapper and VAD state machine
third_party/webrtcvad WebRTC VAD C source vendored into the package
android/             Gradle/CMake integration for the packaged sources
ios/ + podspec       CocoaPods integration for the packaged sources
```

WebRTC VAD should be treated as vendored C source, not as an external build dependency. The package build files must compile the required `.c`, `.cc`, and header files directly.

## Simplicity Rule

Keep the implementation as small as the product goal allows. This package only needs to deliver reliable voice activity events, so avoid broad rewrites, extra abstraction layers, new build systems, or framework migrations unless they are required to preserve the consumer build contract.

When changing code:

- Prefer the current Nitro C++ module structure over introducing another native module framework.
- Prefer a thin C++ wrapper around WebRTC VAD C APIs.
- Prefer editing the existing spec, wrapper, CMake file, and podspec over adding new layers.
- Prefer native state transitions such as `speechStart` and `speechEnd` over exposing low-level frame streams to JS.
- Keep public API additions minimal and directly tied to voice activity detection.
- Do not refactor unrelated generated, example, or package files while implementing VAD.

## Native Build Rules

Android:

- `android/CMakeLists.txt` must list or glob all required WebRTC VAD source files from `third_party/webrtcvad`.
- The Android library must build through the existing Nitro CMake target.
- The consumer app must not need to add extra Gradle, CMake, or NDK configuration beyond normal RN/Expo native builds.

iOS:

- `NitroWebrtcVad.podspec` must include required C/C++ implementation files and headers.
- The pod must build from source during normal `pod install` and Xcode/EAS builds.
- The consumer app must not need to add source files or linker flags manually.

Package publishing:

- `package.json` `files` must include every source file needed for native builds.
- If a listed file such as `app.plugin.js` is included, it must exist and serve a real setup purpose; otherwise remove it.
- Generated Nitro files required by the package must either be committed or reliably generated before publish.

## Runtime Design

Keep the JS/native boundary narrow. The package should expose voice activity events, not stream every audio frame into JS.

Preferred shape:

```ts
NitroWebrtcVad.start(options)
NitroWebrtcVad.stop()
NitroWebrtcVad.setListener(listener)
```

Native side responsibilities:

- Accept or produce mono PCM16 frames in supported WebRTC VAD frame sizes.
- Run WebRTC VAD in native code.
- Apply a small state machine/hysteresis before notifying JS.
- Emit only meaningful transitions such as `speechStart` and `speechEnd`.

Avoid calling JS directly from audio callback threads. Audio processing should remain native, and JS notification should be dispatched through a safe runtime path.

## Acceptance Criteria

Before considering the package ready for Expo/RN consumers:

- A clean consumer app can install this package and `react-native-nitro-modules`.
- `expo prebuild` does not require manual project edits.
- iOS builds through CocoaPods using only packaged sources.
- Android builds through Gradle/CMake using only packaged sources.
- No WebRTC-specific external tooling appears in the consumer README.
- The public README clearly distinguishes Expo Go from Expo prebuild/dev-client support.
