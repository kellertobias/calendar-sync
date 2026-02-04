import SwiftUI

import EventKit

struct CapExReportView: View {
  @EnvironmentObject var appState: AppState
  @State private var engine = CapExEngine()
  
  @State private var currentDate = Date()
  @State private var result: CapExEngine.CalculationResult?
  @State private var isLoading = false
  
  // View State
  @State private var viewMode: ViewMode = .weekly
  
  enum ViewMode: String, CaseIterable, Identifiable {
    case daily = "Daily"
    case weekly = "Weekly"
    var id: String { rawValue }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Picker("View Mode", selection: $viewMode) {
          ForEach(ViewMode.allCases) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
        
        Spacer()
        
        HStack(spacing: 16) {
            Button(action: previousPeriod) {
                Image(systemName: "chevron.left")
            }
            Text(periodLabel)
                .font(.headline)
                .frame(minWidth: 140, alignment: .center)
            Button(action: nextPeriod) {
                Image(systemName: "chevron.right")
            }
        }
        
        Spacer()
        
        Button(action: { Task { await refresh() } }) {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(isLoading)
      }
      .padding()
      .background(Color(NSColor.controlBackgroundColor))
      
      Divider()
      
      if isLoading {
          ProgressView("Calculating...")
              .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let res = result {
          contentView(res)
      } else {
          ContentUnavailableView("No Data", systemImage: "clock.arrow.circlepath")
      }
    }
    .frame(minWidth: 600, minHeight: 400)
    .task(id: currentDate) { await refresh() }
    .task(id: viewMode) { await refresh() }
    .task(id: appState.capExConfig) { await refresh() }
  }
  
  @ViewBuilder
  private func contentView(_ res: CapExEngine.CalculationResult) -> some View {
      HStack(spacing: 0) {
          // Sidebar Summary
          VStack(spacing: 24) {
              summaryCard(title: "Working Time", seconds: res.totalWorkingSeconds, color: .blue)
              summaryCard(title: "Excluded (OpEx)", seconds: res.totalExcludedSeconds, color: .orange)
              Divider()
              summaryCard(title: "CapEx (Net)", seconds: res.netCapExSeconds, color: .green, large: true)
              
              Spacer()
          }
          .padding()
          .frame(width: 200)
          .background(Color(NSColor.controlBackgroundColor))
          
          Divider()
          
          // Main Content
          List {
              if viewMode == .daily {
                  // If we are in daily mode, we might want to show events or just the day?
                  // Currently the engine provides daily stats in range. 
                  // If viewMode is daily, the range is 1 day.
                  // If viewMode is weekly, the range is 7 days.
                  
                  // Let's iterate over days in the range
                  ForEach(datesInPeriod, id: \.self) { date in
                    dailyRow(date: date, stat: res.dailyStats[Calendar.current.startOfDay(for: date)])
                  }
              } else {
                  ForEach(datesInPeriod, id: \.self) { date in
                    dailyRow(date: date, stat: res.dailyStats[Calendar.current.startOfDay(for: date)])
                  }
              }
          }
      }
  }
  
  private func summaryCard(title: String, seconds: TimeInterval, color: Color, large: Bool = false) -> some View {
      VStack(alignment: .leading) {
          Text(title)
              .font(large ? .headline : .subheadline)
              .foregroundStyle(.secondary)
          HStack {
              Text(formatDuration(seconds))
                  .font(large ? .title : .title3)
                  .bold()
                  .foregroundStyle(color)
              Spacer()
              Button(action: { copyToClipboard(formatDuration(seconds)) }) {
                  Image(systemName: "doc.on.doc")
                      .font(.caption)
              }
              .buttonStyle(.borderless)
              .help("Copy hours")
          }
      }
  }
  
  private func dailyRow(date: Date, stat: CapExEngine.DailyStat?) -> some View {
      HStack {
          VStack(alignment: .leading) {
              Text(date.formatted(date: .abbreviated, time: .omitted))
                  .font(.headline)
              Text(date.formatted(date: .omitted, time: .omitted)) // weekday?
          }
          .frame(width: 100, alignment: .leading)
          
          if let s = stat {
             Spacer()
             VStack(alignment: .trailing) {
                 Text("Work: " + formatDuration(s.workingSeconds))
                    .foregroundStyle(.blue)
                 Text("Excl: " + formatDuration(s.excludedSeconds))
                    .foregroundStyle(.orange)
             }
             .font(.caption)
             
             Text(formatDuration(s.netSeconds))
                 .font(.headline)
                 .foregroundStyle(.green)
                 .frame(width: 80, alignment: .trailing)
          } else {
              Spacer()
              Text("-")
          }
      }
      .padding(.vertical, 4)
  }
  
  // Helpers
  
  private func refresh() async {
      isLoading = true
      defer { isLoading = false }
      
      let calendar = Calendar.current
      let start = calendar.startOfDay(for: periodStart)
      let end: Date
      
      if viewMode == .daily {
          end = calendar.date(byAdding: .day, value: 1, to: start)!
      } else {
          end = calendar.date(byAdding: .day, value: 7, to: start)!
      }
      
      result = await engine.calculate(config: appState.capExConfig, start: start, end: end)
  }
  
  private var periodStart: Date {
      let calendar = Calendar.current
      if viewMode == .daily {
          return currentDate
      } else {
          // Start of week (Monday)
          let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: currentDate)
          return calendar.date(from: components) ?? currentDate
          // Note: Needs locale awareness for start of week, usually Sunday or Monday.
          // Using ISO8601 behavior (Monday) might be better or system default.
          // System default:
          // return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: currentDate)) ?? currentDate
      }
  }
  
  private var periodLabel: String {
      if viewMode == .daily {
          return currentDate.formatted(date: .complete, time: .omitted)
      } else {
          let start = periodStart
          let end = Calendar.current.date(byAdding: .day, value: 6, to: start)!
          let weekOfYear = Calendar.current.component(.weekOfYear, from: start)
          return "Week \(weekOfYear): \(start.formatted(date: .numeric, time: .omitted)) - \(end.formatted(date: .numeric, time: .omitted))"
      }
  }
  
  private var datesInPeriod: [Date] {
      var dates: [Date] = []
      let calendar = Calendar.current
      let start = periodStart
      let count = viewMode == .daily ? 1 : 7
      
      for i in 0..<count {
          if let d = calendar.date(byAdding: .day, value: i, to: start) {
              dates.append(d)
          }
      }
      return dates
  }
  
  private func previousPeriod() {
      if viewMode == .daily {
          currentDate = Calendar.current.date(byAdding: .day, value: -1, to: currentDate) ?? currentDate
      } else {
          currentDate = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: currentDate) ?? currentDate
      }
  }
  
  private func nextPeriod() {
      if viewMode == .daily {
          currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
      } else {
          currentDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: currentDate) ?? currentDate
      }
  }
  
  private func formatDuration(_ seconds: TimeInterval) -> String {
      let hours = seconds / 3600
      return String(format: "%.1fh", hours)
  }
  
  private func copyToClipboard(_ text: String) {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
  }
}
