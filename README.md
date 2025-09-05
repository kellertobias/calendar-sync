# Calendar Sync (macOS Menu Bar)

A macOS 14+ menu bar app that one-way syncs events between iCal calendars. Supports recurring events and exceptions, filters, time windows, blocker-only mode, safe tagging + mappings, diagnostics logs, periodic scheduling, and an optional Run at Login toggle.

## Build and Run (Dev)

1. Ensure Xcode is installed and license accepted:
   ```bash
   sudo /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -license accept
   ```
2. Generate project (with XcodeGen):
   ```bash
   xcodegen generate
   ```
3. Build (unsigned dev build):
   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   xcodebuild -project CalendarSync.xcodeproj -scheme CalendarSync \
     -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO
   ```
4. Run:
   ```bash
   open build/Build/Products/Release/CalendarSync.app
   ```

## Features

- One-way sync from source → target calendar
- Recurrence + exceptions with per-occurrence mapping
- Filters: include/exclude, regex, ignore other tuples
- Weekday/time windows; blocker-only mode
- Safe tagging in notes/url plus SwiftData mapping table
- Diagnostics logs (levels), filter and export (JSON/Text)
- Scheduler with configurable interval; manual Sync Now
- Run at Login toggle

## Signing & Notarization (Distribution)

Prereqs:

- Apple Developer Program membership and a valid signing identity (Developer ID Application)
- A provisioning profile is not required for Developer ID distribution

Xcode project flags:

- Entitlements include App Sandbox and Calendar access
- Hardened Runtime is enabled for Release in `project.yml`

Steps:

1. Set bundle identifier and team:
   - Update `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`
   - In Xcode, set your Signing Team for Release configuration
2. Enable codesigning:
   - Build with signing:
     ```bash
     xcodebuild -project CalendarSync.xcodeproj -scheme CalendarSync -configuration Release
     ```
3. Notarize the app (notarytool):
   - Create a ZIP of the app:
     ```bash
     ditto -c -k --keepParent build/Build/Products/Release/CalendarSync.app CalendarSync.zip
     ```
   - Submit with notarytool (preferred):
     ```bash
     xcrun notarytool submit CalendarSync.zip --apple-id YOUR_ID@example.com \
       --team-id YOUR_TEAM_ID --password YOUR_APP_SPECIFIC_PW --wait
     ```
   - Staple the ticket:
     ```bash
     xcrun stapler staple build/Build/Products/Release/CalendarSync.app
     ```
4. Verify staple:
   ```bash
   xcrun stapler validate build/Build/Products/Release/CalendarSync.app
   ```
5. Distribute the `.app` or create a DMG as desired.

## Troubleshooting

- EventKit permissions: open System Settings → Privacy & Security → Calendars
- If logs are too verbose, disable diagnostics in Settings
- For Run at Login changes to take effect immediately, ensure the app remains allowed in System Settings → General → Login Items

## Tests

- Future work: XCTest targets for filters, time windows, diff logic, and recurrence edge cases.

## License

MIT
