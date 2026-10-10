import CoreLocation
import Foundation

/// The weather where the Mac is, for frontends' dashboards. From Open-Meteo (no key), for the place
/// set in Settings, or else where the Mac's public IP address points (city-level; a VPN moves it).
/// Units follow the Mac's region.
struct WeatherNow: Codable, Sendable {
    /// Rounded, in `unit`.
    var temp: Int
    var high: Int
    var low: Int
    /// "F" or "C"
    var unit: String
    /// clear, partly-cloudy, cloudy, fog, drizzle, rain, snow or storm
    var symbol: String
    /// "Partly cloudy"
    var condition: String
    /// false at night, so a frontend can draw a moon instead of a sun
    var isDay: Bool
    /// "Brooklyn"; nil when the lookup doesn't say
    var place: String?
}

actor Weather {
    static let shared = Weather()

    private static let refreshEvery: TimeInterval = 15 * 60
    private static let relocateEvery: TimeInterval = 6 * 60 * 60
    /// After a failure, wait this long before asking again.
    private static let retryAfter: TimeInterval = 2 * 60

    private struct Place {
        var lat: Double
        var lon: Double
        var name: String?
        /// The setting it was found for; empty = from the IP address.
        var query: String
        var at: Date
    }

    private var value: WeatherNow?
    private var fetchedAt: Date?
    private var location: Place?
    private var refreshing = false
    /// Why there's no weather, for Settings.
    private var problem: String?

    init() {
        SettingsStore.shared.observe { _ in Task { await Weather.shared.settingsChanged() } }
    }

    /// The location setting, trimmed.
    private static var query: String {
        SettingsStore.shared.current.weatherPlace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The latest weather, or nil before the first fetch works. Never waits on the network:
    /// a stale value starts a refresh in the background.
    func current() -> WeatherNow? {
        let interval = value == nil ? Self.retryAfter : Self.refreshEvery
        if !refreshing, fetchedAt.map({ Date().timeIntervalSince($0) > interval }) ?? true {
            refreshing = true
            Task { await refresh() }
        }
        return value
    }

    /// One line for Settings: what it's showing, or what went wrong.
    func summary() -> String {
        let now = current()
        if let problem { return problem }
        guard let now else { return refreshing ? "Looking it up…" : "Not yet" }
        let place = location?.name ?? "Here"
        return "\(place), \(now.temp)°\(now.unit) and \(now.condition.lowercased())"
            + (location?.query.isEmpty == true ? " (from your internet connection)" : "")
    }

    private func settingsChanged() {
        guard Self.query != location?.query else { return }
        value = nil
        problem = nil
        fetchedAt = nil
        _ = current()
    }

    private func refresh() async {
        let query = Self.query
        defer {
            refreshing = false
            // the setting changed while this was out: look again on the next call
            if Self.query != query { fetchedAt = nil }
        }
        fetchedAt = Date()
        if location == nil || location?.query != query
            || (query.isEmpty && location.map { Date().timeIntervalSince($0.at) > Self.relocateEvery } == true) {
            if let found = query.isEmpty ? await Self.locate() : await Self.geocode(query) {
                location = found
            } else if !query.isEmpty {
                location = nil
                value = nil
                problem = "Couldn’t find “\(query)”"
                return
            } else if location?.query != "" {
                // no IP location, and the last place was a setting that's since been cleared
                location = nil
            }
        }
        guard let location, location.query == query else {
            problem = "Can’t tell where this Mac is"
            return
        }
        guard var weather = await Self.forecast(lat: location.lat, lon: location.lon) else {
            if value == nil { problem = "Can’t reach the weather service" }
            return
        }
        guard Self.query == query else { return }
        weather.place = location.name
        value = weather
        problem = nil
    }

    private struct IPLocation: Decodable {
        var latitude: Double?
        var longitude: Double?
        var city: String?
    }

    private static func locate() async -> Place? {
        guard let url = URL(string: "https://ipapi.co/json/"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let found = try? JSONDecoder().decode(IPLocation.self, from: data),
              let lat = found.latitude, let lon = found.longitude else { return nil }
        return Place(lat: lat, lon: lon, name: found.city, query: "", at: Date())
    }

    /// "Burlington, VT", "05401", "Paris" -> a place, with Apple's geocoder (no location permission needed).
    private static func geocode(_ query: String) async -> Place? {
        guard let mark = try? await CLGeocoder().geocodeAddressString(query).first,
              let coordinate = mark.location?.coordinate else { return nil }
        return Place(lat: coordinate.latitude, lon: coordinate.longitude, name: mark.locality ?? mark.name ?? query, query: query, at: Date())
    }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double
            var weather_code: Int
            var is_day: Int
        }
        struct Daily: Decodable {
            var temperature_2m_max: [Double]
            var temperature_2m_min: [Double]
        }
        var current: Current
        var daily: Daily
    }

    private static func forecast(lat: Double, lon: Double) async -> WeatherNow? {
        let fahrenheit = Locale.current.measurementSystem == .us
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", lat)),
            .init(name: "longitude", value: String(format: "%.3f", lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let f = try? JSONDecoder().decode(Forecast.self, from: data),
              let high = f.daily.temperature_2m_max.first, let low = f.daily.temperature_2m_min.first else { return nil }
        let (symbol, condition) = describe(f.current.weather_code)
        return WeatherNow(
            temp: Int(f.current.temperature_2m.rounded()), high: Int(high.rounded()), low: Int(low.rounded()),
            unit: fahrenheit ? "F" : "C", symbol: symbol, condition: condition, isDay: f.current.is_day == 1, place: nil
        )
    }

    /// WMO weather codes, as Open-Meteo reports them.
    private static func describe(_ code: Int) -> (symbol: String, condition: String) {
        switch code {
        case 0: ("clear", "Clear")
        case 1: ("clear", "Mostly clear")
        case 2: ("partly-cloudy", "Partly cloudy")
        case 3: ("cloudy", "Cloudy")
        case 45, 48: ("fog", "Fog")
        case 51...57: ("drizzle", "Drizzle")
        case 61...67, 80...82: ("rain", code >= 80 ? "Showers" : code == 65 ? "Heavy rain" : "Rain")
        case 71...77, 85, 86: ("snow", "Snow")
        case 95...99: ("storm", "Thunderstorms")
        default: ("cloudy", "Cloudy")
        }
    }
}
