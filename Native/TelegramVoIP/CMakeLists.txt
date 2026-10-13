# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.20)
project(MakoshTelegramVoIP LANGUAGES C CXX OBJC OBJCXX)
get_filename_component(makosh_repo "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
include("${MAKOSH_CALL_DEST}/CompilationInputs.cmake")
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(TG_OWT_SPECIAL_TARGET macstore CACHE STRING "" FORCE)
set(TG_OWT_BUILD_AUDIO_BACKENDS ON CACHE BOOL "" FORCE)
set(TG_OWT_OPENSSL_INCLUDE_PATH "${MAKOSH_OPENSSL}/include" CACHE STRING "" FORCE)
set(TG_OWT_OPUS_INCLUDE_PATH "${makosh_repo}/.local/voice-codec/Sources/COpus/include" CACHE STRING "" FORCE)
set(TG_OWT_LIBJPEG_INCLUDE_PATH "${makosh_repo}/.local/jpeg-codec/Sources/CMozjpeg/include" CACHE STRING "" FORCE)
set(TG_OWT_LIBVPX_INCLUDE_PATH "${MAKOSH_CALL_DEST}/vpx" CACHE STRING "" FORCE)
set(TG_OWT_OPENH264_INCLUDE_PATH "${MAKOSH_CALL_SOURCE}/owt/src" CACHE STRING "" FORCE)
set(TG_OWT_FFMPEG_INCLUDE_PATH "${MAKOSH_CALL_SOURCE}/owt/src" CACHE STRING "" FORCE)
add_subdirectory("${MAKOSH_CALL_SOURCE}/owt" owt)
set(CMAKE_OSX_DEPLOYMENT_TARGET 26.0)
get_target_property(makosh_definitions libwebrtcbuild INTERFACE_COMPILE_DEFINITIONS)
list(REMOVE_ITEM makosh_definitions WEBRTC_USE_H264 RTC_ENABLE_H265)
set_property(TARGET libwebrtcbuild PROPERTY INTERFACE_COMPILE_DEFINITIONS "${makosh_definitions}")
foreach(prop LINK_LIBRARIES INTERFACE_LINK_LIBRARIES)
 get_target_property(makosh_links tg_owt ${prop})
 list(REMOVE_ITEM makosh_links tg_owt::libsdkmacos)
 set_property(TARGET tg_owt PROPERTY ${prop} "${makosh_links}")
endforeach()
set_property(TARGET libsdkmacos PROPERTY EXCLUDE_FROM_ALL TRUE)

set(makosh_calls ${MAKOSH_CALL_SOURCE}/calls/tgcalls)
add_library(makosh_calls STATIC
 ${makosh_calls}/Instance.cpp ${makosh_calls}/InstanceImpl.cpp
 ${makosh_calls}/Manager.cpp ${makosh_calls}/MediaManager.cpp ${makosh_calls}/NetworkManager.cpp
 ${makosh_calls}/Message.cpp ${makosh_calls}/CryptoHelper.cpp ${makosh_calls}/EncryptedConnection.cpp
 ${makosh_calls}/CodecSelectHelper.cpp ${makosh_calls}/AudioDeviceHelper.cpp
 ${makosh_calls}/StaticThreads.cpp ${makosh_calls}/ThreadLocalObject.cpp
 ${makosh_calls}/VideoCaptureInterface.cpp ${makosh_calls}/VideoCaptureInterfaceImpl.cpp
 ${makosh_calls}/TurnCustomizerImpl.cpp ${makosh_calls}/LogSinkImpl.cpp ${makosh_calls}/FieldTrialsConfig.cpp
 ${makosh_calls}/v2/ReflectorRelayPortFactory.cpp ${makosh_calls}/v2/ReflectorPort.cpp ${makosh_calls}/v2/RawTcpSocket.cpp)
target_include_directories(makosh_calls PUBLIC ${CMAKE_CURRENT_SOURCE_DIR} ${makosh_calls} ${TG_OWT_OPENSSL_INCLUDE_PATH})
target_compile_options(makosh_calls PRIVATE -fvisibility=hidden -fvisibility-inlines-hidden -Wno-deprecated-declarations)
target_link_libraries(makosh_calls PUBLIC tg_owt)
add_library(makosh_call_opus STATIC ${MAKOSH_OPUS_SOURCES})
set(makosh_opus "${makosh_repo}/.local/voice-codec/Sources/COpus")
target_include_directories(makosh_call_opus PRIVATE ${makosh_opus} ${makosh_opus}/include ${makosh_opus}/celt ${makosh_opus}/silk ${makosh_opus}/silk/float)
target_compile_definitions(makosh_call_opus PRIVATE OPUS_BUILD USE_ALLOCA HAVE_ALLOCA_H HAVE_LRINT HAVE_LRINTF PACKAGE_VERSION="1.5.1")
target_compile_options(makosh_call_opus PRIVATE -fvisibility=hidden)
add_library(makosh_call_jpeg STATIC ${MAKOSH_JPEG_SOURCES})
target_include_directories(makosh_call_jpeg PRIVATE "${makosh_repo}/.local/jpeg-codec/Sources/CMozjpeg" "${makosh_repo}/.local/jpeg-codec/Sources/CMozjpeg/include")
target_compile_options(makosh_call_jpeg PRIVATE -fvisibility=hidden)
add_library(makosh_call_bridge OBJECT "${makosh_repo}/Native/TelegramVoIP/CallNative.mm" "${makosh_repo}/Native/TelegramVoIP/CallPlatform.cpp" "${makosh_repo}/Native/TelegramVoIP/CallAudio.cpp")
target_include_directories(makosh_call_bridge PUBLIC "${makosh_repo}/Native/TelegramVoIP" "${makosh_repo}/Sources/CMakoshTelegramVoIP/include")
target_compile_options(makosh_call_bridge PRIVATE -fvisibility=hidden -fvisibility-inlines-hidden -fobjc-arc)
target_link_libraries(makosh_call_bridge PUBLIC makosh_calls makosh_call_opus makosh_call_jpeg
 "${MAKOSH_CALL_DEST}/vpx-build/libvpx.a"
 "${MAKOSH_OPENSSL}/lib/libssl.dylib" "${MAKOSH_OPENSSL}/lib/libcrypto.dylib"
 "-framework Cocoa" "-framework CoreAudio" "-framework AudioToolbox" "-framework AVFoundation" "-framework CoreMedia"
 "-framework CoreVideo" "-framework VideoToolbox" "-framework CoreGraphics" "-framework Foundation" "-framework Security")
add_executable(makosh_call_media_tests "${makosh_repo}/Tests/TelegramVoipNative/CallMediaTests.cpp"
 "${MAKOSH_CALL_SOURCE}/owt/src/modules/audio_device/include/test_audio_device.cc"
 "${MAKOSH_CALL_SOURCE}/owt/src/modules/audio_device/test_audio_device_impl.cc")
target_link_libraries(makosh_call_media_tests PRIVATE makosh_call_bridge)
target_compile_options(makosh_call_media_tests PRIVATE -UNDEBUG)

add_library(MakoshTelegramVoIP SHARED)
target_link_libraries(MakoshTelegramVoIP PRIVATE makosh_call_bridge)
target_link_options(MakoshTelegramVoIP PRIVATE -Wl,-dead_strip "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exports.txt")
set_target_properties(MakoshTelegramVoIP PROPERTIES INSTALL_NAME_DIR "@rpath" BUILD_WITH_INSTALL_NAME_DIR TRUE)
add_executable(makosh_call_admission_tests "${makosh_repo}/Tests/TelegramVoipNative/CallAdmissionTests.cpp")
target_include_directories(makosh_call_admission_tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${makosh_repo}/Sources/CMakoshTelegramVoIP/include")
target_compile_options(makosh_call_admission_tests PRIVATE -UNDEBUG -Wall -Wextra -Werror)
add_executable(makosh_call_network_policy_tests "${makosh_repo}/Tests/TelegramVoipNative/CallNetworkPolicyTests.cpp")
target_link_libraries(makosh_call_network_policy_tests PRIVATE makosh_call_bridge)
target_compile_options(makosh_call_network_policy_tests PRIVATE -UNDEBUG)
add_executable(makosh_call_audio_admission_tests "${makosh_repo}/Tests/TelegramVoipNative/CallAudioAdmissionTests.cpp")
target_link_libraries(makosh_call_audio_admission_tests PRIVATE makosh_call_bridge)
target_compile_options(makosh_call_audio_admission_tests PRIVATE -UNDEBUG)
