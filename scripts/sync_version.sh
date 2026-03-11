#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT_DIR}/VERSION"
SWIFT_VERSION_FILE="${ROOT_DIR}/Shared/Config/SentinelVersion.swift"
PLIST_FILE="${ROOT_DIR}/Resources/Info.plist"

if [[ ! -f "${VERSION_FILE}" ]]; then
  echo "Missing VERSION file at ${VERSION_FILE}" >&2
  exit 1
fi

VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
if [[ -z "${VERSION}" ]]; then
  echo "VERSION file is empty" >&2
  exit 1
fi

cat > "${SWIFT_VERSION_FILE}" <<EOF
import Foundation

public enum SentinelVersion {
    public static let current = "${VERSION}"
}
EOF

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST_FILE}" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${PLIST_FILE}" >/dev/null
