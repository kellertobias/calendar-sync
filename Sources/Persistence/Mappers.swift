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

extension SDRuleConfig {
    static func fromUI(_ ui: RuleConfigUI) -> SDRuleConfig {
        let invitation = ui.invitationFilters.map { SDFilterRule(id: $0.id, typeRaw: $0.type.rawValue, pattern: $0.pattern, caseSensitive: $0.caseSensitive) }
        let overlap = ui.overlapFilters.map { SDFilterRule(id: $0.id, typeRaw: $0.type.rawValue, pattern: $0.pattern, caseSensitive: $0.caseSensitive) }
        let windows = ui.timeWindows.map { w in
            SDTimeWindow(id: w.id, weekdayRaw: w.weekday.rawValue, startHour: w.start.hour, startMinute: w.start.minute, endHour: w.end.hour, endMinute: w.end.minute)
        }
        return SDRuleConfig(
            id: ui.id,
            name: ui.name,
            watchCalendarId: ui.watchCalendarId,
            actionRaw: ui.action.rawValue,
            enabled: ui.enabled,
            createdAt: ui.createdAt,
            updatedAt: ui.updatedAt,
            invitationFilters: invitation,
            overlapFilters: overlap,
            timeWindows: windows
        )
    }

    func toUI() -> RuleConfigUI {
        let invitation = invitationFilters.map { FilterRuleUI(id: $0.id, type: FilterRuleType(rawValue: $0.typeRaw) ?? .includeTitle, pattern: $0.pattern, caseSensitive: $0.caseSensitive) }
        let overlap = overlapFilters.map { FilterRuleUI(id: $0.id, type: FilterRuleType(rawValue: $0.typeRaw) ?? .includeTitle, pattern: $0.pattern, caseSensitive: $0.caseSensitive) }
        let windows = timeWindows.map { w in
            TimeWindowUI(id: w.id, weekday: Weekday(rawValue: w.weekdayRaw) ?? .monday, start: TimeOfDay(hour: w.startHour, minute: w.startMinute), end: TimeOfDay(hour: w.endHour, minute: w.endMinute))
        }
        return RuleConfigUI(
            id: id,
            name: name,
            watchCalendarId: watchCalendarId,
            action: RuleAction(rawValue: actionRaw) ?? .decline,
            enabled: enabled,
            invitationFilters: invitation,
            overlapFilters: overlap,
            timeWindows: windows,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}


