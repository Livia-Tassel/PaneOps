# Release Guide

This document defines the packaging flow used for GitHub releases.

## Versioning

- Single source of truth: `VERSION`
- Release scripts propagate this value to:
  - bundle name
  - tarball/pkg artifact names
  - CLI `--version`
  - monitor `--version`
  - app bundle `CFBundleShortVersionString` and `CFBundleVersion`

## Build Artifacts

From repository root:

```bash
make dist
```

Produces:

- `dist/AgentSentinel-<version>-macOS/`
- `dist/AgentSentinel-<version>-macOS.tar.gz`

The bundle contains:

- `bin/agent-sentinel`
- `bin/sentinel-app`
- `bin/sentinel-monitor`
- `Agent Sentinel.app` (includes `SentinelApp` + bundled `sentinel-monitor`)

## Installer Package

```bash
make pkg
```

Produces:

- `dist/AgentSentinel-<version>.pkg`

Installation layout:

- `/Applications/Agent Sentinel.app`
- `/usr/local/bin/agent-sentinel`
- `/usr/local/bin/sentinel-monitor`
- `/usr/local/bin/sentinel-app` (launcher for the installed app bundle)

## Optional Signing

Unsigned package:

```bash
make pkg
```

Signed package:

```bash
APP_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
INSTALLER_SIGNING_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
make pkg
```

Notes:

- `APP_SIGNING_IDENTITY` signs the app bundle and embedded binaries.
- `INSTALLER_SIGNING_IDENTITY` signs the `.pkg`.
- Notarization is not automated by this repository and must be done separately for distribution outside your own Mac.

## Recommended GitHub Release Uploads

- `AgentSentinel-<version>-macOS.tar.gz`
- `AgentSentinel-<version>.pkg`
- Release notes with:
  - minimum macOS version (`14+`)
  - install instructions
  - known limitations (tmux wrapper-first)
