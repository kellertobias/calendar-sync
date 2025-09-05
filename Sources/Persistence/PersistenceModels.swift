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

    init(id: UUID, weekdayRaw: String, startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
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

    init(id: UUID, syncConfigId: UUID, sourceEventIdentifier: String, occurrenceDateKey: String, targetEventIdentifier: String, lastUpdated: Date) {
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
    init(id: UUID, syncConfigId: UUID, startedAt: Date, finishedAt: Date, resultRaw: String, levelRaw: String, created: Int, updated: Int, deleted: Int, message: String) {
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

@Model final class SDAppSettings {
    var id: UUID
    var defaultHorizonDays: Int
    var intervalSeconds: Int
    var diagnosticsEnabled: Bool

    init(id: UUID = UUID(), defaultHorizonDays: Int, intervalSeconds: Int, diagnosticsEnabled: Bool) {
        self.id = id
        self.defaultHorizonDays = defaultHorizonDays
        self.intervalSeconds = intervalSeconds
        self.diagnosticsEnabled = diagnosticsEnabled
    }
}



