import Foundation

/// Hours a device works, like "Work hours": Monday to Friday, 9 to 5. Saved in settings.json;
/// each paired device and named client follows one, or none (always on).
struct Schedule: Codable, Equatable, Sendable, Identifiable {
    var id = String(UUID().uuidString.prefix(8)).lowercased()
    var name = "New schedule"
    /// Days it starts on, as Calendar weekdays: 1 = Sunday … 7 = Saturday.
    var days: [Int] = [2, 3, 4, 5, 6]
    /// Minutes after midnight. When `end` is earlier than `start` it runs past midnight
    /// into the next day; when they're equal it's all day.
    var start = 9 * 60
    var end = 17 * 60

    static let workHours = Schedule(id: "work", name: "Work hours")

    var allDay: Bool { start == end }

    func isOpen(at date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if allDay { return days.contains(weekday) }
        if start < end { return days.contains(weekday) && minute >= start && minute < end }
        // Overnight: on from `start` on a listed day until `end` the next morning.
        if minute >= start { return days.contains(weekday) }
        if minute < end { return days.contains(weekday == 1 ? 7 : weekday - 1) }
        return false
    }

    /// `date` if it's open then, otherwise the next time it opens. Nil if it never does (no days).
    func nextOpen(after date: Date, calendar: Calendar = .current) -> Date? {
        if isOpen(at: date, calendar: calendar) { return date }
        let today = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  days.contains(calendar.component(.weekday, from: day))
            else { continue }
            let opens = allDay ? day : calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: day)
            if let opens, opens > date { return opens }
        }
        return nil
    }

    /// "Weekdays, 9:00 AM – 5:00 PM"
    var summary: String {
        let hours = allDay ? "all day" : "\(Self.time(start)) – \(Self.time(end))"
        return "\(daysSummary), \(hours)"
    }

    var daysSummary: String {
        let set = Set(days)
        if set.count == 7 { return "Every day" }
        if set.isEmpty { return "No days" }
        if set == [2, 3, 4, 5, 6] { return "Weekdays" }
        if set == [1, 7] { return "Weekends" }
        let names = Calendar.current.shortWeekdaySymbols
        return Self.weekOrder.filter(set.contains).map { names[$0 - 1] }.joined(separator: ", ")
    }

    /// Weekdays in the order this Mac's calendar shows them (Sunday or Monday first).
    static var weekOrder: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    static func time(_ minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// Why a caller can't run anything right now. Sent as `off` in API responses.
struct OffStatus: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// Everything on this Mac is paused.
        case mac
        /// This device or client is paused.
        case device
        /// Outside its schedule.
        case schedule
        /// The Mac isn't on its Wi-Fi place's networks, or can't tell which Wi-Fi it's on.
        case wifi
    }

    var reason: Reason
    /// When it turns back on. Missing when it stays off until someone turns it back on, or until
    /// the Mac is back on the right Wi-Fi.
    var until: Date?
    var message: String
}

enum Availability {
    /// Long enough to mean "until I turn it back on".
    static let indefinitely = Date.distantFuture

    static func isIndefinite(_ date: Date) -> Bool {
        date > Date().addingTimeInterval(100 * 365 * 24 * 3600)
    }

    /// Nil when the caller can run macros now. Pausing the Mac stops everyone. A device's or
    /// client's own pause stops it, and it follows its client's schedule and Wi-Fi place, or else
    /// its device's. `wifi` is only asked when there's a place to check.
    static func check(
        _ caller: Caller?, settings: MacapadSettings, now: Date = Date(),
        wifi: () -> String? = { WiFi.shared.current }
    ) -> OffStatus? {
        let device = caller?.device
        let client = caller?.client

        let macPause = settings.pausedUntil.flatMap { $0 > now ? $0 : nil }
        let ownPause = [device?.pausedUntil, client?.pausedUntil].compactMap { $0 }.filter { $0 > now }.max()
        let scheduleId = client?.scheduleId ?? device?.scheduleId
        let schedule = scheduleId.flatMap { id in settings.schedules.first { $0.id == id } }
        let outsideSchedule = schedule.map { !$0.isOpen(at: now) } ?? false
        let placeId = client?.wifiPlaceId ?? device?.wifiPlaceId
        let place = placeId.flatMap { id in settings.wifiPlaces.first { $0.id == id } }
        let network = place.flatMap { _ in wifi() }
        let awayFromPlace = place.map { !$0.contains(network) } ?? false
        guard macPause != nil || ownPause != nil || outsideSchedule || awayFromPlace else { return nil }

        // On again once every pause is over and the schedule is open. There's no knowing when
        // the Mac will be back on the right Wi-Fi.
        var until: Date?
        let pausesEnd = [macPause, ownPause].compactMap { $0 }.max() ?? now
        if !isIndefinite(pausesEnd), !awayFromPlace {
            until = schedule.map { $0.nextOpen(after: pausesEnd) } ?? pausesEnd
        }

        let when = until.map { "until \(describe($0, now: now))" }
        // A pause says when it ends, even when the Wi-Fi keeps it off after that.
        let pauseWhen = when ?? (isIndefinite(pausesEnd) ? nil : "until \(describe(pausesEnd, now: now))")
        if macPause != nil {
            let name = settings.displayName
            return OffStatus(reason: .mac, until: until, message: pauseWhen.map { "\(name) is paused \($0)" }
                ?? "\(name) is paused. Turn it back on from the Mac’s menu bar.")
        }
        let who = client?.name ?? device?.name ?? "This device"
        if ownPause != nil {
            return OffStatus(reason: .device, until: until, message: pauseWhen.map { "\(who) is paused \($0)" }
                ?? "\(who) is paused. Turn it back on in Macapad’s settings on the Mac.")
        }
        if let place, awayFromPlace {
            let blind = network != nil || WiFi.shared.access == .allowed ? ""
                : " Macapad can’t see which Wi-Fi the Mac is on. Allow Location for Macapad in System Settings."
            return OffStatus(reason: .wifi, until: nil, message: "\(who) only works on \(place.label).\(blind)")
        }
        let name = schedule?.name ?? "its schedule"
        return OffStatus(reason: .schedule, until: until, message: when.map { "Outside \(name). \(who) is off \($0)" }
            ?? "Outside \(name). \(who) is off.")
    }

    /// "5:00 PM", "tomorrow at 9:00 AM", "Monday at 9:00 AM" or "Oct 20 at 9:00 AM".
    static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        if date < now.addingTimeInterval(6 * 24 * 3600) {
            return "\(date.formatted(.dateTime.weekday(.wide))) at \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }

    /// "tomorrow at 9:00 AM" or "you turn it back on", to follow "until".
    static func describeUntil(_ date: Date, now: Date = Date()) -> String {
        isIndefinite(date) ? "you turn it back on" : describe(date, now: now)
    }

    /// 8 AM tomorrow, for "Until tomorrow morning".
    static func tomorrowMorning(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}
