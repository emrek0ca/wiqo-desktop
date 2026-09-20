import AppKit
import EventKit
import Foundation

/// Messages, notes, mail, calendar and reminders.
extension MacSystem {
    static func sendMessage(_ payload: MessagePayload) -> RovaError? {
        let recipient = appleScriptLiteral(payload.recipient)
        let body = appleScriptLiteral(payload.body)
        let source = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy \(recipient) of targetService
            send \(body) to targetBuddy
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return RovaError(code: "MESSAGE_UNAVAILABLE", message: "Mesaj gönderme hazırlanamadı.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else { return nil }
        let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == -1743 {
            return RovaError(code: "MESSAGE_PERMISSION_DENIED", message: "Mac'te Wiqo için Messages/Otomasyon izni verilmedi.")
        }
        return RovaError(code: "MESSAGE_SEND_FAILED", message: "Mesaj gönderilemedi.")
    }

    static func createNote(_ payload: NotePayload) -> (data: CommandData?, error: RovaError?) {
        let title = appleScriptLiteral(payload.title)
        // Notes.app bodies are HTML; a plain-text body is wrapped in <div> per line so line breaks
        // survive, and the title is repeated as an <h1> the same way the Notes UI itself does.
        let htmlBody = ([payload.title] + payload.body.components(separatedBy: "\n"))
            .map { "<div>\(htmlEscape($0))</div>" }
            .joined()
        let body = appleScriptLiteral(htmlBody)
        let folderClause: String
        if let folderName = payload.folderName, !folderName.isEmpty {
            folderClause = "make new note at folder \(appleScriptLiteral(folderName)) with properties {name:\(title), body:\(body)}"
        } else {
            folderClause = "make new note with properties {name:\(title), body:\(body)}"
        }
        let source = "tell application \"Notes\" to \(folderClause)"
        guard let script = NSAppleScript(source: source) else {
            return (nil, RovaError(code: "NOTE_UNAVAILABLE", message: "Not oluşturma hazırlanamadı."))
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return (nil, nil) }
        let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == -1743 {
            return (nil, RovaError(code: "NOTE_PERMISSION_DENIED", message: "Mac'te Wiqo için Notes/Otomasyon izni verilmedi."))
        }
        return (nil, RovaError(code: "NOTE_SAVE_FAILED", message: payload.folderName != nil ? "Not kaydedilemedi; klasör adını kontrol edin." : "Not kaydedilemedi."))
    }

    static func sendEmail(_ payload: EmailPayload) -> RovaError? {
        let recipient = appleScriptLiteral(payload.to)
        let subject = appleScriptLiteral(payload.subject)
        let body = appleScriptLiteral(payload.body)
        let source = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:\(subject), content:\(body), visible:false}
            tell newMessage
                make new to recipient at end of to recipients with properties {address:\(recipient)}
                send
            end tell
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return RovaError(code: "EMAIL_UNAVAILABLE", message: "E-posta gönderme hazırlanamadı.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == -1743 {
            return RovaError(code: "EMAIL_PERMISSION_DENIED", message: "Mac'te Wiqo için Mail/Otomasyon izni verilmedi.")
        }
        return RovaError(code: "EMAIL_SEND_FAILED", message: "E-posta gönderilemedi.")
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func listCalendarEvents() async -> (data: CommandData?, error: RovaError?) {
        guard let store = await calendarStore() else {
            return (nil, RovaError(code: "CALENDAR_PERMISSION_DENIED", message: "Takvim erişimi verilmedi."))
        }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 14, to: start) ?? start.addingTimeInterval(14 * 24 * 60 * 60)
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .prefix(100)
            .map(calendarInfo)
        return (.calendarEvents(Array(events)), nil)
    }

    static func createCalendarEvent(_ payload: CalendarEventPayload) async -> (data: CommandData?, error: RovaError?) {
        guard let store = await calendarStore() else {
            return (nil, RovaError(code: "CALENDAR_PERMISSION_DENIED", message: "Takvim erişimi verilmedi."))
        }
        let calendar: EKCalendar?
        if let name = payload.calendarName, !name.isEmpty {
            calendar = store.calendars(for: .event).first { $0.title == name }
        } else {
            calendar = store.defaultCalendarForNewEvents
        }
        guard let calendar else {
            return (nil, RovaError(code: "CALENDAR_NOT_FOUND", message: "Etkinliğin ekleneceği takvim bulunamadı."))
        }
        let event = EKEvent(eventStore: store)
        event.title = payload.title
        event.startDate = payload.startAt
        event.endDate = payload.endAt
        event.calendar = calendar
        event.notes = payload.notes
        event.location = payload.location
        do {
            try store.save(event, span: .thisEvent)
            return (.calendarEvents([calendarInfo(event)]), nil)
        } catch {
            return (nil, RovaError(code: "CALENDAR_SAVE_FAILED", message: "Takvim etkinliği kaydedilemedi."))
        }
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func calendarStore() async -> EKEventStore? {
        let store = EKEventStore()
        let granted = await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
            } else {
                store.requestAccess(to: .event) { granted, _ in continuation.resume(returning: granted) }
            }
        }
        return granted ? store : nil
    }

    private static func calendarInfo(_ event: EKEvent) -> CalendarEventInfo {
        CalendarEventInfo(identifier: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "(Başlıksız)", startAt: event.startDate, endAt: event.endDate, calendarName: event.calendar?.title ?? "Takvim", location: event.location)
    }

    private static func remindersStore() async -> EKEventStore? {
        let store = EKEventStore()
        let granted = await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToReminders { granted, _ in continuation.resume(returning: granted) }
            } else {
                store.requestAccess(to: .reminder) { granted, _ in continuation.resume(returning: granted) }
            }
        }
        return granted ? store : nil
    }

    private static func reminderInfo(_ reminder: EKReminder) -> ReminderInfo {
        var dueAt: Date?
        if let components = reminder.dueDateComponents {
            dueAt = Calendar.current.date(from: components)
        }
        return ReminderInfo(
            identifier: reminder.calendarItemIdentifier,
            title: reminder.title ?? "(Başlıksız)",
            dueAt: dueAt,
            notes: reminder.notes,
            listName: reminder.calendar?.title ?? "Hatırlatıcılar",
            isCompleted: reminder.isCompleted
        )
    }

    /// Lists incomplete reminders due within the next 30 days plus any without a due date,
    /// mirroring how the Reminders app's "Today"/"Scheduled" smart lists read - a plain "all
    /// reminders ever created" dump would be far less useful to the model.
    static func listReminders() async -> (data: CommandData?, error: RovaError?) {
        guard let store = await remindersStore() else {
            return (nil, RovaError(code: "REMINDERS_PERMISSION_DENIED", message: "Hatırlatıcılar erişimi verilmedi."))
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let cutoff = Calendar.current.date(byAdding: .day, value: 30, to: Date())
        // EKReminder isn't Sendable, so it's mapped to the Sendable ReminderInfo before crossing
        // back out of the completion handler rather than after.
        let infos: [ReminderInfo] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let filtered = (reminders ?? [])
                    .filter { reminder in
                        guard let components = reminder.dueDateComponents, let due = Calendar.current.date(from: components) else { return true }
                        return cutoff == nil || due <= cutoff!
                    }
                    .sorted { lhs, rhs in
                        let lhsDue = lhs.dueDateComponents.flatMap(Calendar.current.date(from:)) ?? .distantFuture
                        let rhsDue = rhs.dueDateComponents.flatMap(Calendar.current.date(from:)) ?? .distantFuture
                        return lhsDue < rhsDue
                    }
                    .prefix(100)
                    .map(reminderInfo)
                continuation.resume(returning: Array(filtered))
            }
        }
        return (.reminders(infos), nil)
    }

    static func createReminder(_ payload: ReminderPayload) async -> (data: CommandData?, error: RovaError?) {
        guard let store = await remindersStore() else {
            return (nil, RovaError(code: "REMINDERS_PERMISSION_DENIED", message: "Hatırlatıcılar erişimi verilmedi."))
        }
        let list: EKCalendar?
        if let name = payload.listName, !name.isEmpty {
            list = store.calendars(for: .reminder).first { $0.title == name }
        } else {
            list = store.defaultCalendarForNewReminders()
        }
        guard let list else {
            return (nil, RovaError(code: "REMINDERS_LIST_NOT_FOUND", message: "Hatırlatıcının ekleneceği liste bulunamadı."))
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = payload.title
        reminder.notes = payload.notes
        reminder.calendar = list
        if let dueAt = payload.dueAt {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueAt)
        }
        do {
            try store.save(reminder, commit: true)
            return (.reminders([reminderInfo(reminder)]), nil)
        } catch {
            return (nil, RovaError(code: "REMINDER_SAVE_FAILED", message: "Hatırlatıcı kaydedilemedi."))
        }
    }

    static func completeReminder(_ payload: CompleteReminderPayload) async -> (data: CommandData?, error: RovaError?) {
        guard let store = await remindersStore() else {
            return (nil, RovaError(code: "REMINDERS_PERMISSION_DENIED", message: "Hatırlatıcılar erişimi verilmedi."))
        }
        guard let item = store.calendarItem(withIdentifier: payload.identifier) as? EKReminder else {
            return (nil, RovaError(code: "REMINDER_NOT_FOUND", message: "Hatırlatıcı bulunamadı; listeyi yeniden alıp tekrar dene."))
        }
        item.isCompleted = true
        do {
            try store.save(item, commit: true)
            return (.reminders([reminderInfo(item)]), nil)
        } catch {
            return (nil, RovaError(code: "REMINDER_SAVE_FAILED", message: "Hatırlatıcı güncellenemedi."))
        }
    }
}
