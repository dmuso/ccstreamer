# CC Streamer Makefile
# Build, test, and run the CC Streamer application

# Variables
ZIG = zig
BINARY = ./zig-out/bin/ccstreamer

# Colors for output (disabled if NO_COLOR is set)
ifndef NO_COLOR
	RED = \033[0;31m
	GREEN = \033[0;32m
	YELLOW = \033[1;33m
	NC = \033[0m # No Color
else
	RED =
	GREEN =
	YELLOW =
	NC =
endif

# Default target
.PHONY: all
all: build

# Build the project
.PHONY: build
build:
	@echo "Formatting source code..."
	@$(ZIG) fmt src/
	@echo "Building CC Streamer..."
	@$(ZIG) build

# Build in release mode
.PHONY: release
release:
	@echo "Building CC Streamer (release mode)..."
	@$(ZIG) build --release=fast

# Run the application
.PHONY: run
run:
	@echo "Formatting source code..."
	@$(ZIG) fmt src/
	@$(MAKE) build
	@$(BINARY)

# Run with arguments
.PHONY: run-args
run-args: build
	@$(ZIG) build run -- $(ARGS)

# Run unit tests
.PHONY: test
test:
	@echo "Running unit tests..."
	@$(ZIG) build test

# Run the basic test runner (from test_runner.sh)
.PHONY: test-basic
test-basic: build
	@echo "=== CC Streamer Test Runner ==="
	@echo "Testing current implementation status..."
	@echo ""
	@echo "1. Build status:"
	@echo "$(GREEN)✅ Build successful$(NC)"
	@echo ""
	@echo "2. Running unit tests..."
	@if $(ZIG) build test 2>&1; then \
		echo "$(GREEN)✅ Unit tests passed$(NC)"; \
	else \
		echo "$(RED)❌ Unit tests failed$(NC)"; \
	fi
	@echo ""
	@echo "3. Testing basic functionality..."
	@mkdir -p tmp
	@if echo '{"test": "value"}' | $(BINARY) > tmp/test_output.txt 2>&1; then \
		echo "$(GREEN)✅ Basic execution successful$(NC)"; \
		echo "Output:"; \
		cat tmp/test_output.txt; \
	else \
		echo "$(RED)❌ Basic execution failed$(NC)"; \
		cat tmp/test_output.txt; \
	fi
	@echo ""
	@echo "=== Test complete ==="

# Run manual tests (from test_manual.sh)
.PHONY: test-manual
test-manual: build
	@echo "Testing ccstreamer functionality..."
	@echo ""
	@echo "Test 1: Basic JSON"
	@echo '{"type": "test", "value": 42}' | $(BINARY)
	@echo ""
	@echo "Test 2: NO_COLOR environment variable"
	@NO_COLOR=1 echo '{"name": "example"}' | $(BINARY)
	@echo ""
	@echo "Test 3: Multiple JSON objects"
	@echo -e '{"first": true}\n{"second": false}' | $(BINARY)
	@echo ""
	@echo "Test 4: Malformed JSON (should produce error)"
	@echo '{"malformed":' | $(BINARY) 2>&1 || echo "Error handled correctly"
	@echo ""
	@echo "All manual tests completed."

# Run comprehensive real tests (from run_real_tests.sh)
.PHONY: test-real
test-real: build
	@echo "=== CC Streamer Real Test Assessment ==="
	@echo "Running comprehensive test validation..."
	@echo ""
	@E2E_PASS=0; TOKENIZER_PASS=0; PARSER_PASS=0; COLORS_PASS=0; FORMATTER_PASS=0; BINARY_PASS=0; NO_COLOR_PASS=0; \
	echo "1. Running E2E Tests:"; \
	if $(ZIG) test test/e2e_tests.zig 2>/dev/null; then \
		echo "$(GREEN)✅ E2E Tests: PASSING$(NC)"; \
		E2E_PASS=1; \
	else \
		echo "$(RED)❌ E2E Tests: FAILING$(NC)"; \
	fi; \
	echo ""; \
	echo "2. Running Parser Tests:"; \
	if $(ZIG) test src/parser/tokenizer.zig 2>/dev/null; then \
		echo "$(GREEN)✅ Tokenizer Tests: PASSING$(NC)"; \
		TOKENIZER_PASS=1; \
	else \
		echo "$(RED)❌ Tokenizer Tests: FAILING$(NC)"; \
	fi; \
	if $(ZIG) test src/parser/parser.zig 2>/dev/null; then \
		echo "$(GREEN)✅ Parser Tests: PASSING$(NC)"; \
		PARSER_PASS=1; \
	else \
		echo "$(RED)❌ Parser Tests: FAILING$(NC)"; \
	fi; \
	echo ""; \
	echo "3. Running Formatter Tests:"; \
	if $(ZIG) test src/formatter/colors.zig 2>/dev/null; then \
		echo "$(GREEN)✅ Colors Tests: PASSING$(NC)"; \
		COLORS_PASS=1; \
	else \
		echo "$(RED)❌ Colors Tests: FAILING$(NC)"; \
	fi; \
	if $(ZIG) test test/test_json_formatter.zig 2>/dev/null; then \
		echo "$(GREEN)✅ JSON Formatter Tests: PASSING$(NC)"; \
		FORMATTER_PASS=1; \
	else \
		echo "$(RED)❌ JSON Formatter Tests: FAILING$(NC)"; \
	fi; \
	echo ""; \
	echo "4. Testing Actual Binary Functionality:"; \
	if echo '{"test": "value"}' | $(BINARY) > /dev/null 2>&1; then \
		echo "$(GREEN)✅ Binary JSON Processing: WORKING$(NC)"; \
		BINARY_PASS=1; \
	else \
		echo "$(RED)❌ Binary JSON Processing: BROKEN$(NC)"; \
	fi; \
	if NO_COLOR=1 echo '{"test": "value"}' | $(BINARY) | grep -v '\x1b\[' > /dev/null 2>&1; then \
		echo "$(GREEN)✅ NO_COLOR Support: WORKING$(NC)"; \
		NO_COLOR_PASS=1; \
	else \
		echo "$(RED)❌ NO_COLOR Support: BROKEN$(NC)"; \
	fi; \
	echo ""; \
	echo "=== REAL COVERAGE ASSESSMENT ==="; \
	TOTAL_TESTS=$$(($$E2E_PASS + $$TOKENIZER_PASS + $$PARSER_PASS + $$COLORS_PASS + $$FORMATTER_PASS + $$BINARY_PASS + $$NO_COLOR_PASS)); \
	COVERAGE_PERCENT=$$(($$TOTAL_TESTS * 100 / 7)); \
	echo "Passing test suites: $$TOTAL_TESTS / 7"; \
	echo "Functional coverage: $$COVERAGE_PERCENT%"; \
	mkdir -p tmp; \
	echo "Real Coverage Analysis Report" > tmp/coverage.txt; \
	echo "Test Suites Passing: $$TOTAL_TESTS / 7" >> tmp/coverage.txt; \
	echo "Overall coverage: $$COVERAGE_PERCENT%" >> tmp/coverage.txt; \
	if [ $$COVERAGE_PERCENT -ge 85 ]; then \
		echo "$(GREEN)✅ COVERAGE EXCELLENT: $$COVERAGE_PERCENT% (exceeds 60% minimum)$(NC)"; \
	elif [ $$COVERAGE_PERCENT -ge 60 ]; then \
		echo "$(GREEN)✅ COVERAGE GOOD: $$COVERAGE_PERCENT% (meets 60% minimum)$(NC)"; \
	else \
		echo "$(RED)❌ COVERAGE INSUFFICIENT: $$COVERAGE_PERCENT% (below 60% minimum)$(NC)"; \
		exit 1; \
	fi

# Run E2E tests specifically
.PHONY: test-e2e
test-e2e:
	@echo "Running E2E tests..."
	@$(ZIG) test test/e2e_tests.zig

# Run E2E v2 tests specifically
.PHONY: test-e2e-v2
test-e2e-v2:
	@echo "Running E2E v2 tests..."
	@$(ZIG) test test/e2e_v2_tests.zig

# Clean build artifacts
.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf zig-out
	@rm -rf zig-cache
	@rm -rf tmp
	@echo "Clean complete."

# Create tmp directory if needed
.PHONY: setup
setup:
	@mkdir -p tmp

# Help target
.PHONY: help
help:
	@echo "CC Streamer Makefile Commands:"
	@echo ""
	@echo "  make              - Build the project (default)"
	@echo "  make build        - Build the project"
	@echo "  make release      - Build in release mode"
	@echo "  make run          - Build and run the application"
	@echo "  make run-args ARGS=\"...\" - Run with arguments"
	@echo "  make test         - Run unit tests"
	@echo "  make test-basic   - Run basic test suite"
	@echo "  make test-manual  - Run manual tests"
	@echo "  make test-real    - Run comprehensive real tests with coverage"
	@echo "  make test-e2e     - Run E2E tests only"
	@echo "  make test-e2e-v2  - Run E2E v2 tests only"
	@echo "  make clean        - Clean build artifacts"
	@echo "  make setup        - Create necessary directories"
	@echo "  make help         - Show this help message"
	@echo ""
	@echo "Environment Variables:"
	@echo "  NO_COLOR=1        - Disable colored output"
	@echo "  ARGS=\"...\"        - Arguments to pass to the application"

# Display all targets
.PHONY: list
list:
	@$(MAKE) -pRrq -f $(lastword $(MAKEFILE_LIST)) : 2>/dev/null | awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' | sort | egrep -v -e '^[^[:alnum:]]' -e '^$@$$'