#!/bin/bash
# Manual test of ccstreamer to verify current functionality
set -e

echo "Testing ccstreamer functionality..."

# Test 1: Basic JSON formatting
echo "Test 1: Basic JSON"
echo '{"type": "test", "value": 42}' | ./zig-out/bin/ccstreamer

echo -e "\nTest 2: NO_COLOR environment variable"
NO_COLOR=1 echo '{"name": "example"}' | ./zig-out/bin/ccstreamer

echo -e "\nTest 3: Multiple JSON objects"
echo -e '{"first": true}\n{"second": false}' | ./zig-out/bin/ccstreamer

echo -e "\nTest 4: Malformed JSON (should produce error)"
echo '{"malformed":' | ./zig-out/bin/ccstreamer 2>&1 || echo "Error handled correctly"

echo -e "\nAll manual tests completed."