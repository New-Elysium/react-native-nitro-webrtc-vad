import React, { useMemo, useState } from 'react';
import { Button, PermissionsAndroid, Platform, ScrollView, StyleSheet, Text, View } from 'react-native';
import { NitroWebrtcVad, type VadEventType } from 'react-native-nitro-webrtc-vad';

function App(): React.JSX.Element {
  const [isRunning, setIsRunning] = useState(false);
  const [lastResult, setLastResult] = useState<string>('idle');
  const [events, setEvents] = useState<string[]>([]);

  const silenceFrame = useMemo(() => new Int16Array(320).buffer, []);

  const addLog = (message: string) => {
    setEvents((current) => [message, ...current].slice(0, 8));
  };

  const requestMicrophonePermission = async () => {
    if (Platform.OS !== 'android') {
      return true;
    }

    const result = await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.RECORD_AUDIO);
    return result === PermissionsAndroid.RESULTS.GRANTED;
  };

  const formatError = (error: unknown) => (error instanceof Error ? error.message : String(error));

  const start = async () => {
    try {
      const hasPermission = await requestMicrophonePermission();
      if (!hasPermission) {
        setLastResult('microphone permission denied');
        addLog('microphone permission denied');
        return;
      }

      NitroWebrtcVad.setListener((eventType: VadEventType, timestampMs: number) => {
        setLastResult(eventType);
        addLog(`${eventType} ${timestampMs}`);
      });
      NitroWebrtcVad.start();
      setIsRunning(true);
      setLastResult('started');
      addLog('started');
    } catch (error) {
      const message = `start error: ${formatError(error)}`;
      NitroWebrtcVad.clearListener();
      setIsRunning(false);
      setLastResult(message);
      addLog(message);
    }
  };

  const processSilence = () => {
    try {
      const isSpeech = NitroWebrtcVad.processFrame(silenceFrame);
      setLastResult(isSpeech ? 'speech' : 'silence');
      addLog(`processFrame: ${isSpeech ? 'speech' : 'silence'}`);
    } catch (error) {
      const message = `processFrame error: ${formatError(error)}`;
      setLastResult(message);
      addLog(message);
    }
  };

  const stop = () => {
    try {
      NitroWebrtcVad.stop();
      NitroWebrtcVad.clearListener();
      setIsRunning(false);
      setLastResult('stopped');
      addLog('stopped');
    } catch (error) {
      const message = `stop error: ${formatError(error)}`;
      setLastResult(message);
      addLog(message);
    }
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Nitro WebRTC VAD</Text>
      <Text style={styles.status}>Status: {isRunning ? 'running' : 'stopped'}</Text>
      <Text style={styles.status}>Last result: {lastResult}</Text>

      <View style={styles.actions}>
        <Button title="Start mic VAD" onPress={start} disabled={isRunning} />
        <Button title="Process test silence frame" onPress={processSilence} disabled={!isRunning} />
        <Button title="Stop" onPress={stop} disabled={!isRunning} />
      </View>

      <ScrollView style={styles.log}>
        {events.map((event, index) => (
          <Text key={`${event}-${index}`} style={styles.logText}>
            {event}
          </Text>
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    paddingHorizontal: 24,
    paddingTop: 80,
    backgroundColor: '#f7f8fa',
  },
  title: {
    fontSize: 28,
    fontWeight: '700',
    color: '#111827',
    marginBottom: 16,
  },
  status: {
    fontSize: 17,
    color: '#243043',
    marginBottom: 8,
  },
  actions: {
    gap: 12,
    marginTop: 18,
    marginBottom: 24,
  },
  log: {
    flex: 1,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: '#c8ced8',
    paddingTop: 16,
  },
  logText: {
    fontSize: 14,
    color: '#334155',
    marginBottom: 8,
  },
});

export default App;
