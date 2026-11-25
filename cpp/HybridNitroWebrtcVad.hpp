#pragma once
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <NitroModules/ArrayBuffer.hpp>
#include "HybridNitroWebrtcVadSpec.hpp"
#include "IosAudioSession.hpp"

struct WebRtcVadInst;
typedef struct WebRtcVadInst VadInst;

namespace margelo::nitro::nitrowebrtcvad {
class HybridNitroWebrtcVad : public HybridNitroWebrtcVadSpec {
    public:
        HybridNitroWebrtcVad() : HybridObject(TAG), HybridNitroWebrtcVadSpec() {}
        ~HybridNitroWebrtcVad() override;
       
        void start(double mode, double sampleRate, double frameMs, double speechStartFrames, double speechEndFrames, IosAudioSession iosAudioSession) override;
        void stop() override;
        void setListener(const std::function<void(const std::string&, double)>& listener) override;
        void clearListener() override;
        bool processFrame(const std::shared_ptr<ArrayBuffer>& pcm16) override;
        bool processAudioInputFrame(const int16_t* samples, size_t sampleCount);
        void handlePlatformAudioInputStopped();

    private:
        void setActiveAudioInputInstance();
        void clearActiveAudioInputInstance();
        void processVadResultLocked(bool isSpeech, bool& shouldEmitSpeechStart, bool& shouldEmitSpeechEnd);
        void resetVadLocked();
        void emitEvent(const std::string& eventType);

        std::mutex mutex_;
        VadInst* vad_ = nullptr;
        int sampleRate_ = 16000;
        size_t frameSamples_ = 320;
        int speechStartFrames_ = 3;
        int speechEndFrames_ = 8;
        int speechFrames_ = 0;
        int silenceFrames_ = 0;
        bool isRunning_ = false;
        bool isSpeechActive_ = false;
        std::function<void(const std::string&, double)> listener_;
    };
} // namespace margelo::nitro::nitrowebrtcvad
