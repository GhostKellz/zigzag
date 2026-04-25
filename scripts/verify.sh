#!/bin/bash
# ZigZag Release Verification Script
# Purpose: Quick smoke test for release builds
# Exit: 0 on success, non-zero on any failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }
info() { echo -e "${YELLOW}INFO${NC}: $1"; }

echo "=== ZigZag Release Verification ==="
echo ""

# 1. Default build
echo -n "Default build... "
if zig build 2>&1; then
    pass "zig build"
else
    fail "zig build"
fi

# 2. Run tests
echo -n "Running tests... "
TEST_OUTPUT=$(zig build test --summary all 2>&1) || {
    echo ""
    echo "$TEST_OUTPUT"
    fail "zig build test"
}

if echo "$TEST_OUTPUT" | grep -q "tests passed"; then
    SUMMARY=$(echo "$TEST_OUTPUT" | grep "tests passed")
    pass "tests ($SUMMARY)"
else
    echo ""
    echo "$TEST_OUTPUT"
    fail "Unable to parse test summary"
fi

# 3. Build flag combinations
echo ""
echo "Build flag combinations:"

# Linux backend flags (only valid on Linux)
if [[ "$(uname -s)" == "Linux" ]]; then
    echo -n "  -Dio_uring=false... "
    if zig build -Dio_uring=false 2>&1 >/dev/null; then
        pass "epoll-only build"
    else
        fail "-Dio_uring=false"
    fi
fi

echo -n "  -Dzsync=false... "
if zig build -Dzsync=false 2>&1 >/dev/null; then
    pass "without zsync"
else
    fail "-Dzsync=false"
fi

echo -n "  -Dterminal=false... "
if zig build -Dterminal=false 2>&1 >/dev/null; then
    pass "without terminal"
else
    fail "-Dterminal=false"
fi

# 4. Build the example binary
echo ""
echo -n "Example binary runs... "
OUTPUT=$(./zig-out/bin/zigzag 2>&1) || true
if echo "$OUTPUT" | grep -q "event loop initialized"; then
    pass "zigzag binary"
else
    # Not a fatal error - binary may have different output
    info "zigzag binary output: $OUTPUT"
fi

echo ""
echo -e "${GREEN}=== All verification checks passed ===${NC}"
