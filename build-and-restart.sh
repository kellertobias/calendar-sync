#!/usr/bin/env bash

# Resolve repository root from this script's directory for portability.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

bash -lc "$REPO_ROOT/build.sh | cat" && (pkill -x "CalendarSync" || true) && open "$REPO_ROOT/build/Build/Products/Release/CalendarSync.app"
