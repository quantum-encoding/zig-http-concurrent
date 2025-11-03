#!/bin/bash

# CLI Smoke Tests
# Tests basic CLI functionality without requiring API keys

set -e  # Exit on error

echo "🧪 Running CLI Smoke Tests..."
echo ""

# Test 1: Help flag
echo "Test 1: --help flag"
if zig build cli -- --help 2>&1 | grep -q "USAGE:"; then
    echo "✅ PASS: --help displays usage information"
else
    echo "❌ FAIL: --help did not display expected output"
    exit 1
fi
echo ""

# Test 2: List providers
echo "Test 2: --list flag"
if zig build cli -- --list 2>&1 | grep -q "Available AI Providers"; then
    echo "✅ PASS: --list displays providers"
else
    echo "❌ FAIL: --list did not display expected output"
    exit 1
fi
echo ""

# Test 3: Verify all 5 providers are listed
echo "Test 3: All providers present"
output=$(zig build cli -- --list 2>&1)
providers=("claude" "deepseek" "gemini" "grok" "vertex")
all_present=true

for provider in "${providers[@]}"; do
    if echo "$output" | grep -q "$provider"; then
        echo "  ✅ $provider found"
    else
        echo "  ❌ $provider missing"
        all_present=false
    fi
done

if [ "$all_present" = true ]; then
    echo "✅ PASS: All 5 providers listed"
else
    echo "❌ FAIL: Some providers missing"
    exit 1
fi
echo ""

# Test 4: Short flags
echo "Test 4: Short flags (-h, -l)"
if zig build cli -- -h 2>&1 | grep -q "USAGE:"; then
    echo "✅ PASS: -h flag works"
else
    echo "❌ FAIL: -h flag failed"
    exit 1
fi

if zig build cli -- -l 2>&1 | grep -q "Available AI Providers"; then
    echo "✅ PASS: -l flag works"
else
    echo "❌ FAIL: -l flag failed"
    exit 1
fi
echo ""

# Test 5: Missing prompt error
echo "Test 5: Missing prompt detection"
if timeout 5 bash -c "zig build cli -- 2>&1" | grep -q "No prompt provided"; then
    echo "✅ PASS: Missing prompt error displayed"
else
    echo "❌ FAIL: Expected missing prompt error"
    exit 1
fi
echo ""

# Test 6: Compilation check
echo "Test 6: Project compiles without errors"
if zig build -Doptimize=ReleaseSafe >/dev/null 2>&1; then
    echo "✅ PASS: Project builds successfully"
else
    echo "❌ FAIL: Build failed"
    exit 1
fi
echo ""

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  🎉 All smoke tests passed!                             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Note: These tests verify basic CLI functionality."
echo "Integration tests with actual API calls require valid API keys."
