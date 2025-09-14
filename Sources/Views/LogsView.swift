import AppKit
import SwiftData
import SwiftUI

/// Minimal logs view placeholder. Will render future sync logs.
/// Displays recent sync run logs with level filter and export options.
struct LogsView: View {
  @EnvironmentObject var appState: AppState
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \SDSyncRunLog.finishedAt, order: .reverse) private var logs: [SDSyncRunLog]
  @State private var selectedLevel: String = "all"  // all | info | warn | error
  @State private var selectedRunId: UUID? = nil
  @State private var searchText: String = ""
  @State private var showConfirmClear: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Logs").font(.title2).bold()
      if logs.isEmpty {
        Text("No logs yet. Run a sync to see entries.").foregroundStyle(.secondary)
        Spacer()
      } else {
        HStack {
          Picker("Level", selection: $selectedLevel) {
            Text("All").tag("all")
            Text("Info").tag("info")
            Text("Warn").tag("warn")
            Text("Error").tag("error")
          }.pickerStyle(.segmented)
          Spacer()
          Button("Clear Logs", role: .destructive) { showConfirmClear = true }
            .disabled(logs.isEmpty)
          Button("Copy Logs as Text", action: copyLogsAsText)
        }
        .padding(.bottom, 4)

        HStack(spacing: 12) {
          // Left: logs table. Clicking any cell selects the run id.
          Table(filteredLogs()) {
            TableColumn("Finished") { log in
              Text(
                DateFormatter.localizedString(
                  from: log.finishedAt, dateStyle: .short, timeStyle: .short)
              )
              .contentShape(Rectangle())
              .onTapGesture { selectedRunId = log.id }
            }.width(min: 140, ideal: 160)
            TableColumn("Result") { log in
              Text(log.resultRaw.capitalized)
                .foregroundStyle(
                  log.levelRaw == "error" ? .red : (log.levelRaw == "warn" ? .orange : .green)
                )
                .contentShape(Rectangle())
                .onTapGesture { selectedRunId = log.id }
            }.width(min: 80, ideal: 100)
            TableColumn("Level") { log in
              Text(log.levelRaw.uppercased())
                .contentShape(Rectangle())
                .onTapGesture { selectedRunId = log.id }
            }.width(min: 70)
            TableColumn("Created") { log in
              Text("\(log.created)")
                .contentShape(Rectangle())
                .onTapGesture { selectedRunId = log.id }
            }.width(min: 70)
            TableColumn("Updated") { log in
              Text("\(log.updated)")
                .contentShape(Rectangle())
                .onTapGesture { selectedRunId = log.id }
            }.width(min: 70)
            TableColumn("Deleted") { log in
              Text("\(log.deleted)")
                .contentShape(Rectangle())
                .onTapGesture { selectedRunId = log.id }
            }.width(min: 70)
            TableColumn("Message") { log in
              Text(log.message).lineLimit(2)
                .contentShape(Rectangle())
                .onTapGesture { selectedRunId = log.id }
            }
          }
          .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
          .layoutPriority(1)

          Divider()

          // Right: actions for selected run id
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Actions").font(.headline)
              Spacer()
              TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            }
            .padding(.bottom, 4)

            // Sync details for the selected run
            if let runId = selectedRunId, let cfg = syncConfig(forRunId: runId) {
              VStack(alignment: .leading, spacing: 6) {
                Text(cfg.name).font(.subheadline).bold()
                HStack(spacing: 12) {
                  calendarChip(label: "Source", calendarId: cfg.sourceCalendarId)
                  calendarChip(label: "Target", calendarId: cfg.targetCalendarId)
                }
              }
              .padding(.bottom, 6)
              Divider()
            }

            if let runId = selectedRunId, !actionsForRun(runId: runId).isEmpty {
              List(actionsForRun(runId: runId)) { a in
                VStack(alignment: .leading, spacing: 2) {
                  HStack {
                    Text(a.kindRaw.uppercased())
                      .font(.caption)
                      .foregroundStyle(kindColor(a.kindRaw))
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(kindColor(a.kindRaw).opacity(0.12))
                      .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(a.reason).font(.subheadline)
                    Spacer()
                  }
                  if let src = a.sourceTitle {
                    Text("Source: \(src)").foregroundStyle(.secondary)
                  }
                  if let tgt = a.targetTitle {
                    Text("Target: \(tgt)").foregroundStyle(.secondary)
                  }
                  if let calId = a.targetCalendarId, !calId.isEmpty {
                    Text("Target calendar: \(calId)").foregroundStyle(.secondary)
                  }
                  if let evId = a.targetEventIdentifier, !evId.isEmpty {
                    Text("Target event ID: \(evId)").foregroundStyle(.secondary)
                  }
                }
                .padding(.vertical, 4)
              }
              .listStyle(.inset)
              .frame(maxHeight: .infinity)
            } else {
              Text(
                selectedRunId == nil ? "Select a run to view actions" : "No actions for this run"
              )
              .foregroundStyle(.secondary)
              Spacer()
            }
          }
          .frame(width: 400)
          .frame(maxHeight: .infinity)
        }
      }
    }
    .padding()
    .frame(minWidth: 600, minHeight: 400)
    .alert("Clear all logs?", isPresented: $showConfirmClear) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) { clearLogs() }
    } message: {
      Text("This will permanently remove all run and action logs.")
    }
  }

  private func filteredLogs() -> [SDSyncRunLog] {
    guard selectedLevel != "all" else { return logs }
    return logs.filter { $0.levelRaw == selectedLevel }
  }

  private func copyLogsAsText() {
    var sections: [String] = []
    let iso = ISO8601DateFormatter()
    if let runId = selectedRunId,
      let run = filteredLogs().first(where: { $0.id == runId })
    {
      var lines: [String] = []
      lines.append("RUN id=\(run.id.uuidString)")
      lines.append(
        "finishedAt=\(iso.string(from: run.finishedAt)) result=\(run.resultRaw) level=\(run.levelRaw)"
      )
      lines.append("created=\(run.created) updated=\(run.updated) deleted=\(run.deleted)")
      lines.append("message=\(run.message)")
      if let cfg = syncConfig(forRunId: runId) {
        lines.append("configId=\(cfg.id) name=\(cfg.name)")
        lines.append("sourceCalendarId=\(cfg.sourceCalendarId)")
        lines.append("targetCalendarId=\(cfg.targetCalendarId)")
        lines.append("mode=\(cfg.modeRaw) horizonDays=\(cfg.horizonDaysOverride ?? 0)")
      }
      let acts = actionsForRun(runId: runId)
      lines.append("actions.count=\(acts.count)")
      for (idx, a) in acts.enumerated() {
        lines.append("-- action[\(idx)] kind=\(a.kindRaw) reason=\(a.reason)")
        func fmt(_ d: Date?) -> String { d.map { iso.string(from: $0) } ?? "" }
        if let s = a.sourceTitle { lines.append("   sourceTitle=\(s)") }
        if let d = a.sourceStart { lines.append("   sourceStart=\(fmt(d))") }
        if let d = a.sourceEnd { lines.append("   sourceEnd=\(fmt(d))") }
        if let t = a.targetTitle { lines.append("   targetTitle=\(t)") }
        if let d = a.targetStart { lines.append("   targetStart=\(fmt(d))") }
        if let d = a.targetEnd { lines.append("   targetEnd=\(fmt(d))") }
        if let cal = a.targetCalendarId, !cal.isEmpty { lines.append("   targetCalendarId=\(cal)") }
        if let ev = a.targetEventIdentifier, !ev.isEmpty {
          lines.append("   targetEventIdentifier=\(ev)")
        }
      }
      sections.append(lines.joined(separator: "\n"))
    } else {
      let lines = filteredLogs().map { log in
        "[\(log.levelRaw.uppercased())] \(iso.string(from: log.finishedAt)) cfg=\(log.syncConfigId) res=\(log.resultRaw) c/u/d=\(log.created)/\(log.updated)/\(log.deleted) msg=\(log.message)"
      }
      sections.append(lines.joined(separator: "\n"))
    }
    let text = sections.joined(separator: "\n\n")
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
  }

  /// Fetches actions for the selected run id and filters with a simple search query.
  private func actionsForRun(runId: UUID) -> [SDSyncActionLog] {
    let fetch = FetchDescriptor<SDSyncActionLog>(
      predicate: #Predicate { $0.runLogId == runId }
    )
    let items: [SDSyncActionLog] = (try? modelContext.fetch(fetch)) ?? []
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return items }
    let lq = q.lowercased()
    func contains(_ s: String?) -> Bool { (s ?? "").lowercased().contains(lq) }
    return items.filter { a in
      contains(a.kindRaw) || contains(a.reason) || contains(a.sourceTitle)
        || contains(a.targetTitle) || contains(a.targetCalendarId)
        || contains(a.targetEventIdentifier)
    }
  }

  /// Maps action kind to a color used in the UI badge.
  private func kindColor(_ kind: String) -> Color {
    switch kind {
    case "create": return .green
    case "update": return .orange
    case "delete": return .red
    default: return .secondary
    }
  }

  /// Finds the sync config for a given run id.
  private func syncConfig(forRunId runId: UUID) -> SDSyncConfig? {
    guard let run = logs.first(where: { $0.id == runId }) else { return nil }
    let configId = run.syncConfigId
    let fetch = FetchDescriptor<SDSyncConfig>(
      predicate: #Predicate { $0.id == configId }
    )
    return (try? modelContext.fetch(fetch))?.first
  }

  /// Small labeled pill showing a calendar name with its color dot.
  @ViewBuilder private func calendarChip(label: String, calendarId: String) -> some View {
    let option = appState.availableCalendars.first(where: { $0.id == calendarId })
    let name = option?.name ?? calendarId
    let color = option?.colorHex.flatMap(colorFromHex) ?? .secondary
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 10, height: 10)
      Text("\(label): \(name)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.secondary.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  /// Converts a hex color string like "#RRGGBB" to a SwiftUI Color.
  private func colorFromHex(_ hex: String) -> Color {
    var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if hexSanitized.hasPrefix("#") { hexSanitized.removeFirst() }
    guard hexSanitized.count == 6, let rgb = UInt32(hexSanitized, radix: 16) else {
      return .secondary
    }
    let r = Double((rgb & 0xFF0000) >> 16) / 255.0
    let g = Double((rgb & 0x00FF00) >> 8) / 255.0
    let b = Double(rgb & 0x0000FF) / 255.0
    return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
  }

  /// Deletes all logs and associated action rows from the store.
  private func clearLogs() {
    selectedRunId = nil
    // Delete actions first, then run logs.
    let actionFetch = FetchDescriptor<SDSyncActionLog>()
    let runFetch = FetchDescriptor<SDSyncRunLog>()
    let actions: [SDSyncActionLog] = (try? modelContext.fetch(actionFetch)) ?? []
    for action in actions { modelContext.delete(action) }
    let runs: [SDSyncRunLog] = (try? modelContext.fetch(runFetch)) ?? []
    for run in runs { modelContext.delete(run) }
    try? modelContext.save()
  }
}

#Preview {
  LogsView().environmentObject(AppState())
}
