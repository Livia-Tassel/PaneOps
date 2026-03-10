.PHONY: build build-cli build-app build-monitor install install-monitor clean release

BUILD_DIR := .build
CLI_NAME := agent-sentinel
MONITOR_NAME := sentinel-monitor
APP_NAME := AgentSentinel
INSTALL_DIR := /usr/local/bin
APP_INSTALL_DIR := /Applications

# Build all targets
build:
	swift build

# Build CLI only
build-cli:
	swift build --target SentinelCLI

# Build App only
build-app:
	swift build --target SentinelApp

# Build monitor daemon only
build-monitor:
	swift build --target SentinelMonitor

# Release build
release:
	swift build -c release

# Install CLI to /usr/local/bin
install: release
	@mkdir -p $(INSTALL_DIR)
	cp $(BUILD_DIR)/release/$(CLI_NAME) $(INSTALL_DIR)/$(CLI_NAME)
	@echo "Installed $(CLI_NAME) to $(INSTALL_DIR)"

# Install monitor daemon to /usr/local/bin
install-monitor: release
	@mkdir -p $(INSTALL_DIR)
	cp $(BUILD_DIR)/release/$(MONITOR_NAME) $(INSTALL_DIR)/$(MONITOR_NAME)
	@echo "Installed $(MONITOR_NAME) to $(INSTALL_DIR)"

# Run tests
test:
	swift test

# Clean build artifacts
clean:
	swift package clean
	rm -rf $(BUILD_DIR)

# Format code (if swift-format is installed)
format:
	@if command -v swift-format > /dev/null 2>&1; then \
		swift-format format --in-place --recursive Sources/ Tests/; \
	else \
		echo "swift-format not installed"; \
	fi

# Show help
help:
	@echo "Available targets:"
	@echo "  build      - Build all targets (debug)"
	@echo "  build-cli  - Build CLI only"
	@echo "  build-app  - Build App only"
	@echo "  build-monitor - Build monitor daemon only"
	@echo "  release    - Build all targets (release)"
	@echo "  install    - Install CLI to /usr/local/bin"
	@echo "  install-monitor - Install monitor daemon to /usr/local/bin"
	@echo "  test       - Run all tests"
	@echo "  clean      - Clean build artifacts"
	@echo "  format     - Format code with swift-format"
