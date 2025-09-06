import EventKit
import SwiftData
import SwiftUI

// MARK: - Small helpers
extension Color {
  /// Initialize from hex string like "#RRGGBB".
  fileprivate init?(hex: String) {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xFF) / 255.0
    let g = Double((v >> 8) & 0xFF) / 255.0
    let b = Double(v & 0xFF) / 255.0
    self = Color(red: r, green: g, blue: b)
  }
}

/// List and basic editor scaffold for sync tuples.
struct SyncListView: View {
  @EnvironmentObject var appState: AppState
  @State private var selection: UUID?
  @State private var isPresentingEditor: Bool = false
  @Environment(\.modelContext) private var context
  @Query(sort: \SDSyncConfig.name) private var storedSyncs: [SDSyncConfig]

  var body: some View {
    NavigationSplitView {
      List(appState.syncs, selection: $selection) { sync in
        HStack {
          VStack(alignment: .leading) {
            Text(sync.name)
            Text(sync.mode == .blocker ? "Blocker-only" : "Full info")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Toggle("Enabled", isOn: binding(for: sync).enabled)
            .labelsHidden()
        }
        .contextMenu {
          Button("Edit") {
            selection = sync.id
            isPresentingEditor = true
          }
          Button(role: .destructive) {
            appState.deleteSync(id: sync.id)
          } label: {
            Text("Delete")
          }
        }
        .tag(sync.id)
      }
      .toolbar {
        Button(action: { appState.addSync() }) { Label("New Sync", systemImage: "plus") }
        Button(action: { if let sel = selection { appState.deleteSync(id: sel) } }) {
          Label("Delete", systemImage: "trash")
        }
      }
    } detail: {
      if let sel = selection, let sync = appState.syncs.first(where: { $0.id == sel }) {
        SyncEditorView(sync: binding(for: sync))
      } else {
        ContentUnavailableView("Select a Sync", systemImage: "calendar")
      }
    }
    .sheet(isPresented: $isPresentingEditor) {
      if let sel = selection, let sync = appState.syncs.first(where: { $0.id == sel }) {
        SyncEditorView(sync: binding(for: sync))
          .padding()
      }
    }
    .onAppear {
      // Sync selection with global selection if present (e.g., opened from menu)
      if let target = appState.selectedSyncId {
        selection = target
      }
      if appState.syncs.isEmpty && !storedSyncs.isEmpty {
        appState.syncs = storedSyncs.map { $0.toUI() }
      }
    }
    .onChange(of: appState.syncs) { _, newValue in
      let existingById = Dictionary(uniqueKeysWithValues: storedSyncs.map { ($0.id, $0) })
      var seen: Set<UUID> = []
      for ui in newValue {
        seen.insert(ui.id)
        if let existing = existingById[ui.id] {
          existing.name = ui.name
          existing.sourceCalendarId = ui.sourceCalendarId
          existing.targetCalendarId = ui.targetCalendarId
          existing.modeRaw = ui.mode.rawValue
          existing.blockerTitleTemplate = ui.blockerTitleTemplate
          existing.horizonDaysOverride = ui.horizonDaysOverride
          existing.enabled = ui.enabled
          existing.updatedAt = Date()
          existing.filters = ui.filters.map {
            SDFilterRule(
              id: $0.id, typeRaw: $0.type.rawValue, pattern: $0.pattern,
              caseSensitive: $0.caseSensitive)
          }
          existing.timeWindows = ui.timeWindows.map {
            SDTimeWindow(
              id: $0.id, weekdayRaw: $0.weekday.rawValue, startHour: $0.start.hour,
              startMinute: $0.start.minute, endHour: $0.end.hour, endMinute: $0.end.minute)
          }
        } else {
          let model = SDSyncConfig.fromUI(ui)
          context.insert(model)
        }
      }
      for model in storedSyncs where !seen.contains(model.id) {
        context.delete(model)
      }
      try? context.save()
    }
  }

  private func binding(for sync: SyncConfigUI) -> Binding<SyncConfigUI> {
    guard let idx = appState.syncs.firstIndex(of: sync) else {
      return .constant(sync)
    }
    return $appState.syncs[idx]
  }
}

/// Editor UI for a single sync tuple with a live right-hand preview panel.
struct SyncEditorView: View {
  @Binding var sync: SyncConfigUI
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var auth: EventKitAuth
  /// Calendar loader used to populate `appState.availableCalendars` for the pickers.
  @EnvironmentObject var calendars: EventKitCalendars
  /// Optional action to navigate to the app Settings in the current window context.
  var onRequestSettings: (() -> Void)? = nil
  @Environment(\.modelContext) private var context

  // MARK: Preview State
  /// Lightweight representation of a create action preview.
  /// Why: Avoid leaking `EKEvent` details to the view; keep UI-friendly data only.
  private struct PreviewPair: Identifiable {
    let id: String
    let sourceTitle: String
    let sourceStart: Date
    let sourceEnd: Date
    let targetTitle: String
    let targetStart: Date
    let targetEnd: Date
    let included: Bool
    // Extra details for popover
    let sourceNotes: String
    let repeats: Bool
    let statusLabel: String
    let attendeesCount: Int
    let availabilityLabel: String
  }
  @State private var createPreviews: [PreviewPair] = []
  @State private var isLoadingPreview: Bool = false
  @State private var previewError: String? = nil
  @State private var activePreview: PreviewPair? = nil
  /// Background task that performs the heavy preview computation.
  /// Why: Fetching events and building previews can be expensive; we offload to avoid blocking the UI thread.
  @State private var previewComputeTask: Task<Void, Never>? = nil
  /// Debounce task that delays firing `refreshPreview()` while the user is actively editing.
  /// Why: Prevents running many expensive preview computations during rapid config changes.
  @State private var refreshDebounceTask: Task<Void, Never>? = nil
  /// Debounce interval for preview, in milliseconds. Tuned to feel responsive but not chatty.
  private let previewDebounceMs: UInt64 = 350
  /// Pixel-perfect leading inset so primary text labels align with menu-based pickers.
  /// Match the intrinsic leading used by `CalendarMenuPicker` label spacing.
  private let fieldLabelLeading: CGFloat = 16

  /// Shared date formatter for concise date-time display in preview.
  private static let previewDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  var body: some View {
    // Align editor content to the top so the form starts at the same vertical origin as the preview.
    // Why: Improves visual hierarchy and ensures the first field is immediately visible when adding a sync.
    HStack(alignment: .top, spacing: 16) {
      // LEFT: Editor form
      Form {
        // Basic
        Section(header: sectionHeader("Basic").padding(.top, 14).padding(.bottom, 4)) {
          // Name label above field, with Enabled toggle kept inline to the right for quick access.
          VStack(alignment: .leading, spacing: 4) {
            Text("Name").padding(.horizontal, fieldLabelLeading / 2)
            HStack {
              TextField("", text: $sync.name, prompt: Text("Name"))
                .padding(.vertical, 4)
              Toggle(isOn: $sync.enabled) { Text("Enabled") }
            }
          }
          .padding(.leading, fieldLabelLeading)
          // Source and Target side-by-side for quicker scanning and less vertical space.
          HStack(alignment: .top, spacing: 24) {
            // Source selection using a Menu (reliably renders icons/colors on macOS)
            CalendarMenuPicker(
              title: "Source",
              calendars: appState.availableCalendars,
              selection: $sync.sourceCalendarId,
              writableOnly: false
            )
            .disabled(!auth.hasReadAccess)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Target selection (writable only)
            CalendarMenuPicker(
              title: "Target",
              calendars: appState.availableCalendars,
              selection: $sync.targetCalendarId,
              writableOnly: true
            )
            .disabled(!auth.hasReadAccess)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          if !auth.hasReadAccess {
            VStack(alignment: .leading, spacing: 4) {
              Text("Calendar access is required to select calendars.")
                .font(.caption)
                .foregroundStyle(.secondary)
              Button("Open Settings to request access") { onRequestSettings?() }
                .font(.caption)
            }
          }
          if sync.sourceCalendarId == sync.targetCalendarId && !sync.sourceCalendarId.isEmpty {
            Text("Source and target must differ").font(.caption).foregroundStyle(.red)
          }
        }

        // Sync Mode
        Section(header: sectionHeader("Sync Mode").padding(.top, 24).padding(.bottom, 4)) {
          // Hide the inline "Mode" label for a cleaner look under the section heading.
          Picker("", selection: $sync.mode) {
            Text("Full info").tag(SyncMode.full)
            Text("Blocker-only").tag(SyncMode.blocker)
          }
          .labelsHidden()
          .padding(.vertical, 4)
          if sync.mode == .blocker {
            // Show label above template field to match Name layout for consistency.
            VStack(alignment: .leading, spacing: 4) {
              Text("Blocker Title Template").padding(.horizontal, fieldLabelLeading / 2)
              TextField(
                "",
                text: Binding(
                  get: { sync.blockerTitleTemplate ?? "" },
                  set: { sync.blockerTitleTemplate = $0.isEmpty ? nil : $0 }
                ), prompt: Text("Blocker Title Template")
              )
              .padding(.vertical, 4)
            }
            .padding(.leading, fieldLabelLeading)
            Text(
              "Use placeholders like {sourceTitle} to include the source event’s title in the blocker title."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
          }
        }

        // Lookahead (per-sync horizon override)
        // Why: Allow a sync to look further ahead or closer in than the app default when
        //      planning which future events to mirror. This writes to `horizonDaysOverride`,
        //      which is an optional to indicate "use default" when nil.
        Section(header: sectionHeader("Lookahead").padding(.top, 24).padding(.bottom, 4)) {
          HStack(alignment: .firstTextBaseline) {
            Toggle(
              "Override lookahead",
              isOn: Binding(
                get: { sync.horizonDaysOverride != nil },
                set: { isOn in
                  if isOn {
                    // Initialize with a sane value: keep existing override if present,
                    // otherwise seed with the app default. Enforce minimum of 1 day.
                    sync.horizonDaysOverride = max(
                      sync.horizonDaysOverride ?? appState.defaultHorizonDays, 1)
                  } else {
                    // Clearing the override falls back to the app default horizon.
                    sync.horizonDaysOverride = nil
                  }
                }
              )
            )
            .padding(.vertical, 4)
            if sync.horizonDaysOverride != nil {
              Stepper(
                value: Binding(
                  get: { sync.horizonDaysOverride ?? appState.defaultHorizonDays },
                  set: { newVal in sync.horizonDaysOverride = newVal }
                ), in: 1...365
              ) {
                Text("\(sync.horizonDaysOverride ?? appState.defaultHorizonDays) days")
              }
              .frame(width: 220, alignment: .leading)
            } else {
              Text("\(appState.defaultHorizonDays) days")
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
          Text(
            "How far into the future to look when planning this sync. Leave off to use the app default."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        // Filters
        // Why: After a filter is added via the "Add Filter" menu, the attribute cannot be changed inline.
        //      Users adjust only the operator (appropriate to that attribute) and the value.
        //      Layout: Title row (attribute + delete), Operator row (picker), Value row (input), divider.
        Section(header: sectionHeader("Filters").padding(.top, 24).padding(.bottom, 4)) {
          VStack(alignment: .leading, spacing: 8) {

            ForEach($sync.filters) { $rule in
              VStack(alignment: .leading, spacing: 6) {
                // Title row: Attribute summary (immutable) + delete button on the right.
                HStack(alignment: .firstTextBaseline) {
                  Text(
                    "Title: Filter for Attribute \(attributeDisplayName(for: group(for: rule.type)))"
                  )
                  Spacer()
                  Button(role: .destructive) {
                    removeRule(rule.id)
                  } label: {
                    Image(systemName: "trash")
                  }
                }

                // Operator row: Operators permitted for this attribute.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text("Operator").frame(width: 120, alignment: .leading)
                  Picker("Operator", selection: $rule.type) {
                    ForEach(operatorChoices(for: group(for: rule.type))) { choice in
                      Text(operatorLabel(for: choice)).tag(choice.id)
                    }
                  }
                  .labelsHidden()
                  .frame(width: 260, alignment: .leading)
                  Spacer()
                }

                // Value row: keep the row in the layout to avoid reflow when switching operators.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text("Value").frame(width: 120, alignment: .leading)
                  if requiresValue(rule.type) {
                    TextField(valuePlaceholder(for: rule.type), text: $rule.pattern)
                  } else {
                    // Preserve layout height while visually hiding the input when not needed.
                    TextField("", text: .constant(""))
                      .disabled(true)
                      .opacity(0)
                  }
                  Spacer()
                }
                Divider()
              }
              .padding(.vertical, 6)
            }
            HStack {
              Menu("Add Filter") {
                // First level: Property → second level: Operation
                Menu("Title") {
                  Button("Includes") { addRule(.includeTitle) }
                  Button("Excludes") { addRule(.excludeTitle) }
                }
                Menu("Notes") {
                  Button("Includes") { addRule(.includeNotes) }
                  Button("Excludes") { addRule(.excludeNotes) }
                }
                Menu("Attendees") {
                  Button("Includes") { addRule(.includeAttendee) }
                  Button("Does not include") { addRule(.excludeAttendee) }
                  Divider()
                  Button("Count above…") { addRule(.attendeesCountAbove) }
                  Button("Count below…") { addRule(.attendeesCountBelow) }
                }
                Menu("Duration") {
                  Button("Longer than… (minutes)") { addRule(.durationLongerThan) }
                  Button("Shorter than… (minutes)") { addRule(.durationShorterThan) }
                  Divider()
                  Button("Include all-day events") { addRule(.includeAllDay) }
                  Button("Exclude all-day events") { addRule(.excludeAllDay) }
                }
                Menu("Status") {
                  Button("Only accepted") { addRule(.onlyAccepted) }
                  Button("Accepted or maybe") { addRule(.acceptedOrMaybe) }
                }
                Menu("Availability") {
                  Button("Busy") { addRule(.availabilityBusy) }
                  Button("Free") { addRule(.availabilityFree) }
                }
                Menu("Repeating") {
                  Button("Is repeating") { addRule(.isRepeating) }
                  Button("Is not repeating") { addRule(.isNotRepeating) }
                }
                Menu("Synced items") {
                  Button("Exclude items from other syncs") { addRule(.ignoreOtherTuples) }
                }
              }
            }
          }
        }

        Section(header: sectionHeader("Time Windows").padding(.top, 24).padding(.bottom, 4)) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach($sync.timeWindows) { $tw in
              HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                  Text("Day")
                  Picker("", selection: $tw.weekday) {
                    ForEach(Weekday.allCases) { d in Text(d.label).tag(d) }
                  }
                  .labelsHidden()
                  .frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                  Text("Start")
                  DatePicker(
                    "",
                    selection: Binding(
                      get: { tw.start.asDate() }, set: { tw.start = TimeOfDay.from(date: $0) }),
                    displayedComponents: .hourAndMinute
                  )
                  .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                  Text("End")
                  DatePicker(
                    "",
                    selection: Binding(
                      get: { tw.end.asDate() }, set: { tw.end = TimeOfDay.from(date: $0) }),
                    displayedComponents: .hourAndMinute
                  )
                  .labelsHidden()
                }
                Button(role: .destructive) {
                  removeTimeWindow(tw.id)
                } label: {
                  Image(systemName: "trash")
                }
                .padding(.top, 20)
                Spacer()
              }
              .padding(.vertical, 4)
              Divider()
            }
            Button {
              addTimeWindow()
            } label: {
              Label("Add Time Window", systemImage: "plus")
            }
          }
        }
      }
      .frame(minWidth: 500, minHeight: 420)
      .padding()

      Divider()

      // RIGHT: Preview pane showing all source events within horizon
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Preview").font(.headline)
          Text("(all events in horizon; filtered appear faded)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Spacer()
          Button(action: refreshPreview) {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .disabled(isPreviewDisabled)
        }

        if isPreviewDisabled {
          previewDisabledMessage
        } else if isLoadingPreview {
          ProgressView("Computing preview…")
        } else if let error = previewError {
          Text(error).foregroundStyle(.red)
        } else if createPreviews.isEmpty {
          Text("No new events would be created in the current horizon.")
            .foregroundStyle(.secondary)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              ForEach(createPreviews) { pair in
                VStack(alignment: .leading, spacing: 6) {
                  HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                      Text("Original")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                      Text(pair.sourceTitle.isEmpty ? "(No title)" : pair.sourceTitle)
                        .font(.body)
                        .lineLimit(2)
                      Text(
                        "\(Self.previewDateFormatter.string(from: pair.sourceStart)) → \(Self.previewDateFormatter.string(from: pair.sourceEnd))"
                      )
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .leading, spacing: 2) {
                      Text("Would create")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                      Text(pair.targetTitle.isEmpty ? "(No title)" : pair.targetTitle)
                        .font(.body)
                        .lineLimit(2)
                      Text(
                        "\(Self.previewDateFormatter.string(from: pair.targetStart)) → \(Self.previewDateFormatter.string(from: pair.targetEnd))"
                      )
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    }
                  }
                  Divider()
                }
                .opacity(pair.included ? 1.0 : 0.4)
                .contentShape(Rectangle())
                .onTapGesture { activePreview = pair }
                // Attach the popover to each row so it anchors above/below the clicked item,
                // not to the container (which can place it at the side).
                .popover(
                  item: Binding(
                    get: { activePreview?.id == pair.id ? activePreview : nil },
                    set: { newValue in if newValue == nil { activePreview = nil } }
                  ),
                  attachmentAnchor: .rect(.bounds),
                  arrowEdge: .top
                ) { item in
                  VStack(alignment: .leading, spacing: 8) {
                    Text(item.sourceTitle.isEmpty ? "(No title)" : item.sourceTitle)
                      .font(.headline)
                    if !item.sourceNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                      Text(item.sourceNotes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                    }
                    Divider()
                    Label {
                      Text("Start: \(Self.previewDateFormatter.string(from: item.sourceStart))")
                    } icon: {
                      Image(systemName: "calendar")
                    }
                    .font(.caption)
                    Label {
                      Text("End: \(Self.previewDateFormatter.string(from: item.sourceEnd))")
                    } icon: {
                      Image(systemName: "calendar")
                    }
                    .font(.caption)
                    Label {
                      Text("Repeats: \(item.repeats ? "Yes" : "No")")
                    } icon: {
                      Image(systemName: item.repeats ? "arrow.triangle.2.circlepath" : "minus")
                    }
                    .font(.caption)
                    Label {
                      Text("Status: \(item.statusLabel)")
                    } icon: {
                      Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    .font(.caption)
                    Label {
                      Text("Attendees: \(item.attendeesCount)")
                    } icon: {
                      Image(systemName: "person.2")
                    }
                    .font(.caption)
                    Label {
                      Text("Availability: \(item.availabilityLabel)")
                    } icon: {
                      Image(systemName: "clock")
                    }
                    .font(.caption)
                  }
                  .padding(12)
                  .frame(minWidth: 320, maxWidth: 400)
                }
              }
            }
            .padding(.vertical, 4)
          }
          .frame(minWidth: 360)
        }
        Spacer()
      }
      .frame(minWidth: 380, maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
      .padding()
    }
    // Add subtle top spacing so the editor content does not feel cramped against the sheet/window chrome.
    .padding(.top, 12)
    // Keep calendar options in sync when permission changes without requiring app restart.
    .onChange(of: auth.status) { _, _ in
      calendars.reload(authorized: auth.hasReadAccess)
      appState.availableCalendars = calendars.calendars
      refreshPreview()
    }
    .onAppear { refreshPreview() }
    // Refresh preview on key edits that influence the plan.
    .onChange(of: sync.sourceCalendarId) { _, _ in schedulePreviewRefreshDebounced() }
    .onChange(of: sync.targetCalendarId) { _, _ in schedulePreviewRefreshDebounced() }
    .onChange(of: sync.mode) { _, _ in schedulePreviewRefreshDebounced() }
    .onChange(of: sync.blockerTitleTemplate) { _, _ in schedulePreviewRefreshDebounced() }
    .onChange(of: sync.horizonDaysOverride) { _, _ in schedulePreviewRefreshDebounced() }
    .onChange(of: appState.defaultHorizonDays) { _, _ in schedulePreviewRefreshDebounced() }
    .onChange(of: sync.filters) { _, _ in schedulePreviewRefreshDebounced() }
    .onChange(of: sync.timeWindows) { _, _ in schedulePreviewRefreshDebounced() }
  }

  private func addRule(_ type: FilterRuleType) {
    sync.filters.append(FilterRuleUI(type: type))
  }
  private func removeRule(_ id: UUID) { sync.filters.removeAll { $0.id == id } }

  private func addTimeWindow() {
    sync.timeWindows.append(
      TimeWindowUI(weekday: .monday, start: .default, end: TimeOfDay(hour: 17, minute: 0)))
  }
  private func removeTimeWindow(_ id: UUID) { sync.timeWindows.removeAll { $0.id == id } }

  // MARK: - Preview helpers
  /// Whether preview is currently disabled due to missing permissions or invalid selection.
  private var isPreviewDisabled: Bool {
    !auth.hasReadAccess || sync.sourceCalendarId.isEmpty || sync.targetCalendarId.isEmpty
      || sync.sourceCalendarId == sync.targetCalendarId
  }

  /// Human-friendly explanation for why the preview is disabled.
  private var previewDisabledMessage: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !auth.hasReadAccess {
        Text("Grant calendar access to compute a preview.")
      } else if sync.sourceCalendarId.isEmpty || sync.targetCalendarId.isEmpty {
        Text("Select both source and target calendars to compute a preview.")
      } else if sync.sourceCalendarId == sync.targetCalendarId {
        Text("Source and target calendars must differ to compute a preview.")
      } else if !sync.enabled {
        Text("Enable this sync to preview planned creations.")
      }
    }
    .foregroundStyle(.secondary)
  }

  /// Schedules a debounced preview refresh after a short delay, cancelling any in-flight debounce.
  /// How: Uses a `Task` that sleeps for `previewDebounceMs` and then invokes `refreshPreview()`.
  ///      Subsequent calls cancel the prior task to ensure only the last edit triggers a refresh.
  private func schedulePreviewRefreshDebounced() {
    refreshDebounceTask?.cancel()
    refreshDebounceTask = Task { @MainActor in
      // Sleep uses nanoseconds; convert ms → ns.
      try? await Task.sleep(nanoseconds: previewDebounceMs * 1_000_000)
      if Task.isCancelled { return }
      refreshPreview()
    }
  }

  /// Computes a non-destructive, comprehensive preview of source events in horizon.
  /// How: Offloads EventKit reads and rules application to a background task, then publishes
  ///      UI-friendly pairs back on the main thread. Excluded items are shown at 40% opacity.
  private func refreshPreview() {
    createPreviews.removeAll()
    previewError = nil
    // Always cancel any ongoing compute before deciding whether to proceed.
    previewComputeTask?.cancel()
    // If disabled (e.g., missing permissions or invalid selection), stop here with no spinner.
    guard !isPreviewDisabled else {
      isLoadingPreview = false
      return
    }
    isLoadingPreview = true

    // Snapshot inputs for thread-safety and determinism across the async boundary.
    let syncSnapshot = sync
    let defaultHorizonDays = appState.defaultHorizonDays

    previewComputeTask = Task.detached(priority: .userInitiated) {
      [syncSnapshot, defaultHorizonDays] in
      if Task.isCancelled { return }

      let store = EKEventStore()
      let horizonDays = syncSnapshot.horizonDaysOverride ?? defaultHorizonDays
      let windowStart = Date()
      let windowEnd = Date().addingTimeInterval(TimeInterval(horizonDays * 24 * 3600))
      guard let sourceCal = store.calendar(withIdentifier: syncSnapshot.sourceCalendarId) else {
        await MainActor.run { isLoadingPreview = false }
        return
      }

      // Fetch source events within the planning window
      let sourcePredicate = store.predicateForEvents(
        withStart: windowStart, end: windowEnd, calendars: [sourceCal])
      let sourceEvents = store.events(matching: sourcePredicate)

      if Task.isCancelled { return }

      // Sort by start ascending for stable UI
      let sorted = sourceEvents.sorted { (a, b) in
        let aS = a.startDate ?? .distantPast
        let bS = b.startDate ?? .distantPast
        return aS < bS
      }

      var pairs: [PreviewPair] = []
      pairs.reserveCapacity(sorted.count)
      for ev in sorted {
        if Task.isCancelled { return }
        let title = ev.title ?? ""
        let start = ev.startDate ?? Date()
        let end = ev.endDate ?? start
        let organizerName = ev.organizer?.name ?? ev.organizer?.url.absoluteString
        let attendees: [String] = (ev.attendees ?? []).compactMap {
          $0.name ?? $0.url.absoluteString
        }
        let durationMinutes: Int? = {
          guard let s = ev.startDate, let e = ev.endDate else { return nil }
          return max(0, Int(e.timeIntervalSince(s) / 60.0))
        }()
        let isAllDay = ev.isAllDay
        let isStatusConfirmed: Bool
        let isStatusTentative: Bool
        switch ev.status {
        case .confirmed:
          isStatusConfirmed = true
          isStatusTentative = false
        case .tentative:
          isStatusConfirmed = false
          isStatusTentative = true
        default:
          isStatusConfirmed = false
          isStatusTentative = false
        }

        let passes = SyncRules.passesFilters(
          title: title,
          location: ev.location,
          notes: ev.notes,
          organizer: organizerName,
          attendees: attendees,
          durationMinutes: durationMinutes,
          isAllDay: isAllDay,
          isStatusConfirmed: isStatusConfirmed,
          isStatusTentative: isStatusTentative,
          filters: syncSnapshot.filters,
          sourceNotes: ev.notes,
          sourceURLString: ev.url?.absoluteString,
          configId: syncSnapshot.id
        )
        let allowed = SyncRules.allowedByTimeWindows(
          start: ev.startDate, isAllDay: isAllDay, windows: syncSnapshot.timeWindows)
        let included = passes && allowed

        let targetTitle: String
        switch syncSnapshot.mode {
        case .full:
          targetTitle = title
        case .blocker:
          let template = (syncSnapshot.blockerTitleTemplate ?? "Busy")
          targetTitle = template.replacingOccurrences(of: "{sourceTitle}", with: title)
        }

        let id =
          "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)-\(title)-\(pairs.count)"
        let availabilityLabel: String = {
          switch ev.availability {
          case .busy: return "Busy"
          case .free: return "Free"
          case .tentative: return "Tentative"
          case .unavailable: return "Unavailable"
          default: return "Not set"
          }
        }()
        pairs.append(
          PreviewPair(
            id: id,
            sourceTitle: title,
            sourceStart: start,
            sourceEnd: end,
            targetTitle: targetTitle,
            targetStart: start,
            targetEnd: end,
            included: included,
            sourceNotes: ev.notes ?? "",
            repeats: ev.hasRecurrenceRules,
            statusLabel: {
              switch ev.status {
              case .confirmed: return "Accepted"
              case .tentative: return "Maybe"
              case .canceled: return "Declined"
              default: return "Unknown"
              }
            }(),
            attendeesCount: ev.attendees?.count ?? 0,
            availabilityLabel: availabilityLabel
          ))
      }

      await MainActor.run {
        if Task.isCancelled { return }
        createPreviews = pairs
        isLoadingPreview = false
      }
    }
  }
}

// MARK: - Filter helpers (attribute grouping, operators, and value requirements)
extension SyncEditorView {
  /// Canonical grouping for `FilterRuleType` to derive attribute and operator sets.
  fileprivate enum FilterAttributeGroup {
    case title, location, notes, organizer, attendees, duration, allDay, status, attendeesCount,
      repeating, availability, syncedItems
  }

  /// Display name for the attribute group used in the Title row.
  fileprivate func attributeDisplayName(for group: FilterAttributeGroup) -> String {
    switch group {
    case .title: return "Title"
    case .location: return "Location"
    case .notes: return "Notes"
    case .organizer: return "Organizer"
    case .attendees: return "Attendees"
    case .duration: return "Duration"
    case .allDay: return "All-day"
    case .status: return "Status"
    case .attendeesCount: return "Attendees Count"
    case .repeating: return "Repeating"
    case .availability: return "Availability"
    case .syncedItems: return "Synced items"
    }
  }

  /// Determine the attribute group for a specific rule type.
  fileprivate func group(for type: FilterRuleType) -> FilterAttributeGroup {
    switch type {
    case .includeTitle, .excludeTitle, .includeRegex, .excludeRegex:
      return .title
    case .includeLocation, .excludeLocation, .includeLocationRegex, .excludeLocationRegex:
      return .location
    case .includeNotes, .excludeNotes, .includeNotesRegex, .excludeNotesRegex:
      return .notes
    case .includeOrganizer, .excludeOrganizer, .includeOrganizerRegex, .excludeOrganizerRegex:
      return .organizer
    case .includeAttendee, .excludeAttendee:
      return .attendees
    case .durationLongerThan, .durationShorterThan:
      return .duration
    case .includeAllDay, .excludeAllDay:
      return .allDay
    case .onlyAccepted, .acceptedOrMaybe:
      return .status
    case .attendeesCountAbove, .attendeesCountBelow:
      return .attendeesCount
    case .isRepeating, .isNotRepeating:
      return .repeating
    case .availabilityBusy, .availabilityFree:
      return .availability
    case .ignoreOtherTuples:
      return .syncedItems
    }
  }

  fileprivate struct OperatorChoice: Identifiable, Hashable {
    let id: FilterRuleType
    var label: String { id.label }
  }

  /// Available operators for an attribute group.
  fileprivate func operatorChoices(for group: FilterAttributeGroup) -> [OperatorChoice] {
    switch group {
    case .title:
      return [
        .init(id: .includeTitle), .init(id: .excludeTitle), .init(id: .includeRegex),
        .init(id: .excludeRegex),
      ]
    case .location:
      return [
        .init(id: .includeLocation), .init(id: .excludeLocation), .init(id: .includeLocationRegex),
        .init(id: .excludeLocationRegex),
      ]
    case .notes:
      return [
        .init(id: .includeNotes), .init(id: .excludeNotes), .init(id: .includeNotesRegex),
        .init(id: .excludeNotesRegex),
      ]
    case .organizer:
      return [
        .init(id: .includeOrganizer), .init(id: .excludeOrganizer),
        .init(id: .includeOrganizerRegex), .init(id: .excludeOrganizerRegex),
      ]
    case .attendees:
      return [.init(id: .includeAttendee), .init(id: .excludeAttendee)]
    case .duration:
      return [.init(id: .durationLongerThan), .init(id: .durationShorterThan)]
    case .allDay:
      return [.init(id: .includeAllDay), .init(id: .excludeAllDay)]
    case .status:
      return [.init(id: .onlyAccepted), .init(id: .acceptedOrMaybe)]
    case .attendeesCount:
      return [.init(id: .attendeesCountAbove), .init(id: .attendeesCountBelow)]
    case .repeating:
      return [.init(id: .isRepeating), .init(id: .isNotRepeating)]
    case .availability:
      return [.init(id: .availabilityBusy), .init(id: .availabilityFree)]
    case .syncedItems:
      return [.init(id: .ignoreOtherTuples)]
    }
  }

  /// Whether the selected operator requires an input value.
  fileprivate func requiresValue(_ type: FilterRuleType) -> Bool {
    switch type {
    case .includeTitle, .excludeTitle, .includeRegex, .excludeRegex,
      .includeLocation, .excludeLocation, .includeLocationRegex, .excludeLocationRegex,
      .includeNotes, .excludeNotes, .includeNotesRegex, .excludeNotesRegex,
      .includeOrganizer, .excludeOrganizer, .includeOrganizerRegex, .excludeOrganizerRegex,
      .includeAttendee, .excludeAttendee,
      .durationLongerThan, .durationShorterThan,
      .attendeesCountAbove, .attendeesCountBelow:
      return true
    case .includeAllDay, .excludeAllDay, .onlyAccepted, .acceptedOrMaybe,
      .isRepeating, .isNotRepeating, .availabilityBusy, .availabilityFree,
      .ignoreOtherTuples:
      return false
    }
  }

  /// Contextual placeholder for the value input.
  fileprivate func valuePlaceholder(for type: FilterRuleType) -> String {
    switch type {
    case .durationLongerThan, .durationShorterThan:
      return "Minutes"
    case .attendeesCountAbove, .attendeesCountBelow:
      return "Count"
    case .includeAttendee, .excludeAttendee:
      return "Name or email"
    case .includeRegex, .excludeRegex, .includeLocationRegex, .excludeLocationRegex,
      .includeNotesRegex, .excludeNotesRegex, .includeOrganizerRegex, .excludeOrganizerRegex:
      return "Regex pattern"
    default:
      return "Text"
    }
  }

  /// Provide display for operator choices using the underlying label from `FilterRuleType`.
  fileprivate func operatorLabel(for choice: OperatorChoice) -> String { choice.label }
}

// MARK: - UI helpers
extension SyncEditorView {
  /// Renders a full-width, left-aligned section header with a slightly larger font and subtle divider line beneath.
  /// Why: Improves scannability and visually separates sections across the entire editor width.
  fileprivate func sectionHeader(_ title: String) -> some View {
    VStack(spacing: 6) {
      Text(title)
        .font(.title3)
        .frame(maxWidth: .infinity, alignment: .leading)
      Divider()
        .frame(maxWidth: .infinity)
    }
  }
}

/// A macOS-friendly calendar selector using `Menu` that reliably displays icons and colors in the menu items.
/// - Why: SwiftUI `Picker` in menu style can omit custom content/icon rendering in some contexts.
/// - How: Uses grouped `Menu` content with `Label` rows tinted via `symbolRenderingMode(.monochrome)` + `foregroundColor`.
private struct CalendarMenuPicker: View {
  var title: String
  var calendars: [CalendarOption]
  @Binding var selection: String
  var writableOnly: Bool

  var body: some View {
    // Render label above to avoid Form's label-column indentation and keep
    // consistent left alignment with other vertically labeled fields.
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
      Menu {
        let filtered = writableOnly ? calendars.filter { $0.isWritable } : calendars
        let groups = Dictionary(grouping: filtered, by: { $0.account })
        let accounts = groups.keys.sorted {
          $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        ForEach(accounts, id: \.self) { account in
          // Account header
          Text(account).font(.caption).foregroundStyle(.secondary)
          let options = (groups[account] ?? []).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
          }
          ForEach(options) { option in
            Button {
              selection = option.id
            } label: {
              if let hex = option.colorHex, let color = Color(hex: hex) {
                Text("●").foregroundColor(color) + Text(" \(option.name)")
              } else {
                Text("●").foregroundColor(.secondary) + Text(" \(option.name)")
              }
            }
          }
          Divider()
        }
      } label: {
        // Current selection summary
        let current = calendars.first(where: { $0.id == selection })
        let name = current?.name ?? "Select…"
        if let current, let hex = current.colorHex, let color = Color(hex: hex) {
          Text("●").foregroundColor(color) + Text(" \(name)")
        } else {
          Text("●").foregroundColor(.secondary) + Text(" \(name)")
        }
      }
      .menuStyle(.borderlessButton)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

#Preview {
  SyncListView().environmentObject(AppState())
}
