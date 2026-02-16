import SwiftUI
import EventKit
import SwiftData

struct CapExSettingsView: View {
  @Binding var config: CapExConfigUI
  @Binding var submitConfig: CapExSubmitConfigUI
  @EnvironmentObject var appState: AppState
  @Environment(\.modelContext) private var context
  @Query private var storedCapEx: [SDCapExConfig]
  
  @StateObject private var submissionService = CapExSubmissionService()
  @State private var showingAddRule = false
  @State private var editingRuleId: UUID?
  @State private var testOutput: String = ""
  @State private var showingTestOutput = false
  @State private var showSavedIndicator = false
  
  private let fieldLabelLeading: CGFloat = 16

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        
        // Configuration Section
        VStack(alignment: .leading, spacing: 8) {
             sectionHeader("Configuration")
             
             VStack(alignment: .leading, spacing: 12) {
                CalendarMenuPicker(
                    title: "Working Time Calendar",
                    calendars: appState.availableCalendars,
                    selection: $config.workingTimeCalendarId
                )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("History Period")
                    HStack {
                        Text("\(config.historyDays) days")
                        Spacer()
                        Stepper("", value: $config.historyDays, in: 7...365).labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
    
                VStack(alignment: .leading, spacing: 4) {
                    Text("CapEx Percentage")
                    HStack {
                        Text("\(config.capExPercentage)%")
                            .frame(width: 40, alignment: .trailing)
                        Slider(value: Binding(
                            get: { Double(config.capExPercentage) },
                            set: { config.capExPercentage = Int($0) }
                        ), in: 1...100, step: 1)
                    }
                    .padding(.vertical, 4)
                }
    
                Toggle("Show Daily Breakdown", isOn: $config.showDaily)
            }
            .padding(.leading, fieldLabelLeading)
        }

        // Exclusion Rules Section
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Exclusion Rules")
            
            VStack(alignment: .leading, spacing: 12) {
              if config.rules.isEmpty {
                  Text("No exclusion rules defined.")
                      .foregroundStyle(.secondary)
              } else {
                  ForEach(config.rules) { rule in
                      HStack(alignment: .top) {
                          VStack(alignment: .leading, spacing: 4) {
                              if let cal = appState.availableCalendars.first(where: { $0.id == rule.calendarId }) {
                                    if let color = Color(hex: cal.colorHex) {
                                      Text("●").foregroundColor(color) + Text(" \(cal.name)")
                                    } else {
                                      Text("●").foregroundColor(.secondary) + Text(" \(cal.name)")
                                    }
                              } else {
                                  Text("Unknown Calendar").foregroundStyle(.red)
                              }
                              
                              if let title = rule.titleFilter, !title.isEmpty {
                                  Text("Title: \(title)").font(.caption).foregroundStyle(.secondary)
                              }
                              if let part = rule.participantsFilter, !part.isEmpty {
                                  Text("Participants: \(part)").font(.caption).foregroundStyle(.secondary)
                              }
                              if (rule.titleFilter?.isEmpty ?? true) && (rule.participantsFilter?.isEmpty ?? true) {
                                  Text("All events").font(.caption).foregroundStyle(.secondary)
                              }
                          }
                          Spacer()
                          Button(action: { startEditing(rule: rule) }) {
                              Image(systemName: "pencil")
                                  .foregroundStyle(.blue)
                          }
                          .buttonStyle(.borderless)
                          .help("Edit rule")
                          
                          Button(action: { deleteRule(rule) }) {
                              Image(systemName: "trash")
                                  .foregroundStyle(.red)
                          }
                          .buttonStyle(.borderless)
                          .help("Delete rule")
                      }
                      .padding(.vertical, 4)
                      
                      Divider()
                  }
                  // Note: onDelete is not available outside List/ForEach native, so we need a different deletion UI or stick to List for this part?
                  // Providing a delete button in the row or edit sheet is safer.
                  // Let's add a delete button next to edit.
              }
            
              Button(action: { showingAddRule = true }) {
                Label("Add Exclusion Rule", systemImage: "plus")
              }
            }
            .padding(.leading, fieldLabelLeading)
        }
        
        // Script Submission Section
        VStack(alignment: .leading, spacing: 8) {
          sectionHeader("Submit Script")
          
          VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text("Script Template")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if showSavedIndicator {
                  Text("Saved")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .transition(.opacity)
                }
              }
              
              TextEditor(text: $submitConfig.scriptTemplate)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80)
                .padding(4)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                  RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
              
              Text("Use {{week_capex[0]}} for current week, {{week_capex[-1]}} for last week.\nAlso: {{week_number}}, {{start \"DD.MM.YYYY\"}}, {{end \"YYYY-MM-DD\"}}")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
              
              Divider().padding(.vertical, 8)
              
              // Schedule Toggle
              Toggle("Enable Scheduled Submission", isOn: $submitConfig.scheduleEnabled)
              
              if submitConfig.scheduleEnabled {
                // Schedule Days
                VStack(alignment: .leading, spacing: 4) {
                  Text("Run on Days")
                  HStack(spacing: 6) {
                    ForEach(Weekday.allCases) { day in
                      Button(action: { toggleDay(day) }) {
                        Text(day.label)
                          .font(.caption)
                          .padding(.horizontal, 8)
                          .padding(.vertical, 4)
                          .background(submitConfig.scheduleDays.contains(day) ? Color.accentColor : Color.gray.opacity(0.2))
                          .foregroundColor(submitConfig.scheduleDays.contains(day) ? .white : .primary)
                          .cornerRadius(4)
                      }
                      .buttonStyle(.plain)
                    }
                  }
                }
                
                // Schedule Time
                HStack {
                  Text("After")
                  Picker("Hour", selection: $submitConfig.scheduleAfterHour) {
                    ForEach(0..<24, id: \.self) { hour in
                      Text(String(format: "%02d", hour)).tag(hour)
                    }
                  }
                  .labelsHidden()
                  .frame(width: 60)
                  Text(":")
                  Picker("Minute", selection: $submitConfig.scheduleAfterMinute) {
                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { minute in
                      Text(String(format: "%02d", minute)).tag(minute)
                    }
                  }
                  .labelsHidden()
                  .frame(width: 60)
                  Spacer()
                }
              }
              
              Divider().padding(.vertical, 8)
              
              // Test & Status
              HStack {
                Button(action: { Task { await testScript() } }) {
                  if submissionService.isRunning {
                    ProgressView()
                      .controlSize(.small)
                      .padding(.trailing, 4)
                  }
                  Text(submissionService.isRunning ? "Running…" : "Test Script")
                }
                .disabled(submitConfig.scriptTemplate.isEmpty || submissionService.isRunning)
                
                Button(action: { Task { await submitNow() } }) {
                  Text("Submit Now")
                }
                .disabled(submitConfig.scriptTemplate.isEmpty || submissionService.isRunning)
                .buttonStyle(.borderedProminent)
                
                Spacer()
                
                if let lastSubmit = submitConfig.lastSubmittedAt {
                  Text("Last: \(lastSubmit.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              
              if submissionService.isRunning || !submissionService.lastOutput.isEmpty || submissionService.lastError != nil {
                VStack(alignment: .leading, spacing: 4) {
                  if let error = submissionService.lastError {
                    Text("Error: \(error)")
                      .font(.caption)
                      .foregroundColor(.red)
                  }
                  if submissionService.isRunning || !submissionService.lastOutput.isEmpty {
                    Text("Output:")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    ScrollViewReader { proxy in
                      ScrollView {
                        Text(submissionService.lastOutput)
                          .font(.system(.caption, design: .monospaced))
                          .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("outputEnd")
                      }
                      .onChange(of: submissionService.lastOutput) { _, _ in
                        if submissionService.isRunning {
                          proxy.scrollTo("outputEnd", anchor: .bottom)
                        }
                      }
                    }
                    .frame(maxHeight: 150)
                    .padding(4)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                    .cornerRadius(4)
                  }
                }
              }
          }
          .padding(.leading, fieldLabelLeading)
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(isPresented: $showingAddRule) {
        RuleEditor(
            rule: CapExRuleUI(calendarId: appState.availableCalendars.first?.id ?? ""),
            calendars: appState.availableCalendars,
            onSave: { newRule in
                config.rules.append(newRule)
                showingAddRule = false
            },
            onCancel: { showingAddRule = false }
        )
        .padding()
    }
    .sheet(item: $editingRuleId) { ruleId in
        if let index = config.rules.firstIndex(where: { $0.id == ruleId }) {
            RuleEditor(
                rule: config.rules[index],
                calendars: appState.availableCalendars,
                onSave: { updatedRule in
                    config.rules[index] = updatedRule
                    editingRuleId = nil
                },
                onCancel: { editingRuleId = nil }
            )
            .padding()
        }
    }
    .onChange(of: config) { _, newValue in
        saveConfig(newValue)
    }
    .onChange(of: submitConfig) { _, newValue in
        saveSubmitConfig(newValue)
    }
  }
  
  private func saveConfig(_ newValue: CapExConfigUI) {
    if let stored = storedCapEx.first {
        stored.workingTimeCalendarId = newValue.workingTimeCalendarId
        stored.historyDays = newValue.historyDays
        stored.showDaily = newValue.showDaily
        stored.capExPercentage = newValue.capExPercentage
        
        let existingRules = Dictionary(uniqueKeysWithValues: stored.rules.map { ($0.id, $0) })
        var seenIds: Set<UUID> = []
        var newRules: [SDCapExRule] = []
        
        for ruleUI in newValue.rules {
            seenIds.insert(ruleUI.id)
            if let existing = existingRules[ruleUI.id] {
                existing.calendarId = ruleUI.calendarId
                existing.titleFilter = ruleUI.titleFilter
                existing.participantsFilter = ruleUI.participantsFilter
                existing.matchMode = ruleUI.matchMode
                newRules.append(existing)
            } else {
                let newRule = SDCapExRule(
                    id: ruleUI.id,
                    calendarId: ruleUI.calendarId,
                    titleFilter: ruleUI.titleFilter,
                    participantsFilter: ruleUI.participantsFilter,
                    matchMode: ruleUI.matchMode
                )
                newRules.append(newRule)
            }
        }
        
        stored.rules = newRules
        for rule in stored.rules where !seenIds.contains(rule.id) {
           context.delete(rule)
        }
    } else {
        // Create new config
        let rules = newValue.rules.map {
            SDCapExRule(id: $0.id, calendarId: $0.calendarId, titleFilter: $0.titleFilter, participantsFilter: $0.participantsFilter, matchMode: $0.matchMode)
        }
        let newConfig = SDCapExConfig(
            id: newValue.id,
            workingTimeCalendarId: newValue.workingTimeCalendarId,
            historyDays: newValue.historyDays,
            showDaily: newValue.showDaily,
            capExPercentage: newValue.capExPercentage,
            rules: rules
        )
        context.insert(newConfig)
    }
    try? context.save()
    withAnimation {
      showSavedIndicator = true
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      withAnimation {
        showSavedIndicator = false
      }
    }
  }

  private func startEditing(rule: CapExRuleUI) {
      editingRuleId = rule.id
  }
  
  private func deleteRule(_ rule: CapExRuleUI) {
      if let index = config.rules.firstIndex(where: { $0.id == rule.id }) {
          config.rules.remove(at: index)
      }
  }
  
  private func toggleDay(_ day: Weekday) {
    if submitConfig.scheduleDays.contains(day) {
      // Don't allow removing the last day
      if submitConfig.scheduleDays.count > 1 {
        submitConfig.scheduleDays.remove(day)
      }
    } else {
      submitConfig.scheduleDays.insert(day)
    }
  }
  
  private func testScript() async {
    do {
      _ = try await submissionService.executeScript(template: submitConfig.scriptTemplate, config: config, streamOutput: true)
    } catch {
      // Error is already captured in submissionService.lastError
    }
  }
  
  private func submitNow() async {
    do {
      _ = try await submissionService.executeScript(template: submitConfig.scriptTemplate, config: config)
      // Update submission tracking on success
      submitConfig.lastSubmittedAt = Date()
      let calendar = Calendar.current
      let now = Date()
      let currentISOWeek = calendar.component(.weekOfYear, from: now)
      let currentYear = calendar.component(.yearForWeekOfYear, from: now)
      submitConfig.lastSubmittedWeek = currentYear * 100 + currentISOWeek
    } catch {
      // Error is already captured in submissionService.lastError
    }
  }
  
  private func saveSubmitConfig(_ newValue: CapExSubmitConfigUI) {
    if let stored = storedCapEx.first {
      stored.submitScriptTemplate = newValue.scriptTemplate
      stored.submitScheduleEnabled = newValue.scheduleEnabled
      stored.submitScheduleDaysRaw = newValue.scheduleDaysRaw
      stored.submitAfterHour = newValue.scheduleAfterHour
      stored.submitAfterMinute = newValue.scheduleAfterMinute
      stored.lastSubmittedAt = newValue.lastSubmittedAt
      stored.lastSubmittedWeek = newValue.lastSubmittedWeek
    } else {
      // Create a new config record so the submit config is not lost
      let newConfig = SDCapExConfig(
        id: config.id,
        workingTimeCalendarId: config.workingTimeCalendarId,
        historyDays: config.historyDays,
        showDaily: config.showDaily,
        capExPercentage: config.capExPercentage,
        rules: config.rules.map {
          SDCapExRule(id: $0.id, calendarId: $0.calendarId, titleFilter: $0.titleFilter, participantsFilter: $0.participantsFilter, matchMode: $0.matchMode)
        },
        submitScriptTemplate: newValue.scriptTemplate,
        submitScheduleEnabled: newValue.scheduleEnabled,
        submitScheduleDaysRaw: newValue.scheduleDaysRaw,
        submitAfterHour: newValue.scheduleAfterHour,
        submitAfterMinute: newValue.scheduleAfterMinute,
        lastSubmittedAt: newValue.lastSubmittedAt,
        lastSubmittedWeek: newValue.lastSubmittedWeek
      )
      context.insert(newConfig)
    }
    try? context.save()
    withAnimation {
      showSavedIndicator = true
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      withAnimation {
        showSavedIndicator = false
      }
    }
  }
  
  private func sectionHeader(_ title: String) -> some View {
    VStack(alignment: .leading) {
      Text(title.uppercased())
        .font(.caption)
        .fontWeight(.bold)
        .foregroundStyle(.secondary)
      Divider()
    }
  }
}



extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

struct RuleEditor: View {
    @State var rule: CapExRuleUI
    var calendars: [CalendarOption]
    var onSave: (CapExRuleUI) -> Void
    var onCancel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Exclusion Rule").font(.headline)
            
            Form {
                CalendarMenuPicker(
                    title: "Source Calendar",
                    calendars: calendars,
                    selection: $rule.calendarId
                )
                
                Section(header: Text("Filters").font(.caption).foregroundStyle(.secondary)) {
                    TextField("Title Contains", text: Binding(
                        get: { rule.titleFilter ?? "" },
                        set: { rule.titleFilter = $0.isEmpty ? nil : $0 }
                    ))
                    
                    TextField("Participants Contain", text: Binding(
                        get: { rule.participantsFilter ?? "" },
                        set: { rule.participantsFilter = $0.isEmpty ? nil : $0 }
                    ))
                    
                    Picker("Match Mode", selection: $rule.matchMode) {
                        Text("Contains").tag("contains")
                        Text("Exact").tag("exact")
                    }
                }
            }
            .formStyle(.grouped)
            
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Save", action: { onSave(rule) })
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(minWidth: 400, minHeight: 400)
    }
}
