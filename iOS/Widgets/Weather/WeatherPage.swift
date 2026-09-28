import Charts
import CoreLocation
import SwiftUI

/// Current weather, the next 12 hours and 5 days for where the phone is.
/// Open-Meteo instead of WeatherKit: WeatherKit needs a paid developer account.
@MainActor
final class WeatherModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Forecast {
        var place: String?
        var temperature: Double
        var feelsLike: Double
        var wind: Double
        var code: Int
        var isDay: Bool
        var hourly: [(time: Date, temp: Double, code: Int)]
        var daily: [(day: Date, min: Double, max: Double, code: Int)]
        var fetched: Date
    }

    @Published private(set) var forecast: Forecast? = WeatherModel.cache {
        didSet { Self.cache = forecast }
    }
    /// Shared by every weather widget instance (pages, overview tiles): one fetch per 15 minutes.
    private static var cache: Forecast?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var error: String?

    private let manager = CLLocationManager()
    private var location: CLLocation?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        #if DEBUG
        // Demo screenshots shouldn't depend on the network; `--demo-weather` fetches the real forecast.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo"), !args.contains("--demo-weather") { forecast = Self.sample(); return }
        #endif
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        if let forecast, Date().timeIntervalSince(forecast.fetched) < 15 * 60 { return }
        manager.requestLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            self.location = location
            Task { await fetch(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.error = "Couldn't find your location" }
    }

    private func fetch(_ location: CLLocation) async {
        let c = location.coordinate
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(c.latitude)),
            .init(name: "longitude", value: String(c.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "5"),
            .init(name: "wind_speed_unit", value: "ms"),
        ]
        do {
            let (data, _) = try await URLSession.shared.data(from: url.url!)
            let r = try JSONDecoder().decode(OpenMeteo.self, from: data)
            let hourFormatter = DateFormatter()
            hourFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
            hourFormatter.timeZone = TimeZone(identifier: r.timezone)
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.timeZone = hourFormatter.timeZone
            let now = Date()
            let hourly = zip(r.hourly.time, zip(r.hourly.temperature_2m, r.hourly.weather_code))
                .compactMap { t, v -> (Date, Double, Int)? in hourFormatter.date(from: t).map { ($0, v.0, v.1) } }
                .filter { $0.0 > now.addingTimeInterval(-3600) }
                .prefix(12)
            let daily = r.daily.time.indices.compactMap { i -> (Date, Double, Double, Int)? in
                dayFormatter.date(from: r.daily.time[i]).map {
                    ($0, r.daily.temperature_2m_min[i], r.daily.temperature_2m_max[i], r.daily.weather_code[i])
                }
            }
            let place = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Lang.locale).first?.locality
            forecast = Forecast(place: place, temperature: r.current.temperature_2m, feelsLike: r.current.apparent_temperature,
                                wind: r.current.wind_speed_10m, code: r.current.weather_code, isDay: r.current.is_day == 1,
                                hourly: hourly.map { (time: $0.0, temp: $0.1, code: $0.2) },
                                daily: daily.map { (day: $0.0, min: $0.1, max: $0.2, code: $0.3) },
                                fetched: Date())
            error = nil
        } catch {
            self.error = "No weather data"
        }
    }

    #if DEBUG
    /// A mild autumn day in Moscow for demo screenshots.
    private static func sample() -> Forecast {
        let hour = Calendar.current.dateInterval(of: .hour, for: Date())!.start
        let day = Calendar.current.startOfDay(for: Date())
        let temps: [Double] = [10, 11, 12, 12, 13, 12, 11, 10, 9, 8, 8, 7]
        let codes = [2, 2, 1, 1, 2, 3, 3, 61, 61, 3, 2, 2]
        return Forecast(place: "Moscow", temperature: 10.4, feelsLike: 8.1, wind: 3.2, code: 2, isDay: true,
                        hourly: temps.indices.map { (time: hour.addingTimeInterval(Double($0) * 3600), temp: temps[$0], code: codes[$0]) },
                        daily: ([(7, 13, 2), (6, 11, 61), (4, 9, 3), (5, 12, 1), (6, 14, 0)] as [(Double, Double, Int)]).enumerated().map {
                            (day: day.addingTimeInterval(Double($0.offset) * 86400), min: $0.element.0, max: $0.element.1, code: $0.element.2)
                        },
                        fetched: Date())
    }
    #endif

    private struct OpenMeteo: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double
            var apparent_temperature: Double
            var weather_code: Int
            var wind_speed_10m: Double
            var is_day: Int
        }
        struct Hourly: Decodable {
            var time: [String]
            var temperature_2m: [Double]
            var weather_code: [Int]
        }
        struct Daily: Decodable {
            var time: [String]
            var weather_code: [Int]
            var temperature_2m_max: [Double]
            var temperature_2m_min: [Double]
        }
        var timezone: String
        var current: Current
        var hourly: Hourly
        var daily: Daily
    }
}

/// WMO weather codes → SF Symbol + Russian description.
enum WeatherCode {
    static func symbol(_ code: Int, day: Bool = true) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func text(_ code: Int) -> String {
        switch code {
        case 0: L("Clear")
        case 1: L("Mostly clear")
        case 2: L("Partly cloudy")
        case 3: L("Overcast")
        case 45, 48: L("Fog")
        case 51...57: L("Drizzle")
        case 61...67: L("Rain")
        case 71...77: L("Snow")
        case 80...82: L("Showers")
        case 85, 86: L("Snowfall")
        case 95...99: L("Thunderstorm")
        default: "—"
        }
    }
}

struct WeatherPage: View {
    @StateObject private var model = WeatherModel()
    @Environment(\.widgetSize) private var size

    var body: some View {
        Group {
            if let f = model.forecast {
                if size == .full { content(f) } else { compact(f) }
            } else if model.authorization == .denied || model.authorization == .restricted {
                VStack(spacing: 12) {
                    Glyph(systemName: "location.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No access to location").font(.headline)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    if let error = model.error {
                        Glyph(systemName: "cloud.fill").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text(L(error)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry") { model.start() }.buttonStyle(PillButtonStyle())
                    } else {
                        ThemedSpinner()
                        Text("Loading weather…").foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .onAppear { model.start() }
    }

    /// Card version: now, today's range and (with room) the next hours.
    private func compact(_ f: WeatherModel.Forecast) -> some View {
        GeometryReader { geo in
            compactBody(f, wide: size == .medium && geo.size.width > geo.size.height * 1.3)
        }
    }

    private func now(_ f: WeatherModel.Forecast) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(f.place ?? L("Here")).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Glyph(WeatherCode.symbol(f.code, day: f.isDay), multicolor: true)
                    .font(size == .small ? .title2 : .largeTitle)
                Text("\(Int(f.temperature.rounded()))°").font(.system(size: size == .small ? 36 : 48, weight: .light))
            }
            Text(WeatherCode.text(f.code)).font(.caption).lineLimit(1)
            if let today = f.daily.first {
                Text("↓\(Int(today.min.rounded()))°  ↑\(Int(today.max.rounded()))°").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func days(_ f: WeatherModel.Forecast, count: Int) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(f.daily.dropFirst().prefix(count).enumerated()), id: \.offset) { _, d in
                HStack(spacing: 8) {
                    Text(d.day.text(.dateTime.weekday(.abbreviated)).capitalizedFirst)
                        .foregroundStyle(.secondary).lineLimit(1).fixedSize().frame(minWidth: 28, alignment: .leading)
                    Glyph(WeatherCode.symbol(d.code), multicolor: true).frame(width: 22)
                    Spacer(minLength: 0)
                    Text("\(Int(d.min.rounded()))°").foregroundStyle(.secondary)
                    Text("\(Int(d.max.rounded()))°").fontWeight(.medium).lineLimit(1).fixedSize().frame(minWidth: 30, alignment: .trailing)
                }
                .font(.callout.monospacedDigit())
            }
        }
    }

    private func compactBody(_ f: WeatherModel.Forecast, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if wide {
                // A wide half-page card: now on the left, the next days beside it (the right side was empty).
                HStack(alignment: .top, spacing: 20) {
                    now(f)
                    days(f, count: 4).frame(maxWidth: 220)
                }
            } else {
                now(f)
            }
            if size == .small {
                Spacer(minLength: 4)
                // Tall tiles have room for the next hours — as many as fit (8, 6, 4, or none).
                ViewThatFits(in: .vertical) {
                    ForEach([12, 10, 8, 6, 4], id: \.self) { count in
                    VStack(spacing: 5) {
                        ForEach(Array(f.hourly.dropFirst().prefix(count).enumerated()), id: \.offset) { _, h in
                            HStack(spacing: 6) {
                                Text(h.time.hour24).foregroundStyle(.secondary)
                                    .lineLimit(1).fixedSize()
                                Glyph(WeatherCode.symbol(h.code), multicolor: true).frame(width: 20)
                                Spacer(minLength: 0)
                                Text("\(Int(h.temp.rounded()))°").fontWeight(.medium)
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                    }
                    Color.clear.frame(height: 0)
                }
            }
            if size == .medium {
                if !wide {
                // Taller half-page cards: as many days of the week as fit fill the middle.
                ViewThatFits(in: .vertical) {
                    ForEach([5, 3, 2], id: \.self) { days in
                    VStack(spacing: 6) {
                        ForEach(Array(f.daily.dropFirst().prefix(days).enumerated()), id: \.offset) { _, d in
                            HStack(spacing: 8) {
                                Text(d.day.text(.dateTime.weekday(.abbreviated)).capitalizedFirst)
                                    .foregroundStyle(.secondary).lineLimit(1).fixedSize().frame(minWidth: 28, alignment: .leading)
                                Glyph(WeatherCode.symbol(d.code), multicolor: true).frame(width: 22)
                                Spacer(minLength: 0)
                                Text("\(Int(d.min.rounded()))°").foregroundStyle(.secondary)
                                Text("\(Int(d.max.rounded()))°").fontWeight(.medium).lineLimit(1).fixedSize().frame(minWidth: 30, alignment: .trailing)
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    }
                    Color.clear.frame(height: 0)
                }
                .layoutPriority(1) // offered the room before the spacer, so the days actually appear
                }
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    ForEach(Array(f.hourly.prefix(6).enumerated()), id: \.offset) { i, h in
                        VStack(spacing: 3) {
                            Text(i == 0 ? L("Now") : h.time.hour24)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.6) // "Сейчас" in a narrow column: smaller, not "Сейча/с"
                            Glyph(WeatherCode.symbol(h.code), multicolor: true).font(.caption)
                            Text("\(Int(h.temp.rounded()))°").font(.caption.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Whole page: now, the next hours as strip and curve, the week. Lying sideways in two columns.
    private func content(_ f: WeatherModel.Forecast) -> some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.3
            if wide {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 12) {
                        hero(f, big: false)
                        TemperatureCurve(hourly: Array(f.hourly.prefix(25))).frame(maxHeight: .infinity)
                    }
                    ScrollView { DailyList(daily: f.daily) }.pointerScrollable()
                }
                .widgetPadding()
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        hero(f, big: true)
                        hourlyStrip(f)
                        TemperatureCurve(hourly: Array(f.hourly.prefix(25))).frame(height: max(150, geo.size.height - 510)) // the rest of the page
                        DailyList(daily: f.daily)
                    }
                    .frame(minHeight: geo.size.height - 12, alignment: .top)
                    .widgetPadding()
                }
                .pointerScrollable()
            }
        }
    }

    private func hero(_ f: WeatherModel.Forecast, big: Bool) -> some View {
        VStack(spacing: 4) {
            Text(f.place ?? L("Here")).font(.title3.weight(.medium))
            HStack(alignment: .top, spacing: 8) {
                Glyph(WeatherCode.symbol(f.code, day: f.isDay), multicolor: true).font(.system(size: big ? 48 : 34))
                Text("\(Int(f.temperature.rounded()))°").font(.system(size: big ? 80 : 56, weight: .thin))
                    .contentTransition(.numericText())
            }
            Text(WeatherCode.text(f.code)).font(.headline)
            Text("Feels like \(Int(f.feelsLike.rounded()))° · wind \(Int(f.wind.rounded())) m/s")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, big ? 12 : 0)
    }

    private func hourlyStrip(_ f: WeatherModel.Forecast) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(Array(f.hourly.enumerated()), id: \.offset) { i, h in
                    VStack(spacing: 6) {
                        Text(i == 0 ? L("Now") : h.time.hour24)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Glyph(WeatherCode.symbol(h.code), multicolor: true).font(.title3)
                        Text("\(Int(h.temp.rounded()))°").font(.callout.weight(.medium))
                    }
                }
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
    }
}

/// The coming hours as a warm-to-cool temperature curve with the extremes labelled.
private struct TemperatureCurve: View {
    let hourly: [(time: Date, temp: Double, code: Int)]
    @Environment(\.theme) private var theme

    var body: some View {
        let temps = hourly.map(\.temp)
        let lo = temps.min() ?? 0, hi = temps.max() ?? 1
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Next hours").font(.subheadline.weight(.semibold))
                Spacer()
                Text("↓\(Int(lo.rounded()))°  ↑\(Int(hi.rounded()))°").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if theme.style == .ascii {
                AsciiChart(values: temps, color: theme.text).frame(maxHeight: .infinity)
            } else {
                curve(lo: lo, hi: hi)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
    }

    private func curve(lo: Double, hi: Double) -> some View {
            Chart(Array(hourly.enumerated()), id: \.offset) { i, h in
                AreaMark(x: .value("t", h.time), yStart: .value("lo", lo - 1), yEnd: .value("°", h.temp))
                    .foregroundStyle(LinearGradient(colors: [.orange.opacity(0.35), .cyan.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", h.time), y: .value("°", h.temp))
                    .foregroundStyle(LinearGradient(colors: [.orange, .cyan], startPoint: .top, endPoint: .bottom))
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
                if i == 0 {
                    PointMark(x: .value("t", h.time), y: .value("°", h.temp)).foregroundStyle(.white).symbolSize(40)
                }
            }
            .chartYScale(domain: (lo - 1)...(hi + 1))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                }
            }
    }
}

private struct DailyList: View {
    let daily: [(day: Date, min: Double, max: Double, code: Int)]
    @Environment(\.theme) private var theme
    private var ascii: Bool { theme.style == .ascii }

    var body: some View {
        let lo = daily.map(\.min).min() ?? 0, hi = daily.map(\.max).max() ?? 1
        VStack(spacing: 10) {
            ForEach(Array(daily.enumerated()), id: \.offset) { i, d in
                HStack(spacing: 10) {
                    Text(i == 0 ? L("Today") : d.day.text(.dateTime.weekday(.abbreviated)).capitalizedFirst)
                        .frame(width: 70, alignment: .leading)
                    Glyph(WeatherCode.symbol(d.code), multicolor: true).frame(width: 28)
                    Text("\(Int(d.min.rounded()))°").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    if ascii {
                        AsciiBar(value: (d.max - lo) / max(hi - lo, 1), color: theme.text)
                    } else {
                    GeometryReader { geo in
                        let w = geo.size.width, span = max(hi - lo, 1)
                        Capsule().fill(Color.primary.opacity(0.1))
                            .overlay(alignment: .leading) {
                                Capsule().fill(LinearGradient(colors: [.cyan, .orange], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, w * (d.max - d.min) / span))
                                    .offset(x: w * (d.min - lo) / span)
                            }
                    }
                    .frame(height: 5)
                    }
                    Text("\(Int(d.max.rounded()))°").frame(width: 34, alignment: .trailing)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
    }
}
