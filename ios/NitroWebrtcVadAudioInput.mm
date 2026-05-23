#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <string>

extern "C" void NitroWebrtcVadProcessAudioInputFrame(const int16_t* samples, size_t sampleCount);
extern "C" void NitroWebrtcVadNotifyAudioInputStopped();

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

BOOL ConfigureSession(NSError** error) {
  AVAudioSession* session = [AVAudioSession sharedInstance];
  NSTimeInterval frameDuration = static_cast<NSTimeInterval>(targetFrameSamples) / targetSampleRate;
  NSError* sessionError = nil;

  BOOL ok = [session setCategory:AVAudioSessionCategoryPlayAndRecord
                            mode:AVAudioSessionModeMeasurement
                         options:AVAudioSessionCategoryOptionAllowBluetoothHFP |
                                 AVAudioSessionCategoryOptionMixWithOthers
                           error:&sessionError];
  ok = ok && [session setPreferredSampleRate:targetSampleRate error:&sessionError];
  ok = ok && [session setPreferredIOBufferDuration:frameDuration error:&sessionError];
  ok = ok && [session setActive:YES error:&sessionError];

  if (!ok && error != nullptr) {
    *error = sessionError ?: AudioError(@"Failed to configure iOS audio session.");
  }
  return ok;
}

void StopEngine(BOOL deactivateSession) {
  if (engine != nil) {
    [engine.inputNode removeTapOnBus:0];
    [engine stop];
    engine = nil;
  }
  converter = nil;
  outputFormat = nil;
  [pendingPcm setLength:0];

  if (deactivateSession) {
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:nil];
  }
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

BOOL RestartEngine() {
  StopEngine(NO);
  NSError* error = nil;
  return ConfigureSession(&error) && StartEngine(&error);
}

void StopAndNotify() {
  isRunning = NO;
  isInterrupted = NO;
  StopEngine(YES);
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
  });
}

- (void)routeChanged:(NSNotification*)notification {
  (void)notification;
  dispatch_async(Queue(), ^{
    if (isRunning && !isInterrupted && !RestartEngine()) {
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
      StopEngine(NO);
    } else if (type == AVAudioSessionInterruptionTypeEnded && isRunning && isInterrupted) {
      isInterrupted = NO;
      if (!RestartEngine()) {
        StopAndNotify();
      }
    }
  });
}
@end

extern "C" void NitroWebrtcVadStartAudioInput(int sampleRate, size_t frameSamples) {
  @autoreleasepool {
    [NitroWebrtcVadAudioObserver install];

    __block NSError* error = nil;
    __block BOOL ok = NO;
    dispatch_sync(Queue(), ^{
      StopEngine(NO);
      targetSampleRate = sampleRate;
      targetFrameSamples = frameSamples;
      ok = EnsurePermission(&error) && ConfigureSession(&error) && StartEngine(&error);
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
      StopEngine(YES);
    });
  }
}
