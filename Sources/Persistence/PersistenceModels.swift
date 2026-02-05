import Foundation
import SwiftData

@Model final class SDSyncConfig {
  @Attribute(.unique) var id: UUID
  var name: String
  var sourceCalendarId: String
  var targetCalendarId: String
  var modeRaw: String
  var blockerTitleTemplate: String?
  var horizonDaysOverride: Int?
  var enabled: Bool
  var createdAt: Date
  var updatedAt: Date
  @Relationship(deleteRule: .cascade) var filters: [SDFilterRule]
  @Relationship(deleteRule: .cascade) var timeWindows: [SDTimeWindow]

  init(
    id: UUID,
    name: String,
    sourceCalendarId: String,
    targetCalendarId: String,
    modeRaw: String,
    blockerTitleTemplate: String?,
    horizonDaysOverride: Int?,
    enabled: Bool,
    createdAt: Date,
    updatedAt: Date,
    filters: [SDFilterRule],
    timeWindows: [SDTimeWindow]
  ) {
    self.id = id
    self.name = name
    self.sourceCalendarId = sourceCalendarId
    self.targetCalendarId = targetCalendarId
    self.modeRaw = modeRaw
    self.blockerTitleTemplate = blockerTitleTemplate
    self.horizonDaysOverride = horizonDaysOverride
    self.enabled = enabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.filters = filters
    self.timeWindows = timeWindows
  }
}

@Model final class SDFilterRule {
  var id: UUID
  var typeRaw: String
  var pattern: String
  var caseSensitive: Bool

  init(id: UUID, typeRaw: String, pattern: String, caseSensitive: Bool) {
    self.id = id
    self.typeRaw = typeRaw
    self.pattern = pattern
    self.caseSensitive = caseSensitive
  }
}

@Model final class SDTimeWindow {
  var id: UUID
  var weekdayRaw: String
  var startHour: Int
  var startMinute: Int
  var endHour: Int
  var endMinute: Int

  init(id: UUID, weekdayRaw: String, startHour: Int, startMinute: Int, endHour: Int, endMinute: Int)
  {
    self.id = id
    self.weekdayRaw = weekdayRaw
    self.startHour = startHour
    self.startMinute = startMinute
    self.endHour = endHour
    self.endMinute = endMinute
  }
}

@Model final class SDEventMapping {
  var id: UUID
  var syncConfigId: UUID
  var sourceEventIdentifier: String
  var occurrenceDateKey: String
  var targetEventIdentifier: String
  var lastUpdated: Date

  init(
    id: UUID, syncConfigId: UUID, sourceEventIdentifier: String, occurrenceDateKey: String,
    targetEventIdentifier: String, lastUpdated: Date
  ) {
    self.id = id
    self.syncConfigId = syncConfigId
    self.sourceEventIdentifier = sourceEventIdentifier
    self.occurrenceDateKey = occurrenceDateKey
    self.targetEventIdentifier = targetEventIdentifier
    self.lastUpdated = lastUpdated
  }
}

@Model final class SDSyncRunLog {
  var id: UUID
  var syncConfigId: UUID
  var startedAt: Date
  var finishedAt: Date
  var resultRaw: String
  /// Log level string (e.g., "info", "warn", "error").
  var levelRaw: String
  var created: Int
  var updated: Int
  var deleted: Int
  var message: String

  /// Designated initializer for sync run logs.
  /// - Parameters:
  ///   - levelRaw: Severity of this log entry ("info" for success, "error" for failures).
  init(
    id: UUID, syncConfigId: UUID, startedAt: Date, finishedAt: Date, resultRaw: String,
    levelRaw: String, created: Int, updated: Int, deleted: Int, message: String
  ) {
    self.id = id
    self.syncConfigId = syncConfigId
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.resultRaw = resultRaw
    self.levelRaw = levelRaw
    self.created = created
    self.updated = updated
    self.deleted = deleted
    self.message = message
  }
}

/// Persists a single action performed during a sync run.
/// Why: Enables drill-down from a run log entry to the concrete actions (create/update/delete)
/// that were applied. We persist a lightweight snapshot of relevant fields for clarity.
@Model final class SDSyncActionLog {
  /// Unique identifier of this action log row.
  var id: UUID
  /// Foreign key to the parent `SDSyncRunLog` entry.
  var runLogId: UUID
  /// Action kind serialized as a string: "create", "update", or "delete".
  var kindRaw: String
  /// Human-readable reason describing why this action was proposed/applied.
  var reason: String
  /// Snapshot of the source event's title if available (for create/update).
  var sourceTitle: String?
  /// Snapshot of the source event's start date if available.
  var sourceStart: Date?
  /// Snapshot of the source event's end date if available.
  var sourceEnd: Date?
  /// Snapshot of the target event's title if available (for update/delete).
  var targetTitle: String?
  /// Snapshot of the target event's start date if available.
  var targetStart: Date?
  /// Snapshot of the target event's end date if available.
  var targetEnd: Date?
  /// Identifier of the target calendar for this action (from the config at run time).
  var targetCalendarId: String?
  /// Identifier of the target event if known (after apply or for updates/deletes).
  var targetEventIdentifier: String?
  /// Whether the action appears to have been applied successfully (post-verify).
  /// - Note: Nil when verification was not performed.
  var applied: Bool?
  /// Diagnostic message captured during verification or apply, if any (e.g., error or mismatch).
  var diagnostic: String?

  /// Designated initializer for an action log row.
  /// - Parameters:
  ///   - runLogId: Parent sync run log id this action belongs to.
  ///   - kindRaw: One of "create", "update", "delete".
  ///   - reason: Human-readable explanation for the action.
  ///   - sourceTitle/sourceStart/sourceEnd: Optional source snapshots.
  ///   - targetTitle/targetStart/targetEnd: Optional target snapshots.
  init(
    id: UUID = UUID(),
    runLogId: UUID,
    kindRaw: String,
    reason: String,
    sourceTitle: String?,
    sourceStart: Date?,
    sourceEnd: Date?,
    targetTitle: String?,
    targetStart: Date?,
    targetEnd: Date?,
    targetCalendarId: String? = nil,
    targetEventIdentifier: String? = nil,
    applied: Bool? = nil,
    diagnostic: String? = nil
  ) {
    self.id = id
    self.runLogId = runLogId
    self.kindRaw = kindRaw
    self.reason = reason
    self.sourceTitle = sourceTitle
    self.sourceStart = sourceStart
    self.sourceEnd = sourceEnd
    self.targetTitle = targetTitle
    self.targetStart = targetStart
    self.targetEnd = targetEnd
    self.targetCalendarId = targetCalendarId
    self.targetEventIdentifier = targetEventIdentifier
    self.applied = applied
    self.diagnostic = diagnostic
  }
}

@Model final class SDAppSettings {
  var id: UUID
  var defaultHorizonDays: Int
  var intervalSeconds: Int
  var diagnosticsEnabled: Bool
  var tasksURL: String

  init(
    id: UUID = UUID(), defaultHorizonDays: Int, intervalSeconds: Int, diagnosticsEnabled: Bool,
    tasksURL: String = ""
  ) {
    self.id = id
    self.defaultHorizonDays = defaultHorizonDays
    self.intervalSeconds = intervalSeconds
    self.diagnosticsEnabled = diagnosticsEnabled
    self.tasksURL = tasksURL
  }
}

@Model final class SDCapExConfig {
  @Attribute(.unique) var id: UUID
  var workingTimeCalendarId: String
  var historyDays: Int
  var showDaily: Bool
  var capExPercentage: Int
  @Relationship(deleteRule: .cascade) var rules: [SDCapExRule]
  @Relationship(deleteRule: .cascade) var submissions: [SDCapExSubmission]
  
  // Submission configuration
  var submitScriptTemplate: String
  var submitScheduleEnabled: Bool
  var submitScheduleDaysRaw: String  // Comma-separated weekday names: "monday,tuesday"
  var submitAfterHour: Int
  var submitAfterMinute: Int
  var lastSubmittedAt: Date?
  var lastSubmittedWeek: Int?

  init(
    id: UUID = UUID(),
    workingTimeCalendarId: String,
    historyDays: Int,
    showDaily: Bool,
    capExPercentage: Int = 100,
    rules: [SDCapExRule],
    submissions: [SDCapExSubmission] = [],
    submitScriptTemplate: String = "",
    submitScheduleEnabled: Bool = false,
    submitScheduleDaysRaw: String = "monday",
    submitAfterHour: Int = 10,
    submitAfterMinute: Int = 0,
    lastSubmittedAt: Date? = nil,
    lastSubmittedWeek: Int? = nil
  ) {
    self.id = id
    self.workingTimeCalendarId = workingTimeCalendarId
    self.historyDays = historyDays
    self.showDaily = showDaily
    self.capExPercentage = capExPercentage
    self.rules = rules
    self.submissions = submissions
    self.submitScriptTemplate = submitScriptTemplate
    self.submitScheduleEnabled = submitScheduleEnabled
    self.submitScheduleDaysRaw = submitScheduleDaysRaw
    self.submitAfterHour = submitAfterHour
    self.submitAfterMinute = submitAfterMinute
    self.lastSubmittedAt = lastSubmittedAt
    self.lastSubmittedWeek = lastSubmittedWeek
  }
}


@Model final class SDCapExRule {
  var id: UUID
  var calendarId: String
  var titleFilter: String?
  var participantsFilter: String?
  /// "contains", "exact", etc.
  var matchMode: String

  init(
    id: UUID = UUID(),
    calendarId: String,
    titleFilter: String? = nil,
    participantsFilter: String? = nil,
    matchMode: String = "contains"
  ) {
    self.id = id
    self.calendarId = calendarId
    self.titleFilter = titleFilter
    self.participantsFilter = participantsFilter
    self.matchMode = matchMode
  }
}

@Model final class SDCapExSubmission {
  var id: UUID
  var submittedAt: Date
  /// Unique identifier for the period submitted.
  /// Format: "WEEK-YYYY-WW" (ISO week) or "DAY-YYYY-MM-DD"
  @Attribute(.unique) var periodIdentifier: String
  
  init(id: UUID = UUID(), submittedAt: Date, periodIdentifier: String) {
    self.id = id
    self.submittedAt = submittedAt
    self.periodIdentifier = periodIdentifier
  }
}
