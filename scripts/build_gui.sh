#!/bin/sh
# Build the CatalinaPerformance local GUI without changing system settings.

set -u

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P) || exit 1
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P) || exit 1
PACKAGE_DIR="$REPO_ROOT/app/CatalinaPerformance"

error() {
    printf 'Error: %s\n' "$1" >&2
}

if ! command -v xcode-select >/dev/null 2>&1; then
    error "xcode-select was not found. Install Xcode 12.4 or the Xcode command line tools for macOS Catalina."
    exit 1
fi

XCODE_PATH=$(xcode-select -p 2>/dev/null) || {
    error "No Xcode developer directory is selected. Install Xcode 12.4, then run 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'."
    exit 1
}

if [ ! -d "$XCODE_PATH" ]; then
    error "The selected developer directory does not exist: $XCODE_PATH"
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    error "xcrun was not found. The selected Xcode developer tools appear incomplete: $XCODE_PATH"
    exit 1
fi

if ! xcrun -f xctest >/dev/null 2>&1; then
    error "xcrun cannot find xctest. The selected Xcode install may be incomplete or the command line tools may be selected instead of full Xcode."
    error "Selected developer directory: $XCODE_PATH"
    error "On Catalina, install/open Xcode 12.4 and select it with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    error "swift was not found in PATH. Install Xcode 12.4 or ensure Xcode's toolchain is selected."
    exit 1
fi

if [ ! -d "$PACKAGE_DIR" ]; then
    error "Swift package directory was not found: $PACKAGE_DIR"
    exit 1
fi

printf 'Using developer directory: %s\n' "$XCODE_PATH"
printf 'Building CatalinaPerformance GUI package: %s\n' "$PACKAGE_DIR"
cd "$PACKAGE_DIR" || exit 1
swift build
