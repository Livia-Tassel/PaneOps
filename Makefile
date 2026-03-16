.PHONY: run stop sync-version build build-cli build-app build-monitor release dist pkg dmg install install-cli install-monitor install-app up down status logs test clean format help

BUILD_DIR := .build-agent-sentinel
CLI_NAME := agent-sentinel
MONITOR_NAME := sentinel-monitor
APP_BINARY := SentinelApp
APP_BUNDLE_NAME := Agent Sentinel.app
APP_LAUNCH_NAME := sentinel-app
VERSION_FILE := VERSION
VERSION := $(shell tr -d '[:space:]' < $(VERSION_FILE) 2>/dev/null || echo 0.1.0)
PREFIX ?= /usr/local
INSTALL_DIR ?= $(PREFIX)/bin
APP_INSTALL_DIR ?= /Applications
APP_INSTALL_PATH := $(APP_INSTALL_DIR)/$(APP_BUNDLE_NAME)
INSTALL_TOOL := /usr/bin/install
LOG_DIR := $(HOME)/.agent-sentinel/logs
MONITOR_LOG := $(LOG_DIR)/monitor.log
APP_LOG := $(LOG_DIR)/app.log
SOCKET_PATH := $(HOME)/.agent-sentinel/monitor.sock
MONITOR_STARTUP_RETRIES := 100
MONITOR_STARTUP_SLEEP := 0.2
SWIFT_BUILD := swift build --build-path $(BUILD_DIR)
SWIFT_TEST := swift test --build-path $(BUILD_DIR)

# Default target: build and start locally (no install needed)
run: build
	@mkdir -p $(LOG_DIR)
	@if pgrep -f '(^|/)$(MONITOR_NAME)$$' >/dev/null 2>&1; then \
		echo "$(MONITOR_NAME) already running (use 'make stop' first to restart)"; \
	else \
		nohup $(BUILD_DIR)/debug/$(MONITOR_NAME) >$(MONITOR_LOG) 2>&1 & \
		echo "Started $(MONITOR_NAME) from build dir"; \
	fi
	@for i in $$(seq 1 $(MONITOR_STARTUP_RETRIES)); do \
		[ -S "$(SOCKET_PATH)" ] && break; \
		sleep $(MONITOR_STARTUP_SLEEP); \
	done
	@if ! pgrep -f '(^|/)$(MONITOR_NAME)$$' >/dev/null 2>&1; then \
		echo "Monitor failed to start. Check: make logs"; \
		exit 1; \
	fi
	@if [ ! -S "$(SOCKET_PATH)" ]; then \
		echo "Monitor socket not ready. Check: make logs"; \
		exit 1; \
	fi
	@if pgrep -f '(^|/)$(APP_BINARY)$$' >/dev/null 2>&1; then \
		echo "$(APP_BINARY) already running"; \
	else \
		nohup $(BUILD_DIR)/debug/$(APP_BINARY) >$(APP_LOG) 2>&1 & \
		echo "Started $(APP_BINARY) from build dir"; \
	fi
	@sleep 0.3
	@if pgrep -f '(^|/)$(APP_BINARY)$$' >/dev/null 2>&1; then \
		echo "Ready. Use 'make stop' to shut down, 'make logs' for diagnostics."; \
	else \
		echo "App failed to start. Check: make logs"; \
		exit 1; \
	fi

# Stop monitor + app (works for both 'run' and 'up')
stop:
	@pkill -f '(^|/)$(MONITOR_NAME)$$' >/dev/null 2>&1 || true
	@pkill -f '(^|/)$(APP_LAUNCH_NAME)$$|(^|/)$(APP_BINARY)$$' >/dev/null 2>&1 || true
	@rm -f $(SOCKET_PATH)
	@echo "Stopped"

sync-version:
	@bash ./scripts/sync_version.sh

# Build all targets
build: sync-version
	$(SWIFT_BUILD)

# Build CLI only
build-cli: sync-version
	$(SWIFT_BUILD) --target SentinelCLI

# Build App only
build-app: sync-version
	$(SWIFT_BUILD) --target SentinelApp

# Build monitor daemon only
build-monitor: sync-version
	$(SWIFT_BUILD) --target SentinelMonitor

# Release build
release: sync-version
	@if [ "$$(id -u)" -eq 0 ] && [ -n "$$SUDO_USER" ] && [ "$$SUDO_USER" != "root" ]; then \
		echo "Building as $$SUDO_USER to avoid root-owned .build artifacts"; \
		sudo -u "$$SUDO_USER" HOME="$$(eval echo ~$$SUDO_USER)" swift build --build-path $(BUILD_DIR) -c release; \
	else \
		$(SWIFT_BUILD) -c release; \
	fi

# Build release tarball for GitHub Releases
dist:
	@BUILD_DIR=$(BUILD_DIR) ./scripts/build_release_bundle.sh

# Build macOS installer package (.pkg)
pkg:
	@BUILD_DIR=$(BUILD_DIR) ./scripts/build_pkg.sh

# Build macOS disk image (.dmg)
dmg:
	@BUILD_DIR=$(BUILD_DIR) ./scripts/build_dmg.sh

# Install all binaries (CLI + monitor + app bundle + launcher)
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

# Install menu bar app bundle under /Applications and launcher under /usr/local/bin/sentinel-app
install-app:
	@BUILD_DIR=$(BUILD_DIR) ./scripts/build_release_bundle.sh >/dev/null
	@mkdir -p "$(APP_INSTALL_DIR)"
	@mkdir -p $(INSTALL_DIR)
	@if [ ! -w "$(INSTALL_DIR)" ]; then \
		echo "No write permission to $(INSTALL_DIR). Please run: sudo make install"; \
		exit 1; \
	fi
	@if [ ! -w "$(APP_INSTALL_DIR)" ]; then \
		echo "No write permission to $(APP_INSTALL_DIR). Please run: sudo make install"; \
		exit 1; \
	fi
	@rm -rf "$(APP_INSTALL_PATH)"
	@cp -R "dist/AgentSentinel-$(VERSION)-macOS/$(APP_BUNDLE_NAME)" "$(APP_INSTALL_PATH)"
	@printf '%s\n' '#!/bin/sh' 'exec /usr/bin/open "$(APP_INSTALL_PATH)"' > "$(INSTALL_DIR)/$(APP_LAUNCH_NAME)"
	@chmod 0755 "$(INSTALL_DIR)/$(APP_LAUNCH_NAME)"
	@echo "Installed $(APP_BUNDLE_NAME) to $(APP_INSTALL_DIR)"
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
	@for i in $$(seq 1 $(MONITOR_STARTUP_RETRIES)); do \
		[ -S "$(SOCKET_PATH)" ] && break; \
		sleep $(MONITOR_STARTUP_SLEEP); \
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
	@echo "== monitor (nohup) ==" && tail -n 40 $(MONITOR_LOG) 2>/dev/null || true
	@echo "== app (nohup) ==" && tail -n 40 $(APP_LOG) 2>/dev/null || true
	@echo "== monitor (os.Logger, last 5m) ==" && log show --style compact --last 5m --predicate 'subsystem == "com.paneops.agent-sentinel" && category == "monitor"' 2>/dev/null | tail -n 40 || true
	@echo "== ipc (os.Logger, last 5m) ==" && log show --style compact --last 5m --predicate 'subsystem == "com.paneops.agent-sentinel" && category == "ipc"' 2>/dev/null | tail -n 40 || true

# Run tests
test: sync-version
	$(SWIFT_TEST)

# Clean build artifacts
clean:
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
	@echo "Quick start:"
	@echo "  make       - Build and start locally (no install needed)"
	@echo "  make stop  - Stop monitor + app"
	@echo ""
	@echo "Development:"
	@echo "  build      - Build all targets (debug)"
	@echo "  test       - Run all tests"
	@echo "  status     - Show monitor + app process status"
	@echo "  logs       - Show recent monitor/app logs"
	@echo "  clean      - Clean build artifacts"
	@echo "  format     - Format code with swift-format"
	@echo ""
	@echo "Distribution:"
	@echo "  release    - Build all targets (release)"
	@echo "  dmg        - Build macOS disk image (.dmg)"
	@echo "  pkg        - Build unsigned macOS installer package (.pkg)"
	@echo "  dist       - Build release bundle + tar.gz"
	@echo ""
	@echo "Install (requires sudo):"
	@echo "  install    - Install CLI + monitor + app to system paths"
	@echo "  up         - Start installed monitor + app"
	@echo "  down       - Stop installed monitor + app"
	@echo ""
	@echo "Current version: $(VERSION)"
