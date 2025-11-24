#!/bin/bash
set -ueo pipefail

# Note: This script requires sudo

# Default configuration
LITERT_REPO_URL="${LITERT_REPO_URL:-https://github.com/google-ai-edge/LiteRT.git}"
LITERT_TAG="${LITERT_TAG:-v2.1.0rc1}"
LITERT_SRC="${LITERT_SRC:-litert}"
OUTPUT_DIR="$(pwd)/litert_android_arm64"
ZIP_FILE="$(pwd)/litert_android_arm64.zip"

# Clone LiteRT if it doesn't already exists
if [ ! -d "${LITERT_SRC}" ]; then
    echo "Cloning LiteRT ${LITERT_TAG}..."
    git clone --depth 1 --branch "${LITERT_TAG}" "${LITERT_REPO_URL}" "${LITERT_SRC}"
else
    echo "LiteRT source found at ${LITERT_SRC}."
fi

cd "${LITERT_SRC}"

build_with_docker() {
    echo "Attempting Docker build..."
    
    if ! command -v docker &> /dev/null; then
        echo "Docker not found. Skipping Docker build."
        return 1
    fi

    if ! sudo docker info &> /dev/null; then
        echo "Docker daemon not running. Skipping Docker build."
        return 1
    fi

    # Build the docker image
    echo "Building Docker image..."
    if [ -f "docker_build/hermetic_build.Dockerfile" ]; then
        sudo docker build -t litert_build -f docker_build/hermetic_build.Dockerfile docker_build
    else
        echo "docker_build/hermetic_build.Dockerfile not found. Cannot build image."
        return 1
    fi

    if [ $? -ne 0 ]; then
        echo "Docker image build failed."
        return 1
    fi

    echo "Running Bazel build inside Docker..."
    
    HOST_OS=$(uname -s || echo unknown)
    HOST_ARCH=$(uname -m || echo unknown)
    DISABLE_SVE_ARG=""
    if [ "$HOST_OS" = "Darwin" ] && { [ "$HOST_ARCH" = "arm64" ] || [ "$HOST_ARCH" = "aarch64" ]; }; then
        DISABLE_SVE_ARG="-e DISABLE_SVE_FOR_BAZEL=1"
    fi

    # Run the build command inside the container
    sudo docker run --rm \
        --security-opt seccomp=unconfined \
        --user $(id -u):$(id -g) \
        -e HOME=/litert_build \
        -e USER=$(id -un) \
        $DISABLE_SVE_ARG \
        -v $(pwd):/litert_build \
        -w /litert_build \
        litert_build \
        bazel build --config=android_arm64 //litert/c:litert_runtime_c_api_so

    if [ $? -eq 0 ]; then
        echo "Docker build successful."

        # Find shared library
        FOUND=$(find .cache -name "libLiteRt.so" -path "*/arm64-v8a-opt/bin/litert/c/*" 2>/dev/null | head -1)
        if [ -n "$FOUND" ]; then
            echo "Build Artifacts: $(pwd)/$FOUND"
            package_artifacts
            return 0
        else
            echo "Build completed but libLiteRt.so not found."
            return 1
        fi
    fi
    
    echo "Docker build failed or artifacts not found."
    return 1
}

# Package artifacts into a zip file suitable for CMake FetchContent
package_artifacts() {
    echo "Packaging artifacts into zip file..."
    
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR/lib"
    mkdir -p "$OUTPUT_DIR/include"
    
    # Find and copy the shared library
    SO_FILE=""
    
    # Search specifically in arm64-v8a-opt output to avoid wrong architecture
    # Use the most recent file in case of multiple builds
    SO_FILE=$(find .cache -name "libLiteRt.so" -path "*/arm64-v8a-opt/bin/litert/c/*" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
    
    if [ -n "$SO_FILE" ]; then
        echo "Copying library: $SO_FILE"
        cp "$SO_FILE" "$OUTPUT_DIR/lib/"
    else
        echo "Error: Could not find libLiteRt.so"
        return 1
    fi
    
    # Copy all necessary headers using pattern matching
    echo "Copying header files..."
    
    # Copy all C++ API headers from litert/cc/ (includes all subdirectories)
    if [ -d "litert/cc" ]; then
        find litert/cc -name "*.h" | while read header; do
            mkdir -p "$OUTPUT_DIR/include/$(dirname $header)"
            cp "$header" "$OUTPUT_DIR/include/$header"
        done
    fi
    
    # Copy C API headers
    echo "Copying C API headers..."
    if [ -d "litert/c" ]; then
        find litert/c -name "*.h" | while read header; do
            mkdir -p "$OUTPUT_DIR/include/$(dirname $header)"
            cp "$header" "$OUTPUT_DIR/include/$header"
        done
    fi
    
    # Copy necessary TFLite headers
    echo "Copying TFLite headers..."
    if [ -f "tflite/builtin_ops.h" ]; then
        mkdir -p "$OUTPUT_DIR/include/tflite"
        cp "tflite/builtin_ops.h" "$OUTPUT_DIR/include/tflite/"
    fi
    
    if [ -d "tflite/c" ]; then
        find tflite/c -name "*.h" | while read header; do
            mkdir -p "$OUTPUT_DIR/include/$(dirname $header)"
            cp "$header" "$OUTPUT_DIR/include/$header"
        done
    fi
    
    if [ -d "tflite/core/c" ]; then
        find tflite/core/c -name "*.h" | while read header; do
            mkdir -p "$OUTPUT_DIR/include/$(dirname $header)"
            cp "$header" "$OUTPUT_DIR/include/$header"
        done
    fi
    
    echo "Copying generated build_config.h..."
    BUILD_CONFIG=$(find .cache -name "build_config.h" -path "*/arm64-v8a-opt/bin/litert/build_common/*" ! -path "*/_virtual_includes/*" 2>/dev/null | head -1)
    if [ -n "$BUILD_CONFIG" ]; then
        mkdir -p "$OUTPUT_DIR/include/litert/build_common"
        cp "$BUILD_CONFIG" "$OUTPUT_DIR/include/litert/build_common/"
        echo "Copied build_config.h from: $BUILD_CONFIG"
    else
        echo "WARNING: build_config.h not found. This may cause compilation errors."
    fi
    
    # Create a CMakeLists.txt
    cat > "$OUTPUT_DIR/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.19)
project(LiteRT)

add_library(litert SHARED IMPORTED GLOBAL)
set_target_properties(litert PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/lib/libLiteRt.so"
    INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

# Create an interface target for easier use
add_library(LiteRT::litert ALIAS litert)
EOF
    
    echo "Creating zip file: $ZIP_FILE"
    cd "$(dirname $OUTPUT_DIR)"
    zip -r "$ZIP_FILE" "$(basename $OUTPUT_DIR)"
    cd - > /dev/null
    
    echo
    echo "---"
    echo "Build and packaging complete!"
    echo "Output directory: $OUTPUT_DIR"
    echo "Zip file: $ZIP_FILE"
    echo "---"
}


# Execution
if build_with_docker; then
    exit 0
else
    echo "Docker build failed."
    exit 1
fi
