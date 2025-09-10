rm -rf build

# Determine repository root from this script's location for portability.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# Build release without signing so we can sign manually with entitlements.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "$REPO_ROOT/CalendarSync.xcodeproj" \
  -scheme CalendarSync \
  -configuration Release \
  -derivedDataPath "$REPO_ROOT/build" \
  CODE_SIGNING_ALLOWED=NO | cat

# Ad-hoc sign the app bundle with entitlements to ensure App Sandbox + Calendars entitlement are active.
APP="$REPO_ROOT/build/Build/Products/Release/CalendarSync.app"
ENTITLEMENTS="$REPO_ROOT/Config/CalendarSync.entitlements"
if [ -d "$APP" ]; then
  codesign --force --options=runtime --timestamp=none --entitlements "$ENTITLEMENTS" -s - "$APP"
  echo "Signed: $APP with $ENTITLEMENTS"
else
  echo "App bundle not found at $APP" >&2
  exit 1
fi