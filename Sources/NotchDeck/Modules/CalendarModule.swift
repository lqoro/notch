import SwiftUI
import EventKit
import Observation

@MainActor
@Observable
final class CalendarModule: NotchModule {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var color: Color
    }

    let id = "calendar"
    let title = "Calendar"
    let icon = "calendar"
    let priority = 50

    enum Access { case unknown, granted, denied }
    private(set) var access: Access = .unknown
    private(set) var events: [Item] = []

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?

    func start(state: NotchState) {
        updateAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
    }

    func onEvent(_ event: NotchEvent) { if event == .opened { reload() } }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .denied, .restricted, .writeOnly: access = .denied
        default: access = .unknown
        }
    }

    func requestAccess() {
        Task { @MainActor in
            _ = try? await store.requestFullAccessToEvents()
            updateAccess()
            reload()
        }
    }

    func reload() {
        updateAccess()
        guard access == .granted else { events = []; return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: end, calendars: nil)
        events = store.events(matching: pred)
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map { Item(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Untitled",
                        start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                        color: Color(nsColor: $0.calendar.color ?? .systemBlue)) }
    }

    func expandedView() -> AnyView { AnyView(CalendarView(module: self)) }
}

struct CalendarView: View {
    let module: CalendarModule

    var body: some View {
        switch module.access {
        case .unknown:
            centered("Show upcoming events in the notch", button: "Allow Calendar Access") { module.requestAccess() }
        case .denied:
            centered("Calendar access is off. Enable it in System Settings > Privacy & Security > Calendars.",
                     button: nil, action: {})
        case .granted:
            if module.events.isEmpty {
                centered("No upcoming events", button: nil, action: {})
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(module.events.prefix(4)) { e in
                        HStack(spacing: 10) {
                            Capsule().fill(e.color).frame(width: 4, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(when(e)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func when(_ e: CalendarModule.Item) -> String {
        let f = DateFormatter()
        if e.allDay { f.dateFormat = "EEE d MMM"; return "All day, " + f.string(from: e.start) }
        let cal = Calendar.current
        f.dateFormat = cal.isDateInToday(e.start) ? "h:mm a" : "EEE h:mm a"
        let end = DateFormatter(); end.dateFormat = "h:mm a"
        return f.string(from: e.start) + " - " + end.string(from: e.end)
    }

    private func centered(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar").font(.system(size: 26)).foregroundStyle(.white.opacity(0.4))
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            if let button { Button(button, action: action).buttonStyle(.borderedProminent) }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }
}
