#!/bin/bash
set -ueo pipefail

# Default configuration
LITERT_REPO_URL="${LITERT_REPO_URL:-https://github.com/google-ai-edge/LiteRT.git}"
LITERT_TAG="${LITERT_TAG:-v2.1.0rc1}"
LITERT_SRC="${LITERT_SRC:-litert}"
OUTPUT_DIR="$(pwd)/litert_android"
ZIP_FILE="$(pwd)/litert_android.zip"
INITIAL_DIR="$(pwd)"
update_release="false"

# Parse command-line arguments
for arg in "$@"
do
    case $arg in
        --update-release)
        update_release="true"
        break
        ;;
    esac
done

# Build configuration - enable GPU support
BUILD_INCLUDE="${BUILD_INCLUDE:-gpu}"  # Can be: gpu, npu, gpu,npu, cpu_only

# Architecture configurations: config_name:abi_name:bazel_output_path
declare -a ARCHITECTURES=(
    "android_arm64:arm64-v8a:arm64-v8a-opt"
    "android_arm:armeabi-v7a:armeabi-v7a-opt"
    "android_x86_64:x86_64:x86_64-opt"
    "android_x86:x86:x86-opt"
)

# Clone LiteRT if it doesn't already exists
if [ ! -d "${LITERT_SRC}" ]; then
    echo "Cloning LiteRT ${LITERT_TAG}..."
    git clone --depth 1 --branch "${LITERT_TAG}" "${LITERT_REPO_URL}" "${LITERT_SRC}"
    rm -rf "${LITERT_SRC}/.git"
    rm -rf "${LITERT_SRC}/.gitignore"
    rm -rf "${LITERT_SRC}/.gitattributes"
    rm -rf "${LITERT_SRC}/.gitconfig"
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

    echo "Running Bazel builds inside Docker for all architectures..."
    
    HOST_OS=$(uname -s || echo unknown)
    HOST_ARCH=$(uname -m || echo unknown)
    DISABLE_SVE_ARG=""
    if [ "$HOST_OS" = "Darwin" ] && { [ "$HOST_ARCH" = "arm64" ] || [ "$HOST_ARCH" = "aarch64" ]; }; then
        DISABLE_SVE_ARG="-e DISABLE_SVE_FOR_BAZEL=1"
    fi

    # Build target
    TARGET="//litert/c:litert_runtime_c_api_so"
    
    # Loop through all architectures
    for arch_config in "${ARCHITECTURES[@]}"; do
        IFS=':' read -r BUILD_CONFIG ABI_NAME OUTPUT_PATH <<< "$arch_config"
        
        echo ""
        echo "---"
        echo "Building for $ABI_NAME (config: $BUILD_CONFIG)..."
        echo "---"
        
        # Build flags for GPU/NPU support
        BUILD_FLAGS="--config=${BUILD_CONFIG}"
        if [ -n "$BUILD_INCLUDE" ]; then
            BUILD_FLAGS="$BUILD_FLAGS --//litert/build_common:build_include=${BUILD_INCLUDE}"
        fi
        
        echo "Build configuration: $BUILD_FLAGS"
        
        # Run the build command inside the container
        sudo docker run --rm \
            --security-opt seccomp=unconfined \
            --user $(id -u):$(id -g) \
            -e HOME=/litert_build \
            -e USER=$(whoami) \
            $DISABLE_SVE_ARG \
            -v $(pwd):/litert_build \
            -w /litert_build \
            litert_build \
            bazel build $BUILD_FLAGS $TARGET

        if [ $? -ne 0 ]; then
            echo "ERROR: Build failed for $ABI_NAME"
            return 1
        fi
        
        echo "Build successful for $ABI_NAME"
    done
    
    echo ""
    echo "---"
    echo "All architecture builds completed successfully!"
    echo "---"
    
    # Verify all libraries were generated
    echo "Verifying build artifacts..."
    all_found=true
    for arch_config in "${ARCHITECTURES[@]}"; do
        IFS=':' read -r BUILD_CONFIG ABI_NAME OUTPUT_PATH <<< "$arch_config"
        FOUND=$(find .cache -name "libLiteRt.so" -path "*/${OUTPUT_PATH}/bin/litert/c/*" 2>/dev/null | head -1)
        if [ -n "$FOUND" ]; then
            echo "Found $ABI_NAME: $FOUND"
        else
            echo "Missing $ABI_NAME library"
            all_found=false
        fi
    done

    if [ "$all_found" = true ]; then
        echo "Docker builds successful."
        package_artifacts
        return 0
    else
        echo "Build completed but some libraries not found."
        return 1
    fi
}

# Package artifacts into a zip file suitable for CMake FetchContent
package_artifacts() {
    echo "Packaging artifacts into zip file..."
    
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR/include"
    
    # Find and copy the shared libraries for all architectures
    echo "Copying libraries for all architectures..."
    for arch_config in "${ARCHITECTURES[@]}"; do
        IFS=':' read -r BUILD_CONFIG ABI_NAME OUTPUT_PATH <<< "$arch_config"
        
        mkdir -p "$OUTPUT_DIR/lib/$ABI_NAME"
        
        # Search for the architecture-specific library
        SO_FILE=$(find .cache -name "libLiteRt.so" -path "*/${OUTPUT_PATH}/bin/litert/c/*" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
        
        if [ -n "$SO_FILE" ]; then
            echo "  Copying $ABI_NAME library: $SO_FILE"
            cp "$SO_FILE" "$OUTPUT_DIR/lib/$ABI_NAME/"
        else
            echo "  ERROR: Could not find libLiteRt.so for $ABI_NAME"
            return 1
        fi
    done

    # Download GPU Accelerator from Google Maven
    echo "Downloading GPU Accelerator from Google Maven..."
    LITERT_VERSION="2.1.0rc1"
    AAR_URL="https://dl.google.com/android/maven2/com/google/ai/edge/litert/litert/${LITERT_VERSION}/litert-${LITERT_VERSION}.aar"
    TEMP_AAR_DIR=$(mktemp -d)
    
    if curl -sL "$AAR_URL" -o "$TEMP_AAR_DIR/litert.aar"; then
        cd "$TEMP_AAR_DIR"
        
        # Extract GPU accelerator for all architectures
        for arch_config in "${ARCHITECTURES[@]}"; do
            IFS=':' read -r BUILD_CONFIG ABI_NAME OUTPUT_PATH <<< "$arch_config"
            
            if unzip -q litert.aar "jni/$ABI_NAME/libLiteRtOpenClAccelerator.so" 2>/dev/null; then
                cp "jni/$ABI_NAME/libLiteRtOpenClAccelerator.so" "$OUTPUT_DIR/lib/$ABI_NAME/"
                echo "  Copied GPU Accelerator for $ABI_NAME"
            else
                echo "  WARNING: Could not extract GPU Accelerator for $ABI_NAME from AAR"
            fi
        done
        
        cd - > /dev/null
    else
        echo "WARNING: Could not download LiteRT AAR from Google Maven"
    fi
    rm -rf "$TEMP_AAR_DIR"

    copy_sources() {
        local src_dir="$1"
        local dest_base="$2"
        if [ -d "$src_dir" ]; then
            find "$src_dir" \( -name "*.h" -o -name "*.cc" \) \
                ! -name "*_test.h" \
                ! -name "*_test.cc" \
                ! -name "*_win.cc" \
                ! -name "test_*.cc" \
                | while read src; do
                mkdir -p "$dest_base/$(dirname $src)"
                cp "$src" "$dest_base/$src"
            done
        fi
    }
    
    echo "Copying C++ API sources..."
    copy_sources "litert/cc" "$OUTPUT_DIR/include"

    copy_headers() {
        local src_dir="$1"
        local dest_base="$2"
        if [ -d "$src_dir" ]; then
            find "$src_dir" \( -name "*.h" -o -name "*.cc" \) \
                ! -name "*_test.h" \
                ! -name "*_test.cc" \
                ! -name "*_win.cc" \
                ! -name "test_*.cc" \
                | while read src; do
                mkdir -p "$dest_base/$(dirname $src)"
                cp "$src" "$dest_base/$src"
            done
        fi
    }
    
    # Copy C API headers (excludes test files)
    echo "Copying C API headers..."
    copy_headers "litert/c" "$OUTPUT_DIR/include"
    
    # Copy necessary TFLite headers (only the essential ones for LiteRT API)
    echo "Copying TFLite headers..."
    if [ -f "tflite/builtin_ops.h" ]; then
        mkdir -p "$OUTPUT_DIR/include/tflite"
        cp "tflite/builtin_ops.h" "$OUTPUT_DIR/include/tflite/"
    fi
    
    # Copy only tflite/c and tflite/core/c headers (needed for C API compatibility)
    if [ -d "tflite/c" ]; then
        find tflite/c -maxdepth 1 -name "*.h" | while read header; do
            mkdir -p "$OUTPUT_DIR/include/tflite/c"
            cp "$header" "$OUTPUT_DIR/include/tflite/c/"
        done
    fi
    
    if [ -d "tflite/core/c" ]; then
        find tflite/core/c -maxdepth 1 -name "*.h" | while read header; do
            mkdir -p "$OUTPUT_DIR/include/tflite/core/c"
            cp "$header" "$OUTPUT_DIR/include/tflite/core/c/"
        done
    fi
    
    # Copy tflite/core/api headers
    if [ -d "tflite/core/api" ]; then
        find tflite/core/api -maxdepth 1 -name "*.h" | while read header; do
            mkdir -p "$OUTPUT_DIR/include/tflite/core/api"
            cp "$header" "$OUTPUT_DIR/include/tflite/core/api/"
        done
    fi
    
    # Copy tflite/profiling headers (required by litert/c/litert_profiler_event.h)
    echo "Copying TFLite profiling headers..."
    if [ -d "tflite/profiling" ]; then
        find tflite/profiling -maxdepth 1 -name "*.h" ! -name "*_test.h" | while read header; do
            mkdir -p "$OUTPUT_DIR/include/tflite/profiling"
            cp "$header" "$OUTPUT_DIR/include/tflite/profiling/"
        done
    fi
    
    # Copy OpenCL headers from Bazel cache if available
    echo "Copying OpenCL headers..."
    OPENCL_HEADERS=$(find .cache -type d -name "OpenCL-Headers-*" 2>/dev/null | head -1)
    if [ -n "$OPENCL_HEADERS" ] && [ -d "$OPENCL_HEADERS/CL" ]; then
        mkdir -p "$OUTPUT_DIR/include/CL"
        cp -r "$OPENCL_HEADERS/CL/"* "$OUTPUT_DIR/include/CL/"
        echo "Copied OpenCL headers from: $OPENCL_HEADERS"
    else
        # Try alternative location
        OPENCL_HEADERS=$(find .cache -path "*/external/opencl_headers*/CL" -type d 2>/dev/null | head -1)
        if [ -n "$OPENCL_HEADERS" ]; then
            mkdir -p "$OUTPUT_DIR/include/CL"
            cp -r "$OPENCL_HEADERS/"* "$OUTPUT_DIR/include/CL/"
            echo "Copied OpenCL headers from: $OPENCL_HEADERS"
        else
            echo "WARNING: OpenCL headers not found in Bazel cache."
            echo "         GPU tensor buffer features may require manual OpenCL header installation."
        fi
    fi
    
    echo "Copying generated build_config.h..."
    BUILD_CONFIG_FILE=$(find .cache -name "build_config.h" -path "*/arm64-v8a-opt/bin/litert/build_common/*" ! -path "*/_virtual_includes/*" 2>/dev/null | head -1)
    if [ -n "$BUILD_CONFIG_FILE" ]; then
        mkdir -p "$OUTPUT_DIR/include/litert/build_common"
        cp "$BUILD_CONFIG_FILE" "$OUTPUT_DIR/include/litert/build_common/"
        echo "Copied build_config.h from: $BUILD_CONFIG_FILE"
    else
        echo "WARNING: build_config.h not found. This may cause compilation errors."
    fi
    
    # Remove test files that were accidentally copied
    echo "Cleaning up test files..."
    find "$OUTPUT_DIR/include" -name "*_test.cc" -delete 2>/dev/null || true
    find "$OUTPUT_DIR/include" -name "*_test.mm" -delete 2>/dev/null || true
    
    # Create a CMakeLists.txt
    cat > "$OUTPUT_DIR/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.19)
project(LiteRT)

# --- Dependencies ---
include(FetchContent)

# Fetch FlatBuffers (Required for LiteRT C++ API)
FetchContent_Declare(
    flatbuffers
    GIT_REPOSITORY https://github.com/google/flatbuffers.git
    GIT_TAG v24.3.25
)
set(FLATBUFFERS_BUILD_TESTS OFF)
set(FLATBUFFERS_INSTALL OFF)
FetchContent_MakeAvailable(flatbuffers)

# --- LiteRT C API (Shared Library) ---
add_library(litert_c_api SHARED IMPORTED GLOBAL)
set_target_properties(litert_c_api PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/lib/${ANDROID_ABI}/libLiteRt.so"
    INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

# --- LiteRT GPU Accelerator (OpenCL) ---
# This library is dynamically loaded at runtime by LiteRT when GPU compilation is requested
add_library(litert_gpu_accelerator SHARED IMPORTED GLOBAL)
set_target_properties(litert_gpu_accelerator PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/lib/${ANDROID_ABI}/libLiteRtOpenClAccelerator.so"
)

# --- LiteRT C++ API (Static Wrapper) ---
# Collect all C++ source files
file(GLOB_RECURSE LITERT_CC_SOURCES 
    "${CMAKE_CURRENT_SOURCE_DIR}/include/litert/cc/*.cc"
)

# Create a static library for the C++ wrapper
add_library(litert_cc_api STATIC ${LITERT_CC_SOURCES})

# Include directories
target_include_directories(litert_cc_api PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

# Link against the C API shared library and Abseil
# Note: You must ensure Abseil is available in your main project
target_link_libraries(litert_cc_api PUBLIC
    litert_c_api
    absl::status
    absl::statusor
    absl::strings
    absl::span
    absl::log
    absl::hash
)

# Alias for easy consumption
add_library(LiteRT::litert ALIAS litert_cc_api)
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
    echo ""
    echo "Package contents:"
    echo "  - lib/arm64-v8a/: Libraries for ARM 64-bit"
    echo "  - lib/armeabi-v7a/: Libraries for ARM 32-bit"
    echo "  - lib/x86_64/: Libraries for x86 64-bit"
    echo "  - lib/x86/: Libraries for x86 32-bit"
    echo "    - libLiteRt.so: Main runtime library"
    echo "    - libLiteRtOpenClAccelerator.so: GPU accelerator (OpenCL)"
    echo "  - include/litert/c/: C API headers"
    echo "  - include/litert/cc/: C++ API headers"
    echo "  - include/tflite/: TFLite compatibility headers"
    echo "  - CMakeLists.txt: CMake configuration (uses \${ANDROID_ABI})"
    echo "---"
}


# Execution
if build_with_docker; then
    cd "${INITIAL_DIR}"
    if [ "${update_release}" = "true" ] && [ -f "update_release.sh" ]; then
        echo "Build successful. Executing update_release.sh..."
        ./update_release.sh

        # Clear cpp file cache to force main project rebuild
        rm -rf /mnt/c/Users/fancy/mihon-ocr/data/.cxx
    elif [ "${update_release}" = "true" ]; then
        echo "Build successful, but update_release.sh not found."
    else
        echo "Build successful. Skipping update_release.sh execution."
    fi
    exit 0
else
    echo "Docker build failed."
    exit 1
fi
