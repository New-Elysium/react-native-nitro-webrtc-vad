package com.nitrowebrtcvad;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.util.Log;

import com.margelo.nitro.NitroModules;

import java.util.concurrent.atomic.AtomicBoolean;

final class NitroWebrtcVadAudioInput {
  private static final String TAG = "NitroWebrtcVadAudio";

  private static final AtomicBoolean isRecording = new AtomicBoolean(false);
  private static AudioRecord audioRecord;
  private static Thread recordingThread;

  private NitroWebrtcVadAudioInput() {}

  static synchronized void start(int sampleRate, int frameSamples) {
    stop();

    int minBufferSize = AudioRecord.getMinBufferSize(
      sampleRate,
      AudioFormat.CHANNEL_IN_MONO,
      AudioFormat.ENCODING_PCM_16BIT
    );
    if (minBufferSize <= 0) {
      throw new IllegalStateException("Failed to resolve Android AudioRecord buffer size.");
    }

    int frameBytes = frameSamples * 2;
    int bufferSize = Math.max(minBufferSize, frameBytes * 4);

    // The VAD only reads from the microphone. It never changes the AudioManager mode,
    // speakerphone or communication device, so routing chosen by the app (expo-audio,
    // react-native-webrtc, ...) is left as is.
    int audioSource = resolveAudioSource();
    audioRecord = createAudioRecord(audioSource, sampleRate, bufferSize);
    if (audioRecord == null && audioSource != MediaRecorder.AudioSource.VOICE_RECOGNITION) {
      audioRecord = createAudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, sampleRate, bufferSize);
    }
    if (audioRecord == null) {
      throw new IllegalStateException("Failed to initialize Android AudioRecord.");
    }

    audioRecord.startRecording();
    isRecording.set(true);

    recordingThread = new Thread(() -> readLoop(frameSamples), "NitroWebrtcVadAudioInput");
    recordingThread.start();
  }

  static synchronized void stop() {
    isRecording.set(false);
    if (audioRecord != null) {
      try {
        audioRecord.stop();
      } catch (IllegalStateException ignored) {
      }
    }
    if (recordingThread != null) {
      try {
        recordingThread.join(300);
      } catch (InterruptedException ignored) {
        Thread.currentThread().interrupt();
      }
      recordingThread = null;
    }
    releaseAudioRecord();
  }

  /**
   * While the app is in a call/communication audio mode (e.g. react-native-webrtc, or
   * expo-audio routing through the earpiece), capture from the same VOICE_COMMUNICATION
   * path instead of opening a separate VOICE_RECOGNITION input. A second, different
   * input path can make the audio policy re-route the active call on some devices, and
   * VOICE_COMMUNICATION also applies echo cancellation so remote audio coming out of
   * the speaker is not detected as local speech.
   */
  private static int resolveAudioSource() {
    try {
      Context context = NitroModules.getApplicationContext();
      if (context != null) {
        AudioManager audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (audioManager != null) {
          int mode = audioManager.getMode();
          if (mode == AudioManager.MODE_IN_COMMUNICATION || mode == AudioManager.MODE_IN_CALL) {
            return MediaRecorder.AudioSource.VOICE_COMMUNICATION;
          }
        }
      }
    } catch (RuntimeException error) {
      Log.w(TAG, "Failed to read Android audio mode.", error);
    }
    return MediaRecorder.AudioSource.VOICE_RECOGNITION;
  }

  private static AudioRecord createAudioRecord(int audioSource, int sampleRate, int bufferSize) {
    AudioRecord recorder;
    try {
      recorder = new AudioRecord(
        audioSource,
        sampleRate,
        AudioFormat.CHANNEL_IN_MONO,
        AudioFormat.ENCODING_PCM_16BIT,
        bufferSize
      );
    } catch (IllegalArgumentException error) {
      Log.w(TAG, "AudioRecord rejected source=" + audioSource, error);
      return null;
    }
    if (recorder.getState() != AudioRecord.STATE_INITIALIZED) {
      recorder.release();
      return null;
    }
    return recorder;
  }

  private static void readLoop(int frameSamples) {
    short[] frame = new short[frameSamples];

    while (isRecording.get()) {
      int offset = 0;
      while (isRecording.get() && offset < frameSamples) {
        AudioRecord recorder = audioRecord;
        if (recorder == null) {
          return;
        }

        int read = recorder.read(frame, offset, frameSamples - offset);
        if (read < 0) {
          Log.e(TAG, "AudioRecord read failed code=" + read);
          isRecording.set(false);
          return;
        }
        offset += read;
      }

      if (isRecording.get() && offset == frameSamples) {
        try {
          onAudioFrame(frame);
        } catch (UnsatisfiedLinkError error) {
          Log.e(TAG, "Native audio frame callback is not linked.", error);
          isRecording.set(false);
          return;
        } catch (RuntimeException error) {
          Log.e(TAG, "Native audio frame callback failed.", error);
          isRecording.set(false);
          return;
        }
      }
    }
  }

  private static void releaseAudioRecord() {
    if (audioRecord != null) {
      audioRecord.release();
      audioRecord = null;
    }
  }

  private static native void onAudioFrame(short[] audioFrame);
}
