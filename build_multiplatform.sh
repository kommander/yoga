#!/bin/bash

# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

set -e

# Build configuration
BUILD_TYPE=${BUILD_TYPE:-Release}
OUTPUT_DIR="build_output"
YOGA_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Platform and architecture combinations
PLATFORMS=(
    "darwin:x86_64"
    "darwin:arm64"
    "linux:x86_64" 
    "linux:aarch64"
    "windows:x86_64"
    "windows:aarch64"
)

# Library types
LIB_TYPES=("STATIC" "SHARED")

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Clean output directory
clean_output() {
    log_info "Cleaning output directory..."
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
}

# Get performance optimization flags
get_performance_flags() {
    local platform="$1"
    local arch="$2"
    
    case "$platform" in
        "darwin"|"linux")
            case "$arch" in
                "x86_64")
                    echo "-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -march=x86-64 -mtune=generic -fomit-frame-pointer -funroll-loops -ffast-math -flto"
                    echo "-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG -march=x86-64 -mtune=generic -fomit-frame-pointer -funroll-loops -ffast-math -flto"
                    ;;
                "arm64"|"aarch64")
                    echo "-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -march=armv8-a -mtune=generic -fomit-frame-pointer -funroll-loops -ffast-math -flto"
                    echo "-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG -march=armv8-a -mtune=generic -fomit-frame-pointer -funroll-loops -ffast-math -flto"
                    ;;
            esac
            ;;
        "windows")
            # MSVC optimization flags
            case "$arch" in
                "x86_64")
                    echo "-DCMAKE_C_FLAGS_RELEASE=/O2 /Ob2 /Oi /Ot /Oy /GL /DNDEBUG"
                    echo "-DCMAKE_CXX_FLAGS_RELEASE=/O2 /Ob2 /Oi /Ot /Oy /GL /DNDEBUG"
                    echo "-DCMAKE_EXE_LINKER_FLAGS_RELEASE=/LTCG /OPT:REF /OPT:ICF"
                    echo "-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=/LTCG /OPT:REF /OPT:ICF"
                    ;;
                "aarch64")
                    echo "-DCMAKE_C_FLAGS_RELEASE=/O2 /Ob2 /Oi /Ot /GL /DNDEBUG"
                    echo "-DCMAKE_CXX_FLAGS_RELEASE=/O2 /Ob2 /Oi /Ot /GL /DNDEBUG"
                    echo "-DCMAKE_EXE_LINKER_FLAGS_RELEASE=/LTCG /OPT:REF /OPT:ICF"
                    echo "-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=/LTCG /OPT:REF /OPT:ICF"
                    ;;
            esac
            ;;
    esac
}

# Get toolchain file for cross-compilation
get_toolchain_args() {
    local platform="$1"
    local arch="$2"
    
    case "$platform:$arch" in
        "darwin:x86_64")
            echo "-DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_SYSTEM_NAME=Darwin"
            ;;
        "darwin:arm64")
            echo "-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_SYSTEM_NAME=Darwin"
            ;;
        "linux:x86_64")
            if [[ "$OSTYPE" != "linux-gnu"* ]]; then
                echo "-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=x86_64"
            fi
            ;;
        "linux:aarch64")
            echo "-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++"
            ;;
        "windows:x86_64")
            echo "-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64"
            ;;
        "windows:aarch64")
            echo "-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=aarch64"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Get generator based on platform and host OS
get_generator() {
    local platform="$1"
    
    if command -v ninja >/dev/null 2>&1; then
        echo "Ninja"
    elif [[ "$platform" == "windows" ]] && [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        echo "\"Visual Studio 17 2022\""
    else
        echo "\"Unix Makefiles\""
    fi
}

# Get library file extension
get_lib_extension() {
    local platform="$1"
    local lib_type="$2"
    
    case "$platform:$lib_type" in
        "darwin:STATIC") echo "a" ;;
        "darwin:SHARED") echo "dylib" ;;
        "linux:STATIC") echo "a" ;;
        "linux:SHARED") echo "so" ;;
        "windows:STATIC") echo "lib" ;;
        "windows:SHARED") echo "dll" ;;
        *) echo "a" ;;
    esac
}

# Modify CMakeLists.txt for library type
modify_cmake_for_lib_type() {
    local lib_type="$1"
    local cmake_file="yoga/CMakeLists.txt"
    
    # Backup original if it doesn't exist
    if [[ ! -f "${cmake_file}.bak" ]]; then
        cp "$cmake_file" "${cmake_file}.bak"
    fi
    
    # Restore from backup and modify
    cp "${cmake_file}.bak" "$cmake_file"
    sed -i.tmp "s/add_library(yogacore STATIC/add_library(yogacore $lib_type/" "$cmake_file"
    rm -f "${cmake_file}.tmp"
}

# Restore original CMakeLists.txt
restore_cmake() {
    local cmake_file="yoga/CMakeLists.txt"
    if [[ -f "${cmake_file}.bak" ]]; then
        mv "${cmake_file}.bak" "$cmake_file"
    fi
}

# Build for specific platform, architecture, and library type
build_platform() {
    local platform="$1"
    local arch="$2"
    local lib_type="$3"
    
    local build_dir="build_${platform}_${arch}_${lib_type}"
    local lib_type_lower=$(echo "$lib_type" | tr '[:upper:]' '[:lower:]')
    local output_subdir="${OUTPUT_DIR}/${platform}/${arch}/${lib_type_lower}"
    local toolchain_args
    local performance_flags
    local generator
    local lib_ext
    
    toolchain_args=$(get_toolchain_args "$platform" "$arch")
    performance_flags=$(get_performance_flags "$platform" "$arch")
    generator=$(get_generator "$platform")
    lib_ext=$(get_lib_extension "$platform" "$lib_type")
    
    log_info "Building ${lib_type_lower} library for ${platform}/${arch}..."
    
    # Skip if cross-compilation tools are not available
    if [[ "$platform:$arch" == "linux:aarch64" ]] && ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        log_warning "Cross-compilation tools for linux/aarch64 not found, skipping..."
        return 0
    fi
    
    # Skip Windows builds on non-Windows unless using cross-compilation
    if [[ "$platform" == "windows" ]] && [[ "$OSTYPE" != "msys" && "$OSTYPE" != "cygwin" ]]; then
        log_warning "Windows builds require Windows host or cross-compilation setup, skipping..."
        return 0
    fi
    
    # Modify CMakeLists.txt for library type
    modify_cmake_for_lib_type "$lib_type"
    
    # Configure
    log_info "Configuring build for ${platform}/${arch}/${lib_type_lower} with performance optimizations..."
    eval cmake -S . -B "$build_dir" \
        -G "$generator" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        $toolchain_args \
        $performance_flags \
        -DCMAKE_INSTALL_PREFIX="$output_subdir"
    
    # Build
    log_info "Building ${platform}/${arch}/${lib_type_lower}..."
    cmake --build "$build_dir" --config "$BUILD_TYPE" -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    
    # Install/Copy outputs
    mkdir -p "$output_subdir"
    
    case "$lib_type" in
        "STATIC")
            find "$build_dir" -name "libyogacore.${lib_ext}" -o -name "yogacore.${lib_ext}" | head -1 | xargs -I {} cp {} "$output_subdir/"
            ;;
        "SHARED")
            find "$build_dir" -name "libyogacore.${lib_ext}" -o -name "yogacore.${lib_ext}" | head -1 | xargs -I {} cp {} "$output_subdir/"
            # Copy import library for Windows
            if [[ "$platform" == "windows" ]]; then
                find "$build_dir" -name "yogacore.lib" | head -1 | xargs -I {} cp {} "$output_subdir/" 2>/dev/null || true
            fi
            ;;
    esac
    
    # Copy headers
    cp -r yoga/*.h "$output_subdir/" 2>/dev/null || true
    mkdir -p "$output_subdir/yoga"
    find yoga -name "*.h" -exec cp {} "$output_subdir/yoga/" \; 2>/dev/null || true
    
    # Clean build directory
    rm -rf "$build_dir"
    
    log_success "Completed ${lib_type_lower} library for ${platform}/${arch}"
}

# Main build function
main() {
    log_info "Starting multi-platform Yoga build..."
    log_info "Build type: $BUILD_TYPE"
    log_info "Output directory: $OUTPUT_DIR"
    
    # Check dependencies
    if ! command -v cmake >/dev/null 2>&1; then
        log_error "CMake is required but not installed"
        exit 1
    fi
    
    # Clean output
    clean_output
    
    # Build for all platforms, architectures, and library types
    local total_builds=0
    local successful_builds=0
    
    for platform_arch in "${PLATFORMS[@]}"; do
        IFS=':' read -r platform arch <<< "$platform_arch"
        
        # Skip builds not supported on current host
        if [[ "$OSTYPE" == "linux-gnu"* ]] && [[ "$platform" == "darwin" ]]; then
            log_warning "Cannot build Darwin targets on Linux host, skipping ${platform}/${arch}"
            continue
        fi
        
        for lib_type in "${LIB_TYPES[@]}"; do
            ((total_builds++))
            if build_platform "$platform" "$arch" "$lib_type"; then
                ((successful_builds++))
            fi
        done
    done
    
    # Restore original CMakeLists.txt
    restore_cmake
    
    # Print summary
    log_info "Build Summary:"
    log_info "Total builds attempted: $total_builds"
    log_success "Successful builds: $successful_builds"
    
    if [[ $successful_builds -lt $total_builds ]]; then
        log_warning "Some builds failed or were skipped"
    fi
    
    # List outputs
    log_info "Output structure:"
    find "$OUTPUT_DIR" -type f -name "*.a" -o -name "*.so" -o -name "*.dylib" -o -name "*.dll" -o -name "*.lib" | sort
    
    log_success "Multi-platform build completed!"
}

# Handle script arguments
case "${1:-}" in
    "clean")
        clean_output
        restore_cmake
        log_success "Cleaned build artifacts"
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [clean|help]"
        echo ""
        echo "Environment variables:"
        echo "  BUILD_TYPE    Build type (Debug|Release) [default: Release]"
        echo ""
        echo "Commands:"
        echo "  clean         Clean all build artifacts"
        echo "  help          Show this help message"
        echo ""
        echo "This script builds static and dynamic Yoga libraries for:"
        echo "  - Darwin (macOS): x86_64, arm64"
        echo "  - Linux: x86_64, aarch64"
        echo "  - Windows: x86_64, aarch64"
        ;;
    "")
        main
        ;;
    *)
        log_error "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac