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
  private let weekNumberPattern = #"\{\{week_number\}\}"#
  private let startDatePattern = #"\{\{start\s+"([^"]+)"\}\}"#
  private let endDatePattern = #"\{\{end\s+"([^"]+)"\}\}"#

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
  ///   - overrideDate: If set, use this date as the reference implementation "now" for calculating placeholders.
  func submit(template: String, config: CapExConfigUI, periodIdentifier: String, context: ModelContext, overrideDate: Date? = nil) async throws {
      // Execute script
      _ = try await executeScript(template: template, config: config, overrideDate: overrideDate)
      
      // Record success
      recordSubmission(periodIdentifier: periodIdentifier, context: context)
  }

  
  /// Executes the script template with substituted placeholders.
  /// - Parameters:
  ///   - template: The shell script template containing placeholders.
  ///   - config: CapEx configuration for calculating weekly hours.
  ///   - overrideDate: If set, substitutes placeholders relative to this date instead of Date().
  ///   - streamOutput: If true, streams stdout to `lastOutput` in real-time (for test mode).
  /// - Returns: The stdout output from the script.
  /// - Throws: Error if script execution fails.
  func executeScript(template: String, config: CapExConfigUI, overrideDate: Date? = nil, streamOutput: Bool = false) async throws -> String {
    guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SubmissionError.emptyScript
    }

    isRunning = true
    lastError = nil
    lastOutput = ""
    defer { isRunning = false }

    // Substitute placeholders
    let substituted = await substitutePlaceholders(template: template, config: config, overrideDate: overrideDate)
    logger.info("Executing script: \(substituted)")

    do {
      let result = try await runProcess(script: substituted, streamOutput: streamOutput)

      if !streamOutput {
        lastOutput = result.stdout
      }

      if result.exitCode != 0 {
        lastOutput = result.stdout
        let message = "Exit code \(result.exitCode): \(result.stderr)"
        lastError = message
        logger.error("Script failed: \(message)")
        throw SubmissionError.scriptFailed(exitCode: result.exitCode, stderr: result.stderr)
      }

      logger.info("Script completed successfully")
      return result.stdout

    } catch let error as SubmissionError {
      throw error
    } catch {
      let message = error.localizedDescription
      lastError = message
      logger.error("Script execution error: \(message)")
      throw SubmissionError.executionFailed(error)
    }
  }

  /// Result of a process execution.
  private struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int
  }

  /// Runs a script via /bin/sh without blocking the main actor.
  /// Uses `terminationHandler` for non-blocking completion and optionally
  /// `readabilityHandler` for real-time output streaming.
  private func runProcess(script: String, streamOutput: Bool) async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", script]

      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardOutput = outputPipe
      process.standardError = errorPipe

      let accumulator = OutputAccumulator()

      if streamOutput {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
          let data = handle.availableData
          guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
          accumulator.append(text)
          Task { @MainActor [weak self] in
            self?.lastOutput += text
          }
        }
      }

      process.terminationHandler = { [weak self] proc in
        // Stop streaming handler before reading remaining data
        outputPipe.fileHandleForReading.readabilityHandler = nil

        // Read any remaining data from pipes
        let remainingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingText = String(data: remainingData, encoding: .utf8) ?? ""

        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        let stdout: String
        if streamOutput {
          stdout = accumulator.finalize(remaining: remainingText)
          if !remainingText.isEmpty {
            Task { @MainActor [weak self] in
              self?.lastOutput += remainingText
            }
          }
        } else {
          stdout = remainingText
        }

        continuation.resume(returning: ProcessResult(stdout: stdout, stderr: stderr, exitCode: Int(proc.terminationStatus)))
      }

      do {
        try process.run()
      } catch {
        continuation.resume(throwing: SubmissionError.executionFailed(error))
      }
    }
  }
  
  /// Substitutes all placeholders in the template with calculated values.
  /// - Parameters:
  ///   - template: The script template with placeholders.
  ///   - config: CapEx configuration for calculation.
  ///   - overrideDate: If set, this date is treated as "now". Additionally, if provided,
  ///                   any placeholder (regardless of index) will use this date's week/day.
  /// - Returns: The template with placeholders replaced by values.
  func substitutePlaceholders(template: String, config: CapExConfigUI, overrideDate: Date? = nil) async -> String {
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
    
    // If overrideDate is set, we ignore the offset in the template and treat it as offset 0 relative to the overrideDate.
    // Effectively, we map ANY offset found in the template to the calculated value for overrideDate.
    if let overrideDate = overrideDate {
        // Calculate the value for the specific override date
        // Note: weekRange(offset: 0, referenceDate: overrideDate)
        let (start, end) = weekRange(offset: 0, referenceDate: overrideDate)
        let calcResult = await engine.calculate(config: config, start: start, end: end)
        
        // Map ALL found offsets to this single result
        for offset in offsets {
            values[offset] = calcResult.netCapExSeconds
        }
    } else {
        // Default behavior: calculate for each offset relative to current date
        for offset in offsets {
          let (start, end) = weekRange(offset: offset)
          let calcResult = await engine.calculate(config: config, start: start, end: end)
          values[offset] = calcResult.netCapExSeconds
        }
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
    
    // --- Metadata placeholders (week_number, start, end) ---
    // Determine the reference date for metadata.
    // 1. If overrideDate is present, use it.
    // 2. Else, if week_capex matches found, use the offset from the first match relative to now.
    // 3. Else, use now (offset 0).
    var referenceDate: Date
    var referenceOffset: Int = 0
    
    if let override = overrideDate {
        referenceDate = override
    } else {
        // Find first week_capex offset if available
        if let firstOffset = offsets.sorted().first { // Use sorted first or just first? logic implies "use the week from week_capex"
             referenceOffset = firstOffset
             // Calculate date from offset relative to now
             let (start, _) = weekRange(offset: firstOffset) // weekRange uses Date() internally if no ref
             referenceDate = start
        } else {
             referenceDate = Date()
        }
    }
    
    let calendar = Calendar(identifier: .iso8601)
    
    // Replace {{week_number}}
    if let range = result.range(of: weekNumberPattern, options: .regularExpression) {
         let week = calendar.component(.weekOfYear, from: referenceDate)
         result.replaceSubrange(range, with: String(week))
    }
    
    // Replace {{start "FORMAT"}}
    // Since regex replacement with groups needs careful handling in swift strings, we iterate matches manually
    // We re-create regex for start/end because 'result' has changed (capex placeholders replaced)
    
    let replaceDatePlaceholder = { (pattern: String, date: Date) -> Void in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let matches = regex.matches(in: result, options: [], range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result),
                  let formatRange = Range(match.range(at: 1), in: result) else { continue }
            
            let formatString = String(result[formatRange])
            let formatter = DateFormatter()
            formatter.dateFormat = formatString
            let dateString = formatter.string(from: date)
            
            result.replaceSubrange(matchRange, with: dateString)
        }
    }
    
    let (weekStart, weekEnd) = weekRange(offset: 0, referenceDate: referenceDate)
    // Note: weekEnd from weekRange is usually the start of the next week or end of current?
    // weekRange implementation: 
    // let offsetWeekEnd = calendar.date(byAdding: .day, value: 7, to: offsetWeekStart)
    // This effectively gives the START of the next week (7 days later).
    // For "end date" display, users usually expect Sunday (or end of week).
    // Let's assume standard behavior: end date is usually defined as the last day of the week.
    // Subtract 1 second or 1 day depending on desired inclusivity.
    // If format is DD.MM.YYYY, 1 second subtraction gives the previous day effectively.
    let displayEnd = calendar.date(byAdding: .second, value: -1, to: weekEnd) ?? weekEnd
    
    replaceDatePlaceholder(startDatePattern, weekStart)
    replaceDatePlaceholder(endDatePattern, displayEnd)
    
    return result
  }
  
  /// Calculates the start and end dates for an ISO week with the given offset.
  /// - Parameter offset: 0 for current week, -1 for last week, etc.
  /// - Parameter referenceDate: Date to count offset from. Default is now.
  /// - Returns: Tuple of (weekStart, weekEnd) dates.
  func weekRange(offset: Int, referenceDate: Date = Date()) -> (start: Date, end: Date) {
    let calendar = Calendar(identifier: .iso8601)
    
    // Get reference week components
    var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: referenceDate)
    
    // Apply offset
    if let currentWeekStart = calendar.date(from: components) {
      let offsetWeekStart = calendar.date(byAdding: .weekOfYear, value: offset, to: currentWeekStart) ?? currentWeekStart
      let offsetWeekEnd = calendar.date(byAdding: .day, value: 7, to: offsetWeekStart) ?? offsetWeekStart
      return (offsetWeekStart, offsetWeekEnd)
    }
    
    // Fallback
    return (referenceDate, referenceDate)
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

// MARK: - Output Accumulator

/// Thread-safe accumulator for collecting streamed process output from background callbacks.
private final class OutputAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = ""

  func append(_ text: String) {
    lock.lock()
    buffer += text
    lock.unlock()
  }

  func finalize(remaining: String) -> String {
    lock.lock()
    buffer += remaining
    let result = buffer
    lock.unlock()
    return result
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
