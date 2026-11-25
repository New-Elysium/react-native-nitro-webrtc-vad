#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <string>

extern "C" void NitroWebrtcVadProcessAudioInputFrame(const int16_t* samples, size_t sampleCount);
extern "C" void NitroWebrtcVadNotifyAudioInputStopped();

// `AllowBluetooth` was renamed to `AllowBluetoothHFP` in the iOS 26 SDK.
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 260000
#define NITRO_WEBRTC_VAD_BLUETOOTH_HFP AVAudioSessionCategoryOptionAllowBluetoothHFP
#else
#define NITRO_WEBRTC_VAD_BLUETOOTH_HFP AVAudioSessionCategoryOptionAllowBluetooth
#endif

namespace {
AVAudioEngine* engine = nil;
AVAudioConverter* converter = nil;
AVAudioFormat* outputFormat = nil;
NSMutableData* pendingPcm = nil;
dispatch_queue_t audioQueue = nil;
int targetSampleRate = 16000;
NSUInteger targetFrameSamples = 320;
BOOL isRunning = NO;
BOOL isInterrupted = NO;

// Audio session handling.
//
// The AVAudioSession is shared by the whole app (expo-audio, react-native-webrtc, ...).
// The VAD only *reads* from the microphone, so it must never take ownership of the
// session: no category/mode/option changes, no preferred sample rate or IO buffer
// changes, no output route changes and no deactivation while somebody else uses it.
//
// `manageSession == YES` ('auto'): if the session can not record yet, switch it to
// PlayAndRecord (keeping playback on the speaker) and revert that change on stop.
// `manageSession == NO` ('none'): never touch the session at all.
BOOL manageSession = YES;
BOOL didConfigureSession = NO;
AVAudioSessionCategory savedCategory = nil;
AVAudioSessionMode savedMode = nil;
AVAudioSessionCategoryOptions savedOptions = 0;
AVAudioSessionCategoryOptions appliedOptions = 0;

NSError* AudioError(NSString* message) {
  return [NSError errorWithDomain:@"NitroWebrtcVadAudioInput" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

dispatch_queue_t Queue() {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    audioQueue = dispatch_queue_create("com.nitrowebrtcvad.audio", DISPATCH_QUEUE_SERIAL);
    pendingPcm = [NSMutableData data];
  });
  return audioQueue;
}

BOOL EnsurePermission(NSError** error) {
  AVAudioSession* session = [AVAudioSession sharedInstance];
  if (session.recordPermission == AVAudioSessionRecordPermissionGranted) {
    return YES;
  }
  if (session.recordPermission == AVAudioSessionRecordPermissionDenied) {
    if (error != nullptr) {
      *error = AudioError(@"Microphone permission denied.");
    }
    return NO;
  }

  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  __block BOOL granted = NO;
  [session requestRecordPermission:^(BOOL didGrant) {
    granted = didGrant;
    dispatch_semaphore_signal(semaphore);
  }];
  dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

  if (!granted && error != nullptr) {
    *error = AudioError(@"Microphone permission denied.");
  }
  return granted;
}

BOOL CategoryAllowsRecording(AVAudioSessionCategory category) {
  return [category isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
         [category isEqualToString:AVAudioSessionCategoryRecord] ||
         [category isEqualToString:AVAudioSessionCategoryMultiRoute];
}

// Reverts the category change made by PrepareSession(), but only if nobody else has
// reconfigured the session in the meantime. Never deactivates the session, since other
// audio in the app (players, calls) may still be using it.
void RestoreSession() {
  if (!didConfigureSession) {
    return;
  }
  didConfigureSession = NO;

  AVAudioSession* session = [AVAudioSession sharedInstance];
  BOOL untouchedSinceStart = [session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord] &&
                             [session.mode isEqualToString:AVAudioSessionModeDefault] &&
                             session.categoryOptions == appliedOptions;
  if (untouchedSinceStart && savedCategory != nil && savedMode != nil) {
    [session setCategory:savedCategory mode:savedMode options:savedOptions error:nil];
  }
  savedCategory = nil;
  savedMode = nil;
}

// Makes sure the shared session can record, touching it as little as possible.
BOOL PrepareSession(NSError** error) {
  AVAudioSession* session = [AVAudioSession sharedInstance];
  NSError* sessionError = nil;

  if (!CategoryAllowsRecording(session.category)) {
    if (!manageSession) {
      if (error != nullptr) {
        *error = AudioError(@"The iOS audio session category does not allow recording. Configure a record-capable "
                            @"session (e.g. expo-audio setAudioModeAsync({ allowsRecording: true })) before calling "
                            @"start(), or use iosAudioSession: 'auto'.");
      }
      return NO;
    }

    savedCategory = session.category;
    savedMode = session.mode;
    savedOptions = session.categoryOptions;

    // DefaultToSpeaker keeps playback on the loudspeaker. Without it PlayAndRecord
    // routes all app audio to the earpiece.
    AVAudioSessionCategoryOptions options = savedOptions |
                                            AVAudioSessionCategoryOptionDefaultToSpeaker |
                                            AVAudioSessionCategoryOptionMixWithOthers |
                                            NITRO_WEBRTC_VAD_BLUETOOTH_HFP;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                         mode:AVAudioSessionModeDefault
                      options:options
                        error:&sessionError]) {
      savedCategory = nil;
      savedMode = nil;
      if (error != nullptr) {
        *error = sessionError ?: AudioError(@"Failed to configure iOS audio session.");
      }
      return NO;
    }
    didConfigureSession = YES;
    appliedOptions = session.categoryOptions;
  }

  if (manageSession) {
    // No-op when the session is already active (e.g. during a call or playback).
    if (![session setActive:YES error:&sessionError]) {
      RestoreSession();
      if (error != nullptr) {
        *error = sessionError ?: AudioError(@"Failed to activate iOS audio session.");
      }
      return NO;
    }
  }
  return YES;
}

void StopEngine() {
  if (engine != nil) {
    [engine.inputNode removeTapOnBus:0];
    [engine stop];
    engine = nil;
  }
  converter = nil;
  outputFormat = nil;
  [pendingPcm setLength:0];
}

void ProcessInputBuffer(AVAudioPCMBuffer* inputBuffer) {
  if (!isRunning || isInterrupted || converter == nil || outputFormat == nil) {
    return;
  }

  AVAudioFrameCount capacity = static_cast<AVAudioFrameCount>(
      std::ceil(inputBuffer.frameLength * outputFormat.sampleRate / inputBuffer.format.sampleRate) + 16);
  AVAudioPCMBuffer* outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:capacity];
  if (outputBuffer == nil) {
    return;
  }

  __block BOOL didRead = NO;
  AVAudioConverterInputBlock inputBlock = ^AVAudioBuffer*(AVAudioPacketCount, AVAudioConverterInputStatus* status) {
    if (didRead) {
      *status = AVAudioConverterInputStatus_NoDataNow;
      return nil;
    }
    didRead = YES;
    *status = AVAudioConverterInputStatus_HaveData;
    return inputBuffer;
  };

  if ([converter convertToBuffer:outputBuffer error:nil withInputFromBlock:inputBlock] == AVAudioConverterOutputStatus_Error) {
    return;
  }

  const AudioBufferList* buffers = outputBuffer.audioBufferList;
  if (buffers->mNumberBuffers == 0 || buffers->mBuffers[0].mData == nullptr) {
    return;
  }

  [pendingPcm appendBytes:buffers->mBuffers[0].mData length:buffers->mBuffers[0].mDataByteSize];

  const NSUInteger frameBytes = targetFrameSamples * sizeof(int16_t);
  while (pendingPcm.length >= frameBytes) {
    NitroWebrtcVadProcessAudioInputFrame(static_cast<const int16_t*>(pendingPcm.bytes), targetFrameSamples);
    [pendingPcm replaceBytesInRange:NSMakeRange(0, frameBytes) withBytes:nullptr length:0];
  }
}

BOOL StartEngine(NSError** error) {
  engine = [[AVAudioEngine alloc] init];
  AVAudioInputNode* input = engine.inputNode;
  AVAudioFormat* inputFormat = [input outputFormatForBus:0];
  if (inputFormat.channelCount == 0 || inputFormat.sampleRate <= 0) {
    if (error != nullptr) {
      *error = AudioError(@"iOS audio input format is unavailable.");
    }
    return NO;
  }

  outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                  sampleRate:targetSampleRate
                                                    channels:1
                                                 interleaved:YES];
  converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
  if (converter == nil) {
    if (error != nullptr) {
      *error = AudioError(@"Failed to create iOS audio converter.");
    }
    return NO;
  }

  AVAudioFrameCount tapSize = static_cast<AVAudioFrameCount>(std::max<double>(1024, inputFormat.sampleRate * 0.02));
  [input installTapOnBus:0 bufferSize:tapSize format:inputFormat block:^(AVAudioPCMBuffer* buffer, AVAudioTime*) {
    dispatch_async(Queue(), ^{
      ProcessInputBuffer(buffer);
    });
  }];

  NSError* startError = nil;
  if (![engine startAndReturnError:&startError]) {
    [input removeTapOnBus:0];
    if (error != nullptr) {
      *error = startError ?: AudioError(@"Failed to start iOS audio engine.");
    }
    return NO;
  }
  return YES;
}

// Only rebuilds the engine (the input format may have changed). The audio session is
// deliberately left alone so routing set by other code (speaker, Bluetooth) is kept.
BOOL RestartEngine() {
  StopEngine();
  NSError* error = nil;
  return StartEngine(&error);
}

void StopAndNotify() {
  isRunning = NO;
  isInterrupted = NO;
  StopEngine();
  RestoreSession();
  NitroWebrtcVadNotifyAudioInputStopped();
}
} // namespace

@interface NitroWebrtcVadAudioObserver : NSObject
@end

@implementation NitroWebrtcVadAudioObserver
+ (void)install {
  static dispatch_once_t onceToken;
  static NitroWebrtcVadAudioObserver* observer = nil;
  dispatch_once(&onceToken, ^{
    observer = [[NitroWebrtcVadAudioObserver alloc] init];
    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    [center addObserver:observer selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:observer selector:@selector(interrupted:) name:AVAudioSessionInterruptionNotification object:nil];
    [center addObserver:observer
               selector:@selector(engineConfigurationChanged:)
                   name:AVAudioEngineConfigurationChangeNotification
                 object:nil];
  });
}

- (void)engineConfigurationChanged:(NSNotification*)notification {
  // AVAudioEngine stops itself when the I/O configuration changes; rebuild it.
  id changedEngine = notification.object;
  dispatch_async(Queue(), ^{
    if (isRunning && !isInterrupted && changedEngine == engine && !RestartEngine()) {
      StopAndNotify();
    }
  });
}

- (void)routeChanged:(NSNotification*)notification {
  (void)notification;
  // Route changes (speaker override, headphones, category changes by other code) are
  // not ours to undo. Only bring the engine back if the change stopped it.
  dispatch_async(Queue(), ^{
    if (isRunning && !isInterrupted && (engine == nil || !engine.isRunning) && !RestartEngine()) {
      StopAndNotify();
    }
  });
}

- (void)interrupted:(NSNotification*)notification {
  AVAudioSessionInterruptionType type =
      static_cast<AVAudioSessionInterruptionType>([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]);
  dispatch_async(Queue(), ^{
    if (type == AVAudioSessionInterruptionTypeBegan && isRunning) {
      isInterrupted = YES;
      StopEngine();
    } else if (type == AVAudioSessionInterruptionTypeEnded && isRunning && isInterrupted) {
      isInterrupted = NO;
      if (manageSession) {
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
      }
      if (!RestartEngine()) {
        StopAndNotify();
      }
    }
  });
}
@end

extern "C" void NitroWebrtcVadStartAudioInput(int sampleRate, size_t frameSamples, bool manageAudioSession) {
  @autoreleasepool {
    [NitroWebrtcVadAudioObserver install];

    __block NSError* error = nil;
    __block BOOL ok = NO;
    dispatch_sync(Queue(), ^{
      StopEngine();
      RestoreSession();
      targetSampleRate = sampleRate;
      targetFrameSamples = frameSamples;
      manageSession = manageAudioSession ? YES : NO;
      ok = EnsurePermission(&error) && PrepareSession(&error) && StartEngine(&error);
      if (!ok) {
        StopEngine();
        RestoreSession();
      }
      isRunning = ok;
      isInterrupted = NO;
    });

    if (!ok) {
      NSString* message = error.localizedDescription ?: @"Failed to start iOS audio input.";
      throw std::runtime_error(std::string(message.UTF8String));
    }
  }
}

extern "C" void NitroWebrtcVadStopAudioInput() {
  @autoreleasepool {
    dispatch_sync(Queue(), ^{
      isRunning = NO;
      isInterrupted = NO;
      StopEngine();
      RestoreSession();
    });
  }
}
