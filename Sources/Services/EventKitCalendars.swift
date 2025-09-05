import Foundation
import EventKit

/// Observable service that discovers calendars via EventKit.
/// Why: Centralize calendar discovery and provide reactive updates to UI pickers.
final class EventKitCalendars: ObservableObject {
    @Published private(set) var calendars: [CalendarOption] = []

    /// Reload calendars if authorized; otherwise clear.
    func reload(authorized: Bool) {
        guard authorized else {
            DispatchQueue.main.async { self.calendars = [] }
            return
        }
        let store = EKEventStore()
        let cals = store.calendars(for: .event)
        func toHex(_ color: CGColor?) -> String? {
            guard let comps = color?.components else { return nil }
            let r = Int(round((comps.count > 0 ? comps[0] : 0) * 255))
            let g = Int(round((comps.count > 1 ? comps[1] : 0) * 255))
            let b = Int(round((comps.count > 2 ? comps[2] : 0) * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        func sourceLabel(for source: EKSource) -> String {
            // Prefer the user-visible source title when present (e.g., "iCloud", "Gmail").
            if !source.title.isEmpty { return source.title }
            // Fall back to a friendly name for the source type.
            switch source.sourceType {
            case .local: return "On My Mac"
            case .calDAV: return "CalDAV"
            case .exchange: return "Exchange"
            case .mobileMe: return "iCloud"
            case .subscribed: return "Subscribed"
            case .birthdays: return "Birthdays"
            @unknown default: return "Other"
            }
        }
        let mapped: [CalendarOption] = cals.map { cal in
            CalendarOption(id: cal.calendarIdentifier,
                           name: cal.title,
                           account: sourceLabel(for: cal.source),
                           isWritable: cal.allowsContentModifications,
                           colorHex: toHex(cal.cgColor))
        }
        DispatchQueue.main.async {
            self.calendars = mapped.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}


