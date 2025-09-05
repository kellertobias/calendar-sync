import SwiftUI
import SwiftData

/// Minimal logs view placeholder. Will render future sync logs.
/// Displays recent sync run logs with level filter and export options.
struct LogsView: View {
    @EnvironmentObject var appState: AppState
    @Query(sort: \SDSyncRunLog.finishedAt, order: .reverse) private var logs: [SDSyncRunLog]
    @State private var selectedLevel: String = "all" // all | info | warn | error

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

                Table(filteredLogs()) {
                    TableColumn("Finished") { log in
                        Text(DateFormatter.localizedString(from: log.finishedAt, dateStyle: .short, timeStyle: .short))
                    }.width(min: 140, ideal: 160)
                    TableColumn("Result") { log in
                        Text(log.resultRaw.capitalized)
                            .foregroundStyle(log.levelRaw == "error" ? .red : (log.levelRaw == "warn" ? .orange : .green))
                    }.width(min: 80, ideal: 100)
                    TableColumn("Level") { log in Text(log.levelRaw.uppercased()) }.width(min: 70)
                    TableColumn("Created") { log in Text("\(log.created)") }.width(min: 70)
                    TableColumn("Updated") { log in Text("\(log.updated)") }.width(min: 70)
                    TableColumn("Deleted") { log in Text("\(log.deleted)") }.width(min: 70)
                    TableColumn("Message") { log in Text(log.message).lineLimit(2) }
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
                "message": log.message
            ] as [String : Any]
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
}

#Preview {
    LogsView().environmentObject(AppState())
}


