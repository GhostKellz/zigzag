#!/bin/bash
# ZigZag Cross-Compilation Verification
# Purpose: Verify the codebase compiles for all supported targets
# Note: This does NOT verify runtime behavior, only compilation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; }
warn() { echo -e "${YELLOW}WARN${NC}: $1"; }

FAILED=0
PASSED=0

cross_build() {
    local target="$1"
    local name="$2"
    echo -n "  $target ($name)... "

    # Capture both stdout and stderr
    local output
    if output=$(zig build -Dtarget="$target" 2>&1); then
        pass "compiles"
        PASSED=$((PASSED + 1))
    else
        fail "failed"
        echo "    Error: $output" | head -5
        FAILED=$((FAILED + 1))
    fi
}

echo "=== ZigZag Cross-Compilation Verification ==="
echo ""
echo "Host platform: $(uname -s) $(uname -m)"
echo "Zig version: $(zig version)"
echo ""
echo "Cross-compile targets:"
echo ""

# Linux targets (should always work)
echo "Linux:"
cross_build "x86_64-linux-gnu" "x86_64"
cross_build "aarch64-linux-gnu" "ARM64"

# macOS targets
echo ""
echo "macOS:"
cross_build "x86_64-macos" "Intel"
cross_build "aarch64-macos" "Apple Silicon"

# Windows targets
echo ""
echo "Windows:"
cross_build "x86_64-windows-gnu" "x86_64 GNU"

# BSD targets
echo ""
echo "BSD:"
cross_build "x86_64-freebsd" "FreeBSD x86_64"
cross_build "x86_64-netbsd" "NetBSD x86_64"

echo ""
echo "=== Results ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [[ $FAILED -gt 0 ]]; then
    echo ""
    echo -e "${RED}Some cross-compilation targets failed${NC}"
    echo ""
    echo "Note: Cross-compilation verifies the code compiles for each target."
    echo "It does NOT verify runtime behavior on those platforms."
    echo "Runtime testing requires actual hardware or emulation."
    exit 1
else
    echo ""
    echo -e "${GREEN}All cross-compilation targets succeeded${NC}"
fi
