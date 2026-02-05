import SwiftData
import SwiftUI
import OSLog

/// Service for executing CapEx submission scripts with placeholder substitution.
/// Handles templates like {{week_capex[0]}} for current week, {{week_capex[-1]}} for last week.
@MainActor
final class CapExSubmissionService: ObservableObject {
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CalendarSync", category: "CapExSubmit")
  private let engine = CapExEngine()
  
  /// Last execution output for display in UI.
  @Published var lastOutput: String = ""
  @Published var lastError: String?
  @Published var isRunning: Bool = false
  
  /// Placeholder regex pattern: matches {{week_capex[N]}} where N is an integer (positive or negative).
  private let placeholderPattern = #"\{\{week_capex\[(-?\d+)\]\}\}"#

  // Helper to persist submissions
  private func recordSubmission(periodIdentifier: String, context: ModelContext) {
      let submission = SDCapExSubmission(submittedAt: Date(), periodIdentifier: periodIdentifier)
      
      // Check if already exists?
      // Since periodIdentifier is unique, we might get a collision or we should fetch first.
      // Or we can just insert and let SwiftData upsert if we handled the conflict policy, but unique constraints usually throw errors.
      // Let's do a fetch check.
      let fetch = FetchDescriptor<SDCapExSubmission>(predicate: #Predicate { $0.periodIdentifier == periodIdentifier })
      do {
          if let existing = try context.fetch(fetch).first {
              existing.submittedAt = Date()
          } else {
            context.insert(submission)
            // We need to link this to the config? 
            // Currently submissions are a relationship on SDCapExConfig.
            // But since they are independent records, we can also just rely on checking existence by ID.
            // Linking to config is better for cascade delete.
            let configFetch = FetchDescriptor<SDCapExConfig>()
            if let config = try context.fetch(configFetch).first {
                config.submissions.append(submission)
            }
          }
          try context.save()
      } catch {
          logger.error("Failed to record submission: \(error)")
      }
  }

  /// Executes the script for a specific period (week or day) and records it.
  /// - Parameters:
  ///   - template: Script template
  ///   - config: CapEx Config
  ///   - periodIdentifier: Unique identifier for the period (e.g. "WEEK-2026-06")
  ///   - context: SwiftData context for persistence
  func submit(template: String, config: CapExConfigUI, periodIdentifier: String, context: ModelContext) async throws {
      // Execute script
      _ = try await executeScript(template: template, config: config)
      
      // Record success
      recordSubmission(periodIdentifier: periodIdentifier, context: context)
  }

  
  /// Executes the script template with substituted placeholders.
  /// - Parameters:
  ///   - template: The shell script template containing placeholders.
  ///   - config: CapEx configuration for calculating weekly hours.
  /// - Returns: The stdout output from the script.
  /// - Throws: Error if script execution fails.
  func executeScript(template: String, config: CapExConfigUI) async throws -> String {
    guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SubmissionError.emptyScript
    }
    
    isRunning = true
    lastError = nil
    defer { isRunning = false }
    
    // Substitute placeholders
    let substituted = await substitutePlaceholders(template: template, config: config)
    logger.info("Executing script: \(substituted)")
    
    // Execute via /bin/sh
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", substituted]
    
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    
    do {
      try process.run()
      process.waitUntilExit()
      
      let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      
      let stdout = String(data: outputData, encoding: .utf8) ?? ""
      let stderr = String(data: errorData, encoding: .utf8) ?? ""
      
      if process.terminationStatus != 0 {
        let message = "Exit code \(process.terminationStatus): \(stderr)"
        lastError = message
        lastOutput = stdout
        logger.error("Script failed: \(message)")
        throw SubmissionError.scriptFailed(exitCode: Int(process.terminationStatus), stderr: stderr)
      }
      
      lastOutput = stdout
      logger.info("Script completed successfully")
      return stdout
      
    } catch let error as SubmissionError {
      throw error
    } catch {
      let message = error.localizedDescription
      lastError = message
      logger.error("Script execution error: \(message)")
      throw SubmissionError.executionFailed(error)
    }
  }
  
  /// Substitutes all placeholders in the template with calculated values.
  /// - Parameters:
  ///   - template: The script template with placeholders.
  ///   - config: CapEx configuration for calculation.
  /// - Returns: The template with placeholders replaced by values.
  func substitutePlaceholders(template: String, config: CapExConfigUI) async -> String {
    var result = template
    
    // Find all matches
    guard let regex = try? NSRegularExpression(pattern: placeholderPattern, options: []) else {
      logger.error("Failed to compile placeholder regex")
      return template
    }
    
    let range = NSRange(template.startIndex..., in: template)
    let matches = regex.matches(in: template, options: [], range: range)
    
    // Collect unique offsets to calculate
    var offsets: Set<Int> = []
    for match in matches {
      if let offsetRange = Range(match.range(at: 1), in: template) {
        if let offset = Int(template[offsetRange]) {
          offsets.insert(offset)
        }
      }
    }
    
    // Calculate capex for each offset
    var values: [Int: TimeInterval] = [:]
    for offset in offsets {
      let (start, end) = weekRange(offset: offset)
      let calcResult = await engine.calculate(config: config, start: start, end: end)
      values[offset] = calcResult.netCapExSeconds
    }
    
    // Replace placeholders with values
    for match in matches.reversed() {  // Reverse to maintain string indices
      if let matchRange = Range(match.range, in: result),
         let offsetRange = Range(match.range(at: 1), in: template),
         let offset = Int(template[offsetRange]),
         let seconds = values[offset] {
        let hours = seconds / 3600.0
        let formatted = String(format: "%.1f", hours)
        result.replaceSubrange(matchRange, with: formatted)
      }
    }
    
    return result
  }
  
  /// Calculates the start and end dates for an ISO week with the given offset.
  /// - Parameter offset: 0 for current week, -1 for last week, etc.
  /// - Returns: Tuple of (weekStart, weekEnd) dates.
  func weekRange(offset: Int) -> (start: Date, end: Date) {
    let calendar = Calendar(identifier: .iso8601)
    let now = Date()
    
    // Get current week components
    var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
    
    // Apply offset
    if let currentWeekStart = calendar.date(from: components) {
      let offsetWeekStart = calendar.date(byAdding: .weekOfYear, value: offset, to: currentWeekStart) ?? currentWeekStart
      let offsetWeekEnd = calendar.date(byAdding: .day, value: 7, to: offsetWeekStart) ?? offsetWeekStart
      return (offsetWeekStart, offsetWeekEnd)
    }
    
    // Fallback
    return (now, now)
  }
  
  /// Checks if the script should run based on schedule settings.
  /// - Parameters:
  ///   - submitConfig: The submission configuration with schedule.
  ///   - now: Current time (for testing).
  /// - Returns: True if the script should run now.
  func shouldRunNow(submitConfig: CapExSubmitConfigUI, now: Date = Date()) -> Bool {
    guard submitConfig.scheduleEnabled else { return false }
    guard !submitConfig.scriptTemplate.isEmpty else { return false }
    
    let calendar = Calendar.current
    
    // Check if current weekday is in schedule
    let weekdayComponent = calendar.component(.weekday, from: now)
    let currentWeekday = weekdayFromCalendarComponent(weekdayComponent)
    guard submitConfig.scheduleDays.contains(currentWeekday) else { return false }
    
    // Check if we're after the scheduled time
    let hour = calendar.component(.hour, from: now)
    let minute = calendar.component(.minute, from: now)
    let nowMinutes = hour * 60 + minute
    let scheduleMinutes = submitConfig.scheduleAfterHour * 60 + submitConfig.scheduleAfterMinute
    guard nowMinutes >= scheduleMinutes else { return false }
    
    // Check if we've already submitted this week
    let currentISOWeek = calendar.component(.weekOfYear, from: now)
    let currentYear = calendar.component(.yearForWeekOfYear, from: now)
    let weekKey = currentYear * 100 + currentISOWeek  // Unique key: YYYYWW
    
    if submitConfig.lastSubmittedWeek == weekKey {
      return false  // Already submitted this week
    }
    
    return true
  }
  
  /// Converts Calendar weekday component (1=Sunday) to Weekday enum.
  private func weekdayFromCalendarComponent(_ component: Int) -> Weekday {
    switch component {
    case 1: return .sunday
    case 2: return .monday
    case 3: return .tuesday
    case 4: return .wednesday
    case 5: return .thursday
    case 6: return .friday
    case 7: return .saturday
    default: return .monday
    }
  }

  static func weekIdentifier(for date: Date) -> String {
      let calendar = Calendar(identifier: .iso8601)
      let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
      if let year = components.yearForWeekOfYear, let week = components.weekOfYear {
          return String(format: "WEEK-%04d-%02d", year, week)
      }
      return "WEEK-UNKNOWN"
  }
  
  static func dayIdentifier(for date: Date) -> String {
      let calendar = Calendar.current
      let components = calendar.dateComponents([.year, .month, .day], from: date)
      if let year = components.year, let month = components.month, let day = components.day {
          return String(format: "DAY-%04d-%02d-%02d", year, month, day)
      }
      return "DAY-UNKNOWN"
  }
}

// MARK: - Errors

enum SubmissionError: LocalizedError {
  case emptyScript
  case scriptFailed(exitCode: Int, stderr: String)
  case executionFailed(Error)
  
  var errorDescription: String? {
    switch self {
    case .emptyScript:
      return "Script template is empty"
    case .scriptFailed(let exitCode, let stderr):
      return "Script exited with code \(exitCode): \(stderr)"
    case .executionFailed(let error):
      return "Execution failed: \(error.localizedDescription)"
    }
  }
}

// MARK: - Helper Extensions

extension CapExSubmitConfigUI {
  /// Converts scheduleDays Set to comma-separated string for persistence.
  var scheduleDaysRaw: String {
    scheduleDays.map { $0.rawValue }.sorted().joined(separator: ",")
  }
  
  /// Creates CapExSubmitConfigUI from raw persistence values.
  static func from(
    scriptTemplate: String,
    scheduleEnabled: Bool,
    scheduleDaysRaw: String,
    afterHour: Int,
    afterMinute: Int,
    lastSubmittedAt: Date?,
    lastSubmittedWeek: Int?
  ) -> CapExSubmitConfigUI {
    let days = Set(scheduleDaysRaw.split(separator: ",").compactMap { Weekday(rawValue: String($0)) })
    
    // CRITICAL: Must fallback to default template if stored one is empty.
    // This ensures existing users get the new "Submit Now" functionality / examples
    // without needing to reset their settings. Do not remove this fallback.
    let template = scriptTemplate.isEmpty ? CapExSubmitConfigUI().scriptTemplate : scriptTemplate
    
    return CapExSubmitConfigUI(
      scriptTemplate: template,
      scheduleEnabled: scheduleEnabled,
      scheduleDays: days.isEmpty ? [.monday] : days,
      scheduleAfterHour: afterHour,
      scheduleAfterMinute: afterMinute,
      lastSubmittedAt: lastSubmittedAt,
      lastSubmittedWeek: lastSubmittedWeek
    )
  }
}
