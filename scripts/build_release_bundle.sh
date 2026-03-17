#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-.build-agent-sentinel}"
VERSION_FILE="${ROOT_DIR}/VERSION"

if [[ ! -f "${VERSION_FILE}" ]]; then
  echo "Missing VERSION file at ${VERSION_FILE}" >&2
  exit 1
fi

VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
if [[ -z "${VERSION}" ]]; then
  echo "VERSION file is empty" >&2
  exit 1
fi

APP_SIGNING_IDENTITY="${APP_SIGNING_IDENTITY:-}"

bash "${ROOT_DIR}/scripts/sync_version.sh"

DIST_DIR="${ROOT_DIR}/dist"
RELEASE_DIR="${DIST_DIR}/AgentSentinel-${VERSION}-macOS"
APP_BUNDLE="${RELEASE_DIR}/Agent Sentinel.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"
APP_RESOURCES="${APP_CONTENTS}/Resources"
TARBALL="${DIST_DIR}/AgentSentinel-${VERSION}-macOS.tar.gz"

echo "==> Building release binaries"
if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  echo "Building as ${SUDO_USER} to avoid root-owned build artifacts"
  sudo -u "${SUDO_USER}" HOME="$(eval echo ~"${SUDO_USER}")" swift build --build-path "${BUILD_DIR}" -c release
else
  swift build --build-path "${BUILD_DIR}" -c release
fi

echo "==> Preparing release directory"
if [[ -d "${RELEASE_DIR}" ]]; then
  rm -rf "${RELEASE_DIR}" 2>/dev/null || {
    echo "Cannot remove ${RELEASE_DIR} (root-owned files from previous sudo install)." >&2
    echo "Fix: sudo rm -rf dist/" >&2
    exit 1
  }
fi
mkdir -p "${RELEASE_DIR}/bin" "${APP_MACOS}" "${APP_RESOURCES}" "${RELEASE_DIR}/docs"

cp "${ROOT_DIR}/${BUILD_DIR}/release/agent-sentinel" "${RELEASE_DIR}/bin/agent-sentinel"
cp "${ROOT_DIR}/${BUILD_DIR}/release/sentinel-monitor" "${RELEASE_DIR}/bin/sentinel-monitor"
cp "${ROOT_DIR}/${BUILD_DIR}/release/SentinelApp" "${APP_MACOS}/SentinelApp"
cp "${ROOT_DIR}/${BUILD_DIR}/release/sentinel-monitor" "${APP_MACOS}/sentinel-monitor"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_CONTENTS}/Info.plist"

cat > "${RELEASE_DIR}/bin/sentinel-app" <<'EOF'
#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_PATH="${SCRIPT_DIR%/bin}/Agent Sentinel.app"
exec /usr/bin/open "${APP_PATH}"
EOF

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_CONTENTS}/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${APP_CONTENTS}/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable SentinelApp" "${APP_CONTENTS}/Info.plist" >/dev/null

chmod 0755 \
  "${RELEASE_DIR}/bin/agent-sentinel" \
  "${RELEASE_DIR}/bin/sentinel-app" \
  "${RELEASE_DIR}/bin/sentinel-monitor" \
  "${APP_MACOS}/SentinelApp" \
  "${APP_MACOS}/sentinel-monitor"

if [[ -n "${APP_SIGNING_IDENTITY}" ]]; then
  echo "==> Signing app and binaries"
  codesign --force --sign "${APP_SIGNING_IDENTITY}" --options runtime "${RELEASE_DIR}/bin/agent-sentinel"
  codesign --force --sign "${APP_SIGNING_IDENTITY}" --options runtime "${RELEASE_DIR}/bin/sentinel-monitor"
  codesign --force --sign "${APP_SIGNING_IDENTITY}" --options runtime "${APP_MACOS}/sentinel-monitor"
  codesign --force --sign "${APP_SIGNING_IDENTITY}" --options runtime "${APP_MACOS}/SentinelApp"
  codesign --force --sign "${APP_SIGNING_IDENTITY}" --options runtime "${APP_BUNDLE}"
fi

cp "${ROOT_DIR}/README.md" "${RELEASE_DIR}/docs/README.md"
cp "${ROOT_DIR}/Docs/ARCHITECTURE.md" "${RELEASE_DIR}/docs/ARCHITECTURE.md"
cp "${ROOT_DIR}/Docs/DEVELOPMENT.md" "${RELEASE_DIR}/docs/DEVELOPMENT.md"

echo "==> Creating tarball"
rm -f "${TARBALL}"
(
  cd "${DIST_DIR}"
  tar -czf "$(basename "${TARBALL}")" "$(basename "${RELEASE_DIR}")"
)

echo "Release bundle ready:"
echo "  ${RELEASE_DIR}"
echo "  ${TARBALL}"
