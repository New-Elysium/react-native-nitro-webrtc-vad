#include "HybridNitroWebrtcVad.hpp"
#include <chrono>
#include <cstdint>
#include <stdexcept>

#if defined(__ANDROID__)
#include <fbjni/fbjni.h>
#include <jni.h>
#endif

#if defined(__APPLE__) && !defined(__ANDROID__)
extern "C" void NitroWebrtcVadStartAudioInput(int sampleRate, size_t frameSamples);
extern "C" void NitroWebrtcVadStopAudioInput();
#endif

#include "webrtc/common_audio/vad/include/webrtc_vad.h"

namespace margelo::nitro::nitrowebrtcvad {

namespace {
std::mutex activeAudioInputMutex;
HybridNitroWebrtcVad* activeAudioInputInstance = nullptr;

void platformStartAudioInput(int sampleRate, size_t frameSamples);
void platformStopAudioInput();
} // namespace

HybridNitroWebrtcVad::~HybridNitroWebrtcVad() {
    clearActiveAudioInputInstance();
    std::lock_guard<std::mutex> lock(mutex_);
    resetVadLocked();
}

void HybridNitroWebrtcVad::start(double mode, double sampleRate, double frameMs, double speechStartFrames, double speechEndFrames) {
    const int modeValue = static_cast<int>(mode);
    const int sampleRateValue = static_cast<int>(sampleRate);
    const int frameMsValue = static_cast<int>(frameMs);
    const int speechStartFramesValue = static_cast<int>(speechStartFrames);
    const int speechEndFramesValue = static_cast<int>(speechEndFrames);

    if (modeValue < 0 || modeValue > 3) {
        throw std::invalid_argument("VAD mode must be between 0 and 3.");
    }
    if (frameMsValue != 10 && frameMsValue != 20 && frameMsValue != 30) {
        throw std::invalid_argument("VAD frameMs must be 10, 20, or 30.");
    }
    if (speechStartFramesValue < 1 || speechEndFramesValue < 1) {
        throw std::invalid_argument("VAD speech frame thresholds must be greater than 0.");
    }

    const size_t frameSamples = static_cast<size_t>(sampleRateValue * frameMsValue / 1000);
    if (WebRtcVad_ValidRateAndFrameLength(sampleRateValue, frameSamples) != 0) {
        throw std::invalid_argument("Unsupported VAD sampleRate/frameMs combination.");
    }

    VadInst* vad = WebRtcVad_Create();
    if (vad == nullptr || WebRtcVad_Init(vad) != 0 || WebRtcVad_set_mode(vad, modeValue) != 0) {
        if (vad != nullptr) {
            WebRtcVad_Free(vad);
        }
        throw std::runtime_error("Failed to initialize WebRTC VAD.");
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (isRunning_) {
        WebRtcVad_Free(vad);
        throw std::runtime_error("VAD is already running.");
    }

    resetVadLocked();
    vad_ = vad;
    sampleRate_ = sampleRateValue;
    frameSamples_ = frameSamples;
    speechStartFrames_ = speechStartFramesValue;
    speechEndFrames_ = speechEndFramesValue;
    speechFrames_ = 0;
    silenceFrames_ = 0;
    isRunning_ = true;
    isSpeechActive_ = false;

    try {
        setActiveAudioInputInstance();
        platformStartAudioInput(sampleRate_, frameSamples_);
    } catch (...) {
        clearActiveAudioInputInstance();
        resetVadLocked();
        throw;
    }
}

void HybridNitroWebrtcVad::stop() {
    clearActiveAudioInputInstance();
    std::lock_guard<std::mutex> lock(mutex_);
    resetVadLocked();
}

void HybridNitroWebrtcVad::setListener(const std::function<void(const std::string&, double)>& listener) {
    std::lock_guard<std::mutex> lock(mutex_);
    listener_ = listener;
}

void HybridNitroWebrtcVad::clearListener() {
    std::lock_guard<std::mutex> lock(mutex_);
    listener_ = nullptr;
}

bool HybridNitroWebrtcVad::processFrame(const std::shared_ptr<ArrayBuffer>& pcm16) {
    if (pcm16 == nullptr || pcm16->data() == nullptr) {
        throw std::invalid_argument("pcm16 must be a valid ArrayBuffer.");
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!isRunning_ || vad_ == nullptr) {
            throw std::runtime_error("VAD is not running. Call start() before processFrame().");
        }
        if (pcm16->size() != frameSamples_ * sizeof(int16_t)) {
            throw std::invalid_argument("pcm16 byte length does not match the configured VAD frame size.");
        }
    }

    const auto* samples = reinterpret_cast<const int16_t*>(pcm16->data());
    return processAudioInputFrame(samples, pcm16->size() / sizeof(int16_t));
}

bool HybridNitroWebrtcVad::processAudioInputFrame(const int16_t* samples, size_t sampleCount) {
    if (samples == nullptr) {
        return false;
    }

    bool shouldEmitSpeechStart = false;
    bool shouldEmitSpeechEnd = false;
    bool isSpeech = false;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!isRunning_ || vad_ == nullptr || sampleCount != frameSamples_) {
            return false;
        }

        const int result = WebRtcVad_Process(vad_, sampleRate_, samples, frameSamples_);
        if (result < 0) {
            return false;
        }

        isSpeech = result == 1;
        processVadResultLocked(isSpeech, shouldEmitSpeechStart, shouldEmitSpeechEnd);
    }

    if (shouldEmitSpeechStart) {
        emitEvent("speechStart");
    }
    if (shouldEmitSpeechEnd) {
        emitEvent("speechEnd");
    }

    return isSpeech;
}

void HybridNitroWebrtcVad::handlePlatformAudioInputStopped() {
    bool shouldEmitSpeechEnd = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!isRunning_) {
            return;
        }
        shouldEmitSpeechEnd = isSpeechActive_;
        resetVadLocked();
    }

    {
        std::lock_guard<std::mutex> lock(activeAudioInputMutex);
        if (activeAudioInputInstance == this) {
            activeAudioInputInstance = nullptr;
        }
    }

    if (shouldEmitSpeechEnd) {
        emitEvent("speechEnd");
    }
}

void HybridNitroWebrtcVad::setActiveAudioInputInstance() {
    std::lock_guard<std::mutex> lock(activeAudioInputMutex);
    if (activeAudioInputInstance != nullptr && activeAudioInputInstance != this) {
        throw std::runtime_error("Only one VAD audio input instance can run at a time.");
    }
    activeAudioInputInstance = this;
}

void HybridNitroWebrtcVad::clearActiveAudioInputInstance() {
    bool shouldStopAudioInput = false;
    {
        std::lock_guard<std::mutex> lock(activeAudioInputMutex);
        if (activeAudioInputInstance == this) {
            activeAudioInputInstance = nullptr;
            shouldStopAudioInput = true;
        }
    }
    if (shouldStopAudioInput) {
        platformStopAudioInput();
    }
}

void HybridNitroWebrtcVad::processVadResultLocked(bool isSpeech, bool& shouldEmitSpeechStart, bool& shouldEmitSpeechEnd) {
    if (isSpeech) {
        speechFrames_ += 1;
        silenceFrames_ = 0;
        if (!isSpeechActive_ && speechFrames_ >= speechStartFrames_) {
            isSpeechActive_ = true;
            shouldEmitSpeechStart = true;
        }
    } else {
        silenceFrames_ += 1;
        speechFrames_ = 0;
        if (isSpeechActive_ && silenceFrames_ >= speechEndFrames_) {
            isSpeechActive_ = false;
            shouldEmitSpeechEnd = true;
        }
    }
}

void HybridNitroWebrtcVad::resetVadLocked() {
    if (vad_ != nullptr) {
        WebRtcVad_Free(vad_);
        vad_ = nullptr;
    }
    isRunning_ = false;
    speechFrames_ = 0;
    silenceFrames_ = 0;
    isSpeechActive_ = false;
}

void HybridNitroWebrtcVad::emitEvent(const std::string& eventType) {
    std::function<void(const std::string&, double)> listener;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        listener = listener_;
    }
    if (!listener) {
        return;
    }

    const auto now = std::chrono::system_clock::now();
    const auto timestampMs = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
    listener(eventType, static_cast<double>(timestampMs));
}

namespace {

#if defined(__ANDROID__)
void platformStartAudioInput(int sampleRate, size_t frameSamples) {
    JNIEnv* env = facebook::jni::Environment::current();
    jclass audioInputClass = env->FindClass("com/nitrowebrtcvad/NitroWebrtcVadAudioInput");
    if (audioInputClass == nullptr) {
        throw std::runtime_error("Failed to find Android audio input helper.");
    }

    jmethodID startMethod = env->GetStaticMethodID(audioInputClass, "start", "(II)V");
    if (startMethod == nullptr) {
        env->DeleteLocalRef(audioInputClass);
        throw std::runtime_error("Failed to find Android audio input start method.");
    }

    env->CallStaticVoidMethod(audioInputClass, startMethod, static_cast<jint>(sampleRate), static_cast<jint>(frameSamples));
    env->DeleteLocalRef(audioInputClass);

    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        throw std::runtime_error("Failed to start Android audio input.");
    }
}

void platformStopAudioInput() {
    JNIEnv* env = facebook::jni::Environment::current();
    jclass audioInputClass = env->FindClass("com/nitrowebrtcvad/NitroWebrtcVadAudioInput");
    if (audioInputClass == nullptr) {
        env->ExceptionClear();
        return;
    }

    jmethodID stopMethod = env->GetStaticMethodID(audioInputClass, "stop", "()V");
    if (stopMethod != nullptr) {
        env->CallStaticVoidMethod(audioInputClass, stopMethod);
    }
    env->DeleteLocalRef(audioInputClass);

    if (env->ExceptionCheck()) {
        env->ExceptionClear();
    }
}
#elif defined(__APPLE__)
void platformStartAudioInput(int sampleRate, size_t frameSamples) {
    NitroWebrtcVadStartAudioInput(sampleRate, frameSamples);
}

void platformStopAudioInput() {
    NitroWebrtcVadStopAudioInput();
}
#else
void platformStartAudioInput(int, size_t) {}
void platformStopAudioInput() {}
#endif

void processActiveAudioInputFrame(const int16_t* samples, size_t sampleCount) {
    HybridNitroWebrtcVad* instance = nullptr;
    {
        std::lock_guard<std::mutex> lock(activeAudioInputMutex);
        instance = activeAudioInputInstance;
    }
    if (instance != nullptr) {
        instance->processAudioInputFrame(samples, sampleCount);
    }
}

} // namespace

extern "C" void NitroWebrtcVadProcessAudioInputFrame(const int16_t* samples, size_t sampleCount) {
    processActiveAudioInputFrame(samples, sampleCount);
}

extern "C" void NitroWebrtcVadNotifyAudioInputStopped() {
    HybridNitroWebrtcVad* instance = nullptr;
    {
        std::lock_guard<std::mutex> lock(activeAudioInputMutex);
        instance = activeAudioInputInstance;
    }
    if (instance != nullptr) {
        instance->handlePlatformAudioInputStopped();
    }
}

} // namespace margelo::nitro::nitrowebrtcvad

#if defined(__ANDROID__)
namespace margelo::nitro::nitrowebrtcvad {

extern "C" JNIEXPORT void JNICALL
Java_com_nitrowebrtcvad_NitroWebrtcVadAudioInput_onAudioFrame(JNIEnv* env, jclass, jshortArray audioFrame) {
    if (audioFrame == nullptr) {
        return;
    }

    const jsize frameLength = env->GetArrayLength(audioFrame);
    jshort* audioFramePtr = env->GetShortArrayElements(audioFrame, nullptr);
    if (audioFramePtr == nullptr) {
        return;
    }

    processActiveAudioInputFrame(
        reinterpret_cast<const int16_t*>(audioFramePtr),
        static_cast<size_t>(frameLength)
    );

    env->ReleaseShortArrayElements(audioFrame, audioFramePtr, JNI_ABORT);
}

} // namespace margelo::nitro::nitrowebrtcvad
#endif
