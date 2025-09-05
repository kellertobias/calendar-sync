### CalendarSync — Continuation Prompt

Use this prompt to continue development and delivery of the macOS menu bar app that one‑way syncs iCal calendars.

### Objective

- Deliver a robust macOS 14+ menu bar app that one-way syncs events from source → target iCal calendars, supports recurring events and exceptions, respects filters and time windows, and safely tags/cleans up created events. Includes manual and scheduled syncs, logs (with levels), persistence, and packaging for distribution.

### Current State (high level)

- UI: Menu bar (Last Sync/Sync Now), Syncs list+editor, Settings, Logs.
- Auth/Calendars: Modern EventKit auth (macOS 14+) with full/write-only requests; calendar discovery wired; engine gated on `.fullAccess`.
- Sync Engine: horizon query; filters/time-windows; blocker-only mode; tagging via marker; per-occurrence mapping; safe deletion policy.
- Scheduler: periodic background sync with backoff + jitter; manual Sync Now.
- Persistence: SwiftData models for configs, filters, windows, logs, mappings.
- Diagnostics: persistent logging toggle; export.
- Run at Login: ServiceManagement helper.
- Tests: helpers for filters/time-windows/occurrence keys/plan diff/deletion safety; Debug tests pass.
- Build: Release builds cleanly (no warnings).

### Next Tasks (priority)

- Packaging & Distribution
  - Create signed Release build, notarize, and staple. Prepare ZIP/DMG.
  - Verify entitlements (`Config/CalendarSync.entitlements`), Hardened Runtime (enabled for Release), and privacy usage strings (`Config/Info.plist`).
- Recurrence/Exceptions Edge Cases
  - Add tests around modified instances, cancelled occurrences, and moved instances; ensure mapping stability and correct update/delete decisions.
- UX Polish
  - Menu status details on last error/success; open Logs shortcut; smaller niceties.
- Docs
  - Update `README.md` with install/permissions/first-run notes, troubleshooting, and privacy statement.

### How to Build/Run

```bash
# Generate the Xcode project (if you change project.yml)
xcodegen generate

# Debug tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project CalendarSync.xcodeproj -scheme CalendarSync \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS' test | cat

# Release build (unsigned)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project CalendarSync.xcodeproj -scheme CalendarSync \
  -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO | cat

# Built app output
open build/Build/Products/Release/
```

### Notarization (outside Mac App Store)

Note: Requires an Apple Developer account. Replace placeholders.

```bash
# 1) Codesign the app with Developer ID Application certificate
codesign --force --deep --options runtime --timestamp \
  --entitlements Config/CalendarSync.entitlements \
  -s "Developer ID Application: Your Name (TEAMID)" \
  build/Build/Products/Release/CalendarSync.app

# 2) Zip the app
cd build/Build/Products/Release && \
  ditto -c -k --keepParent CalendarSync.app CalendarSync.zip && cd -

# 3) Notarize
xcrun notarytool submit build/Build/Products/Release/CalendarSync.zip \
  --apple-id "you@example.com" --team-id TEAMID --keychain-profile "AC_NOTARY" \
  --wait

# 4) Staple
xcrun stapler staple build/Build/Products/Release/CalendarSync.app
```

### Key Files

- `Sources/CalendarSyncApp.swift`: App entry, scenes, DI.
- `Sources/AppState.swift`: In-memory UI state and app settings.
- `Sources/Services/EventKitAuth.swift`: Authorization helper (modern APIs).
- `Sources/Services/EventKitCalendars.swift`: Calendar discovery.
- `Sources/Services/SyncEngine.swift`: Core plan/apply create/update/delete; tagging; safe delete.
- `Sources/Services/SyncRules.swift`: Pure helpers for filters, time windows, markers, occurrence keys, safe deletion.
- `Sources/Services/SyncCoordinator.swift`: Orchestrates syncs, writes logs.
- `Sources/Services/SyncScheduler.swift`: Timer with backoff+jitter.
- `Sources/Persistence/*`: SwiftData models and mappers.
- `Sources/Views/*`: SwiftUI views (menu, settings, sync list/editor, logs).

### Guidelines

- Prefer clarity over cleverness; keep functions pure/testable where possible.
- Add doc comments explaining why/how for non-trivial code; keep valuable legacy comments.
- Keep deletion safe: only delete events we created (matching target calendar + marker + mapping).
- Respect filters (title/location/notes/organizer; contains/regex; case sensitivity) and time windows.
- When windows are empty: allow all events; when present: exclude all-day events (current policy).

### Definition of Done

- Release build succeeds with zero warnings.
- Tests (Debug) green, including recurrence/exception and plan-diff coverage.
- Notarized, stapled app artifact produced; install/run verified on a clean profile.
- README updated with install and permission guidance.

### Quick Checklist

- [ ] Add recurrence/exception tests (moved, cancelled, edited instance)
- [ ] Verify safe deletions with mapping + marker only
- [ ] Final UI polish for menu error state and logs
- [ ] Notarize and staple Release build (ZIP)
- [ ] Update README
