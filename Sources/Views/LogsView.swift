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
          Button("Export JSON", action: exportJSON)
          Button("Export Text", action: exportText)
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
          .frame(minWidth: 500)

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
                }
                .padding(.vertical, 4)
              }
              .listStyle(.inset)
              // Fixed width keeps the master table fluid while making the detail predictable
              .frame(width: 400)
            } else {
              Text(
                selectedRunId == nil ? "Select a run to view actions" : "No actions for this run"
              )
              .foregroundStyle(.secondary)
              Spacer()
            }
          }
        }
      }
    }
    .padding()
    .frame(minWidth: 600, minHeight: 400)
  }

  private func filteredLogs() -> [SDSyncRunLog] {
    guard selectedLevel != "all" else { return logs }
    return logs.filter { $0.levelRaw == selectedLevel }
  }

  private func exportJSON() {
    let items = filteredLogs().map { log in
      [
        "id": log.id.uuidString,
        "syncConfigId": log.syncConfigId.uuidString,
        "startedAt": ISO8601DateFormatter().string(from: log.startedAt),
        "finishedAt": ISO8601DateFormatter().string(from: log.finishedAt),
        "result": log.resultRaw,
        "level": log.levelRaw,
        "created": log.created,
        "updated": log.updated,
        "deleted": log.deleted,
        "message": log.message,
      ] as [String: Any]
    }
    if let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted]) {
      writeToDownloads(filename: "CalendarSync-Logs.json", data: data)
    }
  }

  private func exportText() {
    let lines = filteredLogs().map { log in
      "[\(log.levelRaw.uppercased())] \(log.finishedAt) cfg=\(log.syncConfigId) res=\(log.resultRaw) c/u/d=\(log.created)/\(log.updated)/\(log.deleted) msg=\(log.message)"
    }
    if let data = lines.joined(separator: "\n").data(using: .utf8) {
      writeToDownloads(filename: "CalendarSync-Logs.txt", data: data)
    }
  }

  private func writeToDownloads(filename: String, data: Data) {
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    if let url = downloads?.appendingPathComponent(filename) {
      try? data.write(to: url)
    }
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
        || contains(a.targetTitle)
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
}

#Preview {
  LogsView().environmentObject(AppState())
}
