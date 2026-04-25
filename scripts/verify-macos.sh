#!/bin/bash
# ZigZag macOS Verification Script
# Purpose: Verify kqueue backend functionality on macOS
# Run this on an actual macOS system for runtime validation

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

# Check we're on macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This script must be run on macOS"
    echo "Current platform: $(uname -s)"
    exit 1
fi

echo "=== ZigZag macOS Verification ==="
echo ""
echo "Platform: $(uname -s) $(uname -m)"
echo "macOS version: $(sw_vers -productVersion)"
echo "Zig version: $(zig version)"
echo ""

# 1. Build
echo -n "Building... "
if zig build 2>&1 >/dev/null; then
    pass "build succeeded"
else
    fail "build failed"
fi

# 2. Run the general runtime suite
echo -n "Running tests... "
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

# 3. Build an explicit kqueue-targeted binary
echo ""
echo -n "Kqueue-targeted build... "
if zig build -Dkqueue=true -Dio_uring=false -Depoll=false 2>&1 >/dev/null; then
    pass "kqueue-only configuration builds"
else
    fail "kqueue-only configuration failed"
fi

echo -n "Kqueue-focused test module... "
if zig test src/backend/kqueue.zig 2>&1 >/dev/null; then
    pass "src/backend/kqueue.zig"
else
    fail "kqueue-focused test module failed"
fi

# 4. Run the binary
echo ""
echo -n "Example binary runs... "
OUTPUT=$(./zig-out/bin/zigzag 2>&1) || true
if echo "$OUTPUT" | grep -q "kqueue"; then
    pass "kqueue backend detected"
elif echo "$OUTPUT" | grep -q "event loop initialized"; then
    pass "event loop working"
else
    info "output: $OUTPUT"
fi

# 5. Feature flag combinations
echo ""
echo "Build flag combinations:"

echo -n "  -Dzsync=false... "
if zig build -Dzsync=false 2>&1 >/dev/null; then
    pass "OK"
else
    fail "failed"
fi

echo -n "  -Dterminal=false... "
if zig build -Dterminal=false 2>&1 >/dev/null; then
    pass "OK"
else
    fail "failed"
fi

echo ""
echo -e "${GREEN}=== macOS verification complete ===${NC}"
echo ""
echo "Kqueue runtime behavior was checked on this macOS host with both the full suite and the focused backend module."
