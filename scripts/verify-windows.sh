#!/bin/bash
# ZigZag Windows Verification Script
#
# This script is a convenience wrapper that:
# - On Linux/macOS: Cross-compiles for Windows (no runtime tests)
# - On Windows under MSYS/Cygwin/MinGW: Runs the native runtime verification steps
#
# For native PowerShell or cmd.exe usage on Windows, run `scripts/verify-windows.ps1`.
#
# This script reports exactly what is and is not verified.
# Cross-compilation validates Windows-targeted builds only.
# Runtime behavior still requires running on a real Windows host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }
info() { echo -e "${YELLOW}INFO${NC}: $1"; }

echo "=== ZigZag Windows Verification ==="
echo ""

# Detect if we're on Windows or cross-compiling
if [[ "$(uname -s)" == *"MINGW"* ]] || [[ "$(uname -s)" == *"MSYS"* ]] || [[ "$(uname -s)" == *"CYGWIN"* ]]; then
    info "Running on Windows (MSYS/Cygwin/MinGW)"
    NATIVE=true
elif [[ "$(uname -s)" == "Linux" ]]; then
    info "Running on Linux - will cross-compile for Windows"
    NATIVE=false
else
    info "Platform: $(uname -s)"
    NATIVE=false
fi

echo "Zig version: $(zig version)"
echo ""

# 1. Build for Windows target
echo -n "Building for Windows... "
if zig build -Dtarget=x86_64-windows-gnu 2>&1 >/dev/null; then
    pass "cross-compilation succeeded"
else
    fail "cross-compilation failed"
fi

# 2. If native Windows, run targeted Windows builds and runtime checks
if [[ "$NATIVE" == "true" ]]; then
    echo ""
    echo -n "Windows-targeted build... "
    if zig build -Dtarget=x86_64-windows-gnu -Diocp=true -Depoll=false -Dio_uring=false -Dkqueue=false 2>&1 >/dev/null; then
        pass "Windows IOCP configuration builds"
    else
        fail "Windows-targeted IOCP build failed"
    fi

    echo -n "Running runtime suite... "
    TEST_OUTPUT=$(zig build test --summary all 2>&1) || {
        echo ""
        echo "$TEST_OUTPUT"
        fail "tests failed"
    }

    if echo "$TEST_OUTPUT" | grep -q "tests passed"; then
        SUMMARY=$(echo "$TEST_OUTPUT" | grep "tests passed")
        pass "tests ($SUMMARY)"
    else
        fail "unable to parse test summary"
    fi

    echo -n "IOCP-focused smoke tests... "
    if zig build test-windows-iocp --summary all 2>&1 >/dev/null; then
        pass "test-windows-iocp"
    else
        fail "IOCP-focused test module failed"
    fi

    echo -n "File-watching smoke tests... "
    if zig build test-windows-filewatch --summary all 2>&1 >/dev/null; then
        pass "test-windows-filewatch"
    else
        fail "file-watching test module failed"
    fi

    echo -n "Windows stress smoke tests... "
    if zig build test-windows-stress --summary all 2>&1 >/dev/null; then
        pass "test-windows-stress"
    else
        fail "Windows stress test module failed"
    fi
else
    echo ""
    info "Cross-compilation only - cannot run tests on this platform"
    info "Run 'zig build test' on Windows for runtime verification"
fi

# 3. Report current Windows support scope
echo ""
echo "Current Windows support scope:"
echo "  - IOCP timers (CreateTimerQueueTimer)"
echo "  - Wake/user events (PostQueuedCompletionStatus)"
echo "  - WinSock socket I/O (WSARecv/WSASend)"
echo "  - Native file watching via ReadDirectoryChangesW (FileWatcher)"
echo "  - Generic addFd(): NOT supported on Windows"

echo ""
echo -e "${GREEN}=== Verification complete ===${NC}"
echo ""
if [[ "$NATIVE" == "true" ]]; then
    echo "Runtime-verified on Windows, including the IOCP-focused backend test module."
else
    echo "Cross-compilation verified only. Real Windows runtime testing is still required."
fi
