import SwiftUI
import EventKit

struct CapExSettingsView: View {
  @Binding var config: CapExConfigUI
  @EnvironmentObject var appState: AppState
  
  @State private var showingAddRule = false
  @State private var editingRuleId: UUID?
  
  private let fieldLabelLeading: CGFloat = 16

  var body: some View {
    Form {
      Section(header: sectionHeader("Configuration").padding(.top, 14).padding(.bottom, 4)) {
        VStack(alignment: .leading, spacing: 12) {
            CalendarMenuPicker(
                title: "Working Time Calendar",
                calendars: appState.availableCalendars,
                selection: $config.workingTimeCalendarId
            )
            .padding(.leading, fieldLabelLeading)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("History Period").padding(.horizontal, fieldLabelLeading / 2)
                HStack {
                    Text("\(config.historyDays) days")
                    Spacer()
                    Stepper("", value: $config.historyDays, in: 7...365).labelsHidden()
                }
                .padding(.vertical, 4)
            }
            .padding(.leading, fieldLabelLeading)

            VStack(alignment: .leading, spacing: 4) {
                Text("CapEx Percentage").padding(.horizontal, fieldLabelLeading / 2)
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
            .padding(.leading, fieldLabelLeading)

            Toggle("Show Daily Breakdown", isOn: $config.showDaily)
                .padding(.leading, fieldLabelLeading)
        }
      }
      
      Section(header: sectionHeader("Exclusion Rules").padding(.top, 24).padding(.bottom, 4)) {
          if config.rules.isEmpty {
              Text("No exclusion rules defined.")
                  .foregroundStyle(.secondary)
                  .padding(.leading, fieldLabelLeading)
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
                      }
                      .buttonStyle(.borderless)
                  }
                  .padding(.vertical, 4)
              }
              .onDelete { indexSet in
                  config.rules.remove(atOffsets: indexSet)
              }
          }
        
        Button(action: { showingAddRule = true }) {
            Label("Add Exclusion Rule", systemImage: "plus")
        }
        .padding(.top, 8)
      }
    }
    .padding()
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
  }
  
  private func startEditing(rule: CapExRuleUI) {
      editingRuleId = rule.id
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
