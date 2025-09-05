## Calendar Sync (macOS, Menu Bar) — Task Plan

A macOS menu bar utility that one-way syncs events between selected iCal calendars. Users can define multiple sync tuples (source → target), choose sync horizon (next X days), support all event types (including recurring and exceptions), tag created events for safe deletion, choose data mode (full info vs blocker-only with custom title), apply weekday/time windows, and apply include/exclude filters. UI-first delivery, then functionality.

Target: Latest macOS releases (Sonoma 14, Sequoia 15). Tech: Swift 5.9+, SwiftUI, MenuBarExtra, EventKit, SwiftData.

---

### High-level Milestones (UI first)

1. App scaffolding and menu bar shell (UI)

- Create SwiftUI macOS app with `MenuBarExtra`.
- Menu shows:
  - Last Sync item (click triggers Sync Now)
  - List of configured syncs (name/mode/status)
  - New Sync… action (opens editor sheet/window)
  - Settings… (opens Settings window)
- Non-functional placeholders wired to view models.

2. Settings UI (UI)

- Calendar permission prompt CTA and current authorization state.
- Sync interval picker (e.g., 5m/15m/30m/1h/custom).
- Horizon (next X days) default.
- Diagnostics toggle and small log viewer link.

3. Sync list and editor UI (UI)

- Sync list with add/edit/delete, enable/disable toggle.
- Editor fields:
  - Source calendar (iCal)
  - Target calendar (iCal)
  - Mode: Full info | Blocker-only
    - If Blocker-only: blocker title template (supports tokens like `{sourceTitle}` and `{sourceOrganizer}`)
  - Horizon override (optional per-sync)
  - Weekday/time window constraints editor
  - Filters: include/exclude title substrings, regex (advanced), “ignore events already synced by other tuples” option
  - Tagging strategy preview (how we stamp events)
  - Dry-run preview button (UI stub)

4. Calendar access and data plumbing (Functionality)

- Request EventKit permissions on demand from Settings.
- Discover calendars and cache readable/writable sets.

5. Persistence (Functionality)

- Store sync configurations with SwiftData (macOS 14+): `SyncConfig`, `FilterRule`, `TimeWindow`, `SyncRunLog`, `EventMapping`.
- Migrate default settings → per-sync overrides.

6. Sync engine core (Functionality)

- Query events in source for next X days using EventKit.
- Build a normalization layer: consistent identifiers, timezones, all-day handling.
- Create/update/delete in target:
  - Create when missing.
  - Update when source changed and we own the target twin.
  - Delete when source deleted and target twin is ours.
- Tag created events with a deterministic marker and mapping (see Tagging section).

7. Recurring events and exceptions (Functionality)

- Correctly handle `EKRecurrenceRule`, occurrence instances, and exceptions.
- Maintain mapping per master event and per-occurrence override when necessary.

8. Filters and constraints (Functionality)

- Include/exclude by title (substring/regex), with case sensitivity option.
- Ignore already-synced events from other tuples:
  - Detect by tag marker pattern in notes/URL and mismatch with current tuple ID.
- Apply weekday/time windows per-sync.

9. Scheduling and controls (Functionality)

- Background timer while app is running; manual “Sync Now”.
- Backoff on errors, jitter between syncs.
- Persist last successful/failed run timestamps and counts.

10. Diagnostics and UX polish

- Log view with filters (per-sync, level) and export.
- Status badges in menu list (Enabled, Error, Needs Auth, Last sync time).
- App icon, accessibility labels, keyboard navigation.

11. Packaging and distribution

- Hardened Runtime, entitlements, codesigning, notarization.
- Optional: login item support, updates channel.

---

### Detailed Task Breakdown and Acceptance Criteria

#### M1 — Menu Bar UI Shell

- Tasks:
  - Scaffold SwiftUI macOS app with `@main` and `MenuBarExtra`.
  - Menu layout: Last Sync, Configured Syncs, New Sync…, Settings…
  - Provide placeholder view models and sample data
- Acceptance:
  - App launches into menu bar, menu renders without runtime errors.
  - Clicking items routes to stub handlers without crashing.

#### M2 — Settings Window (UI)

- Tasks:
  - Build SwiftUI Settings scene with sections: Permissions, Sync Interval, Defaults, Diagnostics
  - Show current Calendar auth status (Not Determined / Denied / Authorized)
  - Buttons: Request Access, Open System Settings → Privacy → Calendars
  - Interval picker and default horizon field
  - Diagnostics toggle and “Open Logs” button
- Acceptance:
  - State updates reflect user choices in-memory.
  - No EventKit calls yet beyond status access.

#### M3 — Syncs List and Editor (UI)

- Tasks:
  - List of sync tuples with name, mode, enabled, last sync status/time
  - Editor with fields: Source, Target, Mode, Blocker title template, Horizon override
  - Weekday/time window editors
  - Filters UI: include/exclude titles, regex advanced, ignore other tuples’ tagged events
  - Validate: source != target; writable target; template preview
- Acceptance:
  - CRUD flows work in-memory.
  - Validation prevents invalid save.

#### M4 — Calendar Access & Discovery

- Tasks:
  - Wire EventKit permission request
  - Load readable and writable calendars, present in pickers
- Acceptance:
  - Settings shows Authorized after grant
  - Editor pickers list actual calendars

#### M5 — Persistence (SwiftData)

- Tasks:
  - Define models: `SyncConfig`, `FilterRule`, `TimeWindow`, `EventMapping`, `SyncRunLog`, `AppSettings`
  - Save/load list of syncs, settings, and logs
- Acceptance:
  - Relaunch preserves settings and syncs
  - Migration-friendly schema versioning stub present

#### M6 — Sync Engine Core

- Tasks:
  - Build a sync service operating on one `SyncConfig`
  - Query source events for horizon; normalize events
  - Determine delta vs target (create/update/delete)
  - Apply mode: Full vs Blocker-only
  - Respect include/exclude filters and time windows
- Acceptance:
  - Dry-run prints planned actions
  - Live run creates/updates/deletes expected events on a test pair

#### M7 — Recurrence & Exceptions

- Tasks:
  - Handle recurring masters, occurrences, and overridden instances
  - Map and tag per master and occurrence as needed
- Acceptance:
  - Modifying/canceling single instances propagates correctly
  - No duplicate blockers across occurrences

#### M8 — Tagging & Safe Deletion

- Tasks:
  - Tag strategy: deterministic marker in `notes` and `url`
  - Maintain `EventMapping` linking source identifier + occurrence date → target identifier
  - Only delete/modify target if we own it (via tag or mapping)
- Acceptance:
  - Deleting source deletes our created target only
  - Third-party events remain untouched

#### M9 — Scheduling & Controls

- Tasks:
  - Timer-based scheduler with configurable interval
  - Manual Sync Now; per-sync enable/disable
  - Error backoff and jitter
- Acceptance:
  - Periodic runs occur while app is open
  - “Sync Now” starts immediately and reports status

#### M10 — Diagnostics & UX Polish

- Tasks:
  - Structured logs, in-app log viewer, export
  - Status badges in menu and editor
  - App icon, accessibility labels
- Acceptance:
  - Logs readable and filterable
  - Basic a11y checks pass with VoiceOver

#### M11 — Packaging & Distribution

- Tasks:
  - Entitlements: `com.apple.security.personal-information.calendars`
  - Hardened Runtime, codesigning, notarization workflow
  - Optional login item for auto-launch
- Acceptance:
  - Build notarizes successfully
  - App runs on a clean machine with calendars access prompt

---

### Data Model (initial)

`SyncConfig`

- id (UUID)
- name (String)
- sourceCalendarId (String)
- targetCalendarId (String)
- mode (enum): full | blocker
- blockerTitleTemplate (String?)
- horizonDays (Int, optional overrides default)
- enabled (Bool)
- weekdayPolicy ([Weekday: Bool])
- timeWindows ([TimeWindow])
- filters ([FilterRule])
- createdAt / updatedAt (Date)

`FilterRule`

- type: includeTitle | excludeTitle | includeRegex | excludeRegex | ignoreOtherTuples
- pattern: String
- caseSensitive: Bool

`TimeWindow`

- weekday (Mon…Sun)
- start (LocalTime)
- end (LocalTime)

`EventMapping`

- id (UUID)
- syncConfigId (UUID)
- sourceEventIdentifier (String)
- occurrenceDateKey (String) // ISO date for per-occurrence mapping
- targetEventIdentifier (String)
- lastUpdated (Date)

`SyncRunLog`

- id (UUID)
- syncConfigId (UUID)
- startedAt / finishedAt (Date)
- result: success | failure | partial
- created/updated/deleted counts
- message (String)

`AppSettings`

- defaultHorizonDays (Int)
- intervalSeconds (Int)
- diagnosticsEnabled (Bool)

---

### Tagging Strategy

- Add a deterministic marker into `EKEvent.notes` and mirror a compact ID into `EKEvent.url`.
- Marker format example (single line, human-friendly, parseable):
  - `[CalendarSync] tuple=<SYNC_ID> source=<SRC_EVENT_ID> occ=<ISO_DATE>`
- Use `EventMapping` as the source of truth; tags provide resilience if identifiers rotate.

---

### Sync Algorithm (overview)

- Load `SyncConfig` and compute time range: now → now + horizonDays.
- Fetch source events with `predicateForEvents(withStart:end:calendars:)`.
- For each source event (including occurrences):
  - If filtered out or outside time windows → skip.
  - Build occurrence key: masterID + occurrenceDate.
  - Look up mapping; if none, try tag lookup in target by query + marker.
  - If no target twin → create; else compare and update if changed.
- For any mapped target with missing source → delete (only if we own it).
- Log actions and update `EventMapping`.

---

### Risks & Mitigations

- Recurrence exceptions: rely on EventKit occurrence APIs and occurrenceDate keys.
- Identifier churn: maintain mapping + tags to survive edits and moves.
- Timezone and DST: normalize to absolute `Date` and compare with tolerance.
- User permissions: surface clear status and fallbacks in Settings.
- Duplicates: deterministic tagging and mapping guard against re-creation.

---

### Definition of Done

- UI milestones M1–M3 shippable without functional crashes.
- EventKit authorized flow clear in Settings.
- Sync engine reliable on typical and recurring cases with safe deletion.
- Packaging ready: signed, notarized, calendar entitlement present.

---

### Progress Log

- [Day 0] Created TASKS.md with a UI-first milestone plan and detailed acceptance criteria.
- [Day 0] Scaffolded SwiftUI menu bar app, Settings and Syncs windows, UI state, and stubs. Generated Xcode project via XcodeGen.
- [Day 0] Implemented EventKit authorization service and wired Settings to show and request permissions.
- [Day 0] Extended Sync editor UI with calendar pickers, filters, weekday/time windows, and validation.
- [Day 0] Implemented EventKit calendar discovery and wired pickers to real calendars.
- [Day 0] Added SwiftData models and persistence, wired Syncs UI to load/save.
- [Day 0] Added core sync engine and wired "Sync Now" to compute/apply plan.
- [Day 0] Improved recurrence handling via occurrenceDate keys, added periodic scheduler.
