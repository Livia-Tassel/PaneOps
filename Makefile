.PHONY: build build-cli build-app build-monitor release install install-cli install-monitor install-app up down status logs test clean format help

BUILD_DIR := .build
CLI_NAME := agent-sentinel
MONITOR_NAME := sentinel-monitor
APP_BINARY := SentinelApp
APP_LAUNCH_NAME := sentinel-app
INSTALL_DIR := /usr/local/bin
INSTALL_TOOL := /usr/bin/install
LOG_DIR := $(HOME)/.agent-sentinel/logs
MONITOR_LOG := $(LOG_DIR)/monitor.log
APP_LOG := $(LOG_DIR)/app.log
SOCKET_PATH := $(HOME)/.agent-sentinel/monitor.sock

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

# Install all binaries (CLI + monitor + app launcher)
install: release install-cli install-monitor install-app

# Install CLI to /usr/local/bin
install-cli:
	@mkdir -p $(INSTALL_DIR)
	@if [ ! -w "$(INSTALL_DIR)" ]; then \
		echo "No write permission to $(INSTALL_DIR). Please run: sudo make install"; \
		exit 1; \
	fi
	$(INSTALL_TOOL) -m 0755 $(BUILD_DIR)/release/$(CLI_NAME) $(INSTALL_DIR)/$(CLI_NAME)
	@echo "Installed $(CLI_NAME) to $(INSTALL_DIR)"

# Install monitor daemon to /usr/local/bin
install-monitor:
	@mkdir -p $(INSTALL_DIR)
	@if [ ! -w "$(INSTALL_DIR)" ]; then \
		echo "No write permission to $(INSTALL_DIR). Please run: sudo make install"; \
		exit 1; \
	fi
	$(INSTALL_TOOL) -m 0755 $(BUILD_DIR)/release/$(MONITOR_NAME) $(INSTALL_DIR)/$(MONITOR_NAME)
	@echo "Installed $(MONITOR_NAME) to $(INSTALL_DIR)"

# Install menu bar app binary launcher to /usr/local/bin/sentinel-app
install-app:
	@mkdir -p $(INSTALL_DIR)
	@if [ ! -w "$(INSTALL_DIR)" ]; then \
		echo "No write permission to $(INSTALL_DIR). Please run: sudo make install"; \
		exit 1; \
	fi
	$(INSTALL_TOOL) -m 0755 $(BUILD_DIR)/release/$(APP_BINARY) $(INSTALL_DIR)/$(APP_LAUNCH_NAME)
	@echo "Installed $(APP_LAUNCH_NAME) to $(INSTALL_DIR)"

# Start monitor + app in background
up:
	@mkdir -p $(LOG_DIR)
	@if ! command -v $(MONITOR_NAME) >/dev/null 2>&1; then \
		echo "$(MONITOR_NAME) not found. Run: sudo make install"; \
		exit 1; \
	fi
	@if ! command -v $(APP_LAUNCH_NAME) >/dev/null 2>&1; then \
		echo "$(APP_LAUNCH_NAME) not found. Run: sudo make install"; \
		exit 1; \
	fi
	@if pgrep -f '(^|/)$(MONITOR_NAME)$$' >/dev/null 2>&1; then \
		echo "$(MONITOR_NAME) already running"; \
	else \
		nohup $(MONITOR_NAME) >$(MONITOR_LOG) 2>&1 & \
		echo "Started $(MONITOR_NAME) (log: $(MONITOR_LOG))"; \
	fi
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do \
		[ -S "$(SOCKET_PATH)" ] && break; \
		sleep 0.2; \
	done
	@if ! pgrep -f '(^|/)$(MONITOR_NAME)$$' >/dev/null 2>&1; then \
		echo "Monitor failed to stay alive. Check: make logs"; \
		exit 1; \
	fi
	@if [ ! -S "$(SOCKET_PATH)" ]; then \
		echo "Monitor socket not ready at $(SOCKET_PATH). Check: make logs"; \
		exit 1; \
	fi
	@if pgrep -f '(^|/)$(APP_LAUNCH_NAME)$$|(^|/)$(APP_BINARY)$$' >/dev/null 2>&1; then \
		echo "$(APP_LAUNCH_NAME) already running"; \
	else \
		nohup $(APP_LAUNCH_NAME) >$(APP_LOG) 2>&1 & \
		echo "Started $(APP_LAUNCH_NAME) (log: $(APP_LOG))"; \
	fi
	@sleep 0.2
	@if ! pgrep -f '(^|/)$(APP_LAUNCH_NAME)$$|(^|/)$(APP_BINARY)$$' >/dev/null 2>&1; then \
		echo "App failed to stay alive. Check: make logs"; \
		exit 1; \
	fi

# Stop monitor + app
down:
	@pkill -f '(^|/)$(MONITOR_NAME)$$' >/dev/null 2>&1 || true
	@pkill -f '(^|/)$(APP_LAUNCH_NAME)$$|(^|/)$(APP_BINARY)$$' >/dev/null 2>&1 || true
	@rm -f $(SOCKET_PATH)
	@echo "Stopped monitor/app (if running)"

# Show process status
status:
	@echo "Monitor:"
	@if pgrep -fl '(^|/)$(MONITOR_NAME)$$' >/dev/null 2>&1; then \
		pgrep -fl '(^|/)$(MONITOR_NAME)$$'; \
		if [ -S "$(SOCKET_PATH)" ]; then \
			echo "  state: healthy"; \
		else \
			echo "  state: running but socket missing"; \
		fi; \
	else \
		echo "  not running"; \
		if [ -S "$(SOCKET_PATH)" ]; then \
			echo "  warning: stale socket exists at $(SOCKET_PATH)"; \
		fi; \
	fi
	@echo "App:"
	@if pgrep -fl '(^|/)$(APP_LAUNCH_NAME)$$|(^|/)$(APP_BINARY)$$' >/dev/null 2>&1; then \
		pgrep -fl '(^|/)$(APP_LAUNCH_NAME)$$|(^|/)$(APP_BINARY)$$'; \
		echo "  state: running"; \
	else \
		echo "  not running"; \
	fi

# Tail monitor and app logs
logs:
	@mkdir -p $(LOG_DIR)
	@echo "== monitor ==" && tail -n 40 $(MONITOR_LOG) 2>/dev/null || true
	@echo "== app ==" && tail -n 40 $(APP_LOG) 2>/dev/null || true

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
		swift-format format --in-place --recursive App/ CLI/ Monitor/ Shared/ Tests/; \
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
	@echo "  install    - Install CLI + monitor + app launcher to /usr/local/bin"
	@echo "  up         - Start monitor + app in background"
	@echo "  down       - Stop monitor + app"
	@echo "  status     - Show monitor + app process status"
	@echo "  logs       - Show recent monitor/app logs"
	@echo "  test       - Run all tests"
	@echo "  clean      - Clean build artifacts"
	@echo "  format     - Format code with swift-format"
