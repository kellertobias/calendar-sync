import SwiftUI
import EventKit

/// Editor UI for a single RSVP rule.
struct RuleEditorView: View {
  @Binding var rule: RuleConfigUI
  @EnvironmentObject var appState: AppState
  @EnvironmentObject var auth: EventKitAuth
  @EnvironmentObject var calendars: EventKitCalendars
  var onRequestSettings: (() -> Void)? = nil

  private let fieldLabelLeading: CGFloat = 16

  var body: some View {
    Form {
      Section(header: sectionHeader("Basic").padding(.top, 14).padding(.bottom, 4)) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Name").padding(.horizontal, fieldLabelLeading / 2)
          HStack {
            TextField("", text: $rule.name, prompt: Text("Name"))
              .padding(.vertical, 4)
            Toggle(isOn: $rule.enabled) { Text("Enabled") }
          }
        }
        .padding(.leading, fieldLabelLeading)

        HStack(alignment: .top, spacing: 24) {
          CalendarMenuPicker(
            title: "Watch Calendar",
            calendars: appState.availableCalendars,
            selection: $rule.watchCalendarId,
            writableOnly: false
          )
          .disabled(!auth.hasReadAccess)
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity, alignment: .leading)

          VStack(alignment: .leading, spacing: 4) {
            Text("Action")
            Picker("", selection: $rule.action) {
              Text("Accept").tag(RuleAction.accept)
              Text("Decline").tag(RuleAction.decline)
            }
            .labelsHidden()
            .frame(width: 180, alignment: .leading)
          }
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
      }

      // Invitation Filters
      Section(header: sectionHeader("Invitation Filters").padding(.top, 24).padding(.bottom, 4)) {
        filterEditor($rule.invitationFilters)
      }

      // Overlap Filters
      Section(header: sectionHeader("Overlap Filters").padding(.top, 24).padding(.bottom, 4)) {
        VStack(alignment: .leading, spacing: 6) {
          Text("At least one overlapping event must match these filters for the rule to apply.")
            .font(.caption)
            .foregroundStyle(.secondary)
          filterEditor($rule.overlapFilters)
        }
      }

      // Time Windows
      Section(header: sectionHeader("Time Windows").padding(.top, 24).padding(.bottom, 4)) {
        timeWindowsEditor($rule.timeWindows)
      }
    }
    .frame(minWidth: 500, minHeight: 420)
  }

  // MARK: - Reused sub-editors
  private func filterEditor(_ filters: Binding<[FilterRuleUI]>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(filters) { $fr in
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .firstTextBaseline) {
            Text("Filter \"\(attributeDisplayName(for: group(for: fr.type)))\"")
            Spacer()
            Button(role: .destructive) { filters.wrappedValue.removeAll { $0.id == fr.id } } label: {
              Image(systemName: "trash")
            }
          }
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Operator").frame(width: 120, alignment: .leading)
            Picker("Operator", selection: $fr.type) {
              ForEach(operatorChoices(for: group(for: fr.type))) { choice in
                Text(operatorLabel(for: choice)).tag(choice.id)
              }
            }
            .labelsHidden()
            .frame(width: 260, alignment: .leading)
            Spacer()
          }
          if requiresValue(fr.type) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("Value").frame(width: 120, alignment: .leading)
              TextField(valuePlaceholder(for: fr.type), text: $fr.pattern)
                .labelsHidden()
                .padding(.vertical, 4)
            }
            Spacer()
          }
          Divider()
        }
        .padding(.vertical, 6)
      }
      HStack {
        Menu("Add Filter") {
          Menu("Title") {
            Button("Includes") { filters.wrappedValue.append(.init(type: .includeTitle)) }
            Button("Excludes") { filters.wrappedValue.append(.init(type: .excludeTitle)) }
          }
          Menu("Notes") {
            Button("Includes") { filters.wrappedValue.append(.init(type: .includeNotes)) }
            Button("Excludes") { filters.wrappedValue.append(.init(type: .excludeNotes)) }
          }
          Menu("Attendees") {
            Button("Includes") { filters.wrappedValue.append(.init(type: .includeAttendee)) }
            Button("Does not include") { filters.wrappedValue.append(.init(type: .excludeAttendee)) }
            Divider()
            Button("Count above…") { filters.wrappedValue.append(.init(type: .attendeesCountAbove)) }
            Button("Count below…") { filters.wrappedValue.append(.init(type: .attendeesCountBelow)) }
          }
          Menu("Duration") {
            Button("Longer than… (minutes)") { filters.wrappedValue.append(.init(type: .durationLongerThan)) }
            Button("Shorter than… (minutes)") { filters.wrappedValue.append(.init(type: .durationShorterThan)) }
            Divider()
            Button("Include all-day events") { filters.wrappedValue.append(.init(type: .includeAllDay)) }
            Button("Exclude all-day events") { filters.wrappedValue.append(.init(type: .excludeAllDay)) }
            Button("Exclude all-day events when free") { filters.wrappedValue.append(.init(type: .excludeAllDayWhenFree)) }
          }
          Menu("Availability") {
            Button("Busy") { filters.wrappedValue.append(.init(type: .availabilityBusy)) }
            Button("Free") { filters.wrappedValue.append(.init(type: .availabilityFree)) }
          }
          Menu("Repeating") {
            Button("Is repeating") { filters.wrappedValue.append(.init(type: .isRepeating)) }
            Button("Is not repeating") { filters.wrappedValue.append(.init(type: .isNotRepeating)) }
          }
          Menu("Synced items") {
            Button("Exclude items from other syncs") { filters.wrappedValue.append(.init(type: .ignoreOtherTuples)) }
          }
        }
      }
    }
  }

  private func timeWindowsEditor(_ windows: Binding<[TimeWindowUI]>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      let sortedIndices = windows.wrappedValue
        .enumerated()
        .sorted { isTimeWindow($0.element, before: $1.element) }
        .map { $0.offset }
      ForEach(sortedIndices, id: \.self) { idx in
        let twBinding = windows[idx]
        let tw = windows.wrappedValue[idx]
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Day")
            Picker("", selection: twBinding.weekday) {
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
                get: { tw.start.asDate() },
                set: { newDate in twBinding.start.wrappedValue = TimeOfDay.from(date: newDate) }
              ),
              displayedComponents: .hourAndMinute
            )
            .labelsHidden()
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("End")
            DatePicker(
              "",
              selection: Binding(
                get: { tw.end.asDate() },
                set: { newDate in twBinding.end.wrappedValue = TimeOfDay.from(date: newDate) }
              ),
              displayedComponents: .hourAndMinute
            )
            .labelsHidden()
          }
          Button(role: .destructive) {
            windows.wrappedValue.removeAll { $0.id == tw.id }
          } label: { Image(systemName: "trash") }
          .padding(.top, 20)
          Spacer()
        }
        .padding(.vertical, 4)
        Divider()
      }
      Button {
        if let last = windows.wrappedValue.sorted(by: { isTimeWindow($0, before: $1) }).last {
          let newWin = TimeWindowUI(weekday: nextWeekday(after: last.weekday), start: last.start, end: last.end)
          windows.wrappedValue.append(newWin)
        } else {
          windows.wrappedValue.append(TimeWindowUI(weekday: .monday, start: .default, end: TimeOfDay(hour: 17, minute: 0)))
        }
      } label: {
        Label("Add Time Window", systemImage: "plus")
      }
    }
  }

  // MARK: - Helpers mirrored from SyncEditorView
  private func sectionHeader(_ title: String) -> some View {
    VStack(spacing: 6) {
      Text(title).font(.title3).frame(maxWidth: .infinity, alignment: .leading)
      Divider().frame(maxWidth: .infinity)
    }
  }

  private func isTimeWindow(_ a: TimeWindowUI, before b: TimeWindowUI) -> Bool {
    let weekdayOrder: [Weekday: Int] = [
      .monday: 1, .tuesday: 2, .wednesday: 3, .thursday: 4, .friday: 5, .saturday: 6, .sunday: 7,
    ]
    let aDay = weekdayOrder[a.weekday] ?? 8
    let bDay = weekdayOrder[b.weekday] ?? 8
    if aDay != bDay { return aDay < bDay }
    if a.start.hour != b.start.hour { return a.start.hour < b.start.hour }
    return a.start.minute < b.start.minute
  }

  private func nextWeekday(after day: Weekday) -> Weekday {
    switch day {
    case .monday: return .tuesday
    case .tuesday: return .wednesday
    case .wednesday: return .thursday
    case .thursday: return .friday
    case .friday: return .saturday
    case .saturday: return .sunday
    case .sunday: return .monday
    }
  }
}


