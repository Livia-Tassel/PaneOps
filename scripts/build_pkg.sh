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

INSTALLER_SIGNING_IDENTITY="${INSTALLER_SIGNING_IDENTITY:-${SIGNING_IDENTITY:-}}"

"${ROOT_DIR}/scripts/build_release_bundle.sh"

DIST_DIR="${ROOT_DIR}/dist"
RELEASE_DIR="${DIST_DIR}/AgentSentinel-${VERSION}-macOS"
PKG_ROOT="${DIST_DIR}/pkgroot"
PKG_NAME="AgentSentinel-${VERSION}.pkg"
PKG_PATH="${DIST_DIR}/${PKG_NAME}"

echo "==> Preparing pkg root"
rm -rf "${PKG_ROOT}"
mkdir -p "${PKG_ROOT}/Applications" "${PKG_ROOT}/usr/local/bin"

cp -R "${RELEASE_DIR}/Agent Sentinel.app" "${PKG_ROOT}/Applications/Agent Sentinel.app"
cp "${RELEASE_DIR}/bin/agent-sentinel" "${PKG_ROOT}/usr/local/bin/agent-sentinel"
cp "${RELEASE_DIR}/bin/sentinel-monitor" "${PKG_ROOT}/usr/local/bin/sentinel-monitor"

cat > "${PKG_ROOT}/usr/local/bin/sentinel-app" <<'EOF'
#!/bin/sh
exec /usr/bin/open "/Applications/Agent Sentinel.app"
EOF
chmod 0755 "${PKG_ROOT}/usr/local/bin/sentinel-app"

echo "==> Building installer package"
rm -f "${PKG_PATH}"

if [[ -n "${INSTALLER_SIGNING_IDENTITY}" ]]; then
  pkgbuild \
    --root "${PKG_ROOT}" \
    --identifier "com.paneops.agent-sentinel" \
    --version "${VERSION}" \
    --install-location "/" \
    --sign "${INSTALLER_SIGNING_IDENTITY}" \
    "${PKG_PATH}"
else
  pkgbuild \
    --root "${PKG_ROOT}" \
    --identifier "com.paneops.agent-sentinel" \
    --version "${VERSION}" \
    --install-location "/" \
    "${PKG_PATH}"
fi

echo "Installer ready:"
echo "  ${PKG_PATH}"
if [[ -z "${INSTALLER_SIGNING_IDENTITY}" ]]; then
  echo "Note: package is unsigned. Set INSTALLER_SIGNING_IDENTITY to sign the installer."
fi
if [[ -n "${INSTALLER_SIGNING_IDENTITY}" && -z "${APP_SIGNING_IDENTITY:-}" ]]; then
  echo "Warning: installer is signed, but embedded app/binaries are unsigned. Set APP_SIGNING_IDENTITY for a fully signed bundle."
fi
