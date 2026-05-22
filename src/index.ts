import { NitroModules } from 'react-native-nitro-modules'
import type { NitroWebrtcVad as NitroWebrtcVadSpec } from './specs/nitro-webrtc-vad.nitro'

export const NitroWebrtcVad =
  NitroModules.createHybridObject<NitroWebrtcVadSpec>('NitroWebrtcVad')