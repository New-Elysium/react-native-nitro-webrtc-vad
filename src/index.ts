import { NitroModules } from 'react-native-nitro-modules'
import type {
  IosAudioSession,
  NitroWebrtcVad as NitroWebrtcVadSpec,
} from './specs/nitro-webrtc-vad.nitro'

export type { IosAudioSession }

const nativeNitroWebrtcVad =
  NitroModules.createHybridObject<NitroWebrtcVadSpec>('NitroWebrtcVad')

export type VadEventType = 'speechStart' | 'speechEnd'

export type VadListener = (eventType: VadEventType, timestampMs: number) => void

export type VadStartOptions = {
  mode?: number
  sampleRate?: number
  frameMs?: number
  speechStartFrames?: number
  speechEndFrames?: number
  /**
   * iOS only. How the shared `AVAudioSession` is handled. Default: `'auto'`.
   * See {@link IosAudioSession}.
   */
  iosAudioSession?: IosAudioSession
}

export const NitroWebrtcVad = {
  start(options: VadStartOptions = {}) {
    nativeNitroWebrtcVad.start(
      options.mode ?? 2,
      options.sampleRate ?? 16000,
      options.frameMs ?? 20,
      options.speechStartFrames ?? 3,
      options.speechEndFrames ?? 8,
      options.iosAudioSession ?? 'auto'
    )
  },
  stop() {
    nativeNitroWebrtcVad.stop()
  },
  setListener(listener: VadListener) {
    nativeNitroWebrtcVad.setListener((eventType, timestampMs) => {
      listener(eventType as VadEventType, timestampMs)
    })
  },
  clearListener() {
    nativeNitroWebrtcVad.clearListener()
  },
  processFrame(pcm16: ArrayBuffer) {
    return nativeNitroWebrtcVad.processFrame(pcm16)
  },
}
