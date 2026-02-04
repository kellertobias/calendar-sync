#!/usr/bin/env bash

#
# CalendarSync - Install and Restart Script
#
# Purpose:
#   Build the CalendarSync app, install it into the Applications folder,
#   and launch the installed application.
#
# Behavior:
#   1) Runs the existing build script (Release).
#   2) Stops any running instance of the app.
#   3) Replaces any existing installed copy in /Applications (or INSTALL_DEST).
#   4) Launches the newly installed app.
#
# Notes:
#   - Set INSTALL_DEST to override the destination folder explicitly.
#
set -euo pipefail

# Resolve repository root from this script's location for portability.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

APP_NAME="CalendarSync"
BUILD_APP_PATH="$REPO_ROOT/build/Build/Products/Release/$APP_NAME.app"

# If caller provided a destination, use it. Otherwise pick a sensible default.
DEST_DIR="${INSTALL_DEST:-/Applications}"

log() { printf "[install-and-restart] %s\n" "$*"; }
fail() { printf "[install-and-restart][error] %s\n" "$*" >&2; exit 1; }

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

log "Launching ${APP_NAME}..."
open "$DEST_APP_PATH"
