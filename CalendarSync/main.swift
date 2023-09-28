//
//  main.swift
//  CalendarSync
//
//  Created by Tobias Keller on 04.08.23.
//
import Foundation
import EventKit

var finished = false

func checkForEventAccess(andThen f:(()->())? = nil) {
    let status = EKEventStore.authorizationStatus(for:.event)
    print(status.rawValue)
    switch status {
    case .authorized:
        print("[ACCESS] Already Authorized...")
        f?()
        break
    case .fullAccess:
        print("[ACCESS] Already Authorized (Full Access)...")
        f?()
        break
    case .notDetermined:
        print("[ACCESS] Requesting Access...")
        EKEventStore().requestFullAccessToEvents() { ok, err in
            if ok {
                print("[ACCESS] ...Granted")
                DispatchQueue.main.async {
                    f?()
                }
            }
        }
        break
    case .writeOnly:
        print("[ACCESS] Write only. Elevating to full access...")
            
            // You need to prompt the user to upgrade to full access here.
            // You can display a UI element (e.g., a dialog or alert) explaining
            // the need for full access and providing an option for the user to upgrade.
            // When the user chooses to upgrade, call the following method:

            EKEventStore().requestFullAccessToEvents() { granted, error in
                if granted {
                    print("[ACCESS] Upgraded to Full Access")
                    DispatchQueue.main.async {
                        f?()
                    }
                } else if let error = error {
                    // Handle the error, e.g., show an alert to inform the user
                    print("[ACCESS] Error upgrading access: \(error.localizedDescription)")
                }
            }
        break
    case .restricted:
        print("[ACCESS] Restricted...")
        // do nothing
        break
    case .denied:
        // do nothing, or beg the user to authorize us in Settings
        print("[ACCESS] Denied...")
        finished = true
        exit(1)
        break
    default:
    print("[ACCESS] Denied... Unknown Reason:")
    print(status.rawValue)
    fatalError()
    }
}

func getDate(value: Int) -> Date {
    let calendar = Calendar.current
    let date = calendar.date(byAdding: .day, value: value, to: Date())!
    
    return date
}

func fetchEvents(from calendarID: String, daysMinus: Int, daysPlus: Int, completion: @escaping ([EKEvent]?, EKEventStore) -> Void) {
    // Request access to the user's calendar
    checkForEventAccess {
        let eventStore = EKEventStore()
        let calendar = eventStore.calendar(withIdentifier: calendarID)
        if calendar == nil {
            print("[ERROR] Calendar with ID \(calendarID) not found.")
            completion(nil, eventStore)
            return
        }
        
        let startDate = getDate(value: daysMinus * -1)
        let endDate = getDate(value: daysPlus)

        
        // Create a predicate to retrieve all events from the calendar
        // let startDate = Date.distantPast
        // let endDate = Date.distantFuture
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: [calendar!])
        
        // Fetch events matching the predicate
        let events = eventStore.events(matching: predicate)
        
        completion(events, eventStore)
    }
}

func fetchAndPushEvents(calendarId: String, apiUrl: String, daysMinus: Int, daysPlus: Int, notifyOffset: Int?, completion: @escaping () -> Void) {
    fetchEvents(from: calendarId, daysMinus: daysMinus, daysPlus: daysPlus) { events, eventStore in
        if events == nil {
            print("Failed fetching Events")
            completion()
            return
        }

        print("[COPY  ] Copying \(events!.count) Events")

        var mappedEvents = [[String: Any]]()
        for event in events! {
            if notifyOffset != nil, let alarm = event.alarms?.first {
                let currentNotificationOffset = alarm.relativeOffset
                if currentNotificationOffset == -15 * 60 {
                    print("Having Offset of 15 Minutes. Replacing with 5 Minutes.")
                    let updatedAlarm = EKAlarm(relativeOffset: -1.0 * Double (notifyOffset!) * 60)
                    event.removeAlarm(alarm)
                    event.addAlarm(updatedAlarm)
                    
                    // Save the modified event back to the event store
                    do {
                        try eventStore.save(event, span: .thisEvent)
                    } catch {
                        print("Error saving modified event: \(error)")
                    }
                }
            }
            
            print("[COPY  ] - \(event.title ?? "")")
            
            mappedEvents.append(
                [
                    "id": "\(event.eventIdentifier ?? "NO ID")",
                    "title": "\(event.title ?? "No Title")",
                    "startDate": "\(event.startDate!)",
                    "endDate": "\(event.endDate!)",
                    "isAllDay": event.isAllDay,
                    "location": "\(event.location ?? "")",
                    "blocksAvailability": event.availability.rawValue != 0 ? false : true,
                    "hasAttendees": event.hasAttendees
                ]
            )
        }
        
        // Encode the array of objects to JSON data
        let urlString = apiUrl
            print(mappedEvents)
            makePOSTRequest(urlString: urlString, data: mappedEvents) { error in
                if let error = error {
                    print("Error: \(error)")
                } else {
                    print("Request successful")
                }
            }
        
        
        
        print("[COPY  ] All events copied to the target calendar.\n\n")
        completion()
    }
}

func printAllCalendars(completion: @escaping () -> Void) {
    // Request access to the user's calendars
    checkForEventAccess() {
        print("All Calendars:")
    
        let eventStore = EKEventStore()
        let calendars = eventStore.calendars(for: .event)
        
        for calendar in calendars {
            let calendarName = calendar.title
            let calendarID = calendar.calendarIdentifier
            let accountName = calendar.source.title
            print(" -  \(calendarID) | \(calendarName) (\(accountName))")
        }
        completion()
    }
}


func main() {
    let calendarId = ProcessInfo.processInfo.environment["CALENDAR_ID"]
    let apiUrl = ProcessInfo.processInfo.environment["API_URL"]
    let daysMinus = Int(ProcessInfo.processInfo.environment["DAYS_PAST"] ?? "") ?? 2
    let daysPlus = Int(ProcessInfo.processInfo.environment["DAYS_FUTURE"] ?? "") ?? 3
    let notifyOffset = Int(ProcessInfo.processInfo.environment["NOTIFY"] ?? "") ?? 5
    
    print("Tobisk Calendar Copy")
    print("")
    
    if calendarId == nil || calendarId == "" {
        printAllCalendars {
            finished = true
        }
        
        while !finished {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        }
        print("Full Usage:")
        print("Usage: CALENDAR_ID='...' API_URL='...' DAYS_PAST=... DAYS_FUTURE=... NOTIFY=... calendar-sync")
        exit(0)
    }
    
    if apiUrl == nil || apiUrl == "" {
        print("Usage: CALENDAR_ID='...' API_URL='...' DAYS_PAST=... DAYS_FUTURE=... NOTIFY=... calendar-sync")
        exit(-1)
    }
    
    finished = false
    print("\n\n\n")
    
    // Add a delay to wait for access to calendars
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        
        fetchAndPushEvents(calendarId: calendarId!, apiUrl: apiUrl!, daysMinus: daysMinus, daysPlus: daysPlus, notifyOffset: notifyOffset) {
            // This completion block will be called once the synchronization is done.
            finished = true // Set the flag to indicate the completion of the task.
        }
    }

    // Run the command-line application by entering the main RunLoop.
    while !finished {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    }
}

main()
print("Exit.")
