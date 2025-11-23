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
HOST_BUILD_DIR="${BUILD_DIR}_host"
ANDROID_BUILD_DIR="${BUILD_DIR}_android"

if [ "$clean_litert" = true ]; then
    echo "Cleaning up ${LITERT_SRC_DIR} directory..."
    rm -rf "${LITERT_SRC_DIR}"
fi

if [ "$clean_build" = true ]; then
    echo "Cleaning up build directory..."
    rm -rf "${HOST_BUILD_DIR}" "${ANDROID_BUILD_DIR}"
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

echo -e "\nBuilding Host Tools (flatc)...\n"
cmake --preset default \
    -B "${HOST_BUILD_DIR}" \
    -DLITERT_BUILD_TESTS=OFF \
    -DLITERT_ENABLE_XNNPACK=OFF \

cmake --build "${HOST_BUILD_DIR}" --target flatc -j8

echo -e "\nBuilding Android Library...\n"
cmake --preset android-arm64 \
  -B "${ANDROID_BUILD_DIR}" \
  -DTFLITE_HOST_TOOLS_DIR="${HOST_BUILD_DIR}/_deps/flatbuffers-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLITERT_ENABLE_GPU=ON \
  -DLITERT_ENABLE_XNNPACK=ON \
  -DCMAKE_SHARED_LINKER_FLAGS_RELEASE="-Wl,--gc-sections" 

cmake --build "${ANDROID_BUILD_DIR}" -j8

echo -e "\nLiteRT build completed. Artifacts are in ${ANDROID_BUILD_DIR}"