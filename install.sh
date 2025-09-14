#!/usr/bin/env bash

#
# CalendarSync - Install Script
#
# Purpose:
#   Build the CalendarSync app and install it into the Applications folder.
#   By default installs to /Applications. Set INSTALL_DEST to override.
#
# Behavior:
#   1) Runs the existing build script (Release, ad-hoc signed with entitlements).
#   2) Stops any running instance of the app.
#   3) Replaces any existing installed copy.
#   4) Copies the freshly built .app bundle using `ditto` to preserve bundle metadata.
#
# Notes:
#   - No sudo prompts: if the destination is not writable, the script fails with guidance.
#   - Set INSTALL_DEST to override the destination folder explicitly.
#   - Keeps output concise; emits clear success/failure diagnostics.
#
set -euo pipefail

# Resolve repository root from this script's location for portability.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

APP_NAME="CalendarSync"
BUILD_APP_PATH="$REPO_ROOT/build/Build/Products/Release/$APP_NAME.app"

# If caller provided a destination, use it. Otherwise pick a sensible default.
DEST_DIR="${INSTALL_DEST:-/Applications}"

log() { printf "[install] %s\n" "$*"; }
fail() { printf "[install][error] %s\n" "$*" >&2; exit 1; }

log "Building ${APP_NAME} (Release)..."
"$REPO_ROOT/build.sh"

[[ -d "$BUILD_APP_PATH" ]] || fail "Built app not found at: $BUILD_APP_PATH"

if [[ ! -d "$DEST_DIR" ]]; then
  # Only attempt to create when overriding; /Applications should already exist.
  if [[ "${INSTALL_DEST:-}" != "" ]]; then
    mkdir -p "$DEST_DIR"
  fi
fi

[[ -d "$DEST_DIR" ]] || fail "Destination folder does not exist: $DEST_DIR"
[[ -w "$DEST_DIR" ]] || fail "Destination not writable: $DEST_DIR (try: sudo INSTALL_DEST=$DEST_DIR $0)"

DEST_APP_PATH="$DEST_DIR/$APP_NAME.app"

log "Installing to: $DEST_APP_PATH"

# Stop any running instance before replacing the bundle.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  log "Stopping running ${APP_NAME}..."
  pkill -x "$APP_NAME" || true
  # Give it a moment to terminate cleanly.
  sleep 0.5
fi

# Remove any existing app bundle at destination.
if [[ -d "$DEST_APP_PATH" ]]; then
  log "Removing existing installation..."
  rm -rf "$DEST_APP_PATH"
fi

# Use ditto to preserve bundle attributes, symlinks, and extended metadata.
ditto "$BUILD_APP_PATH" "$DEST_APP_PATH"

log "Installed successfully: $DEST_APP_PATH"
log "You can launch it with: open \"$DEST_APP_PATH\""


