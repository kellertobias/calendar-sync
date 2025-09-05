import Foundation

extension SDSyncConfig {
    static func fromUI(_ ui: SyncConfigUI) -> SDSyncConfig {
        let filterModels = ui.filters.map { SDFilterRule(id: $0.id, typeRaw: $0.type.rawValue, pattern: $0.pattern, caseSensitive: $0.caseSensitive) }
        let twModels = ui.timeWindows.map { tw in
            SDTimeWindow(id: tw.id, weekdayRaw: tw.weekday.rawValue, startHour: tw.start.hour, startMinute: tw.start.minute, endHour: tw.end.hour, endMinute: tw.end.minute)
        }
        return SDSyncConfig(
            id: ui.id,
            name: ui.name,
            sourceCalendarId: ui.sourceCalendarId,
            targetCalendarId: ui.targetCalendarId,
            modeRaw: ui.mode.rawValue,
            blockerTitleTemplate: ui.blockerTitleTemplate,
            horizonDaysOverride: ui.horizonDaysOverride,
            enabled: ui.enabled,
            createdAt: ui.createdAt,
            updatedAt: ui.updatedAt,
            filters: filterModels,
            timeWindows: twModels
        )
    }

    func toUI() -> SyncConfigUI {
        let filtersUI = filters.map { FilterRuleUI(id: $0.id, type: FilterRuleType(rawValue: $0.typeRaw) ?? .includeTitle, pattern: $0.pattern, caseSensitive: $0.caseSensitive) }
        let windowsUI = timeWindows.map { tw in
            TimeWindowUI(id: tw.id, weekday: Weekday(rawValue: tw.weekdayRaw) ?? .monday, start: TimeOfDay(hour: tw.startHour, minute: tw.startMinute), end: TimeOfDay(hour: tw.endHour, minute: tw.endMinute))
        }
        return SyncConfigUI(
            id: id,
            name: name,
            sourceCalendarId: sourceCalendarId,
            targetCalendarId: targetCalendarId,
            mode: SyncMode(rawValue: modeRaw) ?? .blocker,
            blockerTitleTemplate: blockerTitleTemplate,
            horizonDaysOverride: horizonDaysOverride,
            enabled: enabled,
            createdAt: createdAt,
            updatedAt: updatedAt,
            filters: filtersUI,
            timeWindows: windowsUI
        )
    }
}


