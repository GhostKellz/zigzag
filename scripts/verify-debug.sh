#!/bin/bash
# ZigZag Debug Verification Script
# Purpose: Detailed local diagnosis with verbose output
# Use this when verify.sh fails or for deep debugging

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

section() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }
pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; }
info() { echo -e "${YELLOW}INFO${NC}: $1"; }

echo "=== ZigZag Debug Verification ==="
echo "Date: $(date)"
echo "Platform: $(uname -s) $(uname -m)"
echo "Zig version: $(zig version)"
echo ""

# ============================================
section "Environment"
# ============================================
echo "Working directory: $(pwd)"
echo "Zig cache: $(du -sh .zig-cache 2>/dev/null || echo 'not present')"

# ============================================
section "Default Build (verbose)"
# ============================================
info "Running: zig build"
if zig build; then
    pass "Default build succeeded"
    ls -la zig-out/bin/ 2>/dev/null || echo "No binaries produced"
else
    fail "Default build failed"
    exit 1
fi

# ============================================
section "Test Suite (verbose)"
# ============================================
info "Running: zig build test --summary all"
echo ""
# Run tests with full output visible
if zig build test --summary all; then
    pass "All tests passed"
else
    fail "Tests failed"
    exit 1
fi

# ============================================
section "Backend Detection"
# ============================================
if [[ "$(uname -s)" == "Linux" ]]; then
    info "Linux detected - checking backend support"

    # Check io_uring support
    if [[ -f /proc/sys/kernel/osrelease ]]; then
        KERNEL=$(cat /proc/sys/kernel/osrelease)
        echo "Kernel version: $KERNEL"
    fi

    # Try to detect io_uring support
    if grep -q "io_uring" /proc/kallsyms 2>/dev/null; then
        info "io_uring: available in kernel"
    else
        info "io_uring: may not be available"
    fi

    echo ""
    echo "Testing backend-specific builds:"

    echo -n "  io_uring disabled (epoll-only): "
    if zig build -Dio_uring=false 2>&1; then
        pass "OK"
    else
        fail "FAILED"
    fi

elif [[ "$(uname -s)" == "Darwin" ]]; then
    info "macOS detected - kqueue backend"
    echo "macOS version: $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
fi

# ============================================
section "Feature Flag Combinations"
# ============================================

test_flag() {
    local flag="$1"
    local desc="$2"
    echo -n "  $flag ($desc): "
    if zig build "$flag" 2>&1 >/dev/null; then
        pass "OK"
    else
        fail "FAILED"
    fi
}

test_flag "-Dzsync=false" "without zsync integration"
test_flag "-Dterminal=false" "without terminal features"
test_flag "-Doptimize=ReleaseSafe" "release-safe build"

# ============================================
section "Binary Execution Test"
# ============================================
if [[ -f ./zig-out/bin/zigzag ]]; then
    info "Running zigzag binary..."
    ./zig-out/bin/zigzag 2>&1 || true
else
    info "No binary found at ./zig-out/bin/zigzag"
fi

# ============================================
section "Memory Leak Check (if available)"
# ============================================
if command -v valgrind &>/dev/null; then
    info "Valgrind available - running memory check..."
    if [[ -f ./zig-out/bin/zigzag ]]; then
        valgrind --leak-check=summary --error-exitcode=1 ./zig-out/bin/zigzag 2>&1 || {
            fail "Valgrind detected issues"
        }
    fi
else
    info "Valgrind not installed - skipping memory check"
fi

# ============================================
section "Summary"
# ============================================
echo -e "${GREEN}Debug verification complete${NC}"
echo ""
echo "Next steps if issues found:"
echo "  1. Check specific test: zig build test -Dtest-filter=\"test name\""
echo "  2. Run single test file: zig test src/file.zig"
echo "  3. Check build output: zig build --verbose"
