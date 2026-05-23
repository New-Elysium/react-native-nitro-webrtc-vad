import type { HybridObject } from 'react-native-nitro-modules'

export interface NitroWebrtcVad extends HybridObject<{ ios: 'c++', android: 'c++' }> {
  start(
    mode: number,
    sampleRate: number,
    frameMs: number,
    speechStartFrames: number,
    speechEndFrames: number
  ): void
  stop(): void
  setListener(listener: (eventType: string, timestampMs: number) => void): void
  clearListener(): void
  processFrame(pcm16: ArrayBuffer): boolean
}
