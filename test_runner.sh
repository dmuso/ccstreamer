#!/bin/bash

# Simple test runner to validate current implementation
echo "=== CC Streamer Test Runner ==="
echo "Testing current implementation status..."

# Set up environment
cd /Users/dharper/Documents/code/cc-streamer
export PATH="/nix/store/nh9rks0mj5jci6kigly8ljjqazyxzwvv-zig-0.14.1/bin:$PATH"

echo "1. Building project..."
if zig build; then
    echo "✅ Build successful"
else
    echo "❌ Build failed"
    exit 1
fi

echo ""
echo "2. Running unit tests..."
if zig build test 2>&1; then
    echo "✅ Unit tests passed"
else
    echo "❌ Unit tests failed"
fi

echo ""
echo "3. Testing basic functionality..."
echo '{"test": "value"}' | ./zig-out/bin/ccstreamer > test_output.txt 2>&1
if [ $? -eq 0 ]; then
    echo "✅ Basic execution successful"
    echo "Output:"
    cat test_output.txt
else
    echo "❌ Basic execution failed"
    cat test_output.txt
fi

echo ""
echo "=== Test complete ==="