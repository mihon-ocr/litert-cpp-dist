#!/bin/bash

# Run with:
# chmod +x build_litert.sh && ./build_litert.sh

set -e

# Set LiteRT version
version="v2.1.0rc1"

username=$(whoami)

echo "Attempting to auto-detect ANDROID_NDK_HOME..."
NDK_PATH="/mnt/c/Users/${username}/AppData/Local/Android/Sdk/ndk"

if [ -d "$NDK_PATH" ]; then
    LATEST_NDK=$(ls -1 "${NDK_PATH}" | sort -V | tail -n 1)
    if [ -n "$LATEST_NDK" ]; then
        export ANDROID_NDK_HOME="${NDK_PATH}/${LATEST_NDK}"
        echo "Found NDK at: ${ANDROID_NDK_HOME}"
    fi
fi

if [ -z "$ANDROID_NDK_HOME" ]; then
    echo "Could not auto-detect ANDROID_NDK_HOME. Please set it manually."
    exit 1
fi

# Handle --clean flag
if [ "$1" == "--clean" ]; then
    echo "Cleaning up litert directory..."
    rm -rf litert
fi

# Clone LiteRT source if it doesn't exist
if [ ! -d "litert" ]; then
    echo "Cloning LiteRT ${version}..."
    git clone --depth 1 --branch ${version} https://github.com/google-ai-edge/LiteRT.git litert
fi

cd litert/litert

echo "Building LiteRT version ${version}..."
cmake --preset android-arm64
cmake --build cmake_build_android_arm64 --target flatc -j8

# Build Target (Android) Library
# Point to the host tools we just built so we don't need to patch find_package
cmake --preset android-arm64 \
  -DTFLITE_HOST_TOOLS_DIR="$(pwd)/cmake_build_android_arm64/_deps/flatbuffers-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLITERT_ENABLE_GPU=ON \
  -DLITERT_ENABLE_XNNPACK=ON \
  -DCMAKE_SHARED_LINKER_FLAGS_RELEASE="-Wl,--gc-sections" 

cmake --build cmake_build_android_arm64 -j8
echo "LiteRT build completed."