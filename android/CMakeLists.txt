project(NitroWebrtcVad)
cmake_minimum_required(VERSION 3.9.0)

set (PACKAGE_NAME NitroWebrtcVad)
set (CMAKE_VERBOSE_MAKEFILE ON)
set (CMAKE_CXX_STANDARD 20)

# Enable Raw Props parsing in react-native (for Nitro Views)
add_compile_options(-DRN_SERIALIZABLE_STATE=1)

file(GLOB WEBRTC_VAD_SOURCES CONFIGURE_DEPENDS
        ../third_party/webrtcvad/webrtc/common_audio/vad/*.c
        ../third_party/webrtcvad/webrtc/common_audio/signal_processing/*.c
        ../third_party/webrtcvad/webrtc/common_audio/third_party/spl_sqrt_floor/*.c
        ../third_party/webrtcvad/webrtc/rtc_base/*.cc
)

# Define C++ library and add all sources
add_library(${PACKAGE_NAME} SHARED 
	src/main/cpp/cpp-adapter.cpp
	../cpp/HybridNitroWebrtcVad.cpp
        ${WEBRTC_VAD_SOURCES}
        
)

target_compile_definitions(${PACKAGE_NAME} PRIVATE WEBRTC_POSIX WEBRTC_ANDROID)

# Add Nitrogen specs :)
include(${CMAKE_SOURCE_DIR}/../nitrogen/generated/android/NitroWebrtcVad+autolinking.cmake)

# Set up local includes
include_directories(
        "src/main/cpp"
        "../cpp"
        "../third_party/webrtcvad"
)

find_library(LOG_LIB log)

# Link all libraries together
target_link_libraries(
        ${PACKAGE_NAME}
        ${LOG_LIB}
        android                                   # <-- Android core
)
