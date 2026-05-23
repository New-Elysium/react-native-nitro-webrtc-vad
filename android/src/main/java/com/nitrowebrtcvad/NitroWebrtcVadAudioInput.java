package com.nitrowebrtcvad;

import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.util.Log;

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

    audioRecord = new AudioRecord(
      MediaRecorder.AudioSource.VOICE_RECOGNITION,
      sampleRate,
      AudioFormat.CHANNEL_IN_MONO,
      AudioFormat.ENCODING_PCM_16BIT,
      bufferSize
    );

    if (audioRecord.getState() != AudioRecord.STATE_INITIALIZED) {
      releaseAudioRecord();
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
