rm -rf build

# Build release without signing so we can sign manually with entitlements.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project /Users/keller/repos/calendar-sync/CalendarSync.xcodeproj -scheme CalendarSync -configuration Release -derivedDataPath /Users/keller/repos/calendar-sync/build CODE_SIGNING_ALLOWED=NO

# Ad-hoc sign the app bundle with entitlements to ensure App Sandbox + Calendars entitlement are active.
APP="/Users/keller/repos/calendar-sync/build/Build/Products/Release/CalendarSync.app"
ENTITLEMENTS="/Users/keller/repos/calendar-sync/Config/CalendarSync.entitlements"
if [ -d "$APP" ]; then
  codesign --force --options=runtime --timestamp=none --entitlements "$ENTITLEMENTS" -s - "$APP"
  echo "Signed: $APP with $ENTITLEMENTS"
else
  echo "App bundle not found at $APP" >&2
  exit 1
fi