import EventKit
import Foundation
import MysliCore

/// Finds the calendar event a recording belongs to, via EventKit. Reads the
/// calendars already in macOS Calendar (iCloud, Google, Exchange accounts
/// added there), so there is no separate sign-in.
@MainActor
enum CalendarLookup {
    private static let store = EKEventStore()

    static var authorization: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// The event around `date`, asking for Calendar access the first time.
    /// Nil when access is denied, calendar lookup is off, or nothing fits.
    static func meeting(around date: Date) async -> MeetingInfo? {
        guard Config.calendarEnabled() else { return nil }
        switch authorization {
        case .fullAccess:
            break
        case .notDetermined:
            guard await requestAccess() else { return nil }
        default:
            return nil
        }

        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-6 * 3600),
            end: date.addingTimeInterval(3600),
            calendars: nil
        )
        let events = store.events(matching: predicate).filter { $0.status != .canceled }
        let candidates = events.map {
            MeetingMatcher.Candidate(
                start: $0.startDate,
                end: $0.endDate,
                isAllDay: $0.isAllDay,
                attendeeCount: $0.attendees?.count ?? 0
            )
        }
        guard let index = MeetingMatcher.bestMatch(for: date, in: candidates) else { return nil }
        return info(from: events[index])
    }

    /// The completion-handler form: EKEventStore isn't Sendable, so its
    /// async variant can't be awaited from the main actor under Swift 6.
    private static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func info(from event: EKEvent) -> MeetingInfo {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let attendees = (event.attendees ?? [])
            .filter { $0.participantType == .person || $0.participantType == .unknown }
            .map { participant in
                MeetingInfo.Attendee(
                    name: participant.name,
                    email: email(of: participant),
                    is_self: participant.isCurrentUser
                )
            }
        return MeetingInfo(
            title: event.title ?? "Meeting",
            starts_at: iso.string(from: event.startDate),
            ends_at: iso.string(from: event.endDate),
            organizer: event.organizer.flatMap { $0.name ?? email(of: $0) },
            attendees: attendees
        )
    }

    /// Participants carry their address as a mailto: URL.
    private static func email(of participant: EKParticipant) -> String? {
        let url = participant.url
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = url.absoluteString.dropFirst("mailto:".count)
        return address.isEmpty ? nil : String(address).removingPercentEncoding
    }
}

/// calendar.json in a session folder.
enum SessionCalendar {
    static func url(in dir: URL) -> URL {
        dir.appendingPathComponent("calendar.json")
    }

    static func read(from dir: URL) -> MeetingInfo? {
        guard let data = try? Data(contentsOf: url(in: dir)) else { return nil }
        return try? MeetingInfo.decode(from: data)
    }

    static func write(_ info: MeetingInfo, to dir: URL) {
        try? info.jsonData().write(to: url(in: dir), options: .atomic)
    }
}
