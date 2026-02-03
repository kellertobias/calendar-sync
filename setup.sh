#!/usr/bin/env bash

#
# CalendarSync - Xcode Setup Script
#
# Purpose:
#   Prepare the local machine and Xcode for working on this project.
#   - Verifies Xcode Command Line Tools are installed.
#   - Optionally regenerates the Xcode project from project.yml (via XcodeGen).
#   - Resolves Swift Package dependencies so the project opens cleanly in Xcode.
#
# Usage:
#   ./setup.sh               # run checks and resolve dependencies
#   ./setup.sh --open        # additionally open the project in Xcode
#
# Notes:
#   - This script is safe to re-run at any time.
#   - It does NOT install Homebrew, Xcode, or XcodeGen automatically.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

APP_NAME="CalendarSync"
XCODEPROJ_PATH="$REPO_ROOT/CalendarSync.xcodeproj"
PROJECT_YML_PATH="$REPO_ROOT/project.yml"

SHOULD_OPEN_PROJECT=false

for arg in "$@"; do
  case "$arg" in
    --open)
      SHOULD_OPEN_PROJECT=true
      ;;
    *)
      printf "[setup][warn] Unknown argument: %s\n" "$arg" >&2
      ;;
  esac
done

log()  { printf "[setup] %s\n" "$*"; }
warn() { printf "[setup][warn] %s\n" "$*" >&2; }
fail() { printf "[setup][error] %s\n" "$*" >&2; exit 1; }

ensure_xcode_cli() {
  if ! xcode-select -p >/dev/null 2>&1; then
    warn "Xcode Command Line Tools not found."
    warn "macOS should show a dialog if you run: xcode-select --install"
    warn "After installation completes, re-run this script."
    exit 1
  fi

  if ! xcodebuild -version >/dev/null 2>&1; then
    fail "xcodebuild is not available. Make sure Xcode + Command Line Tools are installed correctly."
  fi

  log "Xcode Command Line Tools detected."
}

maybe_regenerate_project() {
  if [[ -f "$PROJECT_YML_PATH" ]]; then
    if command -v xcodegen >/dev/null 2>&1; then
      log "Regenerating Xcode project from project.yml using XcodeGen..."
      (cd "$REPO_ROOT" && xcodegen generate)
      log "Xcode project successfully generated."
    else
      warn "project.yml detected but XcodeGen is not installed."
      warn "Install with: brew install xcodegen"
      warn "Continuing with existing .xcodeproj at: $XCODEPROJ_PATH"
    fi
  else
    log "No project.yml found; using existing Xcode project."
  fi
}

resolve_swift_packages() {
  if [[ ! -d "$XCODEPROJ_PATH" ]]; then
    fail "Xcode project not found at: $XCODEPROJ_PATH"
  fi

  log "Resolving Swift Package dependencies via xcodebuild..."
  xcodebuild \
    -project "$XCODEPROJ_PATH" \
    -scheme "$APP_NAME" \
    -resolvePackageDependencies \
    >/dev/null

  log "Swift Package dependencies resolved."
}

maybe_open_xcode() {
  if [[ "$SHOULD_OPEN_PROJECT" == "true" ]]; then
    if [[ -d "$XCODEPROJ_PATH" ]]; then
      log "Opening project in Xcode..."
      open "$XCODEPROJ_PATH"
    else
      warn "Cannot open Xcode project; file not found at: $XCODEPROJ_PATH"
    fi
  else
    log "To open the project in Xcode, run:"
    log "  open \"$XCODEPROJ_PATH\""
  fi
}

log "Initializing Xcode environment for CalendarSync..."
ensure_xcode_cli
maybe_regenerate_project
resolve_swift_packages
maybe_open_xcode

log "Setup complete."

