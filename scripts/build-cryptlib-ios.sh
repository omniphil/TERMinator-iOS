#!/bin/bash
# Build Synchronet-patched cryptlib for iOS
# Based on Synchronet 3rdp/build/GNUmakefile

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERMINATOR_ANDROID="/Users/jsonbourne/Dropbox/Coding/TERMinator"
PATCHES_DIR="$TERMINATOR_ANDROID/3rdp/build"
CRYPTLIB_ZIP="$TERMINATOR_ANDROID/3rdp/dist/cryptlib.zip"

BUILD_DIR="/private/tmp/cryptlib-ios-build"
OUTPUT_DIR="$PROJECT_ROOT/TERMinator/Bridge/cryptlib"

# iOS SDK settings
IOS_MIN_VERSION="16.0"

echo "=== Building Synchronet-patched cryptlib for iOS ==="
echo "Build directory: $BUILD_DIR"
echo "Output directory: $OUTPUT_DIR"

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Extract cryptlib
echo ""
echo "=== Extracting cryptlib ==="
unzip -q "$CRYPTLIB_ZIP"

# Convert CRLF to LF (required for Unix builds)
echo "=== Converting line endings ==="
find . -type f \( -name "*.c" -o -name "*.h" -o -name "*.sh" -o -name "makefile" -o -name "Makefile" \) | while read f; do
    tr -d '\r' < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done 2>/dev/null || true

# Apply patches in the correct order (from GNUmakefile)
echo ""
echo "=== Applying Synchronet patches ==="

PATCHES=(
    "cl-terminal-params.patch"
    "cl-ranlib.patch"
    "cl-endian.patch"
    "cl-zz-country.patch"
    "cl-algorithms.patch"
    "cl-allow-duplicate-ext.patch"
    "cl-macosx-minver.patch"
    "cl-posix-me-gently.patch"
    "cl-PAM-noprompts.patch"
    "cl-zlib.patch"
    "cl-Dynamic-linked-static-lib.patch"
    "cl-SSL-fix.patch"
    "cl-bigger-maxattribute.patch"
    "cl-no-odbc.patch"
    "cl-noasm-defines.patch"
    "cl-bn-noasm64-fix.patch"
    "cl-prefer-ECC.patch"
    "cl-prefer-ECC-harder.patch"
    "cl-clear-GCM-flag.patch"
    "cl-use-ssh-ctr.patch"
    "cl-ssh-list-ctr-modes.patch"
    "cl-no-tpm.patch"
    "cl-no-via-aes.patch"
    "cl-just-use-cc.patch"
    "cl-no-safe-stack.patch"
    "cl-allow-pkcs12.patch"
    "cl-allow-none-auth.patch"
    "cl-poll-not-select.patch"
    "cl-good-sockets.patch"
    "cl-moar-objects.patch"
    "cl-remove-march.patch"
    "cl-server-term-support.patch"
    "cl-add-pubkey-attribute.patch"
    "cl-allow-ssh-auth-retries.patch"
    "cl-fix-ssh-channel-close.patch"
    "cl-vt-lt-2005-always-defined.patch"
    "cl-no-pie.patch"
    "cl-no-testobjs.patch"
    "cl-thats-not-asm.patch"
    "cl-make-channels-work.patch"
    "cl-allow-ssh-2.0-go.patch"
    "cl-read-timeout-every-time.patch"
    "cl-pass-after-pubkey.patch"
    "cl-allow-servercheck-pubkeys.patch"
    "cl-double-delete-fine-on-close.patch"
    "cl-handle-unsupported-pubkey.patch"
    "cl-add-patches-info.patch"
    "cl-fix-shell-exec-types.patch"
    "cl-ssh-eof-half-close.patch"
    "cl-ssh-service-type-for-channel.patch"
    "cl-ssh-sbbs-id-string.patch"
    "cl-channel-select-both.patch"
    "cl-allow-none-auth-svr.patch"
    "cl-quote-cc.patch"
    "cl-dont-validate-va-list.patch"
    "cl-fix-constptrptr.patch"
    "cl-fix-void-ptrs.patch"
    "cl-intptr-t.patch"
    "cl-wrong-string-length.patch"
    "cl-remove-silly-pragmas.patch"
    "cl-size-doesnt-mean-copied.patch"
    "cl-add-psk-flag.patch"
    "cl-no-stdc-flexarray.patch"
    "cl-enable-chacha20.patch"
    "cl-no-session-cache.patch"
)

for patch in "${PATCHES[@]}"; do
    if [ -f "$PATCHES_DIR/$patch" ]; then
        echo "  Applying: $patch"
        patch -p0 --silent < "$PATCHES_DIR/$patch" 2>/dev/null || echo "    (skipped - may be incompatible)"
    fi
done

# Modify ccopts.sh for iOS minimum version
sed -i.bak "s/%%MIN_MAC_OSX_VERSION%%/$IOS_MIN_VERSION/g" tools/ccopts.sh 2>/dev/null || true

# Create output directories
mkdir -p "$OUTPUT_DIR/include"
mkdir -p "$OUTPUT_DIR/ios-arm64"
mkdir -p "$OUTPUT_DIR/ios-simulator-arm64"

# Copy header
cp cryptlib.h "$OUTPUT_DIR/include/"

# Build function for a specific architecture
build_for_arch() {
    local ARCH=$1
    local SDK=$2
    local OUTPUT_SUBDIR=$3

    echo ""
    echo "=== Building for $ARCH ($SDK) ==="

    # Clean previous build
    make clean 2>/dev/null || true
    rm -f libcl.a static-obj/*.o 2>/dev/null || true

    # Get SDK path and tools
    local SDK_PATH=$(xcrun --sdk $SDK --show-sdk-path)
    local CC=$(xcrun --sdk $SDK --find clang)
    local AR=$(xcrun --sdk $SDK --find ar)
    local RANLIB=$(xcrun --sdk $SDK --find ranlib)

    # Determine the right target and minimum version flag
    local TARGET_FLAG
    local MIN_VERSION_FLAG
    if [ "$SDK" = "iphoneos" ]; then
        TARGET_FLAG="-target arm64-apple-ios${IOS_MIN_VERSION}"
        MIN_VERSION_FLAG="-miphoneos-version-min=$IOS_MIN_VERSION"
    else
        TARGET_FLAG="-target arm64-apple-ios${IOS_MIN_VERSION}-simulator"
        MIN_VERSION_FLAG="-mios-simulator-version-min=$IOS_MIN_VERSION"
    fi

    # Create a wrapper compiler script that includes all necessary flags
    # and filters out conflicting macOS flags
    cat > /tmp/ios-cc.sh << 'WRAPPER_EOF'
#!/bin/bash
CC_REAL="REPLACE_CC"
SDK_PATH="REPLACE_SDK"
TARGET_FLAG="REPLACE_TARGET"

# Filter out macOS-specific flags that conflict with iOS build
ARGS=()
for arg in "$@"; do
    case "$arg" in
        -mmacosx-version-min=*) ;;  # Skip macOS min version
        -fstack-clash-protection) ;;  # Not available on iOS
        *) ARGS+=("$arg") ;;
    esac
done

exec $CC_REAL $TARGET_FLAG -isysroot $SDK_PATH "${ARGS[@]}"
WRAPPER_EOF
    sed -i '' "s|REPLACE_CC|$CC|g" /tmp/ios-cc.sh
    sed -i '' "s|REPLACE_SDK|$SDK_PATH|g" /tmp/ios-cc.sh
    sed -i '' "s|REPLACE_TARGET|$TARGET_FLAG|g" /tmp/ios-cc.sh
    chmod +x /tmp/ios-cc.sh

    # Export environment for cryptlib build
    export CC="/tmp/ios-cc.sh"
    export AR="$AR"
    export RANLIB="$RANLIB"
    export CFLAGS="-DNDEBUG -D__UNIX__ -DDATA_LITTLEENDIAN -DNO_ODBC -DNO_PKCS11 -DNO_SYSV_SHAREDMEM -DOSVERSION=5 -DNO_ASM -Wno-error -Wno-implicit-function-declaration -Wno-deprecated-declarations"

    echo "  SDK_PATH=$SDK_PATH"
    echo "  CC=$CC"
    echo "  CFLAGS=$CFLAGS"

    # Build using cryptlib's makefile
    # The makefile auto-detects Darwin and builds appropriately
    make -j4 2>&1 | tail -30

    # Copy output
    if [ -f libcl.a ]; then
        cp libcl.a "$OUTPUT_DIR/$OUTPUT_SUBDIR/"
        echo "  Built: $OUTPUT_DIR/$OUTPUT_SUBDIR/libcl.a"
        ls -la "$OUTPUT_DIR/$OUTPUT_SUBDIR/libcl.a"
    else
        echo "  ERROR: libcl.a not found!"
        return 1
    fi
}

# Build for iOS device (arm64)
build_for_arch "arm64" "iphoneos" "ios-arm64"

# Build for iOS Simulator (arm64 - for Apple Silicon Macs)
build_for_arch "arm64" "iphonesimulator" "ios-simulator-arm64"

echo ""
echo "=== Build complete ==="
echo "Headers: $OUTPUT_DIR/include/"
echo "iOS Device: $OUTPUT_DIR/ios-arm64/libcl.a"
echo "iOS Simulator: $OUTPUT_DIR/ios-simulator-arm64/libcl.a"
