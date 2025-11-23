#!/bin/bash

# Run with:
# chmod +x build_litert.sh && ./build_litert.sh

set -e

# Default LiteRT version to build
version="v2.1.0rc1"

export ANDROID_NDK_HOME="$(pwd)/android-ndk-linux"
echo "Using NDK at: ${ANDROID_NDK_HOME}"

clean_litert=false
clean_build=false
build_litert=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)
            clean_litert=true
            clean_build=true
            shift
            ;;
        --clean-litert)
            clean_litert=true
            shift
            ;;
        --clean-build)
            clean_build=true
            shift
            ;;
        --version)
            version="$2"
            shift 2
            ;;
        --no-build)
            build_litert=false
            shift
            ;;
        *)
            shift
            ;;
    esac
done

LITERT_SRC_DIR="litert-${version}"
BUILD_DIR="/home/${USER}/litert-cpp-dist/cmake_builds_${version}"

if [ "$clean_litert" = true ]; then
    echo "Cleaning up ${LITERT_SRC_DIR} directory..."
    rm -rf "${LITERT_SRC_DIR}"
fi

if [ "$clean_build" = true ]; then
    echo "Cleaning up build directory..."
    rm -rf "${BUILD_DIR}"
fi

if [ "$build_litert" = false ]; then
    echo "Ending before build..."
    exit
fi

# Clone LiteRT source if it doesn't exist
if [ ! -d "${LITERT_SRC_DIR}" ]; then
    echo "Cloning LiteRT ${version}..."
    git clone --depth 1 --branch ${version} https://github.com/google-ai-edge/LiteRT.git "${LITERT_SRC_DIR}"
fi

cd "${LITERT_SRC_DIR}/litert"

echo "Building LiteRT version ${version}..."
cmake --preset android-arm64 -B "${BUILD_DIR}"
cmake --build "${BUILD_DIR}" --target flatc -j8

# Build Target (Android) Library
# Point to the host tools we just built so we don't need to patch find_package
cmake --preset android-arm64 \
  -B "${BUILD_DIR}" \
  -DTFLITE_HOST_TOOLS_DIR="${BUILD_DIR}/_deps/flatbuffers-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLITERT_ENABLE_GPU=ON \
  -DLITERT_ENABLE_XNNPACK=ON \
  -DCMAKE_SHARED_LINKER_FLAGS_RELEASE="-Wl,--gc-sections" 

cmake --build "${BUILD_DIR}" -j8
echo "LiteRT build completed."