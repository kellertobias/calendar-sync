import SwiftUI
import SwiftData
import EventKit

// MARK: - Small helpers
private extension Color {
    /// Initialize from hex string like "#RRGGBB".
    init?(hex: String) {
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
                    Button("Edit") { selection = sync.id; isPresentingEditor = true }
                    Button(role: .destructive) { appState.deleteSync(id: sync.id) } label: { Text("Delete") }
                }
                .tag(sync.id)
            }
            .toolbar {
                Button(action: { appState.addSync() }) { Label("New Sync", systemImage: "plus") }
                Button(action: { if let sel = selection { appState.deleteSync(id: sel) } }) { Label("Delete", systemImage: "trash") }
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
                    existing.filters = ui.filters.map { SDFilterRule(id: $0.id, typeRaw: $0.type.rawValue, pattern: $0.pattern, caseSensitive: $0.caseSensitive) }
                    existing.timeWindows = ui.timeWindows.map { SDTimeWindow(id: $0.id, weekdayRaw: $0.weekday.rawValue, startHour: $0.start.hour, startMinute: $0.start.minute, endHour: $0.end.hour, endMinute: $0.end.minute) }
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
    }
    @State private var createPreviews: [PreviewPair] = []
    @State private var isLoadingPreview: Bool = false
    @State private var previewError: String? = nil

    /// Shared date formatter for concise date-time display in preview.
    private static let previewDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 16) {
            // LEFT: Editor form
            Form {
            // Basic
            Section(header: Text("Basic").padding(.top, 8).padding(.bottom, 4)) {
                HStack {
                    TextField("Name", text: $sync.name)
                        .padding(.vertical, 4)
                    Toggle("Enabled", isOn: $sync.enabled).labelsHidden()
                }
                // Source selection using a Menu (reliably renders icons/colors on macOS)
                CalendarMenuPicker(title: "Source",
                                   calendars: appState.availableCalendars,
                                   selection: $sync.sourceCalendarId,
                                   writableOnly: false)
                .disabled(!auth.hasReadAccess)
                .padding(.vertical, 4)
                // Target selection (writable only)
                CalendarMenuPicker(title: "Target",
                                   calendars: appState.availableCalendars,
                                   selection: $sync.targetCalendarId,
                                   writableOnly: true)
                .disabled(!auth.hasReadAccess)
                .padding(.vertical, 4)
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
            Section(header: Text("Sync Mode").padding(.top, 8).padding(.bottom, 4)) {
                Picker("Mode", selection: $sync.mode) {
                    Text("Full info").tag(SyncMode.full)
                    Text("Blocker-only").tag(SyncMode.blocker)
                }
                .padding(.vertical, 4)
                if sync.mode == .blocker {
                    TextField("Blocker Title Template", text: Binding(
                        get: { sync.blockerTitleTemplate ?? "" },
                        set: { sync.blockerTitleTemplate = $0.isEmpty ? nil : $0 }
                    ))
                    .padding(.vertical, 4)
                    Text("Use placeholders like {sourceTitle} to include the source event’s title in the blocker title.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                }
            }

            Section(header: Text("Filters").padding(.top, 8).padding(.bottom, 4)) {
                ForEach($sync.filters) { $rule in
                    HStack {
                        Picker("", selection: $rule.type) {
                            ForEach(FilterRuleType.allCases) { t in Text(t.label).tag(t) }
                        }
                        .labelsHidden()
                        .frame(width: 260, alignment: .leading)
                        // Pattern input where applicable
                        if rule.type != .ignoreOtherTuples && rule.type != .includeAllDay && rule.type != .excludeAllDay && rule.type != .onlyAccepted && rule.type != .acceptedOrMaybe {
                            TextField("Pattern", text: $rule.pattern)
                            // Case-sensitive only for textual filters
                            if rule.type != .durationLongerThan && rule.type != .durationShorterThan {
                                Toggle("Case-sensitive", isOn: $rule.caseSensitive)
                            }
                        } else {
                            Spacer()
                        }
                        Button(role: .destructive) { removeRule(rule.id) } label: { Image(systemName: "trash") }
                    }
                    .padding(.vertical, 4)
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
                        Menu("Synced items") {
                            Button("Exclude items from other syncs") { addRule(.ignoreOtherTuples) }
                        }
                    }
                }
            }

            Section(header: Text("Time Windows").padding(.top, 8).padding(.bottom, 4)) {
                ForEach($sync.timeWindows) { $tw in
                    HStack {
                        Picker("", selection: $tw.weekday) {
                            ForEach(Weekday.allCases) { d in Text(d.label).tag(d) }
                        }.labelsHidden().frame(width: 80)
                        DatePicker("Start", selection: Binding(get: { tw.start.asDate() }, set: { tw.start = TimeOfDay.from(date: $0) }), displayedComponents: .hourAndMinute)
                        DatePicker("End", selection: Binding(get: { tw.end.asDate() }, set: { tw.end = TimeOfDay.from(date: $0) }), displayedComponents: .hourAndMinute)
                        Button(role: .destructive) { removeTimeWindow(tw.id) } label: { Image(systemName: "trash") }
                    }
                    .padding(.vertical, 4)
                }
                Button { addTimeWindow() } label: { Label("Add Time Window", systemImage: "plus") }
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
                                            Text("\(Self.previewDateFormatter.string(from: pair.sourceStart)) → \(Self.previewDateFormatter.string(from: pair.sourceEnd))")
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
                                            Text("\(Self.previewDateFormatter.string(from: pair.targetStart)) → \(Self.previewDateFormatter.string(from: pair.targetEnd))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Divider()
                                }
                                .opacity(pair.included ? 1.0 : 0.4)
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
        // Keep calendar options in sync when permission changes without requiring app restart.
        .onChange(of: auth.status) { _, _ in
            calendars.reload(authorized: auth.hasReadAccess)
            appState.availableCalendars = calendars.calendars
            refreshPreview()
        }
        .onAppear { refreshPreview() }
        // Refresh preview on key edits that influence the plan.
        .onChange(of: sync.sourceCalendarId) { _, _ in refreshPreview() }
        .onChange(of: sync.targetCalendarId) { _, _ in refreshPreview() }
        .onChange(of: sync.mode) { _, _ in refreshPreview() }
        .onChange(of: sync.blockerTitleTemplate) { _, _ in refreshPreview() }
        .onChange(of: sync.horizonDaysOverride) { _, _ in refreshPreview() }
        .onChange(of: appState.defaultHorizonDays) { _, _ in refreshPreview() }
        .onChange(of: sync.filters) { _, _ in refreshPreview() }
        .onChange(of: sync.timeWindows) { _, _ in refreshPreview() }
    }

    private func addRule(_ type: FilterRuleType) {
        sync.filters.append(FilterRuleUI(type: type))
    }
    private func removeRule(_ id: UUID) { sync.filters.removeAll { $0.id == id } }

    private func addTimeWindow() {
        sync.timeWindows.append(TimeWindowUI(weekday: .monday, start: .default, end: TimeOfDay(hour: 17, minute: 0)))
    }
    private func removeTimeWindow(_ id: UUID) { sync.timeWindows.removeAll { $0.id == id } }

    // MARK: - Preview helpers
    /// Whether preview is currently disabled due to missing permissions or invalid selection.
    private var isPreviewDisabled: Bool {
        !auth.hasReadAccess || sync.sourceCalendarId.isEmpty || sync.targetCalendarId.isEmpty || sync.sourceCalendarId == sync.targetCalendarId
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

    /// Computes a non-destructive, comprehensive preview of source events in horizon.
    /// How: Reads from EventKit directly; applies `SyncRules` to determine inclusion, and computes
    ///      the would-be target fields (title and times) for display. Excluded items are shown at 40% opacity.
    private func refreshPreview() {
        createPreviews.removeAll()
        previewError = nil
        guard !isPreviewDisabled else { return }
        isLoadingPreview = true
        defer { isLoadingPreview = false }

        let store = EKEventStore()
        let horizonDays = sync.horizonDaysOverride ?? appState.defaultHorizonDays
        let windowStart = Date()
        let windowEnd = Date().addingTimeInterval(TimeInterval(horizonDays * 24 * 3600))
        guard let sourceCal = store.calendar(withIdentifier: sync.sourceCalendarId) else { return }

        // Fetch source events within the planning window
        let sourcePredicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [sourceCal])
        let sourceEvents = store.events(matching: sourcePredicate)

        // Sort by start ascending for stable UI
        let sorted = sourceEvents.sorted { (a, b) in
            let aS = a.startDate ?? .distantPast
            let bS = b.startDate ?? .distantPast
            return aS < bS
        }

        var pairs: [PreviewPair] = []
        for ev in sorted {
            let title = ev.title ?? ""
            let start = ev.startDate ?? Date()
            let end = ev.endDate ?? start
            let organizerName = ev.organizer?.name ?? ev.organizer?.url.absoluteString
            let attendees: [String] = (ev.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString }
            let durationMinutes: Int? = {
                guard let s = ev.startDate, let e = ev.endDate else { return nil }
                return max(0, Int(e.timeIntervalSince(s) / 60.0))
            }()
            let isAllDay = ev.isAllDay
            let isStatusConfirmed: Bool
            let isStatusTentative: Bool
            switch ev.status {
            case .confirmed: isStatusConfirmed = true; isStatusTentative = false
            case .tentative: isStatusConfirmed = false; isStatusTentative = true
            default: isStatusConfirmed = false; isStatusTentative = false
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
                filters: sync.filters,
                sourceNotes: ev.notes,
                sourceURLString: ev.url?.absoluteString,
                configId: sync.id
            )
            let allowed = SyncRules.allowedByTimeWindows(start: ev.startDate, isAllDay: isAllDay, windows: sync.timeWindows)
            let included = passes && allowed

            let targetTitle: String
            switch sync.mode {
            case .full:
                targetTitle = title
            case .blocker:
                let template = (sync.blockerTitleTemplate ?? "Busy")
                targetTitle = template.replacingOccurrences(of: "{sourceTitle}", with: title)
            }

            let id = "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)-\(title)-\(pairs.count)"
            pairs.append(PreviewPair(
                id: id,
                sourceTitle: title,
                sourceStart: start,
                sourceEnd: end,
                targetTitle: targetTitle,
                targetStart: start,
                targetEnd: end,
                included: included
            ))
        }
        createPreviews = pairs
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
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Menu {
                let filtered = writableOnly ? calendars.filter { $0.isWritable } : calendars
                let groups = Dictionary(grouping: filtered, by: { $0.account })
                let accounts = groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                ForEach(accounts, id: \.self) { account in
                    // Account header
                    Text(account).font(.caption).foregroundStyle(.secondary)
                    let options = (groups[account] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
            .frame(width: 300, alignment: .leading)
            Spacer()
        }
    }
}

#Preview {
    SyncListView().environmentObject(AppState())
}


