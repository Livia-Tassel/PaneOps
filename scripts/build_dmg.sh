#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT_DIR}/VERSION"
BUILD_DIR="${BUILD_DIR:-.build-agent-sentinel}"

if [[ ! -f "${VERSION_FILE}" ]]; then
  echo "Missing VERSION file at ${VERSION_FILE}" >&2
  exit 1
fi

VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
if [[ -z "${VERSION}" ]]; then
  echo "VERSION file is empty" >&2
  exit 1
fi

# Build release bundle first (reuses existing script)
"${ROOT_DIR}/scripts/build_release_bundle.sh"

DIST_DIR="${ROOT_DIR}/dist"
RELEASE_DIR="${DIST_DIR}/AgentSentinel-${VERSION}-macOS"
DMG_NAME="AgentSentinel-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
DMG_STAGING="${DIST_DIR}/dmg-staging"

echo "==> Preparing DMG contents"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"

# App bundle for drag-and-drop install
cp -R "${RELEASE_DIR}/Agent Sentinel.app" "${DMG_STAGING}/Agent Sentinel.app"

# Applications symlink for standard macOS drag-to-install UX
ln -s /Applications "${DMG_STAGING}/Applications"

# CLI tools for manual install
mkdir -p "${DMG_STAGING}/CLI Tools"
cp "${RELEASE_DIR}/bin/agent-sentinel" "${DMG_STAGING}/CLI Tools/agent-sentinel"
cp "${RELEASE_DIR}/bin/sentinel-monitor" "${DMG_STAGING}/CLI Tools/sentinel-monitor"

# Install helper script for CLI tools
cat > "${DMG_STAGING}/CLI Tools/install-cli.sh" <<'SCRIPT'
#!/bin/sh
set -e
DEST="${1:-/usr/local/bin}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -w "${DEST}" ]; then
  echo "Installing CLI tools to ${DEST} (requires sudo)"
  sudo /usr/bin/install -m 0755 "${SCRIPT_DIR}/agent-sentinel" "${DEST}/agent-sentinel"
  sudo /usr/bin/install -m 0755 "${SCRIPT_DIR}/sentinel-monitor" "${DEST}/sentinel-monitor"
else
  /usr/bin/install -m 0755 "${SCRIPT_DIR}/agent-sentinel" "${DEST}/agent-sentinel"
  /usr/bin/install -m 0755 "${SCRIPT_DIR}/sentinel-monitor" "${DEST}/sentinel-monitor"
fi

echo "Installed agent-sentinel and sentinel-monitor to ${DEST}"
SCRIPT
chmod 0755 "${DMG_STAGING}/CLI Tools/install-cli.sh"

echo "==> Creating DMG"
rm -f "${DMG_PATH}"

# Create DMG with hdiutil
hdiutil create \
  -volname "Agent Sentinel ${VERSION}" \
  -srcfolder "${DMG_STAGING}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

# Clean up staging
rm -rf "${DMG_STAGING}"

echo "DMG ready:"
echo "  ${DMG_PATH}"
