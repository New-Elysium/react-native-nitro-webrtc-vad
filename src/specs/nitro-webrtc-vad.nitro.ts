import type { HybridObject } from 'react-native-nitro-modules'

/**
 * How the iOS `AVAudioSession` is handled while the microphone is captured.
 *
 * - `auto`: Cooperative. If the shared session already allows recording (for
 *   example configured by expo-audio, react-native-webrtc or your own code), it
 *   is left untouched: category, mode, options (`defaultToSpeaker`), preferred
 *   sample rate and output route are never changed. Only when the session can
 *   not record yet is it switched to `playAndRecord` (keeping playback on the
 *   speaker), and that change is reverted on `stop()`.
 * - `none`: Never touch the session. The app must configure and activate a
 *   record-capable session before calling `start()`.
 */
export type IosAudioSession = 'auto' | 'none'

export interface NitroWebrtcVad extends HybridObject<{ ios: 'c++', android: 'c++' }> {
  start(
    mode: number,
    sampleRate: number,
    frameMs: number,
    speechStartFrames: number,
    speechEndFrames: number,
    iosAudioSession: IosAudioSession
  ): void
  stop(): void
  setListener(listener: (eventType: string, timestampMs: number) => void): void
  clearListener(): void
  processFrame(pcm16: ArrayBuffer): boolean
}
