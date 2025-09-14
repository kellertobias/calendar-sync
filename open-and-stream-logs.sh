#!/bin/zsh
#
# Launch the built CalendarSync.app and stream its unified logs
# directly to this terminal session.
#
# Requirements:
# - The app is already built at build/Build/Products/Release/CalendarSync.app
# - macOS unified logging available via `log stream`
#
# Usage:
#   ./open-and-stream-logs.sh
#
# Notes:
# - We filter logs by the app's bundle identifier (subsystem) and process name.
# - The script will open a new instance of the app and then attach the log stream.

set -euo pipefail

# Resolve repo root relative to this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/build/Build/Products/Release/CalendarSync.app"
BIN_PATH="$APP_PATH/Contents/MacOS/CalendarSync"

$BIN_PATH