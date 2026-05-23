#include "HybridNitroWebrtcVad.hpp"
#include <chrono>
#include <cstdint>
#include <stdexcept>

#include "webrtc/common_audio/vad/include/webrtc_vad.h"

namespace margelo::nitro::nitrowebrtcvad {

HybridNitroWebrtcVad::~HybridNitroWebrtcVad() {
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
}

void HybridNitroWebrtcVad::stop() {
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

    bool shouldEmitSpeechStart = false;
    bool shouldEmitSpeechEnd = false;
    bool isSpeech = false;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!isRunning_ || vad_ == nullptr) {
            throw std::runtime_error("VAD is not running. Call start() before processFrame().");
        }
        if (pcm16->size() != frameSamples_ * sizeof(int16_t)) {
            throw std::invalid_argument("pcm16 byte length does not match the configured VAD frame size.");
        }

        const auto* samples = reinterpret_cast<const int16_t*>(pcm16->data());
        const int result = WebRtcVad_Process(vad_, sampleRate_, samples, frameSamples_);
        if (result < 0) {
            throw std::runtime_error("WebRTC VAD failed to process the frame.");
        }

        isSpeech = result == 1;
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

    if (shouldEmitSpeechStart) {
        emitEvent("speechStart");
    }
    if (shouldEmitSpeechEnd) {
        emitEvent("speechEnd");
    }

    return isSpeech;
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

} // namespace margelo::nitro::nitrowebrtcvad
