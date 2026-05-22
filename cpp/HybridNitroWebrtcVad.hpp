#pragma once
#include <vector>
#include "HybridNitroWebrtcVadSpec.hpp"

namespace margelo::nitro::nitrowebrtcvad {
class HybridNitroWebrtcVad : public HybridNitroWebrtcVadSpec {
    public:
        HybridNitroWebrtcVad() : HybridObject(TAG), HybridNitroWebrtcVadSpec() {}
       
        double sum(double a, double b) override;
    };
} // namespace margelo::nitro::nitrowebrtcvad
